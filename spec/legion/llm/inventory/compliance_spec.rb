# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
rescue LoadError
  nil
end

# P3 C3: Compliance-by-absence — policy enforcement at the single write_lane choke point.
# After P3, write_lane is the only path into Inventory.
# Denied models can never enter the catalog from any source.
RSpec.describe 'Compliance by absence' do
  def build_lane(provider:, model:, type: :inference, tier: nil, instance: :default, **opts)
    resolved_tier = tier || { bedrock: :cloud, anthropic: :frontier, openai: :frontier,
                               vllm: :direct, ollama: :local, mlx: :local,
                               azure_foundry: :cloud, gemini: :cloud }[provider] || :cloud
    {
      id:              "#{resolved_tier}:#{provider}:#{instance}:#{type}:#{model}",
      tier:            resolved_tier,
      provider_family: provider,
      instance_id:     instance,
      model:           model,
      type:            type,
      capabilities:    opts.delete(:capabilities) || [],
      limits:          opts.delete(:limits) || {},
      enabled:         opts.fetch(:enabled, true),
      cost:            opts.delete(:cost) || {}
    }.merge(opts)
  end

  def write_lane(**)
    Legion::LLM::Inventory.write_lane(lane: build_lane(**))
  end

  def invalidate_policy!(provider:)
    Legion::LLM::Inventory.send(:invalidate_policy_sets!, provider: provider)
  end

  context 'model_blacklist' do
    it 'rejects blacklisted model — denied model never enters Inventory' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_blacklist: ['claude-old'] }
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :bedrock, model: 'claude-old')

      expect(Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-old')).to be_nil
    end

    it 'allows non-blacklisted model through the choke point' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_blacklist: ['claude-old'] }
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6')

      expect(Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')).not_to be_nil
    end

    it 'blacklist is provider-scoped — does not block same model name on another provider' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_blacklist: ['claude-sonnet-4-6'] }
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :openai, model: 'claude-sonnet-4-6')

      expect(Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:claude-sonnet-4-6')).not_to be_nil
    end
  end

  context 'model_whitelist (allowlist mode)' do
    it 'rejects a model not on the whitelist' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_whitelist: ['claude-sonnet-4-6'] }
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6')
      write_lane(provider: :bedrock, model: 'claude-old')

      models = Legion::LLM::Inventory.lanes_for(provider: :bedrock).map { it[:model] }
      expect(models).to contain_exactly('claude-sonnet-4-6')
    end

    it 'allows the whitelisted model' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_whitelist: ['claude-sonnet-4-6'] }
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6')

      expect(Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')).not_to be_nil
    end

    # sonnet B5 / G-precedence: whitelist > blacklist
    # If whitelist is set, blacklist is IGNORED — even a model on BOTH lists is admitted.
    it 'whitelist takes precedence over blacklist: model on both lists is admitted' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = {
        model_whitelist: ['claude-sonnet-4-6'],
        model_blacklist: ['claude-sonnet-4-6']
      }
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6')

      expect(Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')).not_to be_nil
    end

    it 'whitelist mode rejects a model on the blacklist that is NOT on the whitelist' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = {
        model_whitelist: ['claude-sonnet-4-6'],
        model_blacklist: ['claude-old']
      }
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :bedrock, model: 'claude-old')
      write_lane(provider: :bedrock, model: 'claude-haiku')

      expect(Legion::LLM::Inventory.lanes_for(provider: :bedrock)).to be_empty
    end
  end

  context 'cross-provider isolation' do
    it 'bedrock blacklist does not affect openai' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_blacklist: ['claude-sonnet-4-6'] }
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :openai, model: 'claude-sonnet-4-6')

      expect(Legion::LLM::Inventory.lane(id: 'frontier:openai:default:inference:claude-sonnet-4-6')).not_to be_nil
    end

    it 'openai whitelist does not affect bedrock' do
      Legion::Settings.loader.settings[:extensions][:llm][:openai] = { model_whitelist: ['gpt-4o'] }
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = {}
      invalidate_policy!(provider: :openai)
      invalidate_policy!(provider: :bedrock)

      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6')

      expect(Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')).not_to be_nil
    end
  end

  context 'settings reload invalidates memoized policy sets' do
    it 'adding a model to blacklist after first write takes effect on next write' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = {}
      invalidate_policy!(provider: :bedrock)
      write_lane(provider: :bedrock, model: 'claude-old', instance: :a)
      expect(Legion::LLM::Inventory.lanes_for(provider: :bedrock)).not_to be_empty

      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_blacklist: ['claude-old'] }
      invalidate_policy!(provider: :bedrock)
      write_lane(provider: :bedrock, model: 'claude-old', instance: :b)

      ids = Legion::LLM::Inventory.lanes_for(provider: :bedrock).map { it[:instance_id] }
      expect(ids).to contain_exactly(:a)
    end
  end

  # NOTE: HealthTracker.deny_model is deleted in SSOT v3. Runtime IAM-deny is expressed
  # as an explicit health: kwarg on write_lane (e.g. from a RoutingSession OutcomeClassifier
  # :access_denied outcome dispatching via Registry). The invariant — denied lane has
  # lane_weight <= 0 and health.denied — is re-expressed against the write_lane path.
  context 'runtime IAM-deny writes health.denied' do
    it 'a denied lane written with health.denied has lane_weight <= 0' do
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :a, model: 'sonnet'),
        health: { circuit_state: :closed, denied: true, available: false, adjustment: 0 }
      )

      lane = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:a:inference:sonnet')
      expect(lane[:health][:denied]).to be true
      expect(lane[:lane_weight]).to be <= 0
    end
  end

  if defined?(Sinatra::Base) && defined?(Legion::LLM::Routes)
    context 'API surface absence — denied model never appears in /api/llm/offerings' do
      let(:test_app) do
        Class.new(Sinatra::Base) do
          set :show_exceptions, false
          set :raise_errors,    false
          set :host_authorization, permitted: :any
          register Legion::LLM::Routes
        end
      end

      def get_json(path)
        Rack::MockRequest.new(test_app).get(path)
      end

      it 'a blacklisted model never appears in /api/llm/offerings' do
        allow(Legion::LLM).to receive(:started?).and_return(true)
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = { model_blacklist: ['gemma-12b'] }
        Legion::LLM::Inventory.send(:invalidate_policy_sets!, provider: :vllm)

        write_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
        write_lane(provider: :vllm, model: 'gemma-31b', tier: :direct)

        response = get_json('/api/llm/offerings')
        body     = Legion::JSON.load(response.body)

        offerings_tree = body[:data][:offerings].values
        lane_list = offerings_tree.flat_map { |providers| providers.values.flat_map { |instances| instances.values.flatten } }
        all_models = lane_list.map { |o| o[:model].to_s }

        expect(all_models).to include('gemma-31b')
        expect(all_models).not_to include('gemma-12b')
      end
    end
  end
end

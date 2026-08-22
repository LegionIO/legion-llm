# frozen_string_literal: true

require 'spec_helper'
begin
  require 'sinatra/base'
rescue LoadError
  nil
end

# Compliance by absence — the registry publishes the FULL provider catalog;
# the §9.5 fail-closed model policy (the SettingsSnapshot specificity
# cascade) is applied at selection and at every display surface, so a
# denied model never appears in the API surface. The A-store write-choke
# policy engine is gone with the Pattern A lane store; these laws are
# pinned against the policy cascade + the display projections.
RSpec.describe 'Compliance by absence', :ssot_v3 do
  before do
    Legion::LLM::Router::SettingsState.reset!
  end

  def policy_for(provider:, model:, instance: 'default')
    activate(provider_family: provider, instance_id: instance,
             drafts: [offering_draft(model: model, tier: :direct, supported: %i[chat])])
    lane = snapshot.lanes_for(instance_key: instance_key(provider_family: provider, instance_id: instance)).first
    Legion::LLM::Router::SettingsState.current.model_policy_for(offering: lane)
  end

  context 'model_blacklist' do
    it 'denies a blacklisted model (substring, case-insensitive)' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_blacklist: ['claude-old'] }
      Legion::LLM::Router::SettingsState.reset!

      policy = policy_for(provider: :bedrock, model: 'claude-old-2')

      expect(policy[:blacklist]).to eq(['claude-old'])
      expect(policy[:whitelist]).to be_empty
    end

    it 'denial is provider-scoped — same model name on another provider is clean' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_blacklist: ['claude-sonnet-4-6'] }
      Legion::LLM::Router::SettingsState.reset!

      policy = policy_for(provider: :openai, model: 'claude-sonnet-4-6')

      expect(policy[:blacklist]).to be_empty
    end
  end

  context 'model_whitelist (allowlist mode)' do
    it 'a nonempty whitelist admits only listed models' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_whitelist: ['claude-sonnet-4-6'] }
      Legion::LLM::Router::SettingsState.reset!

      sonnet_policy = policy_for(provider: :bedrock, model: 'claude-sonnet-4-6')
      old_policy    = policy_for(provider: :bedrock, model: 'claude-old')

      expect(sonnet_policy[:whitelist]).to eq(['claude-sonnet-4-6'])
      expect(old_policy[:whitelist]).to eq(['claude-sonnet-4-6'])
    end

    # §9.5 precedence (shared owner Provider.policy_allows? + every SSOT
    # surface): a matching blacklist ALWAYS denies, even when the whitelist
    # also matches. (The A-store's whitelist-precedence engine is gone.)
    it 'a model on both lists is denied — blacklist always wins' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = {
        model_whitelist: ['claude-sonnet-4-6'],
        model_blacklist: ['claude-sonnet-4-6']
      }
      Legion::LLM::Router::SettingsState.reset!
      activate(provider_family: :bedrock, instance_id: 'default',
               drafts: [offering_draft(model: 'claude-sonnet-4-6', tier: :direct, supported: %i[chat])])
      lane = snapshot.lanes_for(instance_key: instance_key(provider_family: :bedrock, instance_id: 'default')).first

      expect(Legion::LLM::API::Native::Offerings.policy_permits?(lane)).to be(false)
    end
  end

  context 'settings reload picks up new policy' do
    it 'adding a model to the blacklist after the first read takes effect on the next generation' do
      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = {}
      Legion::LLM::Router::SettingsState.reset!
      before_policy = policy_for(provider: :bedrock, model: 'claude-old', instance: 'a')
      expect(before_policy[:blacklist]).to be_empty

      Legion::Settings.loader.settings[:extensions][:llm][:bedrock] = { model_blacklist: ['claude-old'] }
      Legion::LLM::Router::SettingsState.reload!(
        llm_settings:       Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )
      after_policy = policy_for(provider: :bedrock, model: 'claude-old', instance: 'b')
      expect(after_policy[:blacklist]).to eq(['claude-old'])
    end
  end

  context 'display surfaces — a denied model never appears' do
    it 'is absent from the models-route projection (lane_entries)' do
      Legion::Settings.loader.settings[:extensions][:llm][:vllm] = { model_blacklist: ['gemma-12b'] }
      Legion::LLM::Router::SettingsState.reset!
      activate(provider_family: :vllm, instance_id: 'gpu-01',
               drafts: [
                 offering_draft(model: 'gemma-12b', tier: :direct, supported: %i[chat]),
                 offering_draft(model: 'gemma-31b', tier: :direct, supported: %i[chat])
               ])

      models = Legion::LLM::API::Native::Models.lane_entries.map { |e| e[:model] }

      expect(models).to include('gemma-31b')
      expect(models).not_to include('gemma-12b')
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
        # The provider publishes the FULL catalog to the Registry (the
        # registry does not filter by model policy); the display surface
        # applies the §9.5 fail-closed policy. Rebuild the SettingsState
        # snapshot after mutating settings.
        Legion::LLM::Router::SettingsState.reset!
        activate(
          provider_family: :vllm,
          instance_id:     'gpu-01',
          drafts:          [
            offering_draft(model: 'gemma-12b', tier: :direct, supported: %i[chat]),
            offering_draft(model: 'gemma-31b', tier: :direct, supported: %i[chat])
          ]
        )

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

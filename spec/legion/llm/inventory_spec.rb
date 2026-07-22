# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inventory do
  def write_lane(provider:, model:, type: :inference, tier: nil, instance: :default, **opts)
    resolved_tier = tier || { bedrock: :cloud, anthropic: :frontier, openai: :frontier,
                               vllm: :direct, ollama: :local, mlx: :local,
                               azure_foundry: :cloud, gemini: :cloud }[provider] || :cloud
    id = "#{resolved_tier}:#{provider}:#{instance}:#{type}:#{model}"
    described_class.write_lane(lane: {
      id:              id,
      tier:            resolved_tier,
      provider_family: provider,
      instance_id:     instance,
      model:           model,
      type:            type,
      capabilities:    opts.delete(:capabilities) || [],
      limits:          opts.delete(:limits) || {},
      enabled:         opts.fetch(:enabled, true),
      cost:            opts.delete(:cost) || {}
    }.merge(opts))
  end

  it 'builds default inference and embedding offerings from settings' do
    write_lane(provider: :bedrock, model: 'us.anthropic.claude-sonnet-4-6', type: :inference)
    write_lane(provider: :bedrock, model: 'amazon.titan-embed-text-v2:0', type: :embed)

    offerings = described_class.offerings(provider: 'bedrock')

    expect(offerings.map { |o| [o[:model], o[:type]] }).to include(
      ['us.anthropic.claude-sonnet-4-6', :inference],
      ['amazon.titan-embed-text-v2:0', :embed]
    )
    expect(offerings.first).not_to have_key(:api_key)
    expect(offerings.first).not_to have_key(:bearer_token)
  end

  it 'includes discovered vLLM context windows in the shared fleet lane' do
    write_lane(provider: :vllm, model: 'qwen3.6-27b', type: :inference,
               tier: :direct, limits: { context_window: 65_536 })

    offering = described_class.offerings(provider: 'vllm', model: 'qwen3.6-27b').first

    expect(offering[:limits][:context_window]).to eq(65_536)
  end

  it 'filters embedding and inference offerings independently' do
    write_lane(provider: :ollama, model: 'qwen3.6:27b', type: :inference, tier: :local)
    write_lane(provider: :ollama, model: 'nomic-embed-text', type: :embed, tier: :local)

    embed_offerings = described_class.offerings(provider: 'ollama', type: 'embed')
    inference_offerings = described_class.offerings(provider: 'ollama', type: 'inference')

    expect(embed_offerings.map { |o| o[:model] }).to include('nomic-embed-text')
    expect(inference_offerings.map { |o| o[:model] }).to include('qwen3.6:27b')
  end

  it 'includes MLX as a local HTTP provider' do
    write_lane(provider: :mlx, model: 'mlx-community/Qwen3-14B-4bit', type: :inference,
               tier: :local)

    offering = described_class.offerings(provider: 'mlx').first

    expect(offering).to include(tier: :local, model: 'mlx-community/Qwen3-14B-4bit')
  end

  it 'accepts future instance-level configured offerings' do
    write_lane(provider: :bedrock, model: 'claude-sonnet-4-6', type: :inference,
               instance: :bedrock1, limits: { context_window: 200_000 })
    write_lane(provider: :bedrock, model: 'claude-sonnet-4-6', type: :inference,
               instance: :bedrock2, limits: { context_window: 200_000 })
    write_lane(provider: :bedrock, model: 'claude-sonnet-4-7', type: :inference,
               instance: :bedrock2, limits: { context_window: 200_000 })

    offerings = described_class.offerings(provider: 'bedrock', model: 'claude-sonnet-4-6')

    expect(offerings.map { |o| o[:instance_id].to_s }).to contain_exactly('bedrock1', 'bedrock2')
    expect(offerings.map { |o| o[:limits][:context_window] }).to eq([200_000, 200_000])
  end

  it 'normalizes string-keyed settings loaded from JSON' do
    described_class.write_lane(lane: {
                                 id:              'cloud:bedrock:bedrock_east:inference:claude-sonnet-4-6',
                                 tier:            :cloud,
                                 provider_family: :bedrock,
                                 instance_id:     :'bedrock-east',
                                 model:           'claude-sonnet-4-6',
                                 type:            :inference,
                                 capabilities:    %i[chat tools thinking],
                                 limits:          { context_window: 200_000, max_output_tokens: 8192 },
                                 enabled:         true,
                                 cost:            {},
                                 metadata:        { network_boundary: 'corp_lan' },
                                 policy_tags:     ['phi_allowed']
                               })

    offering = described_class.offerings(provider: 'bedrock', instance_id: 'bedrock-east').first

    expect(offering[:model]).to eq('claude-sonnet-4-6')
    expect(offering[:limits]).to include(context_window: 200_000, max_output_tokens: 8192)
    expect(offering[:capabilities]).to contain_exactly(:chat, :tools, :thinking)
    expect(offering[:metadata]).to eq(network_boundary: 'corp_lan')
  end

  it 'exposes expanded offering routing metadata from configured offerings' do
    described_class.write_lane(lane: {
                                 id:                    'direct:vllm:macbook_m4:inference:qwen3-32b',
                                 offering_id:           'vllm:macbook-m4:inference:qwen3-32b',
                                 tier:                  :direct,
                                 provider_family:       :vllm,
                                 instance_id:           :macbook_m4,
                                 model:                 'qwen3-32b',
                                 model_family:          'qwen',
                                 canonical_model_alias: 'qwen3.32b',
                                 type:                  :inference,
                                 capabilities:          %i[chat tools],
                                 limits:                { context_window: 65_536 },
                                 enabled:               true,
                                 cost:                  {},
                                 routing_metadata:      { accelerator: 'mps', boundary: 'local' }
                               })

    offering = described_class.offerings(offering_id: 'vllm:macbook-m4:inference:qwen3-32b').first

    expect(offering).to include(
      model_family:          'qwen',
      canonical_model_alias: 'qwen3.32b',
      routing_metadata:      { accelerator: 'mps', boundary: 'local' }
    )
    expect(offering).not_to have_key(:credentials)
  end

  it 'consumes lex-llm native provider offerings when adapters expose them' do
    described_class.write_lane(lane: {
                                 id:                    'cloud:azure_foundry:eastus:inference:gpt-4o',
                                 offering_id:           'azure:default:inference:gpt-4o',
                                 tier:                  :cloud,
                                 provider_family:       :azure_foundry,
                                 instance_id:           :eastus,
                                 model:                 'gpt-4o',
                                 model_family:          'openai',
                                 canonical_model_alias: 'gpt-4o',
                                 type:                  :inference,
                                 capabilities:          %i[chat tools],
                                 limits:                {},
                                 enabled:               true,
                                 cost:                  {},
                                 routing_metadata:      { deployment: 'gpt4o-prod' }
                               })

    offering = described_class.offerings(provider: 'azure_foundry').first

    expect(offering).to include(
      provider_family:       :azure_foundry,
      model_family:          'openai',
      canonical_model_alias: 'gpt-4o',
      routing_metadata:      { deployment: 'gpt4o-prod' }
    )
    expect(offering).not_to have_key(:credentials)
  end

  it 'attributes native offerings to the registry instance, not the adapter self-reported default' do
    write_lane(provider: :anthropic, model: 'claude-haiku-4-5-20251001', type: :inference,
               tier: :frontier, instance: :primary, capabilities: %i[chat tools])
    write_lane(provider: :anthropic, model: 'claude-haiku-4-5-20251001', type: :inference,
               tier: :frontier, instance: :secondary, capabilities: %i[chat tools])

    offerings = described_class.offerings(provider: 'anthropic')

    expect(offerings.map { |o| o[:instance_id].to_s }).to contain_exactly('primary', 'secondary')
  end

  it 'uses the live store for inventory reads without forcing provider refresh' do
    write_lane(provider: :vllm, model: 'qwen3.6-27b', type: :inference, tier: :direct,
               instance: :apollo)

    offerings = described_class.offerings(provider: 'vllm')

    expect(offerings.map { |o| o[:model] }).to include('qwen3.6-27b')
  end

  it 'reads provider and embedding settings with symbol keys' do
    write_lane(provider: :'bedrock-json', model: 'claude-sonnet-4-6', type: :inference,
               tier: :cloud)
    write_lane(provider: :'bedrock-json', model: 'amazon.titan-embed-text-v2:0', type: :embed,
               tier: :cloud)

    offerings = described_class.offerings(provider: 'bedrock-json')

    expect(offerings.map { |o| [o[:model], o[:type]] }).to include(
      ['claude-sonnet-4-6', :inference],
      ['amazon.titan-embed-text-v2:0', :embed]
    )
  end

  it 'raises programmer errors instead of returning an empty inventory' do
    allow(described_class).to receive(:normalize_filter_hash).and_raise(NoMethodError, 'broken')

    expect do
      described_class.offerings(provider: 'bedrock')
    end.to raise_error(NoMethodError, /broken/)
  end

  it 'logs invalid configured offerings with no model identifier' do
    # The old compose-from-settings path validated missing model identifiers.
    # With the live store, write_lane validates the lane shape on write.
    expect do
      described_class.write_lane(lane: {
                                   id:              '',
                                   tier:            :cloud,
                                   provider_family: :bedrock,
                                   instance_id:     :default,
                                   model:           '',
                                   type:            :inference,
                                   capabilities:    [],
                                   limits:          {},
                                   enabled:         true,
                                   cost:            {}
                                 })
    end.to raise_error(Legion::LLM::InvalidLane)
  end

  describe 'lane range enrichment via instance settings' do
    let(:base_extensions_llm) { Legion::Settings.dig(:extensions, :llm) || {} }

    after do
      Legion::Settings.set_prop(:extensions, Legion::Settings[:extensions].merge(llm: base_extensions_llm))
    end

    def set_vllm_instance_settings(instance_id, cfg)
      existing = Legion::Settings.dig(:extensions, :llm) || {}
      vllm_cfg = (existing[:vllm] || {}).dup
      instances = (vllm_cfg[:instances] || {}).dup
      instances[instance_id] = cfg
      vllm_cfg[:instances] = instances
      Legion::Settings.set_prop(:extensions, Legion::Settings[:extensions].merge(
                                               llm: existing.merge(vllm: vllm_cfg)
                                             ))
    end

    it 'enriches a lane with preferred_min/max_context_tokens from instance settings' do
      set_vllm_instance_settings(:helios_a,
                                 weight:                       100,
                                 preferred_min_context_tokens: 32_000,
                                 preferred_max_context_tokens: 262_000)

      lane = write_lane(provider: :vllm, model: 'qwen', type: :inference,
                        tier: :direct, instance: :helios_a, limits: { context_window: 262_000 })

      expect(lane[:preferred_min_context_tokens]).to eq(32_000)
      expect(lane[:preferred_max_context_tokens]).to eq(262_000)
    end

    it 'leaves the lane untouched when no range keys are in instance settings' do
      set_vllm_instance_settings(:apollo, weight: 100)

      lane = write_lane(provider: :vllm, model: 'qwen', type: :inference,
                        tier: :direct, instance: :apollo, limits: { context_window: 16_000 })

      expect(lane).not_to have_key(:preferred_min_context_tokens)
      expect(lane).not_to have_key(:preferred_max_context_tokens)
    end

    it 'leaves the lane untouched when the provider has no instances key' do
      existing = Legion::Settings.dig(:extensions, :llm) || {}
      Legion::Settings.set_prop(:extensions, Legion::Settings[:extensions].merge(
                                               llm: existing.merge(vllm: { weight: 100 })
                                             ))

      lane = write_lane(provider: :vllm, model: 'qwen', type: :inference,
                        tier: :direct, instance: :default, limits: { context_window: 16_000 })

      expect(lane).not_to have_key(:preferred_min_context_tokens)
      expect(lane).not_to have_key(:preferred_max_context_tokens)
    end

    it 'leaves the lane untouched when the provider has no settings at all' do
      lane = write_lane(provider: :vllm, model: 'qwen', type: :inference,
                        tier: :direct, instance: :unknown, limits: { context_window: 16_000 })

      expect(lane).not_to have_key(:preferred_min_context_tokens)
      expect(lane).not_to have_key(:preferred_max_context_tokens)
    end

    it 'enriches only min when only min is configured' do
      set_vllm_instance_settings(:bigbox,
                                 weight:                       100,
                                 preferred_min_context_tokens: 50_000)

      lane = write_lane(provider: :vllm, model: 'qwen', type: :inference,
                        tier: :direct, instance: :bigbox, limits: { context_window: 262_000 })

      expect(lane[:preferred_min_context_tokens]).to eq(50_000)
      expect(lane).not_to have_key(:preferred_max_context_tokens)
    end
  end
end

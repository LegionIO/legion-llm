# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inventory do
  before do
    allow(Legion::LLM::Discovery).to receive(:discovered_models).and_return([])
  end

  it 'builds default inference and embedding offerings from settings' do
    Legion::Settings[:extensions][:llm][:bedrock] = {
      enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6', region: 'us-east-2'
    }

    offerings = described_class.offerings(provider: 'bedrock')

    expect(offerings.map { |offering| [offering[:model], offering[:type]] }).to include(
      ['us.anthropic.claude-sonnet-4-6', :inference],
      ['amazon.titan-embed-text-v2:0', :embed]
    )
    expect(offerings.first).not_to have_key(:api_key)
    expect(offerings.first).not_to have_key(:bearer_token)
  end

  it 'includes discovered vLLM context windows in the shared fleet lane' do
    Legion::Settings[:extensions][:llm][:vllm] = { enabled: true, default_model: 'qwen3.6-27b', base_url: 'http://localhost:8000/v1' }
    allow(Legion::LLM::Discovery).to receive(:discovered_models).and_return([
                                                                              {
                                                                                model:          'qwen3.6-27b',
                                                                                provider:       :vllm,
                                                                                instance:       :default,
                                                                                context_length: 65_536
                                                                              }
                                                                            ])

    offering = described_class.offerings(provider: 'vllm', model: 'qwen3.6-27b').first

    expect(offering[:limits][:context_window]).to eq(65_536)
    expect(offering[:fleet_lane]).to eq('llm.fleet.inference.qwen3-6-27b.ctx65536')
    expect(offering[:fleet_offering_lane]).to eq('llm.fleet.offering.vllm.qwen3-6-27b.inference')
  end

  it 'filters embedding and inference offerings independently' do
    Legion::Settings[:extensions][:llm][:ollama] = { enabled: true, base_url: 'http://localhost:11434' }
    allow(Legion::LLM::Discovery).to receive(:discovered_models).and_return([
                                                                              { model: 'qwen3.6:27b', provider: :ollama, instance: :default },
                                                                              { model: 'nomic-embed-text', provider: :ollama, instance: :default }
                                                                            ])

    embed_offerings = described_class.offerings(provider: 'ollama', type: 'embed')
    inference_offerings = described_class.offerings(provider: 'ollama', type: 'inference')

    expect(embed_offerings.map { |offering| offering[:model] }).to include('nomic-embed-text')
    expect(inference_offerings.map { |offering| offering[:model] }).to include('qwen3.6:27b')
  end

  it 'includes MLX as a local HTTP provider' do
    Legion::Settings[:extensions][:llm][:mlx] = {
      enabled:       true,
      default_model: 'mlx-community/Qwen3-14B-4bit'
    }

    offering = described_class.offerings(provider: 'mlx').first

    expect(offering).to include(tier: :local, transport: :http, model: 'mlx-community/Qwen3-14B-4bit')
  end

  it 'accepts future instance-level configured offerings' do
    Legion::Settings[:extensions][:llm][:bedrock] = {
      enabled:   true,
      instances: {
        bedrock1: {
          enabled:   true,
          offerings: [
            { model: 'claude-sonnet-4-6', type: :inference, limits: { context_window: '200000' } }
          ]
        },
        bedrock2: {
          enabled:   true,
          offerings: [
            { model: 'claude-sonnet-4-6', type: :inference, limits: { context_window: 200_000 } },
            { model: 'claude-sonnet-4-7', type: :inference, limits: { context_window: 200_000 } }
          ]
        }
      }
    }

    offerings = described_class.offerings(provider: 'bedrock', model: 'claude-sonnet-4-6')

    expect(offerings.map { |offering| offering[:instance_id] }).to contain_exactly('bedrock1', 'bedrock2')
    expect(offerings.map { |offering| offering[:limits][:context_window] }).to eq([200_000, 200_000])
  end

  it 'normalizes string-keyed settings loaded from JSON' do
    Legion::Settings[:extensions][:llm]['bedrock'] = {
      'enabled'   => true,
      'instances' => {
        'bedrock-east' => {
          'enabled'   => true,
          'offerings' => [
            {
              'model'        => 'claude-sonnet-4-6',
              'type'         => 'inference',
              'limits'       => { 'context_window' => '200000', 'max_output_tokens' => '8192' },
              'policy_tags'  => ['phi_allowed'],
              'metadata'     => { 'network_boundary' => 'corp_lan' },
              'capabilities' => %w[chat tools thinking]
            }
          ]
        }
      }
    }

    offering = described_class.offerings(provider: 'bedrock', instance_id: 'bedrock-east').first

    expect(offering[:model]).to eq('claude-sonnet-4-6')
    expect(offering[:limits]).to include(context_window: 200_000, max_output_tokens: 8192)
    expect(offering[:capabilities]).to contain_exactly('chat', 'thinking', 'tools')
    expect(offering[:metadata]).to eq(network_boundary: 'corp_lan')
  end

  it 'exposes expanded offering routing metadata from configured offerings' do
    Legion::Settings[:extensions][:llm][:vllm] = {
      enabled:   true,
      offerings: [
        {
          model:                 'Qwen/Qwen3-32B',
          offering_id:           'vllm:macbook-m4:inference:qwen3-32b',
          model_family:          :qwen,
          canonical_model_alias: 'qwen3.32b',
          provider_instance:     :macbook_m4,
          routing_metadata:      { accelerator: 'mps', boundary: 'local' },
          capabilities:          %i[chat tools],
          limits:                { context_window: 65_536 }
        }
      ]
    }

    offering = described_class.offerings(offering_id: 'vllm:macbook-m4:inference:qwen3-32b').first

    expect(offering).to include(
      id:                    'vllm:macbook-m4:inference:qwen3-32b',
      offering_id:           'vllm:macbook-m4:inference:qwen3-32b',
      model_family:          'qwen',
      canonical_model_alias: 'qwen3.32b',
      provider_instance:     'macbook_m4',
      routing_metadata:      { accelerator: 'mps', boundary: 'local' }
    )
    expect(offering).not_to have_key(:credentials)
  end

  it 'consumes lex-llm native provider offerings when adapters expose them' do
    adapter = double(
      'Adapter',
      offerings: [
        {
          offering_id:           'azure:default:inference:gpt-4o',
          provider_family:       :azure_foundry,
          model_family:          :openai,
          provider_instance:     :eastus,
          model:                 'gpt4o-prod',
          canonical_model_alias: 'gpt-4o',
          usage_type:            :inference,
          routing_metadata:      { deployment: 'gpt4o-prod' },
          credentials:           { api_key: 'secret' },
          capabilities:          %i[chat tools]
        }
      ]
    )
    allow(Legion::LLM::Call::Registry).to receive(:available).and_return([:azure_foundry])
    allow(Legion::LLM::Call::Registry).to receive(:for).with(:azure_foundry).and_return(adapter)

    offering = described_class.offerings(provider: 'azure_foundry').first

    expect(offering).to include(
      offering_id:           'azure:default:inference:gpt-4o',
      provider_family:       'azure_foundry',
      model_family:          'openai',
      provider_instance:     'eastus',
      canonical_model_alias: 'gpt-4o',
      routing_metadata:      { deployment: 'gpt4o-prod' }
    )
    expect(offering).not_to have_key(:credentials)
  end

  it 'reads top-level string-keyed provider and embedding settings' do
    Legion::Settings[:extensions][:llm] = {
      'bedrock-json' => {
        'enabled'       => true,
        'default_model' => 'claude-sonnet-4-6'
      }
    }
    Legion::Settings[:llm]['embedding'] = {
      'provider_models' => { 'bedrock-json' => 'amazon.titan-embed-text-v2:0' }
    }

    offerings = described_class.offerings(provider: 'bedrock-json')

    expect(offerings.map { |offering| [offering[:model], offering[:type]] }).to include(
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
end

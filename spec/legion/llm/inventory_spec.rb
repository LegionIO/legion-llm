# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inventory do
  before do
    allow(Legion::LLM::Discovery::Ollama).to receive(:models).and_return([])
    allow(Legion::LLM::Discovery::Vllm).to receive(:models).and_return([])
  end

  it 'builds default inference and embedding offerings from settings' do
    Legion::Settings[:llm][:providers][:bedrock][:enabled] = true

    offerings = described_class.offerings(provider: 'bedrock')

    expect(offerings.map { |offering| [offering[:model], offering[:type]] }).to include(
      ['us.anthropic.claude-sonnet-4-6', :inference],
      ['amazon.titan-embed-text-v2:0', :embed]
    )
    expect(offerings.first).not_to have_key(:api_key)
    expect(offerings.first).not_to have_key(:bearer_token)
  end

  it 'includes discovered vLLM context windows in the shared fleet lane' do
    Legion::Settings[:llm][:providers][:vllm][:enabled] = true
    allow(Legion::LLM::Discovery::Vllm).to receive(:models).and_return([
                                                                         { id:            'qwen3.6-27b',
                                                                           max_model_len: 65_536 }
                                                                       ])

    offering = described_class.offerings(provider: 'vllm', model: 'qwen3.6-27b').first

    expect(offering[:limits][:context_window]).to eq(65_536)
    expect(offering[:fleet_lane]).to eq('llm.fleet.inference.qwen3-6-27b.ctx65536')
    expect(offering[:fleet_offering_lane]).to eq('llm.fleet.offering.vllm.qwen3-6-27b.inference')
  end

  it 'filters embedding and inference offerings independently' do
    Legion::Settings[:llm][:providers][:ollama][:enabled] = true
    allow(Legion::LLM::Discovery::Ollama).to receive(:models).and_return([
                                                                           { 'name' => 'qwen3.6:27b' },
                                                                           { 'name' => 'nomic-embed-text' }
                                                                         ])

    embed_offerings = described_class.offerings(provider: 'ollama', type: 'embed')
    inference_offerings = described_class.offerings(provider: 'ollama', type: 'inference')

    expect(embed_offerings.map { |offering| offering[:model] }).to include('nomic-embed-text')
    expect(inference_offerings.map { |offering| offering[:model] }).to include('qwen3.6:27b')
  end

  it 'includes MLX as a local HTTP provider' do
    Legion::Settings[:llm][:providers][:mlx] = {
      enabled:       true,
      default_model: 'mlx-community/Qwen3-14B-4bit'
    }

    offering = described_class.offerings(provider: 'mlx').first

    expect(offering).to include(tier: :local, transport: :http, model: 'mlx-community/Qwen3-14B-4bit')
  end

  it 'accepts future instance-level configured offerings' do
    Legion::Settings[:llm][:providers][:bedrock] = {
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
    Legion::Settings[:llm][:providers]['bedrock'] = {
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

  it 'reads top-level string-keyed provider and embedding settings' do
    Legion::Settings[:llm]['providers'] = {
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

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Prompt do
  let(:mock_response) do
    double('Response', content: 'test response', input_tokens: 10, output_tokens: 5,
                       tool_calls: nil, stop_reason: :end_turn, model_id: 'test-model')
  end

  let(:mock_session) do
    session = double('Chat')
    allow(session).to receive(:ask).and_return(mock_response)
    allow(session).to receive(:with_tool)
    allow(session).to receive(:with_instructions)
    allow(session).to receive(:add_message)
    allow(session).to receive(:respond_to?).and_return(false)
    allow(session).to receive(:respond_to?).with(:on_tool_call).and_return(false)
    allow(session).to receive(:respond_to?).with(:on_tool_result).and_return(false)
    session
  end

  before do
    Legion::Settings.reset!
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:default_provider] = :anthropic
    Legion::Settings[:llm][:default_model] = 'claude-sonnet-4-6'
    Legion::Settings[:llm][:pipeline_enabled] = true
    stub_native_provider(content: 'pipeline response')
  end

  describe '.dispatch' do
    context 'when Router resolves via inventory' do
      before do
        Legion::LLM::Inventory.write_lane(lane: {
                                            id: 'cloud:bedrock:default:inference:us.anthropic.claude-sonnet-4-6-v1',
                                            tier: :cloud, provider_family: :bedrock, instance_id: :default,
                                            model: 'us.anthropic.claude-sonnet-4-6-v1', type: :inference
                                          })
      end

      it 'uses the resolved provider and model from inventory' do
        result = described_class.dispatch('Hello', tier: :cloud)
        expect(result).to be_a(Legion::LLM::Inference::Response)
      end
    end

    context 'when no inventory lane is available' do
      it 'falls back to default_provider and default_model' do
        result = described_class.dispatch('Hello')
        expect(result).to be_a(Legion::LLM::Inference::Response)
        expect(result.routing[:provider]).to eq(:anthropic)
        expect(result.routing[:model]).to eq('claude-sonnet-4-6')
      end
    end

    context 'when a caller passes only a provider-inferable model' do
      before do
        allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(false)
        Legion::Settings[:llm][:default_provider] = 'vllm'
        Legion::Settings[:llm][:default_instance] = 'apollo'
        Legion::Settings[:llm][:default_model] = 'qwen3.6-27b'
        # P5: write Inventory lane for gpt-5.4 so the while remaining.positive? loop can dispatch it
        write_test_lane(provider: :openai, model: 'gpt-5.4', tier: :frontier)
      end

      it 'infers the model provider instead of combining it with the default provider' do
        result = described_class.dispatch('Hello', model: 'gpt-5.4')

        expect(result.routing[:provider]).to eq(:openai)
        expect(result.routing[:model]).to eq('gpt-5.4')
      end
    end

    context 'when a caller passes the LegionIO placeholder model' do
      before do
        Legion::Settings[:llm][:default_provider] = 'vllm'
        Legion::Settings[:llm][:default_instance] = 'apollo'
        Legion::Settings[:llm][:default_model] = 'qwen3.6-27b'
        # P5: reset Inventory so ONLY the anthropic lane exists for claude-sonnet-4-6.
        # stub_native_provider (outer before) writes claude-sonnet-4-6 for all providers.
        # With multiple providers offering the same model, routing_resolution_for may pick
        # a non-anthropic provider, causing model_provider_mismatch → model cleared → raise.
        Legion::LLM::Inventory.reset_live_store!
        write_test_lane(provider: :anthropic, model: 'claude-sonnet-4-6', tier: :frontier)
      end

      it 'routes via inventory instead of configured defaults for LegionIO placeholder' do
        result = described_class.dispatch('Hello', model: 'legionio')

        expect(result.routing[:provider]).to eq(:anthropic)
        expect(result.routing[:model]).to eq('claude-sonnet-4-6')
      end
    end

    context 'when defaults are configured' do
      before do
        allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(false)
        Legion::Settings.set_prop(:llm, {
                                    default_provider: 'anthropic',
                                    default_model:    'claude-sonnet-4-6'
                                  })
      end

      it 'falls back to configured default_provider and default_model' do
        result = described_class.dispatch('Hello')
        expect(result).to be_a(Legion::LLM::Inference::Response)
        expect(result.routing[:provider]).to eq('anthropic')
        expect(result.routing[:model]).to eq('claude-sonnet-4-6')
      end
    end

    context 'when Router is not enabled and no defaults exist' do
      before do
        allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(false)
        Legion::Settings[:llm][:default_provider] = nil
        Legion::Settings[:llm][:default_model] = nil
      end

      it 'raises LLMError when both provider and model are nil' do
        expect { described_class.dispatch('Hello') }.to raise_error(
          Legion::LLM::LLMError, /provider and model must be set/
        )
      end
    end

    context 'with exclude parameter' do
      before do
        allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(false)
      end

      it 'accepts exclude parameter without error' do
        result = described_class.dispatch(
          'Hello',
          exclude: { provider: :anthropic, model: 'claude-sonnet-4-6' }
        )
        expect(result).to be_a(Legion::LLM::Inference::Response)
      end
    end

    context 'with all optional parameters' do
      it 'accepts the full parameter set' do
        result = described_class.dispatch(
          'Hello',
          intent:          { effort: :reasoning },
          exclude:         {},
          schema:          { type: :object },
          tools:           [],
          escalate:        false,
          max_escalations: 3,
          thinking:        { budget_tokens: 32_000 },
          temperature:     0.7,
          max_tokens:      1024,
          tracing:         { trace_id: 'abc' },
          agent:           { id: 'test-agent' },
          caller:          { extension: 'lex-test' },
          cache:           { enabled: true },
          quality_check:   nil
        )
        expect(result).to be_a(Legion::LLM::Inference::Response)
      end
    end

    context 'with real Router.resolve (no stub) — validates call-site keyword compatibility' do
      before do
        Legion::Settings[:llm][:routing] = {
          enabled:        true,
          default_intent: { privacy: 'normal', effort: 'moderate', operation: 'chat', cost: 'normal' },
          rules:          [
            {
              name:     'test-cloud-rule',
              when:     { effort: 'moderate' },
              then:     { tier: 'cloud', provider: 'anthropic', model: 'claude-sonnet-4-6' },
              priority: 10
            }
          ]
        }
        Legion::LLM::Router.reset!
      end

      after { Legion::LLM::Router.reset! }

      it 'does not raise ArgumentError when calling the real Router.resolve with intent' do
        result = described_class.dispatch('Hello', intent: { effort: :moderate })
        expect(result).to be_a(Legion::LLM::Inference::Response)
        expect(result.routing[:provider]).to eq(:anthropic)
        expect(result.routing[:model]).to eq('claude-sonnet-4-6')
      end

      it 'does not raise ArgumentError when passing exclude to dispatch with routing enabled' do
        # exclude: is accepted by dispatch but forwarded to Router only when Router supports it (WS-00E)
        # This verifies dispatch does not crash when exclude is passed, even if Router ignores it
        result = described_class.dispatch('Hello',
                                          intent:  { effort: :moderate },
                                          exclude: { anthropic: ['claude-sonnet-4-6'] })
        expect(result).to be_a(Legion::LLM::Inference::Response)
      end
    end
  end

  describe '.request' do
    context 'with valid provider and model' do
      it 'runs the pipeline in-process and returns a Inference::Response' do
        result = described_class.request('Hello', provider: :anthropic, model: 'claude-sonnet-4-6')
        expect(result).to be_a(Legion::LLM::Inference::Response)
      end

      it 'includes the provider in the response routing' do
        result = described_class.request('Hello', provider: :anthropic, model: 'claude-sonnet-4-6')
        expect(result.routing[:provider]).to eq(:anthropic)
      end

      it 'includes the model in the response routing' do
        result = described_class.request('Hello', provider: :anthropic, model: 'claude-sonnet-4-6')
        expect(result.routing[:model]).to eq('claude-sonnet-4-6')
      end
    end

    context 'with nil provider' do
      it 'raises LLMError' do
        expect { described_class.request('Hello', provider: nil, model: 'claude-sonnet-4-6') }.to raise_error(
          Legion::LLM::LLMError, /provider.*must be set/i
        )
      end
    end

    context 'with nil model' do
      it 'raises LLMError' do
        expect { described_class.request('Hello', provider: :anthropic, model: nil) }.to raise_error(
          Legion::LLM::LLMError, /model.*must be set/i
        )
      end
    end

    context 'with schema parameter' do
      it 'translates schema to response_format on the Inference::Request' do
        executor = instance_double(Legion::LLM::Inference::Executor, call: nil)
        allow(Legion::LLM::Inference::Executor).to receive(:new) do |request|
          expect(request.response_format).to eq({ type: :json_schema, schema: { type: :object } })
          executor
        end
        allow(executor).to receive(:call).and_return(
          Legion::LLM::Inference::Response.build(
            request_id: 'req_test', conversation_id: 'conv_test',
            message: { role: :assistant, content: '{}' },
            routing: { provider: :anthropic, model: 'claude-sonnet-4-6' }
          )
        )
        described_class.request('Extract data', provider: :anthropic, model: 'claude-sonnet-4-6',
                                                schema: { type: :object })
      end
    end

    context 'with temperature parameter' do
      it 'translates temperature into generation hash' do
        executor = instance_double(Legion::LLM::Inference::Executor, call: nil)
        allow(Legion::LLM::Inference::Executor).to receive(:new) do |request|
          expect(request.generation[:temperature]).to eq(0.7)
          executor
        end
        allow(executor).to receive(:call).and_return(
          Legion::LLM::Inference::Response.build(
            request_id: 'req_test', conversation_id: 'conv_test',
            message: { role: :assistant, content: 'hi' },
            routing: { provider: :anthropic, model: 'claude-sonnet-4-6' }
          )
        )
        described_class.request('Hello', provider: :anthropic, model: 'claude-sonnet-4-6', temperature: 0.7)
      end
    end

    context 'with max_tokens parameter' do
      it 'translates max_tokens into tokens hash' do
        executor = instance_double(Legion::LLM::Inference::Executor, call: nil)
        allow(Legion::LLM::Inference::Executor).to receive(:new) do |request|
          expect(request.tokens[:max]).to eq(2048)
          executor
        end
        allow(executor).to receive(:call).and_return(
          Legion::LLM::Inference::Response.build(
            request_id: 'req_test', conversation_id: 'conv_test',
            message: { role: :assistant, content: 'hi' },
            routing: { provider: :anthropic, model: 'claude-sonnet-4-6' }
          )
        )
        described_class.request('Hello', provider: :anthropic, model: 'claude-sonnet-4-6', max_tokens: 2048)
      end
    end

    it 'does NOT call DaemonClient' do
      expect(Legion::LLM::DaemonClient).not_to receive(:available?)
      expect(Legion::LLM::DaemonClient).not_to receive(:chat)
      described_class.request('Hello', provider: :anthropic, model: 'claude-sonnet-4-6')
    end
  end

  describe '.summarize' do
    it 'delegates to dispatch' do
      allow(described_class).to receive(:dispatch).and_call_original
      described_class.summarize('Long text to summarize')
      expect(described_class).to have_received(:dispatch).with(kind_of(String), hash_including(tools: []))
    end

    it 'defaults tools to empty array' do
      allow(described_class).to receive(:dispatch).and_call_original
      described_class.summarize('Text')
      expect(described_class).to have_received(:dispatch).with(anything, hash_including(tools: []))
    end

    it 'allows tools override' do
      tool = Legion::LLM::Types::ToolDefinition.build(name: 'test_tool', description: 'Test tool')
      allow(described_class).to receive(:dispatch).and_call_original
      described_class.summarize('Text', tools: [tool])
      expect(described_class).to have_received(:dispatch).with(anything, hash_including(tools: [tool]))
    end

    it 'returns a Inference::Response' do
      result = described_class.summarize('Some long text to summarize')
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end

  describe '.extract' do
    let(:schema) { { type: :object, properties: { name: { type: :string } } } }

    it 'delegates to dispatch with schema' do
      allow(described_class).to receive(:dispatch).and_call_original
      described_class.extract('Raw text', schema: schema)
      expect(described_class).to have_received(:dispatch).with(
        kind_of(String), hash_including(schema: schema, tools: [])
      )
    end

    it 'defaults tools to empty array' do
      allow(described_class).to receive(:dispatch).and_call_original
      described_class.extract('Text', schema: schema)
      expect(described_class).to have_received(:dispatch).with(anything, hash_including(tools: []))
    end

    it 'returns a Inference::Response' do
      result = described_class.extract('Some text', schema: schema)
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end

  describe '.decide' do
    let(:options) { %w[Refactor Patch Rewrite] }

    it 'delegates to dispatch' do
      allow(described_class).to receive(:dispatch).and_call_original
      described_class.decide('Which approach?', options: options)
      expect(described_class).to have_received(:dispatch).with(kind_of(String), hash_including(tools: []))
    end

    it 'defaults tools to empty array' do
      allow(described_class).to receive(:dispatch).and_call_original
      described_class.decide('Which?', options: options)
      expect(described_class).to have_received(:dispatch).with(anything, hash_including(tools: []))
    end

    it 'returns a Inference::Response' do
      result = described_class.decide('Which approach?', options: options)
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end
end

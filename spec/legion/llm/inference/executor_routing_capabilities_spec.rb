# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  describe 'routing capability requirements' do
    before do
      allow(Legion::LLM::Tools::Special).to receive(:pinned_definitions).and_return([
                                                                                      instance_double(
                                                                                        Legion::LLM::Types::ToolDefinition,
                                                                                        name: :ruby,
                                                                                        to_h: { name: 'ruby' }
                                                                                      )
                                                                                    ])
    end

    # Exercise the executor's actual requirement-construction boundary.
    def build_router(request)
      executor = described_class.new(request)
      executor.send(:build_ssot_router)
      executor.instance_variable_get(:@router)
    end

    it 'does not require :tools for plain non-streaming requests just because pinned tools exist' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        stream:   false
      )

      router = build_router(request)

      expect(router.operation).to eq(:chat)
      expect(router.required_capabilities).not_to include(:tools)
      expect(router.required_capabilities).not_to include(:thinking)
    end

    it 'does not require :tools for plain streaming requests just because pinned tools exist' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        stream:   true
      )

      router = build_router(request)

      expect(router.operation).to eq(:stream_chat)
      expect(router.required_capabilities).to include(:streaming)
      expect(router.required_capabilities).not_to include(:tools)
    end

    it 'requires :tools when the request explicitly includes client tools' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        tools:    [{ name: 'client_echo', description: 'echo', input_schema: { type: 'object', properties: {} } }]
      )

      router = build_router(request)

      expect(router.required_capabilities).to include(:tools)
    end

    it 'includes :thinking in required_capabilities only for explicit thinking requests' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'think this through' }],
        routing:  { model: 'legionio' },
        thinking: { effort: :medium, budget: 1024 }
      )

      router = build_router(request)

      expect(router.required_capabilities).to include(:thinking)
    end

    it 'does not include :thinking for requests without explicit thinking config' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'think this through' }],
        routing:  { model: 'legionio' },
        stream:   false
      )

      router = build_router(request)

      expect(router.required_capabilities).not_to include(:thinking)
    end

    it 'ignores payload client_model as a routing pin when body routing hints are disabled' do
      # The raw client body model reaches the Router via metadata[:client_model]
      # (set by the translator in production); build_ssot_router reads it there.
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  {},
        metadata: { client_model: 'gpt-5.5' }
      )

      router = build_router(request)

      expect(router.model_pin).to be_nil
    end

    it 'honors payload client_model only when body routing hints are enabled' do
      Legion::Settings[:llm][:router][:allow_body_routing_hints] = true
      Legion::LLM::Routing::SettingsState.reset!
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  {},
        metadata: { client_model: 'gpt-5.5' }
      )

      router = build_router(request)

      expect(router.model_pin).to eq('gpt-5.5')
    ensure
      Legion::Settings[:llm][:router][:allow_body_routing_hints] = false
    end

    it 'still honors an explicit Legion routing model over payload auto aliases' do
      request = Legion::LLM::Inference::Request.build(
        messages:     [{ role: :user, content: 'hello' }],
        routing:      { model: 'gemma-4-31b-it' },
        client_model: 'auto'
      )

      router = build_router(request)

      expect(router.model_pin).to eq('gemma-4-31b-it')
    end
  end
end

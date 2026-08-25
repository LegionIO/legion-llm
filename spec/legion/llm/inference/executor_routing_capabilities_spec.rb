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

    # Helper: build the per-request Router and return it (carries operation,
    # required_capabilities, input_bound, etc.).
    def build_reqs(request)
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

      reqs = build_reqs(request)

      expect(reqs.operation).to eq(:chat)
      expect(reqs.required_capabilities).not_to include(:tools)
      expect(reqs.required_capabilities).not_to include(:thinking)
    end

    it 'does not require :tools for plain streaming requests just because pinned tools exist' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        stream:   true
      )

      reqs = build_reqs(request)

      expect(reqs.operation).to eq(:stream_chat)
      expect(reqs.required_capabilities).to include(:streaming)
      expect(reqs.required_capabilities).not_to include(:tools)
    end

    it 'requires :tools when the request explicitly includes client tools' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        tools:    [{ name: 'client_echo', description: 'echo', input_schema: { type: 'object', properties: {} } }]
      )

      reqs = build_reqs(request)

      expect(reqs.required_capabilities).to include(:tools)
    end

    it 'includes :thinking in required_capabilities only for explicit thinking requests' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'think this through' }],
        routing:  { model: 'legionio' },
        thinking: { effort: :medium, budget: 1024 }
      )

      reqs = build_reqs(request)

      expect(reqs.required_capabilities).to include(:thinking)
    end

    it 'does not include :thinking for requests without explicit thinking config' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'think this through' }],
        routing:  { model: 'legionio' },
        stream:   false
      )

      reqs = build_reqs(request)

      expect(reqs.required_capabilities).not_to include(:thinking)
    end

    it 'ignores payload client_model as a routing pin when body routing hints are disabled' do
      # The raw client body model reaches the Router via metadata[:client_model]
      # (set by the translator in production); build_ssot_router reads it there.
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  {},
        metadata: { client_model: 'gpt-5.5' }
      )

      reqs = build_reqs(request)

      expect(reqs.model_pin).to be_nil
    end

    it 'honors payload client_model only when body routing hints are enabled' do
      # allow_body_routing_hints is read live from [:llm][:router] by the Router's
      # body-model-hint ladder — no SettingsState snapshot rebuild needed.
      Legion::Settings[:llm][:router][:allow_body_routing_hints] = true
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  {},
        metadata: { client_model: 'gpt-5.5' }
      )

      reqs = build_reqs(request)

      expect(reqs.model_pin).to eq('gpt-5.5')
    ensure
      Legion::Settings[:llm][:router][:allow_body_routing_hints] = false
    end

    it 'still honors an explicit Legion routing model over payload auto aliases' do
      request = Legion::LLM::Inference::Request.build(
        messages:     [{ role: :user, content: 'hello' }],
        routing:      { model: 'gemma-4-31b-it' },
        client_model: 'auto'
      )

      reqs = build_reqs(request)

      expect(reqs.model_pin).to eq('gemma-4-31b-it')
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM do
  let(:logger) { instance_double('Logger', info: nil) }

  before do
    allow(described_class).to receive(:log).and_return(logger)
    allow(Legion::LLM::Inference).to receive(:log).and_return(logger)
  end

  describe '.chat' do
    it 'logs inference request and response details for pipeline responses' do
      response = Legion::LLM::Inference::Response.build(
        request_id:      'req-123',
        conversation_id: 'conv-123',
        message:         { role: :assistant, content: 'pipeline response' },
        routing:         { provider: :anthropic, model: 'claude-sonnet-4-6' },
        tokens:          { input: 11, output: 7, total: 18 },
        stop:            { reason: :end_turn },
        tools:           [{ name: 'search' }]
      )

      allow(Legion::LLM::Inference).to receive(:dispatch_chat).and_return(response)

      described_class.chat(
        messages: [{ role: :user, content: 'hello' }],
        model:    'claude-sonnet-4-6',
        provider: :anthropic,
        caller:   { source: 'api', path: '/api/llm/inference' },
        tools:    [Class.new]
      )

      expect(logger).to have_received(:info).with(
        include(
          '[llm][inference] request',
          'type=chat',
          'requested_provider=anthropic',
          'requested_model=claude-sonnet-4-6',
          'caller=api:/api/llm/inference',
          'tools=1',
          'input_length=5',
          'input=[{role: :user, content: "hello"}]'
        )
      )

      expect(logger).to have_received(:info).with(
        include(
          '[llm][inference] response',
          'type=chat',
          'status=ok',
          'result_class=Legion::LLM::Inference::Response',
          'provider=anthropic',
          'model=claude-sonnet-4-6',
          'input_tokens=11',
          'output_tokens=7',
          'stop_reason=end_turn',
          'tool_calls=1',
          'output_length=17',
          'output="pipeline response"'
        )
      )
    end
  end

  describe '.ask' do
    it 'logs inference request and response details for direct responses' do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(false)
      allow(Legion::LLM::Inference).to receive(:ask_direct).and_return(
        {
          status:   :done,
          response: 'direct response',
          meta:     {
            tier:       :direct,
            model:      'gpt-4o',
            tokens_in:  3,
            tokens_out: 2
          }
        }
      )

      described_class.ask(message: 'hi', model: 'gpt-4o', provider: :openai)

      expect(logger).to have_received(:info).with(
        include(
          '[llm][inference] request',
          'type=ask',
          'requested_provider=openai',
          'requested_model=gpt-4o',
          'input_length=2',
          'input="hi"'
        )
      )

      expect(logger).to have_received(:info).with(
        include(
          '[llm][inference] response',
          'type=ask',
          'status=ok',
          'result_class=Hash',
          'provider=openai',
          'model=gpt-4o',
          'input_tokens=3',
          'output_tokens=2',
          'tool_calls=0',
          'output_length=15',
          'output="direct response"'
        )
      )
    end
  end
end

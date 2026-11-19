# frozen_string_literal: true

require_relative 'matrix_helper'

RSpec.describe '[matrix] merged RAG context at provider dispatch', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }
  let(:shared) { { id: 'general-shared', content_hash: 'shared-fact', content_type: 'fact', content: 'SHARED_DEPLOYMENT_FACT' } }
  let(:history_fact) { { id: 'history-only', content_type: 'fact', content: 'HISTORY_DEPLOYMENT_FACT' } }
  let(:overflow) { { id: 'overflow', content_type: 'fact', content: 'OVER_BUDGET_FACT' } }

  before do
    MatrixHelper.configure_for_fake!
    Legion::Settings[:llm][:rag][:enabled] = true
    Legion::Settings[:llm][:rag][:full_limit] = 2
    Legion::Settings[:llm][:rag][:exclude_source_agents] = []
    allow_any_instance_of(Legion::LLM::Inference::Executor).to receive(:apollo_available?).and_return(true)
    allow_any_instance_of(Legion::LLM::Inference::Executor).to receive(:apollo_retrieve_general)
      .and_return({ success: true, entries: [shared] })
    allow_any_instance_of(Legion::LLM::Inference::Executor).to receive(:apollo_retrieve_conversation_history)
      .and_return({ success: true, entries: [shared.merge(id: 'history-shared'), history_fact, overflow] })
  end

  after do
    Legion::LLM::Inference::Background.shutdown
    Legion::LLM::Inference::Background.start
    MatrixHelper.restore_started_state!
  end

  %i[chat responses messages].each do |dialect|
    [false, true].each do |streaming|
      it "sends each selected fact once through #{dialect}, stream=#{streaming}" do
        text = 'Explain the deployment decisions from the earlier conversation.'
        body = { model: 'fake-default', stream: streaming }
        path = case dialect
               when :responses
                 body.merge!(input: text, max_output_tokens: 2048)
                 '/v1/responses'
               when :chat
                 body.merge!(messages: [{ role: 'user', content: text }], max_tokens: 2048)
                 '/v1/chat/completions'
               when :messages
                 body.merge!(messages: [{ role: 'user', content: text }], max_tokens: 2048)
                 '/v1/messages'
               end

        FakeProvider.with_scenario(streaming ? :stream_text : :text) do
          post path, Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
        end

        expect(last_response.status).to eq(200), last_response.body
        expect(FakeProvider.calls.size).to eq(1)
        messages = FakeProvider.calls.last[:messages]
        expect(messages).to all(be_a(Legion::Extensions::Llm::Canonical::Message))
        prompt = messages.map(&:text).join("\n")
        expect(prompt.scan(shared[:content]).size).to eq(1)
        expect(prompt.scan(history_fact[:content]).size).to eq(1)
        expect(prompt).not_to include(overflow[:content])
        expect(messages.last.text).to eq(text)
      end
    end
  end
end

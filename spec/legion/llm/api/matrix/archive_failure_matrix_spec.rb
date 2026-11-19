# frozen_string_literal: true

require_relative 'matrix_helper'
require 'legion/apollo'
require 'sequel'

RSpec.describe '[matrix] failed archival preserves resent conversation history', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }
  let(:db) { Sequel.sqlite }
  let(:conversation_id) { SecureRandom.uuid }
  let(:history) do
    [
      { role: :user, content: 'Retain the original deployment decision.' },
      { role: :assistant, content: 'Retain the evidence supporting that decision.' },
      { role: :user, content: 'Review the previous deployment checklist.' },
      { role: :assistant, content: 'The deployment checklist has been reviewed.' }
    ]
  end

  before do
    MatrixHelper.configure_for_fake!
    Legion::LLM::Inference::Conversation.reset!
    Legion::Settings[:llm][:rag][:enabled] = false
    Legion::Settings[:llm][:context_curation][:target_context_tokens] = 5
    Legion::Settings[:llm][:context_curation][:archive_preserve_recent] = 1
    Legion::Settings[:llm][:conversation][:auto_compact] = false
    allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
    allow(Legion::Apollo::Local).to receive(:db).and_return(db)
  end

  after do
    Legion::LLM::Inference::Background.shutdown
    Legion::LLM::Inference::Background.start
    db.disconnect
    MatrixHelper.restore_started_state!
  end

  %i[chat responses messages].each do |dialect|
    [false, true].each do |streaming|
      it "retains original stored rows through #{dialect}, stream=#{streaming}, after SQLite fails" do
        stored = history.map { |message| Legion::LLM::Inference::Conversation.append(conversation_id, **message) }
        resent = history + [{ role: :user, content: 'Continue with the next deployment.' }]
        body = { model: 'fake-default', stream: streaming }
        path = case dialect
               when :responses
                 body.merge!(input: resent, max_output_tokens: 2048)
                 '/v1/responses'
               when :chat
                 body.merge!(messages: resent, max_tokens: 2048)
                 '/v1/chat/completions'
               when :messages
                 body.merge!(messages: resent, max_tokens: 2048)
                 '/v1/messages'
               end

        FakeProvider.with_scenario(streaming ? :stream_text : :text) do
          post path, Legion::JSON.dump(body),
               'CONTENT_TYPE' => 'application/json', 'HTTP_X_LEGION_CONVERSATION_ID' => conversation_id
        end

        expect(last_response.status).to eq(200), last_response.body
        retained_ids = Legion::LLM::Inference::Conversation.messages(conversation_id).map { |message| message[:id] }
        expect(retained_ids).to include(*stored.map { |message| message[:id] })
        expect(FakeProvider.calls.last[:messages].map(&:text)).to include(*history.map { |message| message[:content] })
      end
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'

# Part 3: history double-send. For a client-managed conversation the client
# resends the full history in @request.messages every turn, AND
# step_context_load loads the server-side stored copy into
# @enrichments['context:conversation_history'], which EnrichmentInjector then
# folds into the system prompt as "Prior conversation history" text — sending
# the same turns to the provider twice. step_context_load must store into the
# enrichment only the messages NOT already present in @request.messages.
RSpec.describe Legion::LLM::Inference::Executor, 'conversation history dedup' do
  let(:conv_id) { 'conv-dedup-1' }
  let(:client_messages) do
    [
      { role: :user,      content: 'first question' },
      { role: :assistant, content: 'first answer' },
      { role: :user,      content: 'second question' }
    ]
  end
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages:        client_messages,
      conversation_id: conv_id,
      routing:         { provider: :vllm, model: 'gemma-12b-it' }
    )
  end
  let(:executor) { described_class.new(request) }

  before do
    allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
    allow(Legion::LLM::Audit).to receive(:emit_prompt)
    executor.instance_variable_set(:@enrichments, {})
  end

  context 'when the client resends the full history it already sent' do
    before do
      allow(Legion::LLM::Inference::Conversation).to receive(:messages)
        .with(conv_id).and_return(client_messages.map { |m| m.merge(created_at: Time.now) })
      allow(Legion::LLM::Context::Curator).to receive(:new).and_return(
        instance_double(Legion::LLM::Context::Curator, curated_messages: nil, drop_and_archive: client_messages)
      )
    end

    it 'does not re-inject the already-present history into the system prompt' do
      executor.send(:step_context_load)
      injected = executor.instance_variable_get(:@enrichments)['context:conversation_history']
      expect(Array(injected)).to be_empty
    end
  end

  context 'when the server holds turns the client did NOT resend (server-managed)' do
    let(:client_messages) { [{ role: :user, content: 'latest only' }] }
    let(:stored) do
      [
        { role: :user,      content: 'old turn 1', created_at: Time.now },
        { role: :assistant, content: 'old answer 1', created_at: Time.now },
        { role: :user,      content: 'latest only', created_at: Time.now }
      ]
    end

    before do
      allow(Legion::LLM::Inference::Conversation).to receive(:messages)
        .with(conv_id).and_return(stored)
      allow(Legion::LLM::Context::Curator).to receive(:new).and_return(
        instance_double(Legion::LLM::Context::Curator, curated_messages: nil, drop_and_archive: stored)
      )
    end

    it 'still injects the prior turns the client omitted' do
      executor.send(:step_context_load)
      injected = Array(executor.instance_variable_get(:@enrichments)['context:conversation_history'])
      contents = injected.map { |m| m[:content] || m['content'] }

      expect(contents).to include('old turn 1', 'old answer 1')
      expect(contents).not_to include('latest only')
    end
  end
end

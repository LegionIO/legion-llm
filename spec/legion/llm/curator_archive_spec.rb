# frozen_string_literal: true

require 'spec_helper'
require 'legion/apollo'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe Legion::LLM::Context::Curator, 'confirmed archival' do
  let(:conversation_id) { 'archive-confirmation' }
  let(:curator) { described_class.new(conversation_id: conversation_id) }
  let(:messages) do
    [
      { role: :user, content: 'Preserve the original deployment decision. ' * 3 },
      { role: :assistant, content: 'Preserve the original deployment evidence. ' * 3 },
      { role: :user, content: 'Review the next deployment.' }
    ]
  end

  before do
    Legion::Settings[:llm][:context_curation][:target_context_tokens] = 5
    Legion::Settings[:llm][:context_curation][:archive_preserve_recent] = 1
    Legion::Settings[:llm][:conversation][:auto_compact] = false
    Legion::LLM::Inference::Conversation.reset!
  end

  %i[local facade runner].each do |backend|
    context "through the #{backend} archive path" do
      let(:outcome) { { success: true, entry_id: 42 } }
      let(:receiver) do
        case backend
        when :local then Legion::Apollo::Local
        when :facade then Legion::Apollo
        when :runner then double('optional Apollo knowledge runner', handle_ingest: outcome)
        end
      end
      let(:ingest_method) { backend == :runner ? :handle_ingest : :ingest }

      before do
        if backend == :runner
          hide_const('Legion::Apollo')
          stub_const('Legion::Extensions::Apollo::Runners::Knowledge', receiver)
        else
          allow(Legion::Apollo::Local).to receive(:started?).and_return(backend == :local)
        end
        allow(receiver).to receive(ingest_method).and_return(outcome)
      end

      [
        nil, true, [], {},
        { success: false, error: 'persistence failed' },
        { success: 'true', entry_id: 42 },
        { success: true },
        { success: true, mode: :async },
        { success: true, mode: 'async' },
        { success: true, mode: :queued, id: 42 },
        { success: true, mode: :local, id: nil },
        { success: true, mode: :local, id: false },
        { success: true, entry_id: '' },
        { success: true, mode: :all },
        { success: true, mode: :all, results: [] },
        { success: true, mode: :all, results: [{ success: true, mode: :async }, { success: false }] }
      ].each do |unconfirmed|
        context "with unconfirmed result #{unconfirmed.inspect}" do
          let(:outcome) { unconfirmed }

          it 'retains the complete original history and logs the missing confirmation' do
            expect(curator.log).to receive(:warn).with(a_string_including('archive_unconfirmed', 'policy=retain_history'))
            expect(curator.drop_and_archive(messages, conversation_id: conversation_id)).to equal(messages)
          end
        end
      end

      [
        { success: true, mode: :local, id: 42 },
        { success: true, mode: :deduplicated },
        { success: true, entry_id: 42 },
        { success: true, entry_id: 42, deduped: true },
        { success: true, mode: :all, results: [{ success: true, mode: :async }, { success: true, mode: :local, id: 42 }] }
      ].each do |persisted|
        context "with confirmed result #{persisted.inspect}" do
          let(:outcome) { persisted }

          it 'retains only the configured recent history after confirmation' do
            expect(curator.drop_and_archive(messages, conversation_id: conversation_id)).to eq(messages.last(1))
          end
        end
      end

      it 'retains history when ingest raises an operational error' do
        allow(receiver).to receive(ingest_method).and_raise(IOError, 'archival connection failed')
        expect(curator.drop_and_archive(messages, conversation_id: conversation_id)).to equal(messages)
      end
    end
  end

  context 'with the published Apollo implementation and a real SQLite database' do
    let(:db) { Sequel.sqlite }

    before do
      Legion::Settings.register_library(:apollo, Legion::Apollo::Settings.default)
      allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
      allow(Legion::Apollo::Local).to receive(:db).and_return(db)
      # Embedding generation is independent of the persistence acknowledgment.
      allow(Legion::Apollo::Local).to receive(:generate_embedding).and_return([nil, nil])
    end

    after { db.disconnect }

    it 'retains history when the real ingest returns a missing-table failure' do
      observed = []
      allow(Legion::Apollo::Local).to receive(:ingest).and_wrap_original do |original, **payload|
        original.call(**payload).tap { |result| observed << result }
      end

      expect(curator.drop_and_archive(messages, conversation_id: conversation_id)).to equal(messages)
      expect(observed).to contain_exactly(include(success: false, error: a_string_including('no such table')))
    end

    it 'keeps the executor conversation rows when real SQLite archival fails' do
      stored = messages.map { |message| Legion::LLM::Inference::Conversation.append(conversation_id, **message) }
      request = Legion::LLM::Inference::Request.build(messages: messages, conversation_id: conversation_id)
      executor = Legion::LLM::Inference::Executor.new(request)

      executor.send(:step_context_load)

      expect(Legion::LLM::Inference::Conversation.raw_messages(conversation_id)).to eq(stored)
      expect(executor.context_accounting[:counts][:archived_history_message_count]).to eq(0)
    end

    it 'drops history only after the real archive row is persisted, including deduplicated writes' do
      Sequel::Migrator.run(db, Legion::Apollo::Local::MIGRATION_PATH, table: :schema_migrations_apollo_local)

      2.times do
        expect(curator.drop_and_archive(messages, conversation_id: conversation_id)).to eq(messages.last(1))
      end

      expect(db[:local_knowledge].count).to eq(1)
      row = db[:local_knowledge].first
      expect(row[:content]).to include(messages[0][:content], messages[1][:content])
      expect(Legion::JSON.load(row[:tags])).to include('llm_conversation_history', "conversation:#{conversation_id}")
    end
  end
end

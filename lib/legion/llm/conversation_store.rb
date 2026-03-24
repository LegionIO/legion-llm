# frozen_string_literal: true

module Legion
  module LLM
    module ConversationStore
      MAX_CONVERSATIONS = 256

      class << self
        def append(conversation_id, role:, content:, **metadata)
          ensure_conversation(conversation_id)
          seq = next_seq(conversation_id)
          msg = { seq: seq, role: role, content: content, created_at: Time.now, **metadata }
          conversations[conversation_id][:messages] << msg
          touch(conversation_id)
          persist_message(conversation_id, msg)
          msg
        end

        def messages(conversation_id)
          if in_memory?(conversation_id)
            touch(conversation_id)
            conversations[conversation_id][:messages].sort_by { |m| m[:seq] }
          else
            load_from_db(conversation_id)
          end
        end

        def create_conversation(conversation_id, **metadata)
          conversations[conversation_id] = { messages: [], metadata: metadata, accessed_at: Time.now }
          evict_if_needed
          persist_conversation(conversation_id, metadata)
        end

        def conversation_exists?(conversation_id)
          in_memory?(conversation_id) || db_conversation_exists?(conversation_id)
        end

        def in_memory?(conversation_id)
          conversations.key?(conversation_id)
        end

        def reset!
          @conversations = {}
        end

        private

        def conversations
          @conversations ||= {}
        end

        def ensure_conversation(conversation_id)
          return if in_memory?(conversation_id)

          create_conversation(conversation_id)
        end

        def next_seq(conversation_id)
          msgs = conversations[conversation_id][:messages]
          msgs.empty? ? 1 : msgs.last[:seq] + 1
        end

        def touch(conversation_id)
          return unless in_memory?(conversation_id)

          conversations[conversation_id][:accessed_at] = Time.now
        end

        def evict_if_needed
          return unless conversations.size > self::MAX_CONVERSATIONS

          oldest_id = conversations.min_by { |_, v| v[:accessed_at] }&.first
          conversations.delete(oldest_id) if oldest_id
        end

        def persist_message(conversation_id, msg)
          return unless db_available?

          db_append_message(conversation_id, msg)
        rescue StandardError => e
          spool_message(conversation_id, msg)
          Legion::Logging.warn("ConversationStore persist failed, spooled: #{e.message}") if defined?(Legion::Logging)
        end

        def persist_conversation(conversation_id, metadata)
          return unless db_available?

          db_create_conversation(conversation_id, metadata)
        rescue StandardError => e
          Legion::Logging.warn("ConversationStore conversation persist failed: #{e.message}") if defined?(Legion::Logging)
        end

        def load_from_db(conversation_id)
          return [] unless db_available?

          db_load_messages(conversation_id)
        rescue StandardError
          []
        end

        def db_conversation_exists?(conversation_id)
          return false unless db_available?

          db_conversation_record?(conversation_id)
        rescue StandardError
          false
        end

        def db_available?
          defined?(Legion::Data) &&
            Legion::Data.respond_to?(:connection) &&
            Legion::Data.connection.respond_to?(:table_exists?) &&
            Legion::Data.connection.table_exists?(:conversations)
        rescue StandardError
          false
        end

        def db_create_conversation(conversation_id, metadata)
          Legion::Data.connection[:conversations].insert_ignore.insert(
            id: conversation_id,
            caller_identity: metadata[:caller_identity],
            metadata: metadata.to_json,
            created_at: Time.now,
            updated_at: Time.now
          )
        end

        def db_append_message(conversation_id, msg)
          Legion::Data.connection[:conversation_messages].insert(
            conversation_id: conversation_id,
            seq: msg[:seq],
            role: msg[:role].to_s,
            content: msg[:content],
            provider: msg[:provider]&.to_s,
            model: msg[:model]&.to_s,
            input_tokens: msg[:input_tokens],
            output_tokens: msg[:output_tokens],
            created_at: msg[:created_at] || Time.now
          )
        end

        def db_load_messages(conversation_id)
          Legion::Data.connection[:conversation_messages]
                      .where(conversation_id: conversation_id)
                      .order(:seq)
                      .map { |row| symbolize_message(row) }
        end

        def db_conversation_record?(conversation_id)
          Legion::Data.connection[:conversations].where(id: conversation_id).count.positive?
        end

        def symbolize_message(row)
          {
            seq: row[:seq],
            role: row[:role]&.to_sym,
            content: row[:content],
            provider: row[:provider]&.to_sym,
            model: row[:model],
            input_tokens: row[:input_tokens],
            output_tokens: row[:output_tokens],
            created_at: row[:created_at]
          }
        end

        def spool_message(conversation_id, msg)
          return unless defined?(Legion::Data::Spool)

          dir = File.join(spool_root, 'conversations')
          FileUtils.mkdir_p(dir)
          filename = "#{Time.now.strftime('%s%9N')}-#{SecureRandom.uuid}.json"
          payload = { conversation_id: conversation_id, message: msg }
          File.write(File.join(dir, filename), payload.to_json)
        end

        def spool_root
          @spool_root ||= File.expand_path('~/.legionio/data/spool/llm')
        end
      end
    end
  end
end

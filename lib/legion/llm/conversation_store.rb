# frozen_string_literal: true

require 'securerandom'

require 'legion/logging/helper'
module Legion
  module LLM
    module ConversationStore
      extend Legion::Logging::Helper

      MAX_CONVERSATIONS = 256
      METADATA_ROLE = :__metadata__

      class << self
        def append(conversation_id, role:, content:, parent_id: nil, sidechain: false,
                   message_group_id: nil, agent_id: nil, **metadata)
          ensure_conversation(conversation_id)
          id  = SecureRandom.uuid
          seq = next_seq(conversation_id)
          msg = {
            id:               id,
            seq:              seq,
            role:             role,
            content:          content,
            parent_id:        parent_id,
            sidechain:        sidechain,
            message_group_id: message_group_id,
            agent_id:         agent_id,
            created_at:       Time.now,
            **metadata
          }
          conversations[conversation_id][:messages] << msg
          touch(conversation_id)
          persist_message(conversation_id, msg)
          msg
        end

        # Returns flat ordered message array — backward-compatible.
        # Uses chain reconstruction when parent links exist; falls back to seq order.
        def messages(conversation_id)
          if in_memory?(conversation_id)
            touch(conversation_id)
            raw = conversations[conversation_id][:messages].reject { |m| m[:role] == METADATA_ROLE }
            chain_or_seq(raw)
          else
            load_from_db(conversation_id)
          end
        end

        # Build ordered chain from parent links.
        # Excludes sidechain messages by default.
        def build_chain(conversation_id, include_sidechains: false)
          raw = all_raw_messages(conversation_id)
          raw = raw.reject { |m| m[:sidechain] } unless include_sidechains
          raw = raw.reject { |m| m[:role] == METADATA_ROLE }
          reconstruct_chain(raw)
        end

        # Return sidechain messages; optionally filter by agent_id.
        def sidechain_messages(conversation_id, agent_id: nil)
          raw = all_raw_messages(conversation_id)
          result = raw.select { |m| m[:sidechain] && m[:role] != METADATA_ROLE }
          result = result.select { |m| m[:agent_id] == agent_id } unless agent_id.nil?
          result.sort_by { |m| m[:seq] }
        end

        # Create a new conversation branched from from_message_id.
        # Copies all messages up to and including that message into a new conversation.
        def branch(conversation_id, from_message_id:)
          raw = all_raw_messages(conversation_id)
          target = raw.find { |m| m[:id] == from_message_id }
          raise ArgumentError, "Message #{from_message_id} not found in #{conversation_id}" unless target

          chain = reconstruct_chain(raw)
          # Only keep messages up to (and including) the target message by seq
          cutoff_seq = target[:seq]
          prefix = chain.select { |m| m[:seq] <= cutoff_seq }

          new_id = SecureRandom.uuid
          create_conversation(new_id)
          prefix.each_with_index do |msg, i|
            new_msg = msg.merge(seq: i + 1, id: SecureRandom.uuid, parent_id: nil, created_at: Time.now)
            conversations[new_id][:messages] << new_msg
            persist_message(new_id, new_msg)
          end
          touch(new_id)
          new_id
        end

        # Store session metadata as a special entry (tail-window pattern).
        def store_metadata(conversation_id, title: nil, tags: nil, model: nil)
          ensure_conversation(conversation_id)
          payload = { title: title, tags: tags, model: model }.compact
          msg = {
            id:               SecureRandom.uuid,
            seq:              next_seq(conversation_id),
            role:             METADATA_ROLE,
            content:          payload.to_json,
            parent_id:        nil,
            sidechain:        false,
            message_group_id: nil,
            agent_id:         nil,
            created_at:       Time.now
          }
          conversations[conversation_id][:messages] << msg
          touch(conversation_id)
          persist_message(conversation_id, msg)
          msg
        end

        # Read metadata stored by store_metadata; scans tail of message list.
        def read_metadata(conversation_id, tail_n: 20)
          raw = all_raw_messages(conversation_id)
          tail = raw.last(tail_n).select { |m| m[:role] == METADATA_ROLE }
          return nil if tail.empty?

          entry = tail.last
          ::JSON.parse(entry[:content], symbolize_names: true)
        rescue ::JSON::ParserError
          nil
        end

        def create_conversation(conversation_id, **metadata)
          conversations[conversation_id] = { messages: [], metadata: metadata, lru_tick: next_tick }
          evict_if_needed
          persist_conversation(conversation_id, metadata)
        end

        def replace(conversation_id, messages)
          ensure_conversation(conversation_id)
          conversations[conversation_id][:messages] = messages.each_with_index.map do |msg, i|
            msg.merge(seq: i + 1, created_at: msg[:created_at] || Time.now)
          end
          touch(conversation_id)
        end

        def conversation_exists?(conversation_id)
          in_memory?(conversation_id) || db_conversation_exists?(conversation_id)
        end

        def in_memory?(conversation_id)
          conversations.key?(conversation_id)
        end

        def reset!
          @conversations = {}
          @lru_counter   = 0
        end

        # Migrate existing sequential messages to use parent links.
        # Safe to call on already-migrated data (no-op when parent links present).
        def migrate_parent_links!(conversation_id)
          ensure_conversation(conversation_id)
          msgs = conversations[conversation_id][:messages].sort_by { |m| m[:seq] }
          return if msgs.empty?
          return if msgs.any? { |m| m[:parent_id] }

          prev_id = nil
          msgs.each do |msg|
            msg[:parent_id] = prev_id
            prev_id = msg[:id] ||= SecureRandom.uuid
          end

          touch(conversation_id)
        end

        private

        def conversations
          @conversations ||= {}
        end

        def next_tick
          @lru_counter = (@lru_counter || 0) + 1
        end

        def ensure_conversation(conversation_id)
          return if in_memory?(conversation_id)

          create_conversation(conversation_id)
        end

        def next_seq(conversation_id)
          msgs = conversations[conversation_id][:messages]
          if msgs.empty? && db_available?
            begin
              max = Legion::Data.connection[:conversation_messages]
                                .where(conversation_id: conversation_id)
                                .max(:seq)
              return (max || 0) + 1
            rescue StandardError
              # fall through to default
            end
          end
          msgs.empty? ? 1 : msgs.last[:seq] + 1
        end

        def touch(conversation_id)
          return unless in_memory?(conversation_id)

          conversations[conversation_id][:lru_tick] = next_tick
        end

        def evict_if_needed
          return unless conversations.size > self::MAX_CONVERSATIONS

          oldest_id = conversations.min_by { |_, v| v[:lru_tick] }&.first
          conversations.delete(oldest_id) if oldest_id
        end

        # Return all raw messages (including sidechain and metadata) from memory or DB.
        def all_raw_messages(conversation_id)
          if in_memory?(conversation_id)
            touch(conversation_id)
            conversations[conversation_id][:messages].dup
          else
            load_from_db(conversation_id)
          end
        end

        # Reconstruct ordered chain from parent links; fall back to seq when no links present.
        def reconstruct_chain(msgs)
          return msgs.sort_by { |m| m[:seq] } if msgs.empty?
          return msgs.sort_by { |m| m[:seq] } unless msgs.any? { |m| m[:parent_id] }

          walk_parent_chain(msgs)
        end

        # Walk parent chain from leaf(s) backward, recovering parallel siblings via message_group_id.
        def walk_parent_chain(msgs)
          by_id    = msgs.to_h { |m| [m[:id], m] }
          by_group = msgs.group_by { |m| m[:message_group_id] }

          deepest_leaf = select_deepest_leaf(msgs, by_id)
          return msgs.sort_by { |m| m[:seq] } unless deepest_leaf

          chain_ids       = collect_chain_ids(deepest_leaf, by_id)
          all_ids_ordered = insert_group_siblings(chain_ids, by_id, by_group)
          build_ordered_result(all_ids_ordered, msgs, by_id)
        end

        # Select the deepest leaf that traces back to a root, or fallback to any deepest leaf.
        def select_deepest_leaf(msgs, by_id)
          parent_ids    = msgs.map { |m| m[:parent_id] }.compact.to_set
          leaf_msgs     = msgs.reject { |m| parent_ids.include?(m[:id]) }
          rooted_leaves = leaf_msgs.select { |leaf| chain_reaches_root?(leaf, by_id) }
          candidates    = rooted_leaves.empty? ? leaf_msgs : rooted_leaves
          candidates.max_by { |m| m[:seq] }
        end

        # Walk from leaf up to root collecting ids.
        def collect_chain_ids(leaf, by_id)
          chain_ids = []
          current   = leaf
          while current
            chain_ids.unshift(current[:id])
            break if current[:parent_id].nil?

            current = by_id[current[:parent_id]]
          end
          chain_ids
        end

        # Insert group siblings into the ordered id list after their anchor.
        def insert_group_siblings(chain_ids, by_id, by_group)
          chain_id_set = chain_ids.to_set
          recovered    = collect_group_siblings(chain_ids, chain_id_set, by_id, by_group)
          all_ids      = chain_ids.dup
          recovered.each { |sibling| splice_sibling(all_ids, sibling, by_id) }
          all_ids
        end

        # Collect sibling messages sharing a message_group_id with any chain message.
        def collect_group_siblings(chain_ids, chain_id_set, by_id, by_group)
          recovered = []
          chain_ids.each do |cid|
            msg = by_id[cid]
            next unless msg[:message_group_id]

            (by_group[msg[:message_group_id]] || []).each do |sibling|
              recovered << sibling unless chain_id_set.include?(sibling[:id])
            end
          end
          recovered
        end

        # Splice a recovered sibling into all_ids after its group anchor.
        def splice_sibling(all_ids, sibling, by_id)
          return if all_ids.include?(sibling[:id])

          anchor = all_ids.find { |cid| by_id[cid]&.dig(:message_group_id) == sibling[:message_group_id] }
          if anchor
            all_ids.insert(all_ids.index(anchor) + 1, sibling[:id])
          else
            all_ids << sibling[:id]
          end
        end

        # Build final result: ordered chain messages + orphans at end.
        def build_ordered_result(all_ids_ordered, msgs, by_id)
          resolved_ids = all_ids_ordered.to_set
          orphans      = msgs.reject { |m| resolved_ids.include?(m[:id]) }.sort_by { |m| m[:seq] }
          all_ids_ordered.filter_map { |cid| by_id[cid] } + orphans
        end

        # Returns true if the message's chain reaches a root (parent_id nil) without a missing link.
        def chain_reaches_root?(msg, by_id)
          visited = {}
          current = msg
          while current
            return false if visited[current[:id]] # cycle guard

            visited[current[:id]] = true
            return true if current[:parent_id].nil?
            return false unless by_id.key?(current[:parent_id])

            current = by_id[current[:parent_id]]
          end
          true
        end

        # Use chain reconstruction when parent links exist; seq order otherwise.
        def chain_or_seq(msgs)
          return msgs.sort_by { |m| m[:seq] } unless msgs.any? { |m| m[:parent_id] }

          reconstruct_chain(msgs)
        end

        def persist_message(conversation_id, msg)
          return unless db_available?

          db_append_message(conversation_id, msg)
        rescue StandardError => e
          spool_message(conversation_id, msg)
          handle_exception(e, level: :warn, operation: 'llm.conversation_store.persist_message', conversation_id: conversation_id)
          log.warn("ConversationStore persist failed, spooled conversation_id=#{conversation_id}")
        end

        def persist_conversation(conversation_id, metadata)
          return unless db_available?

          db_create_conversation(conversation_id, metadata)
        rescue StandardError => e
          handle_exception(e, level: :warn)
        end

        def load_from_db(conversation_id)
          return [] unless db_available?

          db_load_messages(conversation_id)
        rescue StandardError => e
          handle_exception(e, level: :debug)
          []
        end

        def db_conversation_exists?(conversation_id)
          return false unless db_available?

          db_conversation_record?(conversation_id)
        rescue StandardError => e
          handle_exception(e, level: :debug)
          false
        end

        def db_available?
          defined?(Legion::Data) &&
            Legion::Data.respond_to?(:connection) &&
            Legion::Data.connection.respond_to?(:table_exists?) &&
            Legion::Data.connection.table_exists?(:conversations)
        rescue StandardError => e
          handle_exception(e, level: :debug)
          false
        end

        def db_create_conversation(conversation_id, metadata)
          Legion::Data.connection[:conversations].insert_ignore.insert(
            id:              conversation_id,
            caller_identity: metadata[:caller_identity],
            metadata:        metadata.to_json,
            created_at:      Time.now,
            updated_at:      Time.now
          )
        end

        def db_append_message(conversation_id, msg)
          # Coerce content to plain string — content may arrive as an array of
          # multi-part blocks (e.g. [{type: "text", text: "..."}]) which Sequel
          # would misinterpret as a filter expression, causing PG::UndefinedColumn.
          raw_content = msg[:content]
          coerced_content = if raw_content.is_a?(Array)
                              raw_content.filter_map do |b|
                                b.is_a?(Hash) ? (b[:text] || b['text']) : b.to_s
                              end.join
                            else
                              raw_content.to_s
                            end

          row = {
            conversation_id: conversation_id,
            seq:             msg[:seq],
            role:            msg[:role].to_s,
            content:         coerced_content,
            provider:        msg[:provider]&.to_s,
            model:           msg[:model]&.to_s,
            input_tokens:    msg[:input_tokens],
            output_tokens:   msg[:output_tokens],
            created_at:      msg[:created_at] || Time.now
          }

          if db_chain_columns_exist?
            row[:message_id]       = msg[:id]
            row[:parent_id]        = msg[:parent_id]
            row[:sidechain]        = msg[:sidechain] ? 1 : 0
            row[:message_group_id] = msg[:message_group_id]
            row[:agent_id]         = msg[:agent_id]
          end

          Legion::Data.connection[:conversation_messages].insert(row)
        end

        def db_chain_columns_exist?
          @db_chain_columns_exist ||=
            Legion::Data.connection.schema(:conversation_messages)
                        .any? { |col, _| col == :parent_id }
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.conversation_store.db_chain_columns_exist')
          false
        end

        def db_load_messages(conversation_id)
          rows = Legion::Data.connection[:conversation_messages]
                             .where(conversation_id: conversation_id)
                             .order(:seq)
                             .map { |row| symbolize_message(row) }
          chain_or_seq(rows)
        end

        def db_conversation_record?(conversation_id)
          Legion::Data.connection[:conversations].where(id: conversation_id).any?
        end

        def symbolize_message(row)
          base = {
            seq:           row[:seq],
            role:          row[:role]&.to_sym,
            content:       row[:content],
            provider:      row[:provider]&.to_sym,
            model:         row[:model],
            input_tokens:  row[:input_tokens],
            output_tokens: row[:output_tokens],
            created_at:    row[:created_at]
          }
          base[:id]               = row[:message_id] if row.key?(:message_id)
          base[:parent_id]        = row[:parent_id]  if row.key?(:parent_id)
          base[:sidechain]        = row[:sidechain].to_i == 1 if row.key?(:sidechain)
          base[:message_group_id] = row[:message_group_id] if row.key?(:message_group_id)
          base[:agent_id]         = row[:agent_id] if row.key?(:agent_id)
          base
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

# frozen_string_literal: true

require 'securerandom'

require 'legion/logging/helper'
module Legion
  module LLM
    module Inference
      module Conversation
        extend Legion::Logging::Helper

        MAX_CONVERSATIONS = 256
        METADATA_ROLE = :__metadata__
        CURATED_ROLE  = :__curated__

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
            msg
          end

          def messages(conversation_id)
            return [] unless in_memory?(conversation_id)

            touch(conversation_id)
            raw = conversations[conversation_id][:messages].reject { |m| internal_role?(m[:role]) }
            chain_or_seq(raw)
          end

          def raw_messages(conversation_id)
            return [] unless in_memory?(conversation_id)

            touch(conversation_id)
            conversations[conversation_id][:messages].dup
          end

          def build_chain(conversation_id, include_sidechains: false)
            raw = all_raw_messages(conversation_id)
            raw = raw.reject { |m| m[:sidechain] } unless include_sidechains
            raw = raw.reject { |m| internal_role?(m[:role]) }
            reconstruct_chain(raw)
          end

          def sidechain_messages(conversation_id, agent_id: nil)
            raw = all_raw_messages(conversation_id)
            result = raw.select { |m| m[:sidechain] && !internal_role?(m[:role]) }
            result = result.select { |m| m[:agent_id] == agent_id } unless agent_id.nil?
            result.sort_by { |m| m[:seq] }
          end

          def branch(conversation_id, from_message_id:)
            raw = all_raw_messages(conversation_id)
            target = raw.find { |m| m[:id] == from_message_id }
            raise ArgumentError, "Message #{from_message_id} not found in #{conversation_id}" unless target

            chain = reconstruct_chain(raw)
            cutoff_seq = target[:seq]
            prefix = chain.select { |m| m[:seq] <= cutoff_seq }

            new_id = SecureRandom.uuid
            create_conversation(new_id)
            prefix.each_with_index do |msg, i|
              new_msg = msg.merge(seq: i + 1, id: SecureRandom.uuid, parent_id: nil, created_at: Time.now)
              conversations[new_id][:messages] << new_msg
            end
            touch(new_id)
            new_id
          end

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
            msg
          end

          def read_metadata(conversation_id, tail_n: 20)
            raw = all_raw_messages(conversation_id)
            tail = raw.last(tail_n).select { |m| m[:role] == METADATA_ROLE }
            return nil if tail.empty?

            entry = tail.last
            Legion::JSON.parse(entry[:content])
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.conversation.metadata_json_parse')
            nil
          end

          def read_sticky_state(conversation_id)
            return {}.freeze unless in_memory?(conversation_id)

            conversations[conversation_id][:sticky_state] ||= {}
          end

          def write_sticky_state(conversation_id, state)
            return unless in_memory?(conversation_id)

            conversations[conversation_id][:sticky_state] = state
            touch(conversation_id)
          end

          def create_conversation(conversation_id, **metadata)
            conversations[conversation_id] = { messages: [], metadata: metadata, lru_tick: next_tick }
            evict_if_needed
          end

          def replace(conversation_id, messages)
            ensure_conversation(conversation_id)
            conversations[conversation_id][:messages] = messages.each_with_index.map do |msg, i|
              msg.merge(seq: i + 1, created_at: msg[:created_at] || Time.now)
            end
            touch(conversation_id)
          end

          def conversation_exists?(conversation_id)
            in_memory?(conversation_id)
          end

          def in_memory?(conversation_id)
            conversations.key?(conversation_id)
          end

          def reset!
            @conversations = {}
            @lru_counter   = 0
          end

          def set_skill_state(conversation_id, skill_key:, resume_at:)
            ensure_conversation(conversation_id)
            conversations[conversation_id][:skill_state] = { skill_key: skill_key, resume_at: resume_at }
            touch(conversation_id)
          end

          def skill_state(conversation_id)
            return nil unless in_memory?(conversation_id)

            touch(conversation_id)
            conversations[conversation_id][:skill_state]&.dup
          end

          def clear_skill_state(conversation_id)
            return unless in_memory?(conversation_id)

            conversations[conversation_id].delete(:skill_state)
            touch(conversation_id)
          end

          def cancel_skill!(conversation_id)
            ensure_conversation(conversation_id)
            state = conversations[conversation_id].delete(:skill_state)
            if state
              conversations[conversation_id][:skill_cancelled] = true
              touch(conversation_id)
            end
            state
          end

          def skill_cancelled?(conversation_id)
            return false unless in_memory?(conversation_id)

            conversations[conversation_id][:skill_cancelled] == true
          end

          def clear_cancel_flag(conversation_id)
            return unless in_memory?(conversation_id)

            conversations[conversation_id].delete(:skill_cancelled)
            touch(conversation_id)
          end

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

          def internal_role?(role)
            [METADATA_ROLE, CURATED_ROLE].include?(role)
          end

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
            msgs.empty? ? 1 : msgs.last[:seq] + 1
          end

          def touch(conversation_id)
            return unless in_memory?(conversation_id)

            conversations[conversation_id][:lru_tick] = next_tick
          end

          def evict_if_needed
            return unless conversations.size > self::MAX_CONVERSATIONS

            oldest_id = conversations.min_by { |_, v| v[:lru_tick] }&.first
            return unless oldest_id

            conversations.delete(oldest_id)
          end

          def all_raw_messages(conversation_id)
            return [] unless in_memory?(conversation_id)

            touch(conversation_id)
            conversations[conversation_id][:messages].dup
          end

          def reconstruct_chain(msgs)
            return msgs.sort_by { |m| m[:seq] } if msgs.empty?
            return msgs.sort_by { |m| m[:seq] } unless msgs.any? { |m| m[:parent_id] }

            walk_parent_chain(msgs)
          end

          def walk_parent_chain(msgs)
            by_id    = msgs.to_h { |m| [m[:id], m] }
            by_group = msgs.group_by { |m| m[:message_group_id] }

            deepest_leaf = select_deepest_leaf(msgs, by_id)
            return msgs.sort_by { |m| m[:seq] } unless deepest_leaf

            chain_ids       = collect_chain_ids(deepest_leaf, by_id)
            all_ids_ordered = insert_group_siblings(chain_ids, by_id, by_group)
            build_ordered_result(all_ids_ordered, msgs, by_id)
          end

          def select_deepest_leaf(msgs, by_id)
            parent_ids    = msgs.map { |m| m[:parent_id] }.compact.to_set
            leaf_msgs     = msgs.reject { |m| parent_ids.include?(m[:id]) }
            rooted_leaves = leaf_msgs.select { |leaf| chain_reaches_root?(leaf, by_id) }
            candidates    = rooted_leaves.empty? ? leaf_msgs : rooted_leaves
            candidates.max_by { |m| m[:seq] }
          end

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

          def insert_group_siblings(chain_ids, by_id, by_group)
            chain_id_set = chain_ids.to_set
            recovered    = collect_group_siblings(chain_ids, chain_id_set, by_id, by_group)
            all_ids      = chain_ids.dup
            recovered.each { |sibling| splice_sibling(all_ids, sibling, by_id) }
            all_ids
          end

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

          def splice_sibling(all_ids, sibling, by_id)
            return if all_ids.include?(sibling[:id])

            anchor = all_ids.find { |cid| by_id[cid]&.dig(:message_group_id) == sibling[:message_group_id] }
            if anchor
              all_ids.insert(all_ids.index(anchor) + 1, sibling[:id])
            else
              all_ids << sibling[:id]
            end
          end

          def build_ordered_result(all_ids_ordered, msgs, by_id)
            resolved_ids = all_ids_ordered.to_set
            orphans      = msgs.reject { |m| resolved_ids.include?(m[:id]) }.sort_by { |m| m[:seq] }
            all_ids_ordered.filter_map { |cid| by_id[cid] } + orphans
          end

          def chain_reaches_root?(msg, by_id)
            visited = {}
            current = msg
            while current
              return false if visited[current[:id]]

              visited[current[:id]] = true
              return true if current[:parent_id].nil?
              return false unless by_id.key?(current[:parent_id])

              current = by_id[current[:parent_id]]
            end
            true
          end

          def chain_or_seq(msgs)
            return msgs.sort_by { |m| m[:seq] } unless msgs.any? { |m| m[:parent_id] }

            reconstruct_chain(msgs)
          end
        end
      end
    end
  end
end

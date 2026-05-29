# frozen_string_literal: true

require 'digest'

require 'legion/logging/helper'
module Legion
  module LLM
    module Context
      class Curator
        include Legion::Logging::Helper

        CURATED_KEY = :__curated__

        # All known provider thinking tag variants.
        # Anthropic: <thinking>…</thinking>
        # DeepSeek / Qwen / Ollama / vLLM inline: <think>…</think>
        THINKING_TAG_PAIRS = [
          ['<thinking>', '</thinking>'],
          ['<think>',    '</think>']
        ].freeze

        def initialize(conversation_id:)
          @conversation_id = conversation_id
          @curated_messages = nil
        end

        # Called async after each turn completes — zero latency impact.
        def curate_turn(turn_messages:, assistant_response:)
          return unless enabled?

          current_turn_count = Array(turn_messages).size + (assistant_response ? 1 : 0)

          Thread.new do
            all_messages = Inference::Conversation.messages(@conversation_id)
            older = if current_turn_count.positive? && all_messages.size > current_turn_count
                     all_messages[0...-current_turn_count]
                   else
                     []
                   end

            if older.any?
              curated = older.map { |msg| curate_message(msg, assistant_response) }
              store_curated(@conversation_id, curated)
            end
            @curated_messages = nil
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.context_curator.curate_turn')
          end
        end

        # Called sync when building next API request.
        # Returns curated messages when available; nil means use raw history.
        def curated_messages
          return nil unless enabled?

          @curated_messages ||= load_curated(@conversation_id)
        end

        # Drops older conversation turns from the prompt window after archiving
        # them into Apollo for scoped retrieval on future turns.
        def drop_and_archive(messages, conversation_id:)
          return messages unless archive_dropped_turns?
          return messages unless messages.is_a?(Array) && messages.any?

          target_tokens = setting(:target_context_tokens, 40_000)
          estimated = Context::Compressor.estimate_tokens(messages)
          return messages if estimated <= target_tokens

          preserve_recent = setting(:archive_preserve_recent, setting(:preserve_recent, 10)).to_i
          preserve_recent = 1 unless preserve_recent.positive?
          return messages if messages.size <= preserve_recent

          retained = messages.last(preserve_recent)
          dropped = messages[0...-preserve_recent]
          return messages if dropped.empty?

          archived = archive_conversation_history(dropped, conversation_id: conversation_id)
          return messages unless archived

          log.info("[llm][context_curator] action=drop_and_archive conversation_id=#{conversation_id} " \
                   "dropped=#{dropped.size} retained=#{retained.size} estimated_tokens=#{estimated}")
          retained
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.context_curator.drop_and_archive',
                              conversation_id: conversation_id)
          messages
        end

        # Heuristic: distill a single tool-result message to a compact summary.
        def distill_tool_result(msg, _assistant_context = nil)
          content = msg[:content].to_s
          max_chars = setting(:tool_result_max_chars, 2000)
          return msg if content.length <= max_chars

          summary = heuristic_tool_summary(content, tool_name_from(msg))
          log.debug "[llm][curator] action=distill_tool_result conversation_id=#{@conversation_id} " \
                    "original_chars=#{content.length} summary_chars=#{summary.length}\n" \
                    "  BEFORE: #{content}\n" \
                    "  AFTER:  #{summary}"
          msg.merge(content: summary, curated: true, original_content: content)
        end

        # Heuristic: remove extended thinking blocks, keep conclusions.
        def strip_thinking(msg)
          return msg unless setting(:thinking_eviction, true)

          content = msg[:content].to_s
          stripped = strip_thinking_tags(content)
          stripped = stripped.gsub(/^#+\s*[Tt]hinking[^\n]*\n(?:[^#\n][^\n]*\n)*/m, '').strip

          return msg if stripped == content || stripped.empty?

          log.debug "[llm][curator] action=strip_thinking conversation_id=#{@conversation_id} " \
                    "original_chars=#{content.length} stripped_chars=#{stripped.length}\n" \
                    "  BEFORE: #{content}\n" \
                    "  AFTER:  #{stripped}"
          msg.merge(content: stripped, curated: true, original_content: content)
        end

        # Heuristic: detect multi-turn clarification that reached agreement; fold to single system note.
        def fold_resolved_exchanges(messages)
          return messages unless setting(:exchange_folding, true)

          result = []
          i = 0
          while i < messages.length
            window = messages[i, 4]
            if resolved_exchange?(window)
              conclusion = window.last[:content].to_s[0, 300]
              note = {
                role:             :system,
                content:          "[Exchange resolved: #{conclusion}]",
                curated:          true,
                original_content: window.map { |m| m[:content] }.join("\n")
              }
              result << note
              i += window.length
            else
              result << messages[i]
              i += 1
            end
          end
          result
        end

        # Heuristic: if same file was read multiple times, keep only the latest read.
        def evict_superseded(messages)
          return messages unless setting(:superseded_eviction, true)

          file_last_seen = {}
          messages.each_with_index do |msg, idx|
            path = extract_file_path(msg[:content].to_s)
            file_last_seen[path] = idx if path
          end

          messages.each_with_index.reject do |msg, idx|
            path = extract_file_path(msg[:content].to_s)
            path && file_last_seen[path] != idx
          end.map(&:first)
        end

        # Heuristic: deduplicate near-identical messages using Jaccard similarity.
        def dedup_similar(messages, threshold: nil)
          return messages unless setting(:dedup_enabled, true)

          threshold ||= setting(:dedup_threshold, 0.85)
          result = Context::Compressor.deduplicate_messages(messages, threshold: threshold)
          result[:messages]
        end

        # LLM-assisted distillation: uses small/fast model to summarize tool results.
        # Falls back to heuristic on any error.
        def llm_distill_tool_result(msg, assistant_response = nil)
          return distill_tool_result(msg, assistant_response) unless llm_assisted?

          content = msg[:content].to_s
          max_chars = setting(:tool_result_max_chars, 2000)
          return msg if content.length <= max_chars

          summary = llm_summarize_tool_result(content, tool_name_from(msg))
          if summary
            msg.merge(content: summary, curated: true, original_content: content)
          else
            distill_tool_result(msg, assistant_response)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn)
          distill_tool_result(msg, assistant_response)
        end

        private

        def enabled?
          setting(:enabled, true)
        end

        def llm_assisted?
          enabled? &&
            setting(:llm_assisted, false) &&
            setting(:mode, 'heuristic') == 'llm_assisted'
        end

        def archive_dropped_turns?
          setting(:archive_dropped_turns, true)
        end

        def curation_settings
          Legion::LLM::Settings.value(:context_curation, default: {})
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.context_curator.curation_settings')
          {}
        end

        def setting(key, default)
          val = Legion::LLM::Settings.config_value(curation_settings, key)
          val.nil? ? default : val
        end

        def strip_thinking_tags(text)
          result = text
          THINKING_TAG_PAIRS.each do |open_tag, close_tag|
            result = strip_tag_pair(result, open_tag, close_tag)
          end
          result
        end

        def strip_tag_pair(text, open_tag, close_tag)
          out = +''
          pos = 0
          while pos < text.length
            open_idx = text.index(open_tag, pos)
            break unless open_idx

            out << text[pos...open_idx]
            close_idx = text.index(close_tag, open_idx + open_tag.length)
            pos = close_idx ? close_idx + close_tag.length : text.length
          end
          out << text[pos..] if pos < text.length
          # Strip any unclosed open tag left at the end (provider died mid-stream).
          out.sub(/#{Regexp.escape(open_tag)}.*\z/m, '').strip
        end

        def curate_message(msg, assistant_response)
          return msg if msg[:role] == :system

          msg = strip_thinking(msg)
          if llm_assisted?
            llm_distill_tool_result(msg, assistant_response)
          else
            distill_tool_result(msg, assistant_response)
          end
        end

        def store_curated(conversation_id, curated_messages)
          curated_count = 0
          curated_messages.each_with_index do |msg, index|
            next unless msg[:curated]

            Inference::Conversation.append(
              conversation_id,
              role:        CURATED_KEY,
              content:     Legion::JSON.dump(curated_message_payload(msg, index)),
              source_id:   msg[:id],
              source_seq:  msg[:seq],
              source_role: msg[:role]
            )
            curated_count += 1
          end

          Inference::Conversation.append(
            conversation_id,
            role:            CURATED_KEY,
            content:         Legion::JSON.dump(type: 'curation_marker', curated_count: curated_count),
            curation_marker: true,
            curated_count:   curated_count
          )
        rescue StandardError => e
          handle_exception(e, level: :warn)
        end

        def load_curated(conversation_id)
          return nil unless Inference::Conversation.conversation_exists?(conversation_id)

          # Use raw_messages so CURATED_ROLE entries are visible even though they
          # are filtered out of the public-facing Conversation#messages array.
          raw = Inference::Conversation.raw_messages(conversation_id)
          curated_entries = raw.select { |m| m[:role] == CURATED_KEY }
          return nil if curated_entries.empty?

          regular = raw.reject { |m| [CURATED_KEY, Inference::Conversation::METADATA_ROLE].include?(m[:role]) }
          summaries = normalized_curated_summaries(curated_entries)
          if summaries.empty?
            apply_curation_pipeline(regular)
          else
            apply_structural_curation_pipeline(substitute_curated_summaries(regular, summaries))
          end
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        # Apply heuristic curation pipeline to a set of messages.
        def apply_curation_pipeline(messages)
          return messages if messages.nil? || messages.empty?

          result = messages.map { |msg| strip_thinking(msg) }
          result = result.map { |msg| distill_tool_result(msg) }
          result = fold_resolved_exchanges(result)
          result = evict_superseded(result)
          dedup_similar(result)
        rescue StandardError => e
          handle_exception(e, level: :warn)
          messages
        end

        def apply_structural_curation_pipeline(messages)
          result = fold_resolved_exchanges(messages)
          result = evict_superseded(result)
          dedup_similar(result)
        rescue StandardError => e
          handle_exception(e, level: :warn)
          messages
        end

        def archive_conversation_history(messages, conversation_id:)
          payload = archived_history_payload(messages, conversation_id: conversation_id)
          return false if payload[:content].empty?

          if defined?(::Legion::Apollo::Local) && ::Legion::Apollo::Local.started?
            ::Legion::Apollo::Local.ingest(
              content:        payload[:content],
              tags:           payload[:tags],
              source_channel: 'llm_context_curator',
              confidence:     0.75,
              metadata:       payload[:metadata]
            )
            return true
          end

          if defined?(::Legion::Apollo) && ::Legion::Apollo.respond_to?(:ingest)
            ::Legion::Apollo.ingest(
              content:          payload[:content],
              content_type:     'conversation_turn',
              tags:             payload[:tags],
              source_channel:   'llm_context_curator',
              knowledge_domain: 'conversation_history',
              context:          payload[:metadata]
            )
            return true
          end

          if defined?(::Legion::Extensions::Apollo::Runners::Knowledge) &&
             ::Legion::Extensions::Apollo::Runners::Knowledge.respond_to?(:handle_ingest)
            result = ::Legion::Extensions::Apollo::Runners::Knowledge.handle_ingest(
              content:          payload[:content],
              content_type:     'conversation_turn',
              tags:             payload[:tags],
              source_agent:     'legion-llm',
              source_channel:   'llm_context_curator',
              knowledge_domain: 'conversation_history',
              context:          payload[:metadata]
            )
            return result.nil? || !result.respond_to?(:key?) || result[:success] != false
          end

          log.debug("[llm][context_curator] action=drop_and_archive.skipped reason=apollo_unavailable conversation_id=#{conversation_id}")
          false
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.context_curator.archive_conversation_history',
                              conversation_id: conversation_id)
          false
        end

        def archived_history_payload(messages, conversation_id:)
          seqs = messages.filter_map { |msg| msg[:seq] }
          {
            content:  messages.map { |msg| archived_message_line(msg) }.join("\n"),
            tags:     ['llm_conversation_history', "conversation:#{conversation_id}"],
            metadata: {
              conversation_id: conversation_id,
              seq_start:       seqs.min,
              seq_end:         seqs.max,
              message_count:   messages.size,
              source:          'conversation_history'
            }.compact
          }
        end

        def archived_message_line(msg)
          role = msg[:role] || 'unknown'
          content = msg[:content]
          content = content.filter_map { |part| part.is_a?(Hash) ? part[:text] || part['text'] : part.to_s }.join if content.is_a?(Array)
          "[#{role}] #{content}"
        end

        def curated_message_payload(msg, index)
          {
            type:          'curated_message',
            content:       msg[:content],
            original_hash: content_digest(msg[:original_content] || msg[:content]),
            source_id:     msg[:id],
            source_seq:    msg[:seq] || (index + 1),
            source_role:   msg[:role]
          }.compact
        end

        def normalized_curated_summaries(entries)
          entries.filter_map do |entry|
            payload = curated_payload(entry)
            next if payload_value(payload, :type) == 'curation_marker' || entry[:curation_marker]

            {
              content:          payload_value(payload, :content) || entry[:content],
              original_content: payload_value(payload, :original_content) || entry[:original_content],
              original_hash:    payload_value(payload, :original_hash) || content_digest(entry[:original_content]),
              source_id:        payload_value(payload, :source_id) || entry[:source_id],
              source_seq:       payload_value(payload, :source_seq) || entry[:source_seq],
              source_role:      payload_value(payload, :source_role) || entry[:source_role]
            }.compact
          end
        end

        def substitute_curated_summaries(messages, summaries)
          by_id       = summary_index(summaries, :source_id)
          by_seq      = summary_index(summaries, :source_seq) { |summary| summary_key(summary[:source_role], summary[:source_seq]) }
          by_original = summary_index(summaries, :original_hash) { |summary| summary_key(summary[:source_role], summary[:original_hash]) }

          messages.map do |msg|
            summary = by_id[msg[:id]] ||
                      by_seq[summary_key(msg[:role], msg[:seq])] ||
                      by_original[summary_key(msg[:role], content_digest(msg[:content]))]
            next msg unless summary

            msg.merge(
              content:          summary[:content],
              curated:          true,
              original_content: summary[:original_content] || msg[:content]
            )
          end
        end

        def summary_index(summaries, field)
          summaries.each_with_object({}) do |summary, index|
            next unless summary[field]

            key = block_given? ? yield(summary) : summary[field]
            index[key] = summary
          end
        end

        def summary_key(role, value)
          [role.to_s, value]
        end

        def content_digest(content)
          return nil if content.nil?

          Digest::SHA256.hexdigest(content.to_s)
        end

        def curated_payload(entry)
          parsed = Legion::JSON.parse(entry[:content].to_s)
          parsed.is_a?(Hash) ? parsed : {}
        rescue Legion::JSON::ParseError => e
          log.debug "[llm][curator] action=curated_payload conversation_id=#{@conversation_id} error=#{e.class} — #{e.message}"
          {}
        end

        def payload_value(payload, key)
          payload[key] || payload[key.to_s]
        end

        # Build a heuristic summary for a tool result based on detected tool type.
        def heuristic_tool_summary(content, tool_name)
          lines = content.lines
          line_count = lines.length
          char_count = content.length

          case tool_name&.to_s
          when /read_file|read/
            first_line = lines.first.to_s.chomp
            last_line  = lines.last.to_s.chomp
            "Read file (#{line_count} lines). First: #{first_line[0, 80]}... Last: #{last_line[0, 80]}"
          when /search|grep|glob/
            file_count = content.lines.count { |l| l.include?('/') }
            "Search returned #{line_count} matches across #{file_count} files"
          when /bash|run_command|execute/
            exit_match = content.match(/exit(?:\s+code)?:?\s*(\d+)/i)
            exit_code  = exit_match ? exit_match[1] : '0'
            last_lines = lines.last(3).map(&:chomp).join(' | ')
            "Command output (#{line_count} lines), exit #{exit_code}: #{last_lines[0, 200]}"
          else
            preview = content[0, 200]
            "Tool result (#{line_count} lines, #{char_count} chars): #{preview}"
          end
        end

        # Detect tool name from message metadata or content.
        def tool_name_from(msg)
          msg[:tool_name] || msg[:name] || infer_tool_name(msg[:content].to_s)
        end

        def infer_tool_name(content)
          first_line = content[0, 200]
          return :read_file   if first_line.match?(/\AFile:|\ARead:|\A#\s+\S+\.rb|\A\d+\t/)
          return :bash        if first_line.match?(/exit code|STDOUT|STDERR/i)
          return :search      if first_line.include?(' match') && first_line.match?(/\d++ match/)

          nil
        end

        # Detect if a 2–4 message window represents a resolved Q&A exchange.
        def resolved_exchange?(window)
          return false if window.length < 2

          roles = window.map { |m| m[:role].to_s }
          # Simple pattern: user -> assistant -> user -> assistant with clarification signals
          return false unless roles.first == 'user' && roles.last == 'assistant'

          contents = window.map { |m| m[:content].to_s.downcase }
          clarification_signals = ['clarif', 'what do you mean', 'i see', 'understood', 'got it', 'correct', 'exactly', 'yes', 'right', 'agree']
          conclusion_signals    = ['in summary', 'to summarize', 'in conclusion', 'therefore', 'so to answer', 'the answer is']

          has_clarification = contents.any? { |c| clarification_signals.any? { |s| c.include?(s) } }
          has_conclusion    = contents.last.length < 500 || conclusion_signals.any? { |s| contents.last.include?(s) }

          has_clarification && has_conclusion
        end

        # Extract a file path from content heuristically.
        def extract_file_path(content)
          prefix = content[0, 500]
          match = prefix.match(%r{(?:reading|read|loaded?|opened?|file:)\s+[`'"]?(/\S+)[`'"]?}i) ||
                  prefix.match(%r{^(/[\w./-]+\.\w+)})
          match ? match[1] : nil
        end

        # Use a small/fast LLM model to distill a tool result.
        def llm_summarize_tool_result(content, tool_name)
          return nil unless defined?(Legion::LLM) && Legion::LLM.respond_to?(:chat_direct)

          model = setting(:llm_model, nil) || detect_small_model
          return nil unless model

          prompt = build_distillation_prompt(content, tool_name)
          response = Legion::LLM.chat_direct(model: model, message: prompt)
          response.respond_to?(:content) ? response.content : nil
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        def build_distillation_prompt(content, tool_name)
          tool_hint = tool_name ? " (from #{tool_name})" : ''
          <<~PROMPT.strip
            Summarize this tool result#{tool_hint} in 1-3 sentences, preserving key facts, file paths, line numbers, and error messages. Omit irrelevant details.

            Tool result:
            #{content[0, 4000]}
          PROMPT
        end

        def detect_small_model
          ext = Legion::Settings[:extensions]
          providers = (ext.is_a?(Hash) && ext[:llm].is_a?(Hash) ? ext[:llm] : {})
          %w[ollama vllm mlx].each do |provider|
            config = Legion::LLM::Settings.config_value(providers, provider, {})
            enabled = Legion::LLM::Settings.config_value(config, :enabled)
            model = Legion::LLM::Settings.config_value(config, :default_model)
            return model if config.is_a?(Hash) && enabled && model
          end
          nil
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.context_curator.detect_small_model')
          nil
        end
      end
    end
  end
end

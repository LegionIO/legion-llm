# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    class ContextCurator
      include Legion::Logging::Helper

      CURATED_KEY = :__curated__

      def initialize(conversation_id:)
        @conversation_id = conversation_id
        @curated_cache   = nil
      end

      # Called async after each turn completes — zero latency impact.
      def curate_turn(turn_messages:, assistant_response:)
        return unless enabled?

        Thread.new do
          curated = turn_messages.map { |msg| curate_message(msg, assistant_response) }
          store_curated(@conversation_id, curated)
          @curated_cache = nil
        rescue StandardError => e
          handle_exception(e, level: :warn)
        end
      end

      # Called sync when building next API request.
      # Returns curated messages when available; nil means use raw history.
      def curated_messages
        return nil unless enabled?

        @curated_messages ||= load_curated(@conversation_id)
      end

      # Heuristic: distill a single tool-result message to a compact summary.
      def distill_tool_result(msg, _assistant_context = nil)
        content = msg[:content].to_s
        max_chars = setting(:tool_result_max_chars, 2000)
        return msg if content.length <= max_chars

        summary = heuristic_tool_summary(content, tool_name_from(msg))
        msg.merge(content: summary, curated: true, original_content: content)
      end

      # Heuristic: remove extended thinking blocks, keep conclusions.
      def strip_thinking(msg)
        return msg unless setting(:thinking_eviction, true)

        content = msg[:content].to_s
        stripped = content
                   .gsub(%r{<thinking>.*?</thinking>}m, '')
                   .gsub(/^#+\s*[Tt]hinking.*?\n(?:(?!^#+\s).)*\n/m, '')
                   .strip

        return msg if stripped == content || stripped.empty?

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
        result = Compressor.deduplicate_messages(messages, threshold: threshold)
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

      def curation_settings
        Legion::Settings.dig(:llm, :context_curation) || {}
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.context_curator.curation_settings')
        {}
      end

      def setting(key, default)
        val = curation_settings[key]
        val.nil? ? default : val
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
        curated_messages.each do |msg|
          next unless msg[:curated]

          ConversationStore.append(
            conversation_id,
            role:             CURATED_KEY,
            content:          msg[:content],
            original_content: msg[:original_content],
            source_role:      msg[:role]
          )
        end
      rescue StandardError => e
        handle_exception(e, level: :warn)
      end

      def load_curated(conversation_id)
        return nil unless ConversationStore.conversation_exists?(conversation_id)

        raw = ConversationStore.messages(conversation_id)
        curated = raw.select { |m| m[:role] == CURATED_KEY }
        return nil if curated.empty?

        regular = raw.reject { |m| m[:role] == CURATED_KEY }
        apply_curation_pipeline(regular)
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
          file_count = content.scan(%r{[^\s/]+/[^\s]+}).uniq.length
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
        return :read_file   if content.match?(/\A(?:File:|Read:|#\s+\S+\.rb|\d+\t)/)
        return :bash        if content.match?(/exit code|STDOUT|STDERR/i)
        return :search      if content.match?(/\d+ match(?:es)? (?:across|in)/i)

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
        match = content.match(%r{(?:reading|read|loaded?|opened?|file:)\s+[`'"]?(/[^\s`'"]+)[`'"]?}i) ||
                content.match(%r{^(/(?:[\w.-]+/)*[\w.-]+\.\w+)})
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
        providers = Legion::Settings.dig(:llm, :providers) || {}
        %w[ollama].each do |provider|
          config = providers[provider.to_sym] || providers[provider]
          return config[:default_model] if config.is_a?(Hash) && config[:enabled] && config[:default_model]
        end
        nil
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.context_curator.detect_small_model')
        nil
      end
    end
  end
end

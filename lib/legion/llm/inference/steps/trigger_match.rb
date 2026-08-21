# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module TriggerMatch
          include Legion::Logging::Helper
          include Steps::Logging

          def step_trigger_match
            start_time = nil
            extensions = settings_extensions
            unless extensions.respond_to?(:tools)
              log_step_debug(:trigger_match, :skipped, reason: :settings_extensions_unavailable)
              log_trigger_match(:skipped, reason: :settings_extensions_unavailable)
              return
            end

            start_time = ::Time.now

            text = extract_recent_text
            word_set = normalize_message_words(text)
            if word_set.empty?
              log_step_debug(:trigger_match, :skipped, reason: :no_words)
              return
            end
            log_step_debug(:trigger_match, :scanning, word_count: word_set.size)

            matched, per_word = settings_extension_tool_matches(word_set, extensions)
            pre_filter_count = matched.size
            subtract_always_loaded(matched, extensions)
            if matched.empty?
              log_step_debug(:trigger_match, :no_matches)
              log_trigger_match(:no_matches, word_count: word_set.size, pre_filter_count: pre_filter_count)
              return
            end

            limit = trigger_tool_limit
            @triggered_tools = if matched.size <= limit
                                 matched.to_a
                               else
                                 log.warn(
                                   "[llm][steps][trigger_match] action=tools_capped request_id=#{@request.id} " \
                                   "matched=#{matched.size} limit=#{limit} dropped=#{matched.size - limit}"
                                 )
                                 rank_and_cap(matched, per_word, limit)
                               end

            names = @triggered_tools.map { |tool| trigger_tool_name(tool) }
            if @triggered_tools.any?
              @enrichments['tool:trigger_match'] = {
                content:   "#{@triggered_tools.size} tools matched via trigger words",
                data:      { tool_count: @triggered_tools.size, tool_names: names },
                timestamp: ::Time.now
              }
            end

            record_trigger_match_timeline(@triggered_tools.size, start_time)
            log_step_debug(:trigger_match, :matched, matched_count: matched.size, injected_count: @triggered_tools.size, limit: limit)
            log_trigger_match(:matched, word_count: word_set.size, matched_count: matched.size,
                                        injected_count: @triggered_tools.size, limit: limit,
                                        names: names)
          rescue StandardError => e
            @warnings << "Trigger match error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.trigger_match')
            record_trigger_match_timeline(0, start_time)
          end

          HARNESS_PREFIXES = [
            '[SUGGESTION MODE',
            '[REQUEST INTERRUPTED',
            'Write the title in the predominant language'
          ].freeze

          def extract_recent_text
            depth = trigger_scan_depth
            messages = @request.messages.last(depth)

            # G3: pipeline messages are Canonical::Message — role/text are
            # member reads (no dual-shape accessor).
            text = messages.filter_map do |msg|
              next unless msg.role.to_s == 'user'

              raw = msg.text.to_s
              next if harness_message?(raw)

              raw
            end.join(' ')

            sanitize_trigger_text(text)
          end

          def sanitize_trigger_text(text)
            session_text = extract_session_text(text)
            return session_text if session_text

            strip_tagged_blocks(text)
          end

          def strip_tagged_blocks(text)
            text.to_s.gsub(%r{<[a-z][\w-]*\b[^>]*>.*?</[a-z][\w-]*>}mi, ' ')
          end

          def harness_message?(text)
            return false if text.nil? || text.empty?

            trimmed = text.lstrip
            HARNESS_PREFIXES.any? { |prefix| trimmed.start_with?(prefix) }
          end

          def extract_session_text(text)
            matches = text.to_s.scan(%r{<session\b[^>]*>(.*?)</session>}mi).flatten
            return nil if matches.empty?

            matches.join(' ')
          end

          def normalize_message_words(text)
            return Set.new if text.nil? || text.empty?

            text.downcase.gsub(/[^a-z ]/, ' ').split.to_set
          end

          def settings_extensions
            return unless defined?(Legion::Settings::Extensions)

            Legion::Settings::Extensions
          end

          def settings_extension_tool_matches(word_set, extensions = settings_extensions)
            matched = Set.new
            per_word = Hash.new { |hash, word| hash[word] = Set.new }
            return [matched, per_word] unless extensions.respond_to?(:tools)

            Array(extensions.tools).each do |entry|
              next unless entry.is_a?(Hash)

              tool_words = trigger_words_for_entry(entry)
              matching_words = word_set & tool_words
              next if matching_words.empty?

              matched << entry
              matching_words.each { |word| per_word[word] << entry }
            end

            [matched, per_word]
          end

          def trigger_words_for_entry(entry)
            values = Array(entry[:trigger_words])
            values << trigger_tool_name_for_word_match(entry[:name])
            values << entry[:extension]
            values << entry[:runner]
            values << entry[:function]
            normalize_message_words(values.compact.join(' '))
          end

          def trigger_tool_name_for_word_match(name)
            name.to_s.sub(/\Alegion[-_]/, '')
          end

          def rank_and_cap(matched, per_word, limit)
            scores = Hash.new(0)
            per_word.each_value do |tools|
              tools.each { |tool| scores[tool] += 1 }
            end
            matched.to_a
                   .sort_by { |tool| [-scores[tool], trigger_tool_name(tool)] }
                   .first(limit)
          end

          def subtract_always_loaded(matched, extensions = settings_extensions)
            unless extensions.respond_to?(:filter_tools)
              log_step_debug(:trigger_match, :always_loaded_filter_skipped, reason: :settings_extensions_unavailable)
              return
            end

            always = extensions.filter_tools(deferred: false).map { |t| t[:name] }
            matched.reject! { |tool| always.include?(trigger_tool_name(tool)) }
            log_step_debug(:trigger_match, :always_loaded_filtered, always_loaded_count: always.size, remaining_count: matched.size)
          end

          def trigger_tool_name(tool)
            if tool.is_a?(Hash)
              (tool[:name] || tool['name']).to_s
            elsif tool.respond_to?(:tool_name)
              tool.tool_name.to_s
            else
              tool.to_s
            end
          end

          def trigger_scan_depth
            Legion::Settings[:llm][:tools][:trigger][:scan_depth]
          end

          def trigger_tool_limit
            Legion::Settings[:llm][:tools][:trigger][:tool_limit]
          end

          def log_trigger_match(action, **fields)
            payload = fields.map { |key, value| "#{key}=#{format_trigger_log_value(value)}" }.join(' ')
            log.info(
              "[llm][tools][trigger] action=#{action} request_id=#{@request.id} " \
              "conversation_id=#{@request.conversation_id || 'none'} #{payload}".strip
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.steps.trigger_match.log')
          end

          def format_trigger_log_value(value)
            case value
            when Array
              value.map(&:to_s).first(Legion::Settings[:llm][:tools][:trigger][:log_name_limit]).join(',')
            else
              value
            end
          end

          def record_trigger_match_timeline(count, start_time = nil)
            return unless @timeline.respond_to?(:record)

            duration = start_time ? ((::Time.now - start_time) * 1000).to_i : 0
            @timeline.record(
              category: :enrichment, key: 'tool:trigger_match',
              direction: :inbound, detail: "#{count} tools matched via trigger words",
              from: 'settings_extensions', to: 'pipeline',
              duration_ms: duration
            )
          end
        end
      end
    end
  end
end

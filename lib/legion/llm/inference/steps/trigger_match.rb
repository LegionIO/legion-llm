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
            unless defined?(::Legion::Tools::TriggerIndex)
              log_step_debug(:trigger_match, :skipped, reason: :trigger_index_unavailable)
              return
            end
            if ::Legion::Tools::TriggerIndex.empty?
              log_step_debug(:trigger_match, :skipped, reason: :trigger_index_empty)
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

            matched, per_word = ::Legion::Tools::TriggerIndex.match(word_set)
            subtract_always_loaded(matched)
            if matched.empty?
              log_step_debug(:trigger_match, :no_matches)
              return
            end

            limit = trigger_tool_limit
            @triggered_tools = if matched.size <= limit
                                 matched.to_a
                               else
                                 rank_and_cap(matched, per_word, limit)
                               end

            if @triggered_tools.any?
              names = @triggered_tools.map(&:tool_name)
              @enrichments['tool:trigger_match'] = {
                content:   "#{@triggered_tools.size} tools matched via trigger words",
                data:      { tool_count: @triggered_tools.size, tool_names: names },
                timestamp: ::Time.now
              }
            end

            record_trigger_match_timeline(@triggered_tools.size, start_time)
            log_step_debug(:trigger_match, :matched, matched_count: matched.size, injected_count: @triggered_tools.size, limit: limit)
          rescue StandardError => e
            @warnings << "Trigger match error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.trigger_match')
            record_trigger_match_timeline(0, start_time)
          end

          private

          def extract_recent_text
            depth = trigger_scan_depth
            messages = @request.messages.last(depth)
            messages.filter_map do |msg|
              next unless msg.is_a?(Hash)
              next unless (msg[:role] || msg['role']).to_s == 'user'

              content = msg[:content] || msg['content']
              content.is_a?(Array) ? content.map { |c| c[:text] || c['text'] }.join(' ') : content.to_s
            end.join(' ')
          end

          def normalize_message_words(text)
            return Set.new if text.nil? || text.empty?

            text.downcase.gsub(/[^a-z ]/, ' ').split.to_set
          end

          def rank_and_cap(matched, per_word, limit)
            scores = Hash.new(0)
            per_word.each_value do |tools|
              tools.each { |tool| scores[tool] += 1 }
            end
            matched.to_a
                   .sort_by { |tool| [-scores[tool], tool.tool_name] }
                   .first(limit)
          end

          def subtract_always_loaded(matched)
            unless Legion::Settings::Extensions.respond_to?(:filter_tools)
              log_step_debug(:trigger_match, :always_loaded_filter_skipped, reason: :settings_extensions_unavailable)
              return
            end

            always = Legion::Settings::Extensions.filter_tools(deferred: false).map { |t| t[:name] }
            matched.reject! { |tool| always.include?(tool.tool_name) }
            log_step_debug(:trigger_match, :always_loaded_filtered, always_loaded_count: always.size, remaining_count: matched.size)
          end

          def trigger_scan_depth
            tool_trigger_setting(:scan_depth, 10)
          end

          def trigger_tool_limit
            tool_trigger_setting(:tool_limit, 50)
          end

          def tool_trigger_setting(key, default = nil)
            Legion::LLM::Settings.config_value(settings_value(:tool_trigger, default: {}), key, default)
          end

          def settings_value(*keys, default: nil)
            Legion::LLM::Settings.value(*keys, default: default)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.steps.trigger_match.settings', keys: keys)
            default
          end

          def record_trigger_match_timeline(count, start_time = nil)
            return unless @timeline.respond_to?(:record)

            duration = start_time ? ((::Time.now - start_time) * 1000).to_i : 0
            @timeline.record(
              category: :enrichment, key: 'tool:trigger_match',
              direction: :inbound, detail: "#{count} tools matched via trigger words",
              from: 'trigger_index', to: 'pipeline',
              duration_ms: duration
            )
          end
        end
      end
    end
  end
end

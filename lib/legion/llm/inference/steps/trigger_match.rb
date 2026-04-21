# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module TriggerMatch
          include Legion::Logging::Helper

          def step_trigger_match
            start_time = nil
            return unless defined?(::Legion::Tools::TriggerIndex)
            return if ::Legion::Tools::TriggerIndex.empty?

            start_time = ::Time.now

            text = extract_recent_text
            word_set = normalize_message_words(text)
            return if word_set.empty?

            matched, per_word = ::Legion::Tools::TriggerIndex.match(word_set)
            subtract_always_loaded(matched)
            return if matched.empty?

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
            return unless defined?(::Legion::Tools::Registry) &&
                          ::Legion::Tools::Registry.respond_to?(:always_loaded_names)

            always = ::Legion::Tools::Registry.always_loaded_names
            matched.reject! { |tool| always.include?(tool.tool_name) }
          end

          def trigger_scan_depth
            Legion::Settings.dig(:llm, :tool_trigger, :scan_depth) || 2
          end

          def trigger_tool_limit
            Legion::Settings.dig(:llm, :tool_trigger, :tool_limit) || 50
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

# frozen_string_literal: true

require 'json'

require 'legion/logging/helper'
module Legion
  module LLM
    module Quality
      module Checker
        extend Legion::Logging::Helper

        QualityResult = Struct.new(:passed, :failures)

        REPETITION_MIN_LENGTH = 20
        REPETITION_THRESHOLD  = 3
        DEFAULT_QUALITY_THRESHOLD = 50

        REFUSAL_PATTERNS = [
          /\bI (?:can(?:'t|not)|cannot|won't|am unable to)\b/i,
          /\bI'm not able to\b/i,
          /\bas an AI\b/i,
          /\bI don't have (?:the ability|access)\b/i
        ].freeze

        class << self
          def check(response, quality_threshold: DEFAULT_QUALITY_THRESHOLD, json_expected: false, quality_check: nil)
            failures = []
            content = effective_content(response)
            has_tool_calls = response.respond_to?(:tool_calls) && response.tool_calls&.any?

            failures << :empty_response if !has_tool_calls && (content.nil? || content.strip.empty?)

            unless failures.include?(:empty_response)
              if quality_setting(:too_short, false) && content.length < quality_threshold
                failures << :too_short
                log.debug "[llm][quality] check=too_short result=fail content_length=#{content.length} threshold=#{quality_threshold}"
              end
              if quality_setting(:repetition, false) && repetitive?(content)
                failures << :repetition
                log.debug "[llm][quality] check=repetition result=fail content_length=#{content.length}"
              end
              if quality_setting(:truncated, false) && truncated?(content)
                failures << :truncated
                log.debug '[llm][quality] check=truncated result=fail'
              end
              if quality_setting(:refusal, false) && refusal?(content)
                failures << :refusal
                log.debug '[llm][quality] check=refusal result=fail'
              end
              if json_expected && !valid_json?(content)
                failures << :json_parse_failure
                log.debug '[llm][quality] check=json_parse result=fail'
              end
            end

            failures << :custom_check_failed if quality_check.respond_to?(:call) && !quality_check.call(response)

            result = QualityResult.new(passed: failures.empty?, failures: failures)
            if result.passed
              log.info "[llm][quality] action=check result=passed content_length=#{content.to_s.length}"
            else
              log.warn "[llm][quality] action=check result=failed failures=#{failures.join(',')}"
            end
            result
          end

          def effective_content(response)
            content = response.respond_to?(:content) ? response.content.to_s : ''
            return content unless content.to_s.strip.empty?

            thinking = response.respond_to?(:thinking) ? response.thinking : nil
            return content unless thinking

            "#{content}#{extract_thinking_content(thinking)}"
          rescue StandardError
            content
          end

          def extract_thinking_content(thinking)
            extracted = if thinking.is_a?(Hash)
                          normalized = thinking.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                          normalized[:content] || normalized[:text]
                        elsif thinking.respond_to?(:content)
                          thinking.content
                        elsif thinking.respond_to?(:text)
                          thinking.text
                        else
                          thinking
                        end
            extracted.to_s.strip
          rescue StandardError
            ''
          end

          def quality_setting(key, default)
            value = Legion::Settings.dig(:llm, :quality, key)
            value.nil? ? default : value
          end

          private

          def repetitive?(content)
            return false if content.length < REPETITION_MIN_LENGTH * REPETITION_THRESHOLD

            seen = {}
            (0..(content.length - REPETITION_MIN_LENGTH)).step(REPETITION_MIN_LENGTH) do |i|
              chunk = content[i, REPETITION_MIN_LENGTH]
              seen[chunk] = (seen[chunk] || 0) + 1
              return true if seen[chunk] >= REPETITION_THRESHOLD
            end

            false
          end

          def truncated?(content)
            return false if content.length < 100

            last_chars = content[-3..]
            return true if last_chars&.match?(/\w{3}\z/) && !content.end_with?('.', '!', '?', '`', '"', "'", ')', ']', '}', "\n")

            false
          end

          def refusal?(content)
            first_line = content.lines.first.to_s
            REFUSAL_PATTERNS.any? { |pat| first_line.match?(pat) }
          end

          def valid_json?(content)
            Legion::JSON.parse(content, symbolize_names: false)
            true
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn)
            false
          end
        end
      end
    end
  end
end

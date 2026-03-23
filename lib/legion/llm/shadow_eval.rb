# frozen_string_literal: true

module Legion
  module LLM
    module ShadowEval
      class << self
        def enabled?
          Legion::Settings.dig(:llm, :shadow, :enabled) == true
        end

        def should_sample?
          return false unless enabled?

          rate = Legion::Settings.dig(:llm, :shadow, :sample_rate) || 0.1
          rand < rate
        end

        def evaluate(primary_response:, messages: nil, shadow_model: nil)
          shadow_model ||= Legion::Settings.dig(:llm, :shadow, :model) || 'gpt-4o-mini'
          Legion::Logging.debug("ShadowEval triggered primary_model=#{primary_response[:model]} shadow_model=#{shadow_model}") if defined?(Legion::Logging)

          shadow_response = Legion::LLM.send(:chat_single,
                                             model: shadow_model, provider: nil,
                                             messages: messages, intent: nil,
                                             tier: nil)

          comparison = compare(primary_response, shadow_response, shadow_model)
          Legion::Events.emit('llm.shadow_eval', comparison) if defined?(Legion::Events)
          comparison
        rescue StandardError => e
          Legion::Logging.warn("ShadowEval failed shadow_model=#{shadow_model}: #{e.message}") if defined?(Legion::Logging)
          { error: e.message, shadow_model: shadow_model }
        end

        def compare(primary, shadow, shadow_model)
          primary_len = primary[:content]&.length || 0
          shadow_len = shadow[:content]&.length || 0

          {
            primary_model:  primary[:model],
            shadow_model:   shadow_model,
            primary_tokens: primary[:usage],
            shadow_tokens:  shadow[:usage],
            length_ratio:   primary_len.zero? ? 0.0 : shadow_len.to_f / primary_len,
            evaluated_at:   Time.now.utc
          }
        end
      end
    end
  end
end

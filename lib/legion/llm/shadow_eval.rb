# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module ShadowEval
      extend Legion::Logging::Helper
      MAX_HISTORY = 100

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
          log.info(
            "[llm][shadow] evaluate primary_model=#{primary_response[:model]} shadow_model=#{shadow_model}"
          )

          shadow_response = Legion::LLM.send(:chat_single,
                                             model: shadow_model, provider: nil,
                                             messages: messages, intent: nil,
                                             tier: nil)

          comparison = compare(primary_response, shadow_response, shadow_model)
          record(comparison)
          log.info(
            "[llm][shadow] recorded primary_model=#{comparison[:primary_model]} " \
            "shadow_model=#{comparison[:shadow_model]} cost_savings=#{comparison[:cost_savings]}"
          )
          Legion::Events.emit('llm.shadow_eval', comparison) if defined?(Legion::Events)
          comparison
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.shadow_eval.evaluate', shadow_model: shadow_model)
          log.error("[llm][shadow] evaluate_failed shadow_model=#{shadow_model} error=#{e.message}")
          { error: e.message, shadow_model: shadow_model }
        end

        def compare(primary, shadow, shadow_model)
          primary_len = primary[:content]&.length || 0
          shadow_len  = shadow[:content]&.length || 0

          primary_cost = estimate_cost(primary[:model], primary[:usage])
          shadow_cost  = estimate_cost(shadow_model, shadow[:usage])

          {
            primary_model:  primary[:model],
            shadow_model:   shadow_model,
            primary_tokens: primary[:usage],
            shadow_tokens:  shadow[:usage],
            length_ratio:   primary_len.zero? ? 0.0 : shadow_len.to_f / primary_len,
            primary_cost:   primary_cost,
            shadow_cost:    shadow_cost,
            cost_savings:   primary_cost.zero? ? 0.0 : ((primary_cost - shadow_cost) / primary_cost).round(4),
            evaluated_at:   Time.now.utc
          }
        end

        def history
          @history ||= []
        end

        def clear_history
          @history = []
        end

        def summary
          entries = history.dup
          return empty_summary if entries.empty?

          {
            total_evaluations:  entries.size,
            avg_length_ratio:   avg(entries.map { |e| e[:length_ratio] }),
            avg_cost_savings:   avg(entries.map { |e| e[:cost_savings] }),
            total_primary_cost: entries.sum { |e| e[:primary_cost] }.round(6),
            total_shadow_cost:  entries.sum { |e| e[:shadow_cost] }.round(6),
            models_evaluated:   entries.map { |e| e[:shadow_model] }.uniq
          }
        end

        private

        def record(comparison)
          history << comparison
          history.shift while history.size > MAX_HISTORY
        end

        def estimate_cost(model, usage)
          return 0.0 unless usage.is_a?(Hash)

          input  = usage[:input_tokens] || usage[:prompt_tokens] || 0
          output = usage[:output_tokens] || usage[:completion_tokens] || 0
          pricing = cost_tracker_pricing(model.to_s)
          ((input * pricing[:input] / 1_000_000.0) + (output * pricing[:output] / 1_000_000.0)).round(6)
        end

        def cost_tracker_pricing(model)
          return CostTracker.pricing_for(model) if defined?(CostTracker)

          { input: 5.0, output: 15.0 }
        end

        def avg(values)
          return 0.0 if values.empty?

          (values.sum / values.size).round(4)
        end

        def empty_summary
          {
            total_evaluations:  0,
            avg_length_ratio:   0.0,
            avg_cost_savings:   0.0,
            total_primary_cost: 0.0,
            total_shadow_cost:  0.0,
            models_evaluated:   []
          }
        end
      end
    end
  end
end

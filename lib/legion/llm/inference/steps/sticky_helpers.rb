# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      module Steps
        module StickyHelpers
          private

          def sticky_enabled?
            sticky_setting(:enabled, true) != false
          end

          def trigger_sticky_turns
            sticky_setting(:trigger_turns, 2)
          end

          def execution_sticky_tool_calls
            sticky_setting(:execution_tool_calls, 5)
          end

          def max_history_entries
            sticky_setting(:max_history_entries, 50)
          end

          def max_result_length
            sticky_setting(:max_result_length, 2000)
          end

          def max_args_length
            sticky_setting(:max_args_length, 500)
          end

          def sticky_setting(key, default = nil)
            config_value(settings_value(:tool_sticky, default: {}), key, default)
          end

          def settings_value(*keys, default: nil)
            Legion::LLM::Settings.value(*keys, default: default)
          rescue StandardError
            default
          end

          def config_value(config, key, default = nil)
            return default unless config.respond_to?(:key?)

            string_key = key.to_s
            return config[string_key] if config.key?(string_key)

            symbol_key = key.to_sym if key.respond_to?(:to_sym)
            return config[symbol_key] if symbol_key && config.key?(symbol_key)

            default
          end
        end
      end
    end
  end
end

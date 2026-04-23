# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module Metering
          module_function

          extend Legion::Logging::Helper

          def build_event(**opts)
            log.debug("[metering][build_event] action=build provider=#{opts[:provider]} model=#{opts[:model_id]}")
            identity_fields(opts).merge(token_fields(opts)).merge(timing_and_context(opts))
          end

          def publish_or_spool(event)
            publish_event(event)
          end

          def flush_spool
            Legion::LLM::Metering.flush_spool
          end

          def identity_fields(opts)
            {
              node_id:      opts[:node_id],
              worker_id:    opts[:worker_id],
              agent_id:     opts[:agent_id],
              request_id:   opts[:request_id],
              caller:       opts[:caller],
              request_type: opts[:request_type],
              tier:         opts[:tier],
              provider:     opts[:provider],
              model_id:     opts[:model_id]
            }
          end

          def token_fields(opts)
            input    = opts.fetch(:input_tokens, 0)
            output   = opts.fetch(:output_tokens, 0)
            thinking = opts.fetch(:thinking_tokens, 0)
            { input_tokens: input, output_tokens: output, thinking_tokens: thinking,
              total_tokens: input + output + thinking }
          end

          def timing_and_context(opts)
            {
              latency_ms:     opts.fetch(:latency_ms, 0),
              wall_clock_ms:  opts.fetch(:wall_clock_ms, 0),
              routing_reason: opts[:routing_reason],
              recorded_at:    Time.now.utc.iso8601
            }
          end

          def publish_event(event)
            Legion::LLM::Metering.emit(event)
          end
        end
      end
    end
  end
end

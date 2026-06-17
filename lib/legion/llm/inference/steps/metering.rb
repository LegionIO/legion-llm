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
            log.debug(
              "[metering][build_event] action=build request_id=#{opts[:request_id]} " \
              "conversation_id=#{opts[:conversation_id] || 'none'} provider=#{opts[:provider]} " \
              "instance=#{opts[:provider_instance] || 'default'} model=#{opts[:model_id]}"
            )
            identity_fields(opts)
              .merge(token_fields(opts))
              .merge(timing_and_context(opts))
              .merge(content_fields(opts))
              .merge(operational_fields(opts))
          end

          def publish_or_spool(event)
            log.debug(
              "[metering][publish_or_spool] action=publish request_id=#{event[:request_id]} " \
              "provider=#{event[:provider]} model=#{event[:model_id]} total_tokens=#{event[:total_tokens]}"
            )
            result = publish_event(event)
            if result == :dropped
              log.warn(
                "[metering][publish_or_spool] action=dropped request_id=#{event[:request_id]} " \
                "provider=#{event[:provider]} model=#{event[:model_id]}"
              )
            end
            result
          end

          def flush_spool
            log.debug('[metering][flush_spool] action=flush')
            Legion::LLM::Metering.flush_spool
          end

          def identity_fields(opts)
            {
              node_id:         opts[:node_id],
              worker_id:       opts[:worker_id],
              agent_id:        opts[:agent_id],
              task_id:         opts[:task_id],
              request_id:      opts[:request_id],
              conversation_id: opts[:conversation_id],
              correlation_id:  opts[:correlation_id],
              caller:          opts[:caller],
              identity:        opts[:identity],
              billing:         opts[:billing],
              request_type:    opts[:request_type],
              tier:            opts[:tier],
              provider:        opts[:provider],
              model_id:        opts[:model_id],
              offering_id:     opts[:offering_id]
            }.compact
          end

          def token_fields(opts)
            input    = opts.fetch(:input_tokens, 0)
            output   = opts.fetch(:output_tokens, 0)
            thinking = opts.fetch(:thinking_tokens, 0)
            total    = input + output + thinking
            log.debug(
              "[llm][steps][metering] action=token_summary request_id=#{opts[:request_id]} " \
              "input=#{input} output=#{output} thinking=#{thinking} total=#{total}"
            )
            { input_tokens: input, output_tokens: output, thinking_tokens: thinking,
              total_tokens: total }
          end

          def timing_and_context(opts)
            {
              latency_ms:        opts.fetch(:latency_ms, 0),
              wall_clock_ms:     opts.fetch(:wall_clock_ms, 0),
              cost_usd:          opts[:cost_usd],
              routing_reason:    opts[:routing_reason],
              offering_metadata: opts[:offering_metadata],
              recorded_at:       Time.now.utc.iso8601
            }.compact
          end

          def content_fields(opts)
            fields = {
              messages:          opts[:messages],
              response_content:  opts[:response_content],
              response_thinking: opts[:response_thinking]
            }
            fields[:context_accounting] = opts[:context_accounting] if opts[:context_accounting]
            fields.compact
          end

          def operational_fields(opts)
            {
              status:             opts[:status],
              error:              opts[:error],
              provider_submitted: opts[:provider_submitted]
            }.compact
          end

          def publish_event(event)
            log.debug(
              "[metering][publish_event] action=emit request_id=#{event[:request_id]} " \
              "conversation_id=#{event[:conversation_id] || 'none'}"
            )
            Legion::LLM::Metering.emit(event)
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module Metering
          module_function
          extend Legion::Logging::Helper

          def build_event(**opts)
            identity_fields(opts).merge(token_fields(opts)).merge(timing_and_context(opts))
          end

          def publish_or_spool(event)
            if transport_connected?
              publish_event(event)
              log.info("[llm][metering] published provider=#{event[:provider]} model=#{event[:model_id]}")
              :published
            elsif spool_available?
              spool_event(event)
              log.info("[llm][metering] spooled provider=#{event[:provider]} model=#{event[:model_id]}")
              :spooled
            else
              log.warn("[llm][metering] dropped provider=#{event[:provider]} model=#{event[:model_id]}")
              :dropped
            end
          end

          def flush_spool
            return 0 unless spool_available? && transport_connected?

            spool = Legion::Data::Spool.for(Legion::LLM)
            flushed = spool.flush(:metering) { |event| publish_event(event) }
            log.info("[llm][metering] spool_flushed count=#{flushed}")
            flushed
          end

          def identity_fields(opts)
            {
              node_id:      opts[:node_id],
              worker_id:    opts[:worker_id],
              agent_id:     opts[:agent_id],
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

          def transport_connected?
            !!(defined?(Legion::Transport) &&
              Legion::Transport.respond_to?(:connected?) &&
              Legion::Transport.connected?)
          end

          def spool_available?
            !!defined?(Legion::Data::Spool)
          end

          def publish_event(event)
            return unless defined?(Legion::Extensions::LLM::Gateway::Transport::Messages::MeteringEvent)

            Legion::Extensions::LLM::Gateway::Transport::Messages::MeteringEvent.new(**event).publish
          end

          def spool_event(event)
            spool = Legion::Data::Spool.for(Legion::LLM)
            spool.write(:metering, event)
          end
        end
      end
    end
  end
end

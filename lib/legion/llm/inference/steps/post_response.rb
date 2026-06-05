# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module PostResponse
          include Legion::Logging::Helper
          include Steps::Logging

          def step_post_response
            response = current_response
            log_step_debug(:post_response, :publish_audit, provider: @resolved_provider || 'none', model: @resolved_model || 'none')

            audit_event = AuditPublisher.publish(request: @request, response: response)

            if defined?(Legion::Gaia::AuditObserver) && audit_event
              log_step_debug(:post_response, :notify_gaia_audit_observer)
              Legion::Gaia::AuditObserver.instance.process_event(audit_event)
            else
              log_step_debug(:post_response, :gaia_audit_observer_skipped, reason: audit_event ? :observer_unavailable : :no_audit_event)
            end

            @timeline.record(
              category: :audit, key: 'audit:publish',
              direction: :outbound, detail: 'published to llm.audit',
              from: 'pipeline', to: 'llm.audit'
            )
            log_step_debug(:post_response, :complete, audit_event_present: !audit_event.nil?)
          rescue StandardError => e
            @warnings << "post_response error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.post_response')
          end

          private

          def extract_tokens
            unless @raw_response.respond_to?(:input_tokens)
              log_step_debug(:post_response, :token_extraction_skipped, reason: :no_token_accessors)
              return {}
            end

            input  = @raw_response.input_tokens.to_i
            output = @raw_response.output_tokens.to_i

            cache_read  = @raw_response.respond_to?(:cache_read_tokens) ? @raw_response.cache_read_tokens.to_i : 0
            cache_write = @raw_response.respond_to?(:cache_write_tokens) ? @raw_response.cache_write_tokens.to_i : 0

            details = if @raw_response.respond_to?(:output_tokens_details) && @raw_response.output_tokens_details.is_a?(Hash)
                        @raw_response.output_tokens_details
                      else
                        {}
                      end

            log_step_debug(:post_response, :tokens_extracted, input: input, output: output,
                                                              cache_read: cache_read, cache_write: cache_write)
            log_zero_token_usage(input, output)

            Usage.new(
              input_tokens:          input,
              output_tokens:         output,
              cache_read_tokens:     cache_read,
              cache_write_tokens:    cache_write,
              output_tokens_details: details
            )
          end

          def current_response
            @extracted_tokens ||= extract_tokens

            content = if @raw_response.respond_to?(:content)
                        @raw_response.content
                      elsif @raw_response.is_a?(Hash) && @raw_response[:content]
                        @raw_response[:content]
                      else
                        @raw_response.to_s
                      end

            msg = Types::Message.build(
              role:            :assistant,
              content:         content,
              provider:        @resolved_provider,
              model:           @resolved_model,
              input_tokens:    @extracted_tokens.respond_to?(:input_tokens) ? @extracted_tokens.input_tokens : nil,
              output_tokens:   @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens : nil,
              conversation_id: @request.conversation_id
            )

            Response.build(
              request_id:      @request.id,
              conversation_id: @request.conversation_id || "conv_#{SecureRandom.hex(8)}",
              message:         msg.to_h,
              routing:         { provider: @resolved_provider, model: @resolved_model },
              tokens:          @extracted_tokens,
              tools:           current_response_tool_calls,
              enrichments:     @enrichments,
              audit:           @audit,
              timeline:        @timeline.events,
              tracing:         @tracing,
              caller:          @request.caller,
              classification:  @request.classification
            )
          end

          def current_response_tool_calls
            return response_tool_calls if respond_to?(:response_tool_calls, true)

            []
          end

          def log_zero_token_usage(input, output)
            return unless input.zero? && output.zero? && @resolved_model
            return if @zero_token_warning_logged

            @zero_token_warning_logged = true
            log.warn(
              "[llm][post_response] zero_tokens request_id=#{@request&.id || 'none'} " \
              "provider=#{@resolved_provider || 'none'} model=#{@resolved_model}"
            )
          end
        end
      end
    end
  end
end

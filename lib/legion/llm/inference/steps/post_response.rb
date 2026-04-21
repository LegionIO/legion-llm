# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module PostResponse
          include Legion::Logging::Helper

          def step_post_response
            response = current_response

            audit_event = AuditPublisher.publish(request: @request, response: response)

            Legion::Gaia::AuditObserver.instance.process_event(audit_event) if defined?(Legion::Gaia::AuditObserver) && audit_event

            @timeline.record(
              category: :audit, key: 'audit:publish',
              direction: :outbound, detail: 'published to llm.audit',
              from: 'pipeline', to: 'llm.audit'
            )
          rescue StandardError => e
            @warnings << "post_response error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.post_response')
          end

          private

          def extract_tokens
            return {} unless @raw_response.respond_to?(:input_tokens)

            input  = @raw_response.input_tokens.to_i
            output = @raw_response.output_tokens.to_i

            cache_read  = @raw_response.respond_to?(:cache_read_tokens) ? @raw_response.cache_read_tokens.to_i : 0
            cache_write = @raw_response.respond_to?(:cache_write_tokens) ? @raw_response.cache_write_tokens.to_i : 0

            Usage.new(
              input_tokens:       input,
              output_tokens:      output,
              cache_read_tokens:  cache_read,
              cache_write_tokens: cache_write
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
        end
      end
    end
  end
end

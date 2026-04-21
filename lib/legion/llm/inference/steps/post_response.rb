# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
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
            msg = if @raw_response.respond_to?(:content)
                    { role: :assistant, content: @raw_response.content }
                  elsif @raw_response.is_a?(Hash) && @raw_response[:content]
                    @raw_response
                  else
                    { role: :assistant, content: @raw_response.to_s }
                  end

            Response.build(
              request_id:      @request.id,
              conversation_id: @request.conversation_id || "conv_#{SecureRandom.hex(8)}",
              message:         msg,
              routing:         { provider: @resolved_provider, model: @resolved_model },
              tokens:          extract_tokens,
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

          def response_tool_calls
            return [] unless @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls

            Array(@raw_response.tool_calls).map do |tool_call|
              {
                id:        tool_call[:id] || tool_call['id'],
                name:      tool_call[:name] || tool_call['name'],
                arguments: tool_call[:arguments] || tool_call['arguments'] || {}
              }
            end
          end
        end
      end
    end
  end
end

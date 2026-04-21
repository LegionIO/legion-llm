# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Translators
        module AnthropicResponse
          extend Legion::Logging::Helper

          # Format internal pipeline response into Anthropic Messages API shape.
          def self.format(pipeline_response, model:, request_id: nil)
            log.debug('[llm][translator][anthropic_response] action=format')

            msg     = pipeline_response.message
            content = extract_content(msg, pipeline_response)
            tokens  = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens : nil
            routing = pipeline_response.respond_to?(:routing) ? (pipeline_response.routing || {}) : {}

            resolved_model = routing[:model] || routing['model'] || model

            {
              id:            request_id || "msg_#{SecureRandom.hex(12)}",
              type:          'message',
              role:          'assistant',
              content:       content,
              model:         resolved_model.to_s,
              stop_reason:   format_stop_reason(pipeline_response),
              stop_sequence: nil,
              usage:         format_usage(tokens)
            }
          end

          # Emit Anthropic streaming events for a single text chunk.
          # Returns the SSE lines for the delta event.
          def self.format_chunk(text, index: 0)
            log.debug('[llm][translator][anthropic_response] action=format_chunk')
            {
              type:  'content_block_delta',
              index: index,
              delta: { type: 'text_delta', text: text }
            }
          end

          # Ordered sequence of SSE event hashes for a complete streaming response.
          # Caller emits each via emit_sse_event.
          def self.streaming_events(pipeline_response, model:, request_id: nil, full_text: '')
            log.debug('[llm][translator][anthropic_response] action=streaming_events')

            tokens  = pipeline_response.respond_to?(:tokens) ? pipeline_response.tokens : nil
            routing = pipeline_response.respond_to?(:routing) ? (pipeline_response.routing || {}) : {}
            resolved_model = routing[:model] || routing['model'] || model

            tool_calls = extract_tool_calls(pipeline_response)
            content_index = 0

            events = []

            events << ['message_start', {
              type:    'message_start',
              message: {
                id:            request_id || "msg_#{SecureRandom.hex(12)}",
                type:          'message',
                role:          'assistant',
                content:       [],
                model:         resolved_model.to_s,
                stop_reason:   nil,
                stop_sequence: nil,
                usage:         { input_tokens: token_count(tokens, :input), output_tokens: 0 }
              }
            }]

            events << ['content_block_start', {
              type:          'content_block_start',
              index:         content_index,
              content_block: { type: 'text', text: '' }
            }]

            events << ['ping', { type: 'ping' }]

            unless full_text.empty?
              events << ['content_block_delta', {
                type:  'content_block_delta',
                index: content_index,
                delta: { type: 'text_delta', text: full_text }
              }]
            end

            events << ['content_block_stop', { type: 'content_block_stop', index: content_index }]

            content_index += 1

            tool_calls.each do |tc|
              events << ['content_block_start', {
                type:          'content_block_start',
                index:         content_index,
                content_block: { type: 'tool_use', id: tc[:id], name: tc[:name], input: {} }
              }]
              events << ['content_block_delta', {
                type:  'content_block_delta',
                index: content_index,
                delta: { type: 'input_json_delta', partial_json: Legion::JSON.dump(tc[:arguments] || {}) }
              }]
              events << ['content_block_stop', { type: 'content_block_stop', index: content_index }]
              content_index += 1
            end

            stop_reason = format_stop_reason(pipeline_response)
            events << ['message_delta', {
              type:  'message_delta',
              delta: { stop_reason: stop_reason, stop_sequence: nil },
              usage: { output_tokens: token_count(tokens, :output) }
            }]

            events << ['message_stop', { type: 'message_stop' }]

            events
          end

          def self.extract_content(msg, pipeline_response)
            tool_calls = extract_tool_calls(pipeline_response)
            blocks = []

            text = msg.is_a?(Hash) ? (msg[:content] || msg['content']) : msg.to_s
            blocks << { type: 'text', text: text.to_s } unless text.to_s.empty? && !tool_calls.empty?

            tool_calls.each do |tc|
              blocks << {
                type:  'tool_use',
                id:    tc[:id],
                name:  tc[:name],
                input: tc[:arguments] || {}
              }
            end

            blocks.empty? ? [{ type: 'text', text: '' }] : blocks
          end

          def self.extract_tool_calls(pipeline_response)
            return [] unless pipeline_response.respond_to?(:tools)

            Array(pipeline_response.tools).map do |tc|
              {
                id:        tc.respond_to?(:id)        ? tc.id        : (tc[:id] || tc['id'] || "toolu_#{SecureRandom.hex(10)}"),
                name:      tc.respond_to?(:name)      ? tc.name      : (tc[:name] || tc['name'] || ''),
                arguments: tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              }
            end
          end

          def self.format_stop_reason(pipeline_response)
            return 'end_turn' unless pipeline_response.respond_to?(:stop)

            stop = pipeline_response.stop
            reason = stop.is_a?(Hash) ? (stop[:reason] || stop['reason']) : stop.to_s

            case reason.to_s
            when 'tool_use'   then 'tool_use'
            when 'max_tokens' then 'max_tokens'
            when 'stop'       then 'stop_sequence'
            else                   'end_turn'
            end
          end

          def self.format_usage(tokens)
            {
              input_tokens:  token_count(tokens, :input),
              output_tokens: token_count(tokens, :output)
            }
          end

          def self.token_count(tokens, key)
            return 0 if tokens.nil?
            return tokens[key] || tokens[key.to_s] || 0 if tokens.is_a?(Hash)

            method_name = { input: :input_tokens, output: :output_tokens }[key]
            return tokens.public_send(method_name) if method_name && tokens.respond_to?(method_name)

            0
          end

          private_class_method :extract_content, :extract_tool_calls, :format_stop_reason,
                               :format_usage, :token_count
        end
      end
    end
  end
end

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
            log.debug("[llm][api][anthropic] action=format request_id=#{request_id} model=#{model}")

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
            log.debug("[llm][api][anthropic] action=format_chunk index=#{index} text=#{text[0, 80]}")
            {
              type:  'content_block_delta',
              index: index,
              delta: { type: 'text_delta', text: text }
            }
          end

          # Ordered sequence of SSE event hashes for a complete streaming response.
          # Caller emits each via emit_sse_event.
          def self.streaming_events(pipeline_response, model:, request_id: nil, full_text: '')
            log.debug("[llm][api][anthropic] action=streaming_events request_id=#{request_id} text_length=#{full_text.length}")

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

            events << ['ping', { type: 'ping' }]

            # Emit text block only when there's real text content.
            # When tool calls are present and the text is just JSON arguments
            # (common with vLLM/qwen forced tool choices), skip the text block
            # so the Anthropic-format SSE emits only tool_use blocks with
            # stop_reason=tool_use.
            text_is_tool_arguments = tool_calls.any? && text_looks_like_tool_json?(full_text)
            unless full_text.empty? || text_is_tool_arguments
              events << ['content_block_start', {
                type:          'content_block_start',
                index:         content_index,
                content_block: { type: 'text', text: '' }
              }]

              events << ['content_block_delta', {
                type:  'content_block_delta',
                index: content_index,
                delta: { type: 'text_delta', text: full_text }
              }]

              events << ['content_block_stop', { type: 'content_block_stop', index: content_index }]
              content_index += 1
            end

            # Emit tool_use/server_tool_use blocks (index may have been bumped above)
            tool_calls.each do |tc|
              if tc[:legionio] == true
                # Server tool: emit call + result together
                events << ['content_block_start', {
                  type:          'content_block_start',
                  index:         content_index,
                  content_block: { type: 'server_tool_use', id: tc[:id], name: tc[:name], input: tc[:arguments] || {} }
                }]
                events << ['content_block_delta', {
                  type:  'content_block_delta',
                  index: content_index,
                  delta: { type: 'input_json_delta', partial_json: Legion::JSON.dump(tc[:arguments] || {}) }
                }]
                events << ['content_block_stop', { type: 'content_block_stop', index: content_index }]
                content_index += 1

                # Emit result
                result = tc[:result]
                if result
                  result_str = if result.is_a?(String)
                                 result
                               else
                                 begin
                                   Legion::JSON.dump(result)
                                 rescue StandardError
                                   result.to_s
                                 end
                               end
                  events << ['content_block_start', {
                    type:          'content_block_start',
                    index:         content_index,
                    content_block: { type: 'server_tool_result', id: tc[:id], content: [] }
                  }]
                  events << ['content_block_delta', {
                    type:  'content_block_delta',
                    index: content_index,
                    delta: { type: 'content_block_delta', content: [{ type: 'text', text: result_str }] }
                  }]
                  events << ['content_block_stop', { type: 'content_block_stop', index: content_index }]
                  content_index += 1
                end
              else
                events << ['content_block_start', {
                  type:          'content_block_start',
                  index:         content_index,
                  content_block: { type: 'tool_use', id: tc[:id], name: tc[:name], input: tc[:arguments] || {} }
                }]
                events << ['content_block_delta', {
                  type:  'content_block_delta',
                  index: content_index,
                  delta: { type: 'input_json_delta', partial_json: Legion::JSON.dump(tc[:arguments] || {}) }
                }]
                events << ['content_block_stop', { type: 'content_block_stop', index: content_index }]
                content_index += 1
              end
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

            thinking_block = thinking_content_block(pipeline_response)
            blocks << thinking_block if thinking_block

            text = msg.is_a?(Hash) ? (msg[:content] || msg['content']) : msg.to_s
            text_content = text.to_s
            blocks << { type: 'text', text: text_content } unless text_content.empty? && !tool_calls.empty?

            tool_calls.each do |tc|
              if tc[:legionio] == true
                # Server tool: emit call + result together
                blocks << {
                  type:  'server_tool_use',
                  id:    tc[:id],
                  name:  tc[:name],
                  input: tc[:arguments] || {}
                }
                result = tc[:result]
                if result
                  result_str = if result.is_a?(String)
                                 result
                               else
                                 begin
                                   Legion::JSON.dump(result)
                                 rescue StandardError
                                   result.to_s
                                 end
                               end
                  blocks << {
                    type:    'server_tool_result',
                    id:      tc[:id],
                    content: [{ type: 'text', text: result_str }]
                  }
                end
              else
                blocks << {
                  type:  'tool_use',
                  id:    tc[:id],
                  name:  tc[:name],
                  input: tc[:arguments] || {}
                }
              end
            end

            blocks.empty? ? [{ type: 'text', text: '' }] : blocks
          end

          def self.thinking_content_block(pipeline_response)
            thinking = thinking_payload(pipeline_response)
            return nil unless thinking

            if thinking[:redacted] || thinking[:type].to_s == 'redacted_thinking'
              data = thinking[:data] || thinking[:signature]
              return nil if data.to_s.empty?

              return { type: 'redacted_thinking', data: data.to_s }
            end

            block = { type: 'thinking', thinking: thinking[:content].to_s }
            block[:signature] = thinking[:signature].to_s unless thinking[:signature].to_s.empty?
            block
          end

          def self.thinking_payload(pipeline_response)
            return nil unless pipeline_response.respond_to?(:thinking)

            thinking_data = begin
              pipeline_response.thinking
            rescue Exception # rubocop:disable Style/RescueException
              nil
            end
            normalize_thinking_payload(thinking_data)
          end

          def self.normalize_thinking_payload(value)
            return nil unless value

            if value.is_a?(Hash)
              normalized = value.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
              content = normalized[:content] || normalized[:text] || normalized[:thinking]
              signature = normalized[:signature]
              data = normalized[:data]
              redacted = normalized[:redacted] || normalized[:type].to_s == 'redacted_thinking'
              type = normalized[:type]
            else
              content = value.respond_to?(:content) ? value.content : nil
              content = value.text if content.nil? && value.respond_to?(:text)
              content = value unless value.respond_to?(:content) || value.respond_to?(:text)
              signature = value.respond_to?(:signature) ? value.signature : nil
              data = value.respond_to?(:data) ? value.data : nil
              redacted = false
              type = nil
            end

            content = content.to_s unless content.nil?
            signature = signature.to_s unless signature.nil?
            data = data.to_s unless data.nil?
            return nil if content.to_s.empty? && signature.to_s.empty? && data.to_s.empty?

            { content: content, signature: signature, data: data, redacted: redacted, type: type }.compact
          end

          def self.extract_tool_calls(pipeline_response)
            return [] unless pipeline_response.respond_to?(:tools)

            Array(pipeline_response.tools).map do |tc|
              source = tc.respond_to?(:source) ? tc.source : (tc[:source] || tc['source'] || {})
              is_legionio = legionio_tool_source?(source)

              {
                id:        if tc.respond_to?(:id)
                             tc.id
                           else
                             tc[:id] || tc['id'] || (is_legionio ? "srvtoolu_#{SecureRandom.hex(10)}" : "toolu_#{SecureRandom.hex(10)}")
                           end,
                name:      tc.respond_to?(:name)      ? tc.name      : (tc[:name] || tc['name'] || ''),
                arguments: tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {}),
                result:    tc.respond_to?(:result)    ? tc.result    : (tc[:result] || tc['result']),
                source:    source,
                legionio:  is_legionio
              }
            end
          end

          def self.legionio_tool_source?(source)
            return false unless source.is_a?(Hash)

            type = source[:type] || source['type']
            %i[special registry extension].include?(type&.to_sym)
          end

          def self.format_stop_reason(pipeline_response)
            tool_calls = extract_tool_calls(pipeline_response)

            # Only return 'pause_turn' for LegionIO tools that are still pending
            # (i.e., executed server-side but result not yet available).
            # If all LegionIO tools have results, the tool loop completed and
            # the turn should end normally.
            pending_legionio = tool_calls.select { |tc| tc[:legionio] == true && tc[:result].nil? }
            return 'pause_turn' if pending_legionio.any?

            # Client-side (passthrough) tool_use blocks without results mean
            # the client needs to execute them.
            return 'tool_use' if tool_calls.any? { |tc| tc[:legionio] != true && tc[:result].nil? }

            return 'end_turn' unless pipeline_response.respond_to?(:stop)

            stop = pipeline_response.stop
            reason = stop.is_a?(Hash) ? (stop[:reason] || stop['reason']) : stop.to_s

            case reason.to_s
            when 'tool_use'       then 'tool_use'
            when 'max_tokens'     then 'max_tokens'
            when 'content_filter' then 'content_filter'
            when 'stop'
              pipeline_response.respond_to?(:stop_sequence) && pipeline_response.stop_sequence ? 'stop_sequence' : 'end_turn'
            else 'end_turn'
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

          # Heuristic: does the full_text look like a bare JSON object that is
          # tool-call arguments (e.g. {"file_path": "...", "limit": 300})?
          # Used to avoid emitting such text as a text_delta when it should be
          # a tool_use block.
          def self.text_looks_like_tool_json?(text)
            stripped = text.to_s.strip
            return false unless stripped.start_with?('{"') && stripped.end_with?('}')

            parsed = Legion::JSON.parse(stripped, symbolize_names: false)
            parsed.is_a?(Hash) && parsed.keys.any?
          rescue Legion::JSON::ParseError, StandardError
            false
          end

          private_class_method :extract_content, :format_usage, :text_looks_like_tool_json?, :legionio_tool_source?

          class << self
            public :extract_tool_calls, :format_stop_reason, :token_count, :thinking_payload, :thinking_content_block, :text_looks_like_tool_json?
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Translators
        module OpenAIResponse
          extend Legion::Logging::Helper

          FINISH_REASON_MAP = {
            'stop'           => 'stop',
            'length'         => 'length',
            'tool_calls'     => 'tool_calls',
            'content_filter' => 'content_filter'
          }.freeze

          module_function

          def format_chat_completion(pipeline_response, model:, request_id: nil, include_reasoning: false)
            request_id ||= SecureRandom.uuid
            routing = pipeline_response.routing || {}
            tokens = pipeline_response.tokens || {}
            raw_msg = pipeline_response.message
            content = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']) : raw_msg.to_s
            stop_reason = pipeline_response.stop&.dig(:reason)&.to_s
            tool_calls = build_tool_calls(pipeline_response)
            resolved_model = (routing[:model] || routing['model'] || model).to_s

            log.debug("[llm][translator][openai_response] action=format_chat_completion request_id=#{request_id} model=#{resolved_model}")

            finish_reason = tool_calls.empty? ? map_finish_reason(stop_reason) : 'tool_calls'

            # When tool calls are present and content is just JSON arguments
            # (e.g. vLLM/qwen forced tool choice), clear the content field
            # so the client sees only structured tool_calls.
            content = nil if tool_calls.any? && content_looks_like_tool_json?(content)

            message_body = { role: 'assistant', content: content }
            message_body[:tool_calls] = tool_calls unless tool_calls.empty?

            # Include reasoning/thinking content in the response when requested.
            # Uses the `reasoning_content` field convention from OpenAI's reasoning models.
            if include_reasoning && pipeline_response.respond_to?(:thinking) && pipeline_response.thinking
              thinking_data = pipeline_response.thinking
              reasoning_text = if thinking_data.is_a?(Hash)
                                 thinking_data[:content] || thinking_data['content'] || thinking_data[:text] || thinking_data['text']
                               elsif thinking_data.respond_to?(:content)
                                 thinking_data.content
                               elsif thinking_data.respond_to?(:text)
                                 thinking_data.text
                               else
                                 thinking_data.to_s
                               end
              message_body[:reasoning_content] = reasoning_text.to_s unless reasoning_text.to_s.empty?
            end

            {
              id:      "chatcmpl-#{request_id.delete('-')}",
              object:  'chat.completion',
              created: Time.now.to_i,
              model:   resolved_model,
              choices: [
                {
                  index:         0,
                  message:       message_body,
                  finish_reason: finish_reason
                }
              ],
              usage:   {
                prompt_tokens:     extract_token_count(tokens, :input),
                completion_tokens: extract_token_count(tokens, :output),
                total_tokens:      (extract_token_count(tokens, :input).to_i + extract_token_count(tokens, :output).to_i)
              }
            }
          end

          def format_stream_chunk(delta_text, model:, request_id:, finish_reason: nil, usage: nil)
            choice = { index: 0, delta: {}, finish_reason: finish_reason }
            choice[:delta][:content] = delta_text if delta_text && !delta_text.empty?

            chunk = {
              id:      "chatcmpl-#{request_id.delete('-')}",
              object:  'chat.completion.chunk',
              created: Time.now.to_i,
              model:   model.to_s,
              choices: [choice]
            }
            chunk[:usage] = usage if usage
            chunk
          end

          def format_stream_tool_call_chunk(tool_call, model:, request_id:, index:)
            fn = tool_call.is_a?(Hash) ? (tool_call[:function] || tool_call['function'] || {}) : {}
            name = tool_call.respond_to?(:name) ? tool_call.name : (tool_call[:name] || tool_call['name'] || fn[:name] || fn['name'])
            args = if tool_call.respond_to?(:arguments)
                     tool_call.arguments
                   else
                     tool_call[:arguments] || tool_call['arguments'] || fn[:arguments] || fn['arguments'] || {}
                   end
            tc_id = tool_call.respond_to?(:id) ? tool_call.id : (tool_call[:id] || tool_call['id'] || "call_#{SecureRandom.hex(8)}")

            format_stream_delta_chunk(
              {
                tool_calls: [
                  {
                    index:    index,
                    id:       tc_id,
                    type:     'function',
                    function: {
                      name:      name.to_s,
                      arguments: args.is_a?(String) ? args : Legion::JSON.dump(args)
                    }
                  }
                ]
              },
              model:      model,
              request_id: request_id
            )
          end

          def format_stream_delta_chunk(delta, model:, request_id:, finish_reason: nil)
            {
              id:      "chatcmpl-#{request_id.delete('-')}",
              object:  'chat.completion.chunk',
              created: Time.now.to_i,
              model:   model.to_s,
              choices: [
                {
                  index:         0,
                  delta:         delta,
                  finish_reason: finish_reason
                }
              ]
            }
          end

          # @param entries [Array] one element per input item, in input order.
          #   Each element is a Hash carrying the raw float vector under :vector
          #   (and the provider token count under :tokens when present) or a bare
          #   Array of floats.
          # @param encoding_format [String] 'float' (default) emits raw floats;
          #   'base64' emits a base64 string of little-endian float32 words.
          def format_embeddings(entries, model:, input_texts: nil, encoding_format: 'float')
            base64 = encoding_format.to_s == 'base64'
            data = Array(entries).each_with_index.map do |entry, index|
              vector = entry.is_a?(Hash) ? (entry[:vector] || entry['vector']) : entry
              vector = [] unless vector.is_a?(Array)
              {
                object:    'embedding',
                embedding: base64 ? base64_float32_vector(vector) : vector,
                index:     index
              }
            end
            prompt_tokens = embedding_token_count(entries, input_texts)

            {
              object: 'list',
              data:   data,
              model:  model.to_s,
              usage:  {
                prompt_tokens: prompt_tokens,
                total_tokens:  prompt_tokens
              }
            }
          end

          # OpenAI encoding_format: 'base64' — the vector as one base64 string of
          # little-endian float32 words ('g' is little-endian). pack('g*')
          # yields the binary words; base64-ENCODING that binary is
          # [binary].pack('m0') (m0 = base64 without line breaks; unpack1('m0')
          # would DECODE, and String has no #pack).
          def base64_float32_vector(vector)
            [vector.pack('g*')].pack('m0')
          end

          def format_model_object(id, created: nil, owned_by: 'legion', limits: nil)
            obj = {
              id:       id.to_s,
              object:   'model',
              created:  created || Time.now.to_i,
              owned_by: owned_by
            }
            if limits.is_a?(Hash)
              if limits[:context_window]
                obj[:context_window] = limits[:context_window]
                obj[:context_size] = limits[:context_window]
              end
              obj[:max_output_tokens] = limits[:max_output_tokens] if limits[:max_output_tokens]
            end
            obj
          end

          def build_tool_calls(pipeline_response)
            tools_data = pipeline_response.respond_to?(:tools) ? pipeline_response.tools : nil
            return [] unless tools_data.is_a?(Array) && !tools_data.empty?

            tools_data.each_with_index.filter_map do |tc, idx|
              name = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'])
              args = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              tc_id = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id'] || "call_#{SecureRandom.hex(8)}")
              next unless name

              {
                id:       tc_id,
                type:     'function',
                index:    idx,
                function: {
                  name:      name.to_s,
                  arguments: args.is_a?(String) ? args : Legion::JSON.dump(args)
                }
              }
            end
          end

          def map_finish_reason(stop_reason)
            return 'stop' if stop_reason.nil? || stop_reason.to_s.empty?

            FINISH_REASON_MAP.fetch(stop_reason.to_s, 'error')
          end

          def extract_token_count(tokens, key)
            return nil if tokens.nil?
            return tokens[key] || tokens[key.to_s] if tokens.is_a?(Hash)

            method_name = { input: :input_tokens, output: :output_tokens }[key]
            return tokens.public_send(method_name) if method_name && tokens.respond_to?(method_name)

            nil
          end

          # Prefers the provider's token counts (carried under :tokens on each
          # embed result); falls back to the input word count when no entry
          # carries a count.
          def embedding_token_count(entries, input_texts)
            counts = Array(entries).filter_map { |e| e.is_a?(Hash) ? (e[:tokens] || e['tokens']) : nil }
            return counts.sum.to_i unless counts.empty?

            Array(input_texts).sum { |t| t.to_s.split.size }
          end

          # Heuristic: does the content look like a bare JSON object that is
          # tool-call arguments (e.g. {"file_path": "...", "limit": 300})?
          def content_looks_like_tool_json?(content)
            stripped = content.to_s.strip
            return false unless stripped.start_with?('{"') && stripped.end_with?('}')

            parsed = Legion::JSON.parse(stripped, symbolize_names: false)
            parsed.is_a?(Hash) && parsed.keys.any?
          rescue Legion::JSON::ParseError, StandardError
            false
          end
        end
      end
    end
  end
end

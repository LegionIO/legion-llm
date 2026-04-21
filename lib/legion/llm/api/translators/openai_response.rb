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

          def format_chat_completion(pipeline_response, model:, request_id: nil)
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

            message_body = { role: 'assistant', content: content }
            message_body[:tool_calls] = tool_calls unless tool_calls.empty?

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

          def format_stream_chunk(delta_text, model:, request_id:, finish_reason: nil)
            choice = { index: 0, delta: {}, finish_reason: finish_reason }
            choice[:delta][:content] = delta_text if delta_text && !delta_text.empty?

            {
              id:      "chatcmpl-#{request_id.delete('-')}",
              object:  'chat.completion.chunk',
              created: Time.now.to_i,
              model:   model.to_s,
              choices: [choice]
            }
          end

          def format_embeddings(vector, model:, input_text:)
            tokens = input_text.to_s.split.size

            {
              object: 'list',
              data:   [
                {
                  object:    'embedding',
                  embedding: vector,
                  index:     0
                }
              ],
              model:  model.to_s,
              usage:  {
                prompt_tokens: tokens,
                total_tokens:  tokens
              }
            }
          end

          def format_model_object(id, created: nil, owned_by: 'legion')
            {
              id:       id.to_s,
              object:   'model',
              created:  created || Time.now.to_i,
              owned_by: owned_by
            }
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
            FINISH_REASON_MAP.fetch(stop_reason.to_s, 'stop')
          end

          def extract_token_count(tokens, key)
            return nil if tokens.nil?
            return tokens[key] || tokens[key.to_s] if tokens.is_a?(Hash)

            method_name = { input: :input_tokens, output: :output_tokens }[key]
            return tokens.public_send(method_name) if method_name && tokens.respond_to?(method_name)

            nil
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Fleet
      module Handler
        extend Legion::Logging::Helper

        module_function

        def handle_fleet_request(payload)
          if Dispatcher.fleet_enabled? && !valid_token?(payload[:signed_token])
            error_response = { success: false, error: 'invalid_token' }
            publish_reply(payload[:reply_to], payload[:correlation_id], error_response) if payload[:reply_to]
            return error_response
          end

          response = call_local_llm(payload)
          response_hash = build_response(payload[:correlation_id], response)
          publish_reply(payload[:reply_to], payload[:correlation_id], response_hash) if payload[:reply_to]
          response_hash
        end

        def valid_token?(token)
          return true unless require_auth?
          return false if token.nil?
          return true unless defined?(Legion::Crypt)

          !Legion::Crypt.validate_jwt(token).nil?
        rescue StandardError => e
          handle_exception(e, level: :debug)
          false
        end

        def require_auth?
          return false unless defined?(Legion::Settings)

          settings = begin
            Legion::Settings[:llm]
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.fleet.handler.require_auth')
            nil
          end
          return false unless settings.is_a?(Hash)

          fleet = settings.dig(:routing, :fleet)
          return false unless fleet.is_a?(Hash)

          fleet.fetch(:require_auth, false)
        end

        def call_local_llm(payload)
          return unavailable_response unless llm_available_for?(payload)

          case payload[:request_type]&.to_s
          when 'structured'
            Legion::LLM.structured_direct(
              messages: payload[:messages],
              schema:   payload[:schema],
              model:    payload[:model],
              provider: payload[:provider]
            )
          when 'embed'
            text = payload[:text] || extract_terminal_content(payload[:messages])
            Legion::LLM.embed_direct(text, model: payload[:model], provider: payload[:provider])
          else
            execute_chat_request(payload)
          end
        end

        def build_response(correlation_id, response)
          {
            correlation_id:  correlation_id,
            success:         extract_success(response),
            error:           extract_error(response),
            response:        response,
            input_tokens:    extract_token(response, :input_tokens),
            output_tokens:   extract_token(response, :output_tokens),
            thinking_tokens: extract_token(response, :thinking_tokens),
            provider:        extract_field(response, :provider),
            model_id:        extract_field(response, :model)
          }.compact
        end

        def publish_reply(reply_to, correlation_id, response_hash)
          return unless defined?(Legion::Transport)

          payload = Legion::JSON.dump(response_hash)

          channel = Legion::Transport.connection.create_channel
          channel.default_exchange.publish(
            payload,
            routing_key:    reply_to,
            correlation_id: correlation_id,
            content_type:   'application/json'
          )
          channel.close
        rescue StandardError => e
          handle_exception(e, level: :warn)
        end

        def extract_token(response, field)
          return hash_token(response, field) if response.is_a?(Hash)

          if response.respond_to?(:tokens) && response.tokens.is_a?(Hash)
            token_key = { input_tokens: :input, output_tokens: :output, thinking_tokens: :thinking }[field]
            value = response.tokens[token_key] || response.tokens[token_key.to_s]
            return value.to_i if value
          end

          return 0 unless response.respond_to?(field)

          response.public_send(field).to_i
        end

        def extract_field(response, field)
          if response.is_a?(Hash)
            direct = response[field] || response[field.to_s]
            return direct unless direct.nil?

            meta = response[:meta] || response['meta']
            if meta.is_a?(Hash)
              meta_value = meta[field] || meta[field.to_s]
              return meta_value unless meta_value.nil?
            end

            routing = response[:routing] || response['routing']
            if routing.is_a?(Hash)
              routing_value = routing[field] || routing[field.to_s]
              return routing_value unless routing_value.nil?
            end

            return nil
          end

          if response.respond_to?(:routing) && response.routing.is_a?(Hash)
            routing_value = response.routing[field] || response.routing[field.to_s]
            return routing_value unless routing_value.nil?
          end

          return nil unless response.respond_to?(field)

          response.public_send(field)
        end

        def llm_available_for?(payload)
          return false unless defined?(Legion::LLM)

          Legion::LLM.respond_to?(availability_method_for(payload), true)
        end

        def availability_method_for(payload)
          case payload[:request_type]&.to_s
          when 'structured'
            :structured_direct
          when 'embed'
            :embed_direct
          else
            :chat_direct
          end
        end

        def unavailable_response
          { success: false, error: 'llm_not_available' }
        end

        def execute_chat_request(payload)
          if payload[:message]
            return Legion::LLM.chat_direct(
              model:    payload[:model],
              provider: payload[:provider],
              intent:   payload[:intent],
              tier:     payload[:tier],
              message:  payload[:message]
            )
          end

          messages = normalize_messages(payload[:messages])
          prompt = extract_terminal_content(messages)
          return { success: false, error: 'invalid_request' } if prompt.nil?

          session = Legion::LLM.send(
            :chat_single,
            model:    payload[:model],
            provider: payload[:provider],
            intent:   payload[:intent],
            tier:     payload[:tier],
            tools:    payload[:tools]
          )
          session.with_instructions(payload[:system]) if payload[:system] && session.respond_to?(:with_instructions)

          prior_messages = messages.size > 1 ? messages[0..-2] : []
          prior_messages.each { |message| session.add_message(message) }

          session.ask(prompt)
        end

        def normalize_messages(messages)
          Array(messages).map do |message|
            next message unless message.is_a?(Hash)

            message.each_with_object({}) do |(key, value), normalized|
              normalized[key.respond_to?(:to_sym) ? key.to_sym : key] = value
            end
          end
        end

        def extract_terminal_content(messages)
          normalized = normalize_messages(messages)
          message_content(normalized.last)
        end

        def message_content(message)
          return unless message.is_a?(Hash)

          message[:content] || message['content']
        end

        def extract_success(response)
          return response[:success] if response.is_a?(Hash) && response.key?(:success)
          return response['success'] if response.is_a?(Hash) && response.key?('success')
          return false if extract_error(response)

          true
        end

        def extract_error(response)
          return unless response.is_a?(Hash)

          response[:error] || response['error']
        end

        def hash_token(response, field)
          direct = response[field] || response[field.to_s]
          return direct.to_i if direct

          meta = response[:meta] || response['meta']
          if meta.is_a?(Hash)
            meta_key = { input_tokens: :tokens_in, output_tokens: :tokens_out, thinking_tokens: :thinking_tokens }[field]
            meta_value = meta[meta_key] || meta[meta_key.to_s]
            return meta_value.to_i if meta_value
          end

          tokens = response[:tokens] || response['tokens']
          if tokens.is_a?(Hash)
            token_key = { input_tokens: :input, output_tokens: :output, thinking_tokens: :thinking }[field]
            token_value = tokens[token_key] || tokens[token_key.to_s]
            return token_value.to_i if token_value
          end

          0
        end
      end
    end
  end
end

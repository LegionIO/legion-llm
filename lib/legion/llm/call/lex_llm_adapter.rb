# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      # Adapts a lex-llm provider class to legion-llm's native dispatch contract.
      class LexLLMAdapter
        include Legion::Logging::Helper

        def initialize(provider_name, provider_class)
          @provider_name = provider_name.to_sym
          @provider_class = provider_class
          @lex_llm_namespace = resolve_lex_llm_namespace
        end

        def chat(model:, messages:, **opts)
          response = provider.complete(
            normalize_messages(messages, system: opts[:system]),
            tools:       normalize_tools(opts[:tools]),
            temperature: opts[:temperature],
            model:       model_info(model),
            params:      opts[:params] || {},
            headers:     opts[:headers] || {},
            schema:      opts[:schema],
            thinking:    opts[:thinking],
            tool_prefs:  opts[:tool_prefs]
          )

          message_response(response)
        end

        def stream(model:, messages:, **opts, &block)
          chunks = []
          provider.complete(
            normalize_messages(messages, system: opts[:system]),
            tools:       normalize_tools(opts[:tools]),
            temperature: opts[:temperature],
            model:       model_info(model),
            params:      opts[:params] || {},
            headers:     opts[:headers] || {},
            schema:      opts[:schema],
            thinking:    opts[:thinking],
            tool_prefs:  opts[:tool_prefs]
          ) do |chunk|
            chunks << chunk
            block&.call(chunk)
          end

          chunk_response(chunks)
        end

        def embed(model:, text:, dimensions: nil, **)
          response = provider.embed(text, model: model, dimensions: dimensions)

          {
            result: response.vectors,
            model:  response.model,
            usage:  { input_tokens: response.input_tokens.to_i, output_tokens: 0 }
          }
        end

        def count_tokens(model:, messages:, **)
          {
            result: estimate_tokens(messages),
            model:  model,
            usage:  {}
          }
        end

        private

        attr_reader :provider_name, :provider_class, :lex_llm_namespace

        def provider
          @provider ||= provider_class.new(lex_llm_namespace.config)
        end

        def model_info(model)
          lex_llm_namespace::Model::Info.new(id: model, provider: provider_name)
        end

        def normalize_messages(messages, system: nil)
          message_class = lex_llm_namespace::Message
          raw_messages = Array(messages)
          raw_messages = [{ role: :system, content: system }] + raw_messages if present_system?(system)

          raw_messages.map do |message|
            next message if message.is_a?(message_class)

            message_hash = normalize_hash(message)
            message_class.new(
              role:         message_hash[:role] || :user,
              content:      message_hash[:content].to_s,
              tool_call_id: message_hash[:tool_call_id]
            )
          end
        end

        def present_system?(system)
          return false if system.nil?
          return false if system.respond_to?(:empty?) && system.empty?

          true
        end

        def resolve_lex_llm_namespace
          return ::Legion::Extensions::Llm if defined?(::Legion::Extensions::Llm::Provider)

          raise NameError, 'lex-llm provider namespace is not loaded'
        end

        def normalize_tools(tools)
          case tools
          when Hash then tools
          when Array then tools.to_h { |tool| [tool.name.to_sym, tool] }
          else {}
          end
        end

        def normalize_hash(value)
          return value.transform_keys(&:to_sym) if value.respond_to?(:transform_keys)

          { role: :user, content: value }
        end

        def message_response(response)
          {
            result: response.content,
            model:  response.model_id,
            usage:  usage_hash(response)
          }
        end

        def chunk_response(chunks)
          last = chunks.reverse.find { |chunk| chunk.respond_to?(:input_tokens) }
          {
            result: chunks.filter_map(&:content).join,
            model:  last&.model_id,
            usage:  last ? usage_hash(last) : {}
          }
        end

        def usage_hash(response)
          {
            input_tokens:       response.input_tokens.to_i,
            output_tokens:      response.output_tokens.to_i,
            cache_read_tokens:  response.cached_tokens.to_i,
            cache_write_tokens: response.cache_creation_tokens.to_i
          }
        end

        def estimate_tokens(messages)
          normalize_messages(messages).sum { |message| (message.content.to_s.length / 4.0).ceil }
        end
      end
    end
  end
end

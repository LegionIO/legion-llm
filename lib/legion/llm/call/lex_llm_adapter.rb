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
            params:      opts[:params] || {},
            headers:     opts[:headers] || {},
            schema:      opts[:schema],
            thinking:    opts[:thinking],
            tool_prefs:  opts[:tool_prefs],
            model:       model_info(model, offering_metadata: opts[:offering_metadata])
          )

          message_response(response, offering_metadata: opts[:offering_metadata])
        end

        def stream(model:, messages:, **opts, &block)
          chunks = []
          provider.complete(
            normalize_messages(messages, system: opts[:system]),
            tools:       normalize_tools(opts[:tools]),
            temperature: opts[:temperature],
            params:      opts[:params] || {},
            headers:     opts[:headers] || {},
            schema:      opts[:schema],
            thinking:    opts[:thinking],
            tool_prefs:  opts[:tool_prefs],
            model:       model_info(model, offering_metadata: opts[:offering_metadata])
          ) do |chunk|
            chunks << chunk
            block&.call(chunk)
          end

          chunk_response(chunks, offering_metadata: opts[:offering_metadata])
        end

        def embed(model:, text:, dimensions: nil, **opts)
          response = provider.embed(text, model: model, dimensions: dimensions)

          {
            result:   response.vectors,
            model:    response.model,
            usage:    { input_tokens: response.input_tokens.to_i, output_tokens: 0 },
            metadata: response_metadata(offering_metadata: opts[:offering_metadata])
          }
        end

        def count_tokens(model:, messages:, **)
          {
            result: estimate_tokens(messages),
            model:  model,
            usage:  {}
          }
        end

        def offerings(live: false, **filters)
          return [] unless provider.respond_to?(:discover_offerings)

          provider.discover_offerings(live: live, **filters)
        end

        private

        attr_reader :provider_name, :provider_class, :lex_llm_namespace

        def provider
          @provider ||= provider_class.new(lex_llm_namespace.config)
        end

        def model_info(model, offering_metadata: nil)
          offering = normalize_offering_metadata(offering_metadata)
          lex_llm_namespace::Model::Info.new(
            id:                model,
            name:              offering[:canonical_model_alias] || model,
            provider:          provider_name,
            family:            offering[:model_family],
            context_window:    offering.dig(:limits, :context_window),
            max_output_tokens: offering.dig(:limits, :max_output_tokens),
            capabilities:      Array(offering[:capabilities]).map(&:to_s),
            metadata:          offering
          )
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

        def message_response(response, offering_metadata: nil)
          {
            result:   response.content,
            model:    response.model_id,
            usage:    usage_hash(response),
            metadata: response_metadata(response, offering_metadata: offering_metadata)
          }
        end

        def chunk_response(chunks, offering_metadata: nil)
          last = chunks.reverse.find { |chunk| chunk.respond_to?(:input_tokens) }
          {
            result:   chunks.filter_map(&:content).join,
            model:    last&.model_id,
            usage:    last ? usage_hash(last) : {},
            metadata: response_metadata(last, offering_metadata: offering_metadata)
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

        def response_metadata(response = nil, offering_metadata: nil)
          metadata = normalize_offering_metadata(offering_metadata)
          raw = response.respond_to?(:raw) ? response.raw : nil
          metadata[:raw_model] = raw['model'] if raw.is_a?(Hash) && raw['model']
          metadata.empty? ? {} : { offering: metadata }
        end

        def normalize_offering_metadata(value)
          return {} unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, metadata_value), normalized|
            normalized[key.respond_to?(:to_sym) ? key.to_sym : key] = metadata_value
          end
        end
      end
    end
  end
end

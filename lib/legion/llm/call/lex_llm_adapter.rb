# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      # Adapts a lex-llm provider class to legion-llm's native dispatch contract.
      class LexLLMAdapter
        include Legion::Logging::Helper

        METADATA_KEYS = %i[tier capabilities enabled].freeze

        def initialize(provider_name, provider_class, instance_config: {})
          @provider_name = provider_name.to_sym
          @provider_class = provider_class
          @instance_config = instance_config
          @lex_llm_namespace = resolve_lex_llm_namespace
        end

        def chat(model:, messages:, **opts)
          response = provider.chat(
            messages:    normalize_messages(messages, system: opts[:system]),
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
          provider.stream_chat(
            messages:    normalize_messages(messages, system: opts[:system]),
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
          model_info = model_info(model, offering_metadata: opts[:offering_metadata])
          response = provider.embed(
            text:       text,
            model:      model_info,
            dimensions: dimensions,
            params:     opts[:params] || {},
            headers:    opts[:headers] || {}
          )

          {
            result:   response.vectors,
            model:    response.model,
            usage:    { input_tokens: response.input_tokens.to_i, output_tokens: 0 },
            metadata: response_metadata(offering_metadata: opts[:offering_metadata])
          }
        end

        def image(model:, prompt:, size:, with: nil, mask: nil, **opts)
          model_info = model_info(model, offering_metadata: opts[:offering_metadata])
          response = call_image_provider(
            prompt:  prompt,
            model:   model_info,
            size:    size,
            with:    with,
            mask:    mask,
            params:  opts[:params] || {},
            headers: opts[:headers] || {}
          )

          image_response(response, model: model_info, offering_metadata: opts[:offering_metadata])
        end

        def health(live: false)
          provider.health(live: live)
        end

        def count_tokens(model:, messages:, **)
          {
            result: provider.count_tokens(messages: normalize_messages(messages), model: model_info(model)),
            model:  model,
            usage:  {}
          }
        end

        def offerings(live: false, **filters)
          return [] unless provider.respond_to?(:discover_offerings)

          provider.discover_offerings(live: live, **filters)
        end

        ToolShim = Struct.new(:name, :description, :params_schema, keyword_init: true)

        private

        attr_reader :provider_name, :provider_class, :lex_llm_namespace

        def provider
          @provider ||= build_instance_provider
        end

        def build_instance_provider
          if @instance_config.empty?
            provider_class.new(lex_llm_namespace.config)
          else
            provider_class.new(@instance_config.except(*METADATA_KEYS))
          end
        end

        def call_image_provider(**args)
          if provider.method(:image).parameters.include?(%i[key headers]) ||
             provider.method(:image).parameters.include?(%i[keyreq headers])
            provider.image(**args)
          else
            provider.image(**args.except(:headers))
          end
        end

        def model_info(model, offering_metadata: nil)
          offering = normalize_offering_metadata(offering_metadata)
          lex_llm_namespace::Model::Info.new(
            id:             model,
            name:           offering[:canonical_model_alias] || model,
            provider:       provider_name,
            family:         offering[:model_family],
            context_length: offering.dig(:limits, :context_window),
            capabilities:   Array(offering[:capabilities]).map(&:to_s),
            metadata:       offering.merge(
              max_output_tokens: offering.dig(:limits, :max_output_tokens)
            ).compact
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
              tool_calls:   message_hash[:tool_calls],
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
          hash = case tools
                 when Hash then tools
                 when Array then tools.to_h { |tool| [tool_key(tool), tool] }
                 else {}
                 end

          hash.transform_values { |tool| tool.is_a?(Hash) ? shim_tool(tool) : tool }
        end

        def tool_key(tool)
          (tool.respond_to?(:name) ? tool.name : tool[:name])&.to_sym
        end

        def shim_tool(hash)
          ToolShim.new(
            name:          hash[:name] || hash['name'],
            description:   hash[:description] || hash['description'],
            params_schema: hash[:parameters] || hash['parameters'] || hash[:input_schema] || hash['input_schema']
          )
        end

        def normalize_hash(value)
          return value.transform_keys(&:to_sym) if value.respond_to?(:transform_keys)

          { role: :user, content: value }
        end

        def message_response(response, offering_metadata: nil)
          {
            result:      response.content,
            model:       response.model_id,
            tool_calls:  response.respond_to?(:tool_calls) ? response.tool_calls : nil,
            stop_reason: response.respond_to?(:tool_call?) && response.tool_call? ? :tool_use : nil,
            thinking:    thinking_hash(response),
            usage:       usage_hash(response),
            metadata:    response_metadata(response, offering_metadata: offering_metadata)
          }.compact
        end

        def chunk_response(chunks, offering_metadata: nil)
          last = chunks.reverse.find { |chunk| chunk.respond_to?(:input_tokens) }
          tool_calls = chunks.filter_map { |chunk| chunk.tool_calls if chunk.respond_to?(:tool_calls) }.reduce({}) do |memo, calls|
            memo.merge(calls || {})
          end
          {
            result:      chunks.filter_map(&:content).join,
            model:       last&.model_id,
            tool_calls:  tool_calls.empty? ? nil : tool_calls,
            stop_reason: tool_calls.empty? ? nil : :tool_use,
            thinking:    stream_thinking_hash(chunks),
            usage:       last ? usage_hash(last) : {},
            metadata:    response_metadata(last, offering_metadata: offering_metadata)
          }.compact
        end

        def image_response(response, model:, offering_metadata: nil)
          return hash_image_response(response, model: model, offering_metadata: offering_metadata) if response.is_a?(Hash)

          {
            result:   [
              {
                url:            response.url,
                b64_json:       response.data,
                mime_type:      response.mime_type,
                revised_prompt: response.revised_prompt
              }.compact
            ],
            model:    response.model_id || model,
            usage:    response.usage || {},
            metadata: response_metadata(response, offering_metadata: offering_metadata)
          }
        end

        def hash_image_response(response, model:, offering_metadata: nil)
          normalized = response.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:model] ||= model
          normalized[:metadata] ||= response_metadata(offering_metadata: offering_metadata)
          normalized
        end

        def usage_hash(response)
          {
            input_tokens:       response.input_tokens.to_i,
            output_tokens:      response.output_tokens.to_i,
            cache_read_tokens:  response.cached_tokens.to_i,
            cache_write_tokens: response.cache_creation_tokens.to_i
          }
        end

        def stream_thinking_hash(chunks)
          thinking_text = chunks.filter_map { |chunk| chunk.thinking&.text if chunk.respond_to?(:thinking) }.join
          return nil if thinking_text.empty?

          { content: thinking_text, enabled: true }
        end

        def thinking_hash(response)
          return nil unless response.respond_to?(:thinking) && response.thinking

          thinking = response.thinking
          {
            content:   thinking.respond_to?(:text) ? thinking.text : thinking,
            signature: thinking.respond_to?(:signature) ? thinking.signature : nil,
            enabled:   true
          }.compact
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

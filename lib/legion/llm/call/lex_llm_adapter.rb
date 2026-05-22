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
          accumulator = build_stream_accumulator
          response = provider.stream_chat(
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
            accumulate_stream_chunk(accumulator, chunk)
            block&.call(chunk)
          end

          if response
            message_response(response, offering_metadata: opts[:offering_metadata])
          else
            chunk_response(accumulator, offering_metadata: opts[:offering_metadata])
          end
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
          raw_messages = prepend_or_merge_system(raw_messages, system) if present_system?(system)

          raw_messages.map do |message|
            next message if message.is_a?(message_class)

            message_hash = normalize_hash(message)
            message_class.new(
              role:         message_hash[:role] || :user,
              content:      normalize_message_content(message_hash[:content]),
              tool_calls:   normalize_message_tool_calls(message_hash[:tool_calls]),
              tool_call_id: message_hash[:tool_call_id]
            )
          end
        end

        def prepend_or_merge_system(raw_messages, system)
          first = raw_messages.first
          first_role = if first.is_a?(Hash)
                         first[:role] || first['role']
                       elsif first.respond_to?(:role)
                         first.role
                       end
          if first_role.to_s == 'system'
            existing_content = first.is_a?(Hash) ? (first[:content] || first['content']) : first.content
            merged = { role: :system, content: "#{system}\n\n#{existing_content}" }
            [merged] + raw_messages[1..]
          else
            [{ role: :system, content: system }] + raw_messages
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

        def normalize_message_content(content)
          return content if content.nil? || content.is_a?(String)
          return content if content.respond_to?(:attachments)

          if content.is_a?(Array)
            text_parts = content.filter_map { |part| text_part_content(part) }
            return text_parts.join("\n\n") unless text_parts.empty?
          end

          text_part_content(content) || content.to_s
        end

        def text_part_content(part)
          return part if part.is_a?(String)

          if part.respond_to?(:transform_keys)
            normalized = part.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            return unless normalized[:type].to_s == 'text'

            return normalized[:text].to_s
          end

          # Data structs expose named readers (type/text) without necessarily implementing [].
          # Try named accessor path first; fall through to [] / fetch for plain hashes/structs.
          if part.respond_to?(:type) || part.respond_to?(:text)
            type = (part.respond_to?(:type) ? part.type.to_s : '')
            text = part.respond_to?(:text) ? part.text : nil
            return text.to_s if type == 'text' || (type.empty? && !text.nil?)

            return nil
          end

          return unless part.respond_to?(:[]) || part.respond_to?(:fetch)

          type = (defined_method_access(part, :type) || '').to_s
          text = defined_method_access(part, :text)
          text.to_s if type == 'text' || (type.empty? && !text.nil?)
        end

        def defined_method_access(obj, key)
          # Prefer named accessor (covers Data structs like Types::ContentBlock).
          key_sym = key.respond_to?(:to_sym) ? key.to_sym : key
          return obj.public_send(key_sym) if obj.respond_to?(key_sym)

          str_key = key.to_s
          obj[key]
        rescue TypeError, NoMethodError, KeyError => e
          log.debug "[llm][adapter] action=defined_method_access key=#{key} class=#{obj.class} " \
                    "fallback=string_key error=#{e.class}: #{e.message}"
          begin
            obj[str_key]
          rescue TypeError, NoMethodError, KeyError => fallback_error
            log.debug "[llm][adapter] action=defined_method_access key=#{key} class=#{obj.class} " \
                      "fallback=none error=#{fallback_error.class}: #{fallback_error.message}"
            nil
          end
        end

        def normalize_message_tool_calls(tool_calls)
          return tool_calls unless tool_calls.is_a?(Array)

          tool_calls.filter_map do |tool_call|
            normalized = normalize_hash(tool_call)
            name = normalized[:name]
            next if name.to_s.empty?

            arguments = normalized[:arguments] || {}
            [
              name.to_sym,
              lex_llm_namespace::ToolCall.new(
                id:        normalized[:id],
                name:      name.to_s,
                arguments: arguments
              )
            ]
          end.to_h
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

        def build_stream_accumulator
          {
            content:            +'',
            model:              nil,
            usage:              {},
            raw:                nil,
            tool_calls:         {},
            thinking_text:      +'',
            thinking_signature: nil
          }
        end

        def accumulate_stream_chunk(accumulator, chunk)
          accumulator[:content] << chunk.content.to_s if chunk.respond_to?(:content) && !chunk.content.nil?
          accumulate_stream_usage(accumulator, chunk)
          accumulator[:tool_calls].merge!(chunk.tool_calls || {}) if chunk.respond_to?(:tool_calls)
          accumulate_stream_thinking(accumulator, chunk)
        end

        def accumulate_stream_usage(accumulator, chunk)
          usage = usage_hash(chunk)
          has_usage_signal = token_usage_signal?(chunk, usage)
          return unless has_usage_signal

          accumulator[:model] = chunk.model_id if chunk.respond_to?(:model_id)
          accumulator[:usage] = merge_usage_hash(accumulator[:usage], usage)
          accumulator[:raw] = chunk.raw if chunk.respond_to?(:raw)
        end

        def accumulate_stream_thinking(accumulator, chunk)
          return unless chunk.respond_to?(:thinking)

          thinking = normalize_thinking_value(chunk.thinking)
          content = thinking[:content]
          accumulator[:thinking_text] << content.to_s unless content.nil?
          accumulator[:thinking_signature] ||= thinking[:signature]
        end

        def chunk_response(accumulator, offering_metadata: nil)
          tool_calls = accumulator[:tool_calls]
          {
            result:      accumulator[:content],
            model:       accumulator[:model],
            tool_calls:  tool_calls.empty? ? nil : tool_calls,
            stop_reason: tool_calls.empty? ? nil : :tool_use,
            thinking:    stream_thinking_hash(accumulator),
            usage:       accumulator[:usage],
            metadata:    response_metadata(accumulator[:raw], offering_metadata: offering_metadata)
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
            input_tokens:       extract_token_metric(response, :input_tokens, :prompt_tokens),
            output_tokens:      extract_token_metric(response, :output_tokens, :completion_tokens),
            cache_read_tokens:  extract_token_metric(response, :cache_read_tokens, :cached_tokens),
            cache_write_tokens: extract_token_metric(response, :cache_write_tokens, :cache_creation_tokens)
          }
        end

        def token_usage_signal?(response, usage)
          usage.values.any?(&:positive?) ||
            response.respond_to?(:input_tokens) ||
            response.respond_to?(:output_tokens)
        end

        def merge_usage_hash(existing, incoming)
          current = existing.is_a?(Hash) ? existing : {}
          latest = incoming.is_a?(Hash) ? incoming : {}

          # Uses max so that a zero-valued chunk later in the stream doesn't
          # overwrite a valid count already captured from an earlier chunk.
          {
            input_tokens:       [current[:input_tokens].to_i, latest[:input_tokens].to_i].max,
            output_tokens:      [current[:output_tokens].to_i, latest[:output_tokens].to_i].max,
            cache_read_tokens:  [current[:cache_read_tokens].to_i, latest[:cache_read_tokens].to_i].max,
            cache_write_tokens: [current[:cache_write_tokens].to_i, latest[:cache_write_tokens].to_i].max
          }
        end

        def extract_token_metric(response, canonical_key, legacy_key = nil)
          values = token_metric_candidates(response, canonical_key, legacy_key)
          positive = values.find(&:positive?)
          positive || values.first || 0
        end

        def token_metric_candidates(response, canonical_key, legacy_key = nil)
          keys = [canonical_key, legacy_key].compact
          token_metric_sources(response).flat_map do |source|
            keys.filter_map { |key| extract_metric_value(source, key) }
          end
        end

        def token_metric_sources(response)
          sources = [response]
          sources << response.usage if response.respond_to?(:usage)
          sources << response.raw if response.respond_to?(:raw)

          sources.compact.flat_map do |source|
            nested = [source]
            if source.respond_to?(:key?)
              nested << hash_value(source, :usage)
              nested << hash_value(source, :data)
            end
            nested
          end.compact.uniq
        end

        def extract_metric_value(source, key)
          if source.respond_to?(key)
            value = source.public_send(key)
            return value.to_i unless value.nil?
          end

          return nil unless source.respond_to?(:key?)

          value = hash_value(source, key)
          value.to_i unless value.nil?
        rescue StandardError => e
          log.debug "[llm][adapter] action=extract_metric_value key=#{key} class=#{source.class} error=#{e.class}: #{e.message}"
          nil
        end

        def hash_value(hash, key)
          return hash[key] if hash.key?(key)

          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)

          nil
        end

        def stream_thinking_hash(accumulator)
          thinking_text = accumulator[:thinking_text]
          return nil if thinking_text.empty?

          { content: thinking_text, signature: accumulator[:thinking_signature], enabled: true }.compact
        end

        def thinking_hash(response)
          return nil unless response.respond_to?(:thinking) && response.thinking

          normalize_thinking_value(response.thinking)
        end

        def normalize_thinking_value(thinking)
          case thinking
          when Hash
            normalized = thinking.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            {
              content:   normalized[:content] || normalized[:text],
              signature: normalized[:signature],
              enabled:   true
            }.compact
          else
            {
              content:   thinking.respond_to?(:text) ? thinking.text : thinking,
              signature: thinking.respond_to?(:signature) ? thinking.signature : nil,
              enabled:   true
            }.compact
          end
        end

        def estimate_tokens(messages)
          normalize_messages(messages).sum { |message| (message.content.to_s.length / 4.0).ceil }
        end

        def response_metadata(response = nil, offering_metadata: nil)
          metadata = normalize_offering_metadata(offering_metadata)
          raw = response.is_a?(Hash) ? response : nil
          raw ||= response.raw if response.respond_to?(:raw)
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

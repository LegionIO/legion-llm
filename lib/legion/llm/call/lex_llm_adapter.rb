# frozen_string_literal: true

require 'event_stream_parser'
require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      # Adapts a lex-llm provider class to legion-llm's native dispatch contract.
      class LexLLMAdapter
        include Legion::Logging::Helper

        METADATA_KEYS = %i[tier capabilities enabled].freeze
        # Only providers that natively expose /v1/responses (OpenAI API proper).
        # All other providers (vLLM, Ollama, MLX, Anthropic, Bedrock, Gemini, Vertex, Azure Foundry)
        # use /v1/chat/completions and must declare :responses in their instance capabilities explicitly.
        RESPONSES_PROVIDER_FAMILIES = %i[openai].freeze

        def initialize(provider_name, provider_class, instance_config: {})
          @provider_name = provider_name.to_sym
          @provider_class = provider_class
          @instance_config = instance_config
          @capabilities = Array(instance_config[:capabilities] || instance_config['capabilities']).map(&:to_sym)
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

        def responses(model:, body:, messages:, stream: false, **opts, &)
          raise Legion::LLM::ProviderError, "Responses API dispatch is not supported for #{provider_name}" unless supports?(:responses)

          payload = build_responses_payload(
            body:     body,
            model:    model,
            messages: messages,
            stream:   stream,
            system:   opts[:system],
            tools:    opts[:tools]
          )

          if stream
            stream_responses_payload(payload, offering_metadata: opts[:offering_metadata], &)
          else
            response = provider.connection.post(responses_url, payload)
            responses_hash_response(response.body, offering_metadata: opts[:offering_metadata])
          end
        end

        def supports?(capability)
          return true unless capability.to_sym == :responses

          @capabilities.include?(:responses) || RESPONSES_PROVIDER_FAMILIES.include?(provider_name)
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

        def responses_url = '/v1/responses'

        def build_responses_payload(body:, model:, messages:, stream:, system: nil, tools: nil)
          payload = normalize_hash(body).dup
          payload[:model] = model
          payload[:stream] = stream
          payload[:input] = responses_payload_input(payload, messages)

          system_content = normalize_response_system(system)
          payload[:instructions] = system_content if present_system?(system_content)

          formatted_tools = responses_tools(tools)
          payload[:tools] = formatted_tools if formatted_tools.any?

          deep_compact(payload)
        end

        def responses_input(messages)
          Array(messages).map do |message|
            normalized = normalize_hash(message)
            if normalized[:role].to_s == 'tool'
              next({
                type:    'function_call_output',
                call_id: normalized[:tool_call_id].to_s,
                output:  normalize_message_content(normalized[:content]).to_s
              })
            end

            {
              role:         normalized[:role]&.to_s || 'user',
              content:      responses_message_content(normalized[:content]),
              tool_call_id: normalized[:tool_call_id]
            }.compact
          end
        end

        def responses_payload_input(payload, messages)
          return payload[:input] if payload.key?(:input)
          return payload['input'] if payload.key?('input')

          responses_input(messages)
        end

        def responses_message_content(content)
          return content if content.nil? || content.is_a?(String)

          if content.is_a?(Array)
            parts = content.filter_map { |part| responses_content_part(part) }
            return parts unless parts.empty?
          end

          text_part_content(content) || content.to_s
        end

        def responses_content_part(part)
          return { type: 'input_text', text: part } if part.is_a?(String)
          return nil unless part.respond_to?(:transform_keys)

          normalized = part.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          type = normalized[:type].to_s
          return { type: type, text: normalized[:text].to_s } if %w[input_text output_text text].include?(type)

          { type: 'input_text', text: normalized.to_s }
        end

        def normalize_response_system(system)
          return nil if system.nil?
          return system[:content] || system['content'] if system.is_a?(Hash)

          system.to_s
        end

        def responses_tools(tools)
          normalize_tools(tools).values.map do |tool|
            {
              type:        'function',
              name:        tool.name.to_s,
              description: tool.description.to_s,
              parameters:  tool.params_schema || { type: 'object', properties: {} }
            }
          end
        end

        def deep_compact(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, hash_value), compacted|
              compact_value = deep_compact(hash_value)
              compacted[key] = compact_value unless compact_value.nil?
            end
          when Array
            value.map { |entry| deep_compact(entry) }.compact
          else
            value
          end
        end

        def stream_responses_payload(payload, offering_metadata: nil, &block)
          accumulator = build_responses_stream_accumulator
          parser = EventStreamParser::Parser.new

          response = provider.connection.post(responses_url, payload) do |req|
            req.headers['Accept'] = 'text/event-stream'
            attach_responses_stream_handler(req, parser, accumulator, block)
          end

          responses_stream_response(accumulator, response.body, offering_metadata: offering_metadata)
        end

        def build_responses_stream_accumulator
          {
            content:    +'',
            thinking:   +'',
            model:      nil,
            usage:      {},
            completed:  nil,
            raw:        nil,
            tool_calls: {}
          }
        end

        def attach_responses_stream_handler(req, parser, accumulator, block)
          handler = proc do |chunk, *_args|
            parser.feed(chunk) do |_event, data|
              handle_responses_stream_data(data, accumulator, block)
            end
          end

          if req.options.respond_to?(:on_data=)
            req.options.on_data = handler
          else
            req.options[:on_data] = handler
          end
        end

        def handle_responses_stream_data(data, accumulator, block)
          return if data == '[DONE]'

          parsed = Legion::JSON.parse(data, symbolize_names: false)
          return unless parsed.is_a?(Hash)

          accumulator[:raw] = parsed
          case parsed['type']
          when 'response.output_text.delta'
            accumulate_responses_text_delta(parsed, accumulator, block)
          when 'response.reasoning_summary_text.delta', 'response.reasoning_text.delta'
            accumulate_responses_thinking_delta(parsed, accumulator, block)
          when 'response.function_call_arguments.delta'
            call_id = parsed['item_id'].to_s
            delta = parsed['delta'].to_s
            return if delta.empty?

            accumulator[:tool_calls][call_id] ||= +''
            accumulator[:tool_calls][call_id] << delta

            block&.call(
              lex_llm_namespace::Chunk.new(
                role:       :assistant,
                content:    '',
                tool_calls: { call_id.to_sym => lex_llm_namespace::ToolCall.new(id: call_id, name: '', arguments: delta) },
                model_id:   parsed['model'],
                raw:        parsed,
                tokens:     nil
              )
            )
          when 'response.completed'
            response = parsed['response'] || {}
            accumulator[:completed] = response
            accumulator[:model] = response['model'] if response['model']
            accumulator[:usage] = responses_usage(response['usage'])
            completed_thinking = extract_responses_thinking(response)
            accumulator[:thinking] << completed_thinking if accumulator[:thinking].empty? && !completed_thinking.empty?
          end
        end

        def accumulate_responses_text_delta(parsed, accumulator, block)
          delta = parsed['delta'].to_s
          return if delta.empty?

          accumulator[:content] << delta
          block&.call(
            lex_llm_namespace::Chunk.new(
              role:     :assistant,
              content:  delta,
              model_id: parsed['model'],
              raw:      parsed,
              tokens:   nil
            )
          )
        end

        def accumulate_responses_thinking_delta(parsed, accumulator, block)
          delta = parsed['delta'].to_s
          return if delta.empty?

          accumulator[:thinking] << delta
          block&.call(
            lex_llm_namespace::Chunk.new(
              role:     :assistant,
              content:  '',
              thinking: { content: delta, enabled: true },
              model_id: parsed['model'],
              raw:      parsed,
              tokens:   nil
            )
          )
        end

        def accumulate_responses_tool_call_delta(parsed, accumulator, block)
          call_id = parsed['item_id']
          delta = parsed['delta'].to_s
          return if delta.empty?

          accumulator[:tool_calls][call_id] ||= { id: call_id, name: '', arguments: '' }
          accumulator[:tool_calls][call_id][:arguments] << delta

          block&.call(
            lex_llm_namespace::Chunk.new(
              role:       :assistant,
              content:    '',
              tool_calls: { call_id.to_sym => lex_llm_namespace::ToolCall.new(id: call_id, name: '', arguments: delta) },
              model_id:   parsed['model'],
              raw:        parsed,
              tokens:     nil
            )
          )
        end

        def responses_stream_response(accumulator, response_body, offering_metadata: nil)
          completed = accumulator[:completed] || {}
          content = accumulator[:content]
          content = extract_responses_text(completed) if content.empty?
          thinking = accumulator[:thinking]
          thinking = extract_responses_thinking(completed) if thinking.empty?
          tool_calls = accumulator[:tool_calls]

          # Convert streaming accumulator (id => args) to standard format, or extract from completed
          if tool_calls && !tool_calls.empty?
            # Prefer completed response data if available (has names)
            completed_tool_calls = extract_responses_tool_calls(completed)
            tool_calls = if completed_tool_calls && !completed_tool_calls.empty?
                           completed_tool_calls
                         else
                           # Fall back to streaming accumulator
                           tool_calls.map do |id, args|
                             { id: id, name: '', arguments: args.is_a?(String) ? args : args.to_s }
                           end
                         end
          else
            tool_calls = extract_responses_tool_calls(completed)
          end

          {
            result:     content,
            model:      accumulator[:model] || completed['model'],
            usage:      accumulator[:usage],
            thinking:   thinking.empty? ? nil : { content: thinking, enabled: true },
            tool_calls: tool_calls.empty? ? nil : tool_calls,
            metadata:   response_metadata(completed.empty? ? response_body : completed, offering_metadata: offering_metadata)
          }.compact
        end

        def responses_hash_response(body, offering_metadata: nil)
          normalized = normalize_string_hash(body)
          {
            result:     extract_responses_text(normalized),
            model:      normalized['model'],
            usage:      responses_usage(normalized['usage']),
            thinking:   response_thinking_hash(normalized),
            tool_calls: extract_responses_tool_calls(normalized),
            metadata:   response_metadata(normalized, offering_metadata: offering_metadata)
          }.compact
        end

        def normalize_string_hash(value)
          return value.map { |entry| normalize_string_hash(entry) } if value.is_a?(Array)
          return {} unless value.respond_to?(:each_pair)

          value.each_with_object({}) do |(key, hash_value), normalized|
            normalized[key.to_s] = normalize_string_hash_value(hash_value)
          end
        end

        def normalize_string_hash_value(value)
          return normalize_string_hash(value) if value.respond_to?(:each_pair)
          return value.map { |entry| normalize_string_hash_value(entry) } if value.is_a?(Array)

          value
        end

        def extract_responses_text(body)
          return body['output_text'].to_s if body['output_text']

          Array(body['output']).flat_map do |item|
            Array(item['content']).filter_map do |content|
              next unless %w[output_text text].include?(content['type'].to_s)

              content['text']
            end
          end.join
        end

        def extract_responses_tool_calls(body)
          Array(body['output']).filter_map do |item|
            next unless item['type'].to_s == 'function_call'

            {
              id:        item['call_id'] || item['id'],
              name:      item['name'].to_s,
              arguments: item['arguments'].is_a?(String) ? item['arguments'] : Legion::JSON.dump(item['arguments'] || {})
            }
          end
        end

        def response_thinking_hash(body)
          thinking = extract_responses_thinking(body)
          return nil if thinking.empty?

          { content: thinking, enabled: true }
        end

        def extract_responses_thinking(body)
          # First check output array for reasoning items
          output_text = Array(body['output']).flat_map do |item|
            next [] unless item['type'].to_s == 'reasoning'

            reasoning_text_parts(item)
          end.join

          return output_text unless output_text.empty?

          # Verbose responses include top-level reasoning.text
          reasoning_obj = body['reasoning']
          if reasoning_obj.is_a?(Hash)
            direct = reasoning_obj['text'] || reasoning_obj['reasoning_text']
            return direct.to_s if direct && !direct.to_s.empty?
          end

          ''
        end

        def reasoning_text_parts(item)
          direct = item['text'] || item['content']
          return [direct.to_s] if direct && !direct.is_a?(Array)

          Array(item['summary']).filter_map { |part| reasoning_part_text(part) } +
            Array(item['content']).filter_map { |part| reasoning_part_text(part) }
        end

        def reasoning_part_text(part)
          return part.to_s if part.is_a?(String)
          return nil unless part.is_a?(Hash)

          part['text'] || part['content'] || part['summary_text']
        end

        def responses_usage(usage)
          usage = normalize_string_hash(usage)
          input = usage['input_tokens'] || usage['prompt_tokens']
          output = usage['output_tokens'] || usage['completion_tokens']
          details = {
            reasoning_tokens: usage.dig('output_tokens_details', 'reasoning_tokens').to_i
          }.compact

          result = {
            input_tokens:       input.to_i,
            output_tokens:      output.to_i,
            cache_read_tokens:  usage.dig('input_tokens_details', 'cached_tokens').to_i,
            cache_write_tokens: usage.dig('input_tokens_details', 'cache_creation_tokens').to_i
          }
          result[:output_tokens_details] = details unless details.empty?
          result
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
          raw_messages = consolidate_system_messages(raw_messages)

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

        def consolidate_system_messages(raw_messages)
          system_parts = []
          non_system = []

          raw_messages.each do |msg|
            role = if msg.is_a?(Hash)
                     (msg[:role] || msg['role']).to_s
                   elsif msg.respond_to?(:role)
                     msg.role.to_s
                   else
                     'user'
                   end

            if role == 'system'
              content = msg.is_a?(Hash) ? (msg[:content] || msg['content']) : msg.content
              system_parts << content.to_s
            else
              non_system << msg
            end
          end

          if system_parts.any?
            [{ role: :system, content: system_parts.join("\n\n") }] + non_system
          else
            non_system
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
            flat = content.flatten
            text_parts = flat.filter_map { |part| text_part_content(part) }
            return text_parts.join("\n\n") unless text_parts.empty?
          end

          text_part_content(content) || content.to_s
        end

        def text_part_content(part)
          return part if part.is_a?(String)
          return nil if part.is_a?(Array)

          if part.respond_to?(:transform_keys)
            normalized = part.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            return unless %w[input_text output_text text].include?(normalized[:type].to_s)

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
          return nil if obj.nil? || obj.is_a?(Array)

          key_sym = key.respond_to?(:to_sym) ? key.to_sym : key
          return obj.public_send(key_sym) if obj.respond_to?(key_sym)

          return nil unless obj.respond_to?(:key?) || obj.respond_to?(:fetch)

          obj[key_sym]
        rescue TypeError, NoMethodError, KeyError => e
          log.warn "[llm][adapter] action=defined_method_access key=#{key} class=#{obj.class} error=#{e.class}: #{e.message}"
          begin
            obj[key.to_s]
          rescue TypeError, NoMethodError, KeyError => fallback_error
            log.warn "[llm][adapter] action=defined_method_access key=#{key} class=#{obj.class} " \
                     "fallback_failed error=#{fallback_error.class}: #{fallback_error.message}"
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
          thinking_val = thinking_hash(response)
          log.info "[llm][adapter] message_response thinking=#{thinking_val ? 'present' : 'nil'}"
          {
            result:      response.content,
            model:       response.model_id,
            tool_calls:  response.respond_to?(:tool_calls) ? response.tool_calls : nil,
            stop_reason: extract_stop_reason_from_message(response),
            thinking:    thinking_val,
            usage:       usage_hash(response),
            metadata:    response_metadata(response, offering_metadata: offering_metadata)
          }.compact
        end

        def extract_stop_reason_from_message(response)
          return :tool_use if response.respond_to?(:tool_call?) && response.tool_call?

          raw = response.respond_to?(:raw) ? response.raw : nil
          return nil unless raw.is_a?(Hash)

          reason = raw.dig('choices', 0, 'finish_reason') || raw['finish_reason'] || raw[:finish_reason]
          reason&.to_sym
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
          return unless token_usage_signal?(chunk, usage)

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
            stop_reason: extract_stream_stop_reason(accumulator, tool_calls),
            thinking:    stream_thinking_hash(accumulator),
            usage:       accumulator[:usage],
            metadata:    response_metadata(accumulator[:raw], offering_metadata: offering_metadata)
          }.compact
        end

        def extract_stream_stop_reason(accumulator, tool_calls)
          return :tool_use unless tool_calls.empty?

          raw = accumulator[:raw]
          return nil unless raw.is_a?(Hash)

          reason = raw.dig('choices', 0, 'finish_reason') || raw['finish_reason'] || raw[:finish_reason]
          reason&.to_sym
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
            response.respond_to?(:usage) ||
            response.respond_to?(:raw) ||
            response.respond_to?(:input_tokens) ||
            response.respond_to?(:output_tokens)
        end

        def merge_usage_hash(existing, incoming)
          current = existing.is_a?(Hash) ? existing : {}
          latest = incoming.is_a?(Hash) ? incoming : {}

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

          sources.compact.flat_map { |source| expand_token_metric_source(source) }.compact.uniq
        end

        def expand_token_metric_source(source, depth = 0)
          return [] if source.nil?
          return [source] unless source.respond_to?(:key?) && depth < 3

          nested = [source]
          nested << hash_value(source, :usage)
          nested << hash_value(source, :data)
          nested << hash_value(source, :response)
          nested.compact.flat_map { |entry| [entry, *expand_token_metric_source(entry, depth + 1)] }
        end

        def extract_metric_value(source, key)
          if source.respond_to?(key)
            value = source.public_send(key)
            return value.to_i unless value.nil?
          end

          return nil unless source.respond_to?(:key?)

          value = hash_value(source, key)
          value&.to_i
        rescue StandardError => e
          log.warn "[llm][adapter] action=extract_metric_value key=#{key} class=#{source.class} error=#{e.class}: #{e.message}"
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

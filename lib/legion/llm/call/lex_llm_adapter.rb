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
        # Canonical roles are exactly system/user/assistant/tool. Dialect roles
        # (developer/critic/discriminator) fold to :system at this edge.
        CANONICAL_ROLES = %i[system user assistant tool].freeze

        def initialize(provider_name, provider_class, instance_config: {})
          @provider_name = provider_name.to_sym
          @provider_class = provider_class
          @instance_config = instance_config
          @capabilities = Array(instance_config[:capabilities] || instance_config['capabilities']).map(&:to_sym)
          @lex_llm_namespace = resolve_lex_llm_namespace
        end

        # 0.8.0 provider funnel (08): positional canonical messages, and the
        # return value is a Canonical::Response — the adapter returns it
        # directly (with offering metadata merged), never a re-projected hash.
        def chat(model:, messages:, **opts)
          response = provider.chat(
            normalize_messages(messages, system: opts[:system]),
            model:      model,
            tools:      normalize_tools(opts[:tools]),
            params:     completion_params(opts),
            headers:    opts[:headers] || {},
            schema:     opts[:schema],
            thinking:   opts[:thinking],
            tool_prefs: opts[:tool_prefs]
          )

          response_with_metadata(response, offering_metadata: opts[:offering_metadata])
        end

        def stream(model:, messages:, **opts, &block)
          accumulator = build_stream_accumulator
          response = provider.stream_chat(
            normalize_messages(messages, system: opts[:system]),
            model:      model,
            tools:      normalize_tools(opts[:tools]),
            params:     completion_params(opts),
            headers:    opts[:headers] || {},
            schema:     opts[:schema],
            thinking:   opts[:thinking],
            tool_prefs: opts[:tool_prefs]
          ) do |chunk|
            accumulate_stream_chunk(accumulator, chunk)
            block&.call(chunk)
          end

          if response
            response_with_metadata(response, offering_metadata: opts[:offering_metadata])
          else
            stream_fallback_response(accumulator, model: model, offering_metadata: opts[:offering_metadata])
          end
        end

        # Canonical Params keys only (03 O03a): temperature folds into params
        # at the adapter edge; the 0.8.0 funnel has no temperature kwarg.
        def completion_params(opts)
          params = (opts[:params] || {}).dup
          params[:temperature] = opts[:temperature] if opts.key?(:temperature) && !opts[:temperature].nil?
          params.empty? ? nil : params
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

        # 0.8.0 embed artifact (05 §3 / O07): a documented Hash
        # `{ text:, model:, embedding: Array<Float>, usage: Canonical::Usage }`.
        def embed(model:, text:, dimensions: nil, **opts)
          response = provider.embed(
            text:       text,
            model:      model,
            dimensions: dimensions,
            params:     opts[:params] || {},
            headers:    opts[:headers] || {}
          )
          usage = response[:usage]
          input_tokens = usage.respond_to?(:input_tokens) ? usage.input_tokens.to_i : 0

          {
            result:   response[:embedding],
            model:    response[:model],
            usage:    { input_tokens: input_tokens, output_tokens: 0 },
            metadata: response_metadata(offering_metadata: opts[:offering_metadata])
          }
        end

        def image(model:, prompt:, size:, with: nil, mask: nil, **opts)
          response = call_image_provider(
            prompt:  prompt,
            model:   model,
            size:    size,
            with:    with,
            mask:    mask,
            params:  opts[:params] || {},
            headers: opts[:headers] || {}
          )

          image_response(response, model: model, offering_metadata: opts[:offering_metadata])
        end

        def health(live: false)
          provider.health(live: live)
        end

        def count_tokens(model:, messages:, **)
          {
            result: provider.count_tokens(messages: normalize_messages(messages), model: model),
            model:  model,
            usage:  {}
          }
        end

        def offerings(live: false, **filters)
          return [] unless provider.respond_to?(:discover_offerings)

          provider.discover_offerings(live: live, raise_on_unreachable: live, **filters)
        rescue ArgumentError => e
          raise unless e.message.include?('raise_on_unreachable')

          provider.discover_offerings(live: live, **filters)
        end

        # SSOT writer contract: every lex-llm-* provider actor discovers its
        # catalog through `adapter.discover_offerings` (forwarded to the
        # per-instance Provider's catalog method — same body as #offerings),
        # then publishes the result into the shared inventory registry
        # (lex-llm Inventory::Registry) on its own discovery cadence,
        # reconciling write-time weights from current settings (lex-llm
        # Inventory::WeightReconciler) before each publish. Without this
        # funnel the actors have no catalog and the registry stays empty.
        def discover_offerings(live: false, **filters)
          offerings(live: live, **filters)
        end

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
          Array(messages).flat_map do |message|
            normalized = normalize_hash(message)
            role = normalized[:role].to_s

            next [responses_function_call_output_item(normalized)] if role == 'tool'

            tool_calls = normalized[:tool_calls]
            next responses_assistant_tool_items(normalized, tool_calls) if role == 'assistant' && tool_calls.is_a?(Array) && tool_calls.any?

            [{
              role:         role.empty? ? 'user' : role,
              content:      responses_message_content(normalized[:content]),
              tool_call_id: normalized[:tool_call_id]
            }.compact]
          end
        end

        def responses_function_call_output_item(normalized)
          {
            type:    'function_call_output',
            call_id: normalized[:tool_call_id].to_s,
            output:  normalize_message_content(normalized[:content]).to_s
          }
        end

        # An assistant turn that issued tool calls must render each call as a
        # Responses `function_call` item so the matching `function_call_output`
        # has a referent — otherwise the Responses API rejects the next turn with
        # "No tool call found for function call output with call_id ...". The
        # function_call items are emitted before their outputs (history order).
        def responses_assistant_tool_items(normalized, tool_calls)
          items = []
          text = normalize_message_content(normalized[:content]).to_s
          items << { role: 'assistant', content: responses_message_content(normalized[:content]) } unless text.strip.empty?
          items.concat(
            tool_calls.filter_map do |tool_call|
              id, name, arguments = read_tool_call_fields(tool_call)
              next if name.to_s.empty?

              {
                type:      'function_call',
                call_id:   id.to_s,
                name:      name.to_s,
                arguments: responses_tool_call_arguments(arguments)
              }
            end
          )
          items
        end

        # OpenAI Responses requires function_call.arguments to be a JSON string.
        def responses_tool_call_arguments(arguments)
          return arguments if arguments.is_a?(String)

          Legion::JSON.dump(arguments || {})
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
          request_id = "resp_#{SecureRandom.hex(8)}"

          response = provider.connection.post(responses_url, payload) do |req|
            req.headers['Accept'] = 'text/event-stream'
            attach_responses_stream_handler(req, parser, accumulator, block, request_id)
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

        def attach_responses_stream_handler(req, parser, accumulator, block, request_id)
          handler = proc do |chunk, *_args|
            parser.feed(chunk) do |_event, data|
              handle_responses_stream_data(data, accumulator, block, request_id)
            end
          end

          if req.options.respond_to?(:on_data=)
            req.options.on_data = handler
          else
            req.options[:on_data] = handler
          end
        end

        # The raw Responses SSE stream is surfaced as Canonical::Chunk objects —
        # the 0.8.0 stream contract (R4) is canonical chunks on the wire.
        def handle_responses_stream_data(data, accumulator, block, request_id)
          return if data == '[DONE]'

          parsed = Legion::JSON.parse(data, symbolize_names: false)
          return unless parsed.is_a?(Hash)

          accumulator[:raw] = parsed
          case parsed['type']
          when 'response.output_text.delta'
            accumulate_responses_text_delta(parsed, accumulator, block, request_id)
          when 'response.reasoning_summary_text.delta', 'response.reasoning_text.delta'
            accumulate_responses_thinking_delta(parsed, accumulator, block, request_id)
          when 'response.function_call_arguments.delta'
            call_id = parsed['item_id'].to_s
            delta = parsed['delta'].to_s
            return if delta.empty?

            accumulator[:tool_calls][call_id] ||= +''
            accumulator[:tool_calls][call_id] << delta

            chunk_class = lex_llm_namespace::Canonical::Chunk
            block&.call(chunk_class.tool_call_delta(
              tool_call:  { id: call_id, name: '', arguments: delta },
              request_id: request_id
            ))
          when 'response.completed'
            response = parsed['response'] || {}
            accumulator[:completed] = response
            accumulator[:model] = response['model'] if response['model']
            accumulator[:usage] = responses_usage(response['usage'])
            completed_thinking = extract_responses_thinking(response)
            accumulator[:thinking] << completed_thinking if accumulator[:thinking].empty? && !completed_thinking.empty?
          end
        end

        def accumulate_responses_text_delta(parsed, accumulator, block, request_id)
          delta = parsed['delta'].to_s
          return if delta.empty?

          accumulator[:content] << delta
          chunk_class = lex_llm_namespace::Canonical::Chunk
          block&.call(chunk_class.text_delta(delta: delta, request_id: request_id))
        end

        def accumulate_responses_thinking_delta(parsed, accumulator, block, request_id)
          delta = parsed['delta'].to_s
          return if delta.empty?

          accumulator[:thinking] << delta
          chunk_class = lex_llm_namespace::Canonical::Chunk
          block&.call(chunk_class.thinking_delta(delta: delta, request_id: request_id))
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

        # 0.8.0: the provider funnel takes a plain model string (Provider#
        # model_identity passes bare strings through unchanged); offering
        # metadata is a response-side fact (response_with_metadata), never a
        # request-side carrier.

        # 0.8.0: messages cross the dispatch boundary as Canonical::Message.
        # The adapter is the edge that turns wire hashes / plain strings into
        # canonical messages; canonical objects pass through untouched.
        def normalize_messages(messages, system: nil)
          message_class = lex_llm_namespace::Canonical::Message
          raw_messages = Array(messages).map do |message|
            next message if message.is_a?(message_class)

            message.is_a?(Hash) ? message : { role: :user, content: message.to_s }
          end
          raw_messages = prepend_or_merge_system(raw_messages, system) if present_system?(system)
          raw_messages = consolidate_system_messages(raw_messages)

          raw_messages.map do |message|
            next message if message.is_a?(message_class)

            message_hash = normalize_hash(message)
            message_class.build(
              role:         normalize_role(message_hash[:role] || :user),
              content:      normalize_message_content(message_hash[:content]),
              tool_calls:   normalize_message_tool_calls(message_hash[:tool_calls]),
              tool_call_id: message_hash[:tool_call_id]
            )
          end
        end

        def normalize_role(role)
          normalized = role.to_sym
          return normalized if CANONICAL_ROLES.include?(normalized)

          :system
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

        # 0.8.0: the provider funnel consumes canonical tools — the edge builds
        # Canonical::ToolDefinition from wire hashes (the `input_schema`
        # spelling is an Anthropic dialect key translated here, O03a).
        def normalize_tools(tools)
          hash = case tools
                 when Hash then tools
                 when Array then tools.to_h { |tool| [tool_key(tool), tool] }
                 else {}
                 end

          hash.transform_values { |tool| tool.is_a?(Hash) ? canonical_tool_definition(tool) : tool }
        end

        def tool_key(tool)
          (tool.respond_to?(:name) ? tool.name : tool[:name])&.to_sym
        end

        def canonical_tool_definition(hash)
          canonical = lex_llm_namespace::Canonical
          canonical::ToolDefinition.build(
            name:        hash[:name] || hash['name'],
            description: (hash[:description] || hash['description'] || '').to_s,
            parameters:  hash[:parameters] || hash['parameters'] || hash[:input_schema] || hash['input_schema'] || {},
            source:      { type: :client, executable: true }
          )
        end

        def normalize_hash(value)
          return value.transform_keys(&:to_sym) if value.respond_to?(:transform_keys)

          { role: :user, content: value }
        end

        def normalize_message_content(content)
          return content if content.nil? || content.is_a?(String)

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
            return text.to_s if %w[text output_text input_text].include?(type) || (type.empty? && !text.nil?)

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

        # Canonical tool calls — arguments is a Hash by law (03 O03a): the
        # JSON-string spelling (OpenAI chat wire) is parsed at this edge.
        def normalize_message_tool_calls(tool_calls)
          return tool_calls unless tool_calls.is_a?(Array)

          tool_calls.filter_map do |tool_call|
            id, name, arguments = read_tool_call_fields(tool_call)
            next if name.to_s.empty?

            canonical_tool_call(id, name, arguments)
          end
        end

        def canonical_tool_call(id, name, arguments)
          canonical = lex_llm_namespace::Canonical
          canonical::ToolCall.build(
            id:        id,
            name:      name.to_s,
            arguments: canonical_tool_arguments(arguments)
          )
        end

        def canonical_tool_arguments(arguments)
          return arguments if arguments.is_a?(Hash)
          return {} if arguments.nil? || arguments.to_s.strip.empty?

          parsed = Legion::JSON.load(arguments.to_s)
          raise ArgumentError, "tool call arguments must be a Hash or a JSON object string, got #{arguments.class}" unless parsed.is_a?(Hash)

          parsed
        end

        # Read id/name/arguments from a tool call regardless of shape:
        # plain Hash, Canonical::ToolCall (Data struct without
        # transform_keys), or anything else with the canonical readers.
        def read_tool_call_fields(tool_call)
          if tool_call.is_a?(Hash)
            normalized = tool_call.transform_keys(&:to_sym)
            [normalized[:id], normalized[:name], normalized[:arguments]]
          elsif tool_call.respond_to?(:name)
            id        = tool_call.respond_to?(:id) ? tool_call.id : nil
            arguments = tool_call.respond_to?(:arguments) ? tool_call.arguments : nil
            [id, tool_call.name, arguments]
          elsif tool_call.respond_to?(:to_h)
            h = tool_call.to_h.transform_keys(&:to_sym)
            [h[:id], h[:name], h[:arguments]]
          else
            [nil, nil, nil]
          end
        end

        # The 0.8.0 funnel guarantees a Canonical::Response; a non-canonical
        # return value is a provider contract violation and fails loud.
        # Offering metadata merges into the response's canonical metadata.
        def response_with_metadata(response, offering_metadata:)
          return nil if response.nil?

          canonical = lex_llm_namespace::Canonical
          raise ArgumentError, "provider returned #{response.class} instead of Canonical::Response" unless response.is_a?(canonical::Response)

          metadata = normalize_offering_metadata(offering_metadata)
          return response if metadata.empty?

          response.with(metadata: response.metadata.merge(offering: metadata))
        end

        # Canonical chunk accumulation for the stream fallback (the provider
        # stream_chat may return nil and leave only chunks on the wire).
        def build_stream_accumulator
          {
            content:            +'',
            usage:              {},
            tool_calls:         {},
            thinking_text:      +'',
            thinking_signature: nil,
            stop_reason:        nil
          }
        end

        def accumulate_stream_chunk(accumulator, chunk)
          case chunk.type
          when :text_delta
            accumulator[:content] << chunk.delta.to_s
          when :thinking_delta
            accumulator[:thinking_text] << chunk.delta.to_s
            accumulator[:thinking_signature] ||= chunk.signature
          when :tool_call_delta
            accumulate_stream_tool_call(accumulator, chunk.tool_call)
          when :done
            accumulate_stream_usage(accumulator, chunk.usage)
            accumulator[:stop_reason] ||= chunk.stop_reason
          end
          accumulator
        end

        def accumulate_stream_tool_call(accumulator, fragment)
          return if fragment.nil?

          fields = if fragment.is_a?(Hash)
                     fragment.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                   else
                     { id: fragment.id, name: fragment.name, arguments: fragment.arguments }
                   end
          id = fields[:id].to_s
          return if id.empty?

          entry = accumulator[:tool_calls][id] ||= { name: nil, arguments: +'' }
          entry[:name] = fields[:name].to_s unless fields[:name].to_s.empty?
          entry[:arguments] << fields[:arguments].to_s if fields[:arguments]
        end

        def accumulate_stream_usage(accumulator, usage)
          return if usage.nil?

          accumulator[:usage] = merge_usage_hash(accumulator[:usage], usage_hash(usage))
        end

        # Fallback response for a stream whose provider returned no final
        # value — assembled from the canonical chunks seen on the wire.
        # Canonical chunks carry no model identity, so the requested model
        # is the fallback identity.
        def stream_fallback_response(accumulator, model:, offering_metadata:)
          canonical = lex_llm_namespace::Canonical
          tool_calls = accumulator[:tool_calls].map do |id, entry|
            arguments = entry[:arguments].to_s
            arguments = Legion::JSON.load(arguments) unless arguments.empty?
            canonical::ToolCall.build(
              id:        id,
              name:      entry[:name].to_s,
              arguments: arguments.is_a?(Hash) ? arguments : {}
            )
          end

          thinking_text = accumulator[:thinking_text]
          thinking = if thinking_text.empty? && accumulator[:thinking_signature].nil?
                       nil
                     else
                       canonical::Thinking.build(
                         content:   thinking_text.empty? ? nil : thinking_text,
                         signature: accumulator[:thinking_signature]
                       )
                     end
          # G2 stop policy (mirrors Dispatch#to_canonical_stop_reason): the
          # provider's value passes through; a nil reason with tool calls
          # derives :tool_use (the response stopped to invoke them); a nil
          # reason without tool calls stays nil — the absence, not a
          # fabricated stop (N6).
          stop_reason = accumulator[:stop_reason]
          stop_reason = :tool_use if stop_reason.nil? && tool_calls.any?
          model_id = model.respond_to?(:id) ? model.id : model

          response = canonical::Response.build(
            text:        accumulator[:content],
            thinking:    thinking,
            tool_calls:  tool_calls.empty? ? nil : tool_calls,
            usage:       canonical::Usage.build(**accumulator[:usage]),
            stop_reason: stop_reason,
            model:       model_id
          )
          response_with_metadata(response, offering_metadata: offering_metadata)
        end

        # 0.8.0 image artifact (05 S3 / O07): a documented Hash
        # { model:, image: <bytes|data-uri>, size: } — pass-through with the
        # offering metadata merged.
        def image_response(response, model:, offering_metadata:)
          raise ArgumentError, "provider image must return the documented Hash artifact, got #{response.class}" unless response.is_a?(Hash)

          normalized = response.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:model] ||= model
          normalized[:metadata] ||= response_metadata(offering_metadata: offering_metadata)
          normalized
        end

        def usage_hash(usage)
          canonical = lex_llm_namespace::Canonical
          return {} if usage.nil?
          if usage.is_a?(canonical::Usage)
            return {
              input_tokens:       usage.input_tokens.to_i,
              output_tokens:      usage.output_tokens.to_i,
              cache_read_tokens:  usage.cache_read_tokens.to_i,
              cache_write_tokens: usage.cache_write_tokens.to_i
            }
          end

          hash = usage.respond_to?(:to_h) ? usage.to_h : usage
          hash = hash.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key } if hash.is_a?(Hash)
          return {} unless hash.is_a?(Hash)

          {
            input_tokens:       (hash[:input_tokens] || 0).to_i,
            output_tokens:      (hash[:output_tokens] || 0).to_i,
            cache_read_tokens:  (hash[:cache_read_tokens] || 0).to_i,
            cache_write_tokens: (hash[:cache_write_tokens] || 0).to_i
          }
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

        def response_metadata(response = nil, offering_metadata: nil)
          metadata = normalize_offering_metadata(offering_metadata)
          raw = response.is_a?(Hash) ? response : nil
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

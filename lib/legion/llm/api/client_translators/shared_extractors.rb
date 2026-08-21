# frozen_string_literal: true

module Legion
  module LLM
    module API
      module ClientTranslators
        # Token-count and thinking-text extraction shared by all client translators.
        # Single source of truth — replaces the 3-way duplicate that lived in
        # AnthropicMessages, OpenAIChat, and OpenAIResponses (P6 dedup).
        module SharedExtractors
          # Client-wire params spellings per canonical member (03 O03a).
          # Canonical::Params accepts canonical keys and types ONLY; the
          # client-dialect spellings are translated at this edge, never in the
          # shared owner.
          PARAM_SPELLINGS = {
            max_tokens:          %i[max_tokens max_output_tokens num_predict max_completion_tokens],
            max_thinking_tokens: %i[max_thinking_tokens budget_tokens thinking_budget],
            stop_sequences:      %i[stop_sequences stop]
          }.freeze

          # A canonical tool_call_delta fragment (R4) arrives as a Hash
          # (string- or symbol-keyed — wire/kit fixtures) or a
          # Canonical::ToolCall. Read one field shape-agnostically.
          def tool_fragment_field(fragment, field)
            return fragment.public_send(field) if fragment.is_a?(Hash) == false && fragment.respond_to?(field)

            return fragment[field] if fragment.is_a?(Hash) && fragment.key?(field)
            return fragment[field.to_s] if fragment.is_a?(Hash)

            nil
          end

          # First non-nil client-wire spelling for a canonical member.
          def param_spelling(body, member)
            PARAM_SPELLINGS.fetch(member).each do |key|
              value = body[key] || body[key.to_s]
              return value unless value.nil?
            end
            nil
          end

          # Map client content parts to canonical content blocks (03 O03a).
          # Canonical::ContentBlock accepts canonical types only; the dialect
          # spellings are translated at the client edge. String parts (e.g.
          # corrupted ContentBlock#inspect output replayed in history) are
          # wrapped as text blocks; other non-Hash parts pass through
          # untouched — canonical validation raises a typed error.
          def canonicalize_content_parts(parts)
            return parts unless parts.is_a?(Array)

            parts.map do |part|
              if part.is_a?(String)
                canonical_content_block({ type: 'text', text: part })
              elsif part.is_a?(Hash)
                canonical_content_block(part.transform_keys(&:to_sym))
              else
                part
              end
            end
          end

          # One client content part → one canonical content block. Type
          # aliases (input_text/output_text → text) and the OpenAI image_url
          # envelope (→ image with data/media_type/source_type) are the two
          # dialect shapes; anything else passes through and the canonical
          # validation raises loudly on a wrong type.
          def canonical_content_block(part)
            case part[:type].to_s
            when 'text', 'input_text', 'output_text'
              { type: 'text', text: part[:text].to_s }
            when 'image_url'
              canonical_image_block(part)
            else
              part
            end
          end

          def canonical_image_block(part)
            image_url = part[:image_url]
            image_url = image_url.is_a?(Hash) ? (image_url[:url] || image_url['url']) : image_url
            url = image_url.to_s
            if url.start_with?('data:')
              media_type, data = url.sub('data:', '').split(',', 2)
              {
                type:        'image',
                data:        data,
                media_type:  (media_type || '').sub(/;.*$/, ''),
                source_type: :base64
              }
            else
              { type: 'image', data: url, source_type: 'url' }
            end
          end

          def token_value(tokens, *keys)
            return 0 if tokens.nil?

            keys.each do |key|
              value = if tokens.is_a?(Hash)
                        tokens[key] || tokens[key.to_s]
                      elsif tokens.respond_to?(key)
                        tokens.public_send(key)
                      end
              return value.to_i unless value.nil?
            end
            0
          end

          def extract_thinking_text(value)
            return '' if value.nil?
            return value.to_s if value.is_a?(String)

            if value.is_a?(Hash)
              normalized = value.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
              text = normalized[:content] || normalized[:text] || normalized[:thinking] || normalized[:reasoning]
              return text.to_s if text
            end

            return value.content.to_s if value.respond_to?(:content) && value.content
            return value.text.to_s if value.respond_to?(:text) && value.text

            value.to_s
          end

          def extract_content_text(value)
            return '' if value.nil?
            return value if value.is_a?(String)

            if value.is_a?(Array)
              return value.filter_map do |part|
                text = extract_content_text(part)
                text.empty? ? nil : text
              end.join
            end

            if value.is_a?(Hash)
              normalized = value.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
              content = normalized[:content]
              return extract_content_text(content) unless content.nil?

              return '' unless text_content_type?(normalized[:type])

              text = normalized[:text] || normalized[:output_text] || normalized[:value]
              return extract_content_text(text) unless text.nil?

              return ''
            end

            if value.respond_to?(:text)
              type = value.respond_to?(:type) ? value.type : nil
              return '' unless text_content_type?(type)

              return value.text.to_s
            end

            return extract_content_text(value.content) if value.respond_to?(:content)

            value.to_s
          end

          def text_content_type?(type)
            type_string = type.to_s
            type_string.empty? || %w[text output_text input_text].include?(type_string)
          end

          def legion_routing_from_env(env)
            {
              model:    env['HTTP_X_LEGION_MODEL'],
              provider: env['HTTP_X_LEGION_PROVIDER'],
              instance: env['HTTP_X_LEGION_INSTANCE']
            }.compact
          end

          def legion_routing_explicit_from_env(env)
            flags = {
              model:    env.key?('HTTP_X_LEGION_MODEL'),
              provider: env.key?('HTTP_X_LEGION_PROVIDER'),
              instance: env.key?('HTTP_X_LEGION_INSTANCE'),
              tier:     env.key?('HTTP_X_LEGION_TIER')
            }.select { |_, value| value }
            flags.empty? ? nil : flags
          end

          # Tool-call argument coercion is FORMAT-SPECIFIC. The two client
          # surfaces have incompatible wire requirements:
          #
          #   - Anthropic /v1/messages tool_use.input  MUST be an Object/Hash.
          #     (`{"type":"tool_use","input":{"command":"ls"}}` — never a string.)
          #   - OpenAI   function_call.arguments       MUST be a JSON String.
          #     (`{"name":"bash","arguments":"{\"command\":\"ls\"}"}` — never an object.)
          #
          # A single uniform helper ("everything is a string") was the bug
          # behind the claude/vllm multi-turn regression where `tool_use.input`
          # surfaced as a JSON string (or worse — a coerced numeric like
          # `1.01` from a degraded model output). Use the explicit per-format
          # helper at the call site; never rebalance by pushing one format's
          # shape onto the other.

          # Coerce raw tool arguments into the OpenAI wire shape: a JSON
          # string. Non-string inputs are JSON-dumped; nil becomes "{}";
          # malformed values are stringified as a last resort so the wire
          # never carries a Ruby object.
          def args_as_json_string(args)
            return args if args.is_a?(String)

            Legion::JSON.dump(args || {})
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.client_translator.args_as_json_string')
            args.to_s
          end

          # Coerce raw tool arguments into the Anthropic wire shape: a Hash.
          # Strings are parsed as JSON when possible; non-Hash literals
          # (numbers, arrays from degraded model output) collapse to `{}`
          # rather than violating the contract.
          def args_as_object(args)
            return args if args.is_a?(Hash)
            return {} if args.nil?

            if args.is_a?(String)
              return {} if args.empty?

              parsed = Legion::JSON.load(args)
              return parsed if parsed.is_a?(Hash)
            end

            {}
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.client_translator.args_as_object')
            {}
          end

          def apply_canonical_params_to_inference(request_kwargs, canonical_params)
            params = normalize_canonical_params(canonical_params)
            return request_kwargs unless params

            max_tokens = params[:max_tokens]
            request_kwargs[:tokens] = { max: max_tokens } if max_tokens

            generation = params.slice(
              :temperature,
              :top_p,
              :top_k,
              :frequency_penalty,
              :presence_penalty,
              :seed
            ).compact
            request_kwargs[:generation] = generation unless generation.empty?

            stop_sequences = normalize_stop_sequences(params[:stop_sequences] || params[:stop])
            request_kwargs[:stop] = { sequences: stop_sequences } unless stop_sequences.empty?

            response_format = normalize_response_format(params[:response_format])
            request_kwargs[:response_format] = response_format if response_format

            request_kwargs
          end

          def normalize_canonical_params(value)
            hash = value.respond_to?(:to_h) ? value.to_h : value
            return nil unless hash.is_a?(Hash)

            hash.each_with_object({}) do |(key, param_value), normalized|
              normalized[key.respond_to?(:to_sym) ? key.to_sym : key] = param_value
            end
          end

          def normalize_stop_sequences(value)
            return [] if value.nil?
            return [value.to_s] if value.is_a?(String) || value.is_a?(Symbol)

            Array(value).compact.map(&:to_s).reject(&:empty?)
          end

          def normalize_response_format(value)
            return nil if value.nil?
            return { type: value.to_sym } if value.is_a?(String) || value.is_a?(Symbol)

            value
          end
        end
      end
    end
  end
end

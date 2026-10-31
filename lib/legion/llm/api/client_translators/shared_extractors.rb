# frozen_string_literal: true

require 'uri'
require 'legion/llm/errors'

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

            normalized = parts.map do |part|
              if part.is_a?(String)
                canonical_content_block({ type: 'text', text: part })
              elsif part.is_a?(Hash)
                canonical_content_block(part.transform_keys(&:to_sym))
              else
                part
              end
            end
            canonical_message_content(parts: normalized)
          end

          # Text fragments carry their own whitespace. Collapse only unannotated
          # text; media, cache boundaries and other block semantics stay ordered.
          def canonical_message_content(parts:)
            plain_text = parts.all? do |part|
              part.is_a?(Hash) && part[:type].to_s == 'text' &&
                part.each_key.all? { |key| %i[type text].include?(key) }
            end
            return parts unless plain_text

            parts.map { |part| part[:text] }.join
          end

          # Client image spellings converge to the provider-neutral image block.
          def canonical_content_block(part)
            case part[:type].to_s
            when 'text', 'input_text', 'output_text'
              { type: 'text', text: part[:text].to_s, cache_control: part[:cache_control] }.compact
            when 'image_url', 'input_image'
              canonical_image_block(part)
            when 'image_generation_call'
              raise Legion::LLM::Errors::InvalidRequest, 'Generated image history is not supported'
            else
              part
            end
          end

          def canonical_image_block(part)
            raise Legion::LLM::Errors::InvalidRequest, 'Image file_id references are not supported' if part.key?(:file_id)

            envelope = part[:image_url]
            envelope = envelope.transform_keys(&:to_sym) if envelope.is_a?(Hash)
            raise Legion::LLM::Errors::InvalidRequest, 'Image file_id references are not supported' if envelope.is_a?(Hash) && envelope.key?(:file_id)

            url = envelope.is_a?(Hash) ? envelope[:url] : envelope
            detail = envelope.is_a?(Hash) ? envelope[:detail] : part[:detail]
            raise Legion::LLM::Errors::InvalidRequest, 'Image URL must be a nonempty string' unless url.is_a?(String) && !url.empty?

            image = if url.start_with?('data:')
                      image_data_url_block(url: url)
                    else
                      image_source_block(source_type: :url, data: url)
                    end
            image.merge(detail: detail, cache_control: part[:cache_control]).compact
          end

          def image_data_url_block(url:)
            separator = url.index(',')
            raise Legion::LLM::Errors::InvalidRequest, 'Malformed image data URL' unless separator

            header = url.byteslice(5, separator - 5)
            media_type, encoding = header.split(';', 2)
            raise Legion::LLM::Errors::InvalidRequest, 'Image data URL must use base64 encoding' unless encoding == 'base64'

            image_source_block(source_type: :base64, media_type: media_type, data: url.byteslice((separator + 1)..))
          end

          def image_source_block(source_type:, data:, media_type: nil)
            raise Legion::LLM::Errors::InvalidRequest, 'Image source must be a nonempty string' unless data.is_a?(String) && !data.empty?

            case source_type
            when :base64
              raise Legion::LLM::Errors::InvalidRequest, 'Image base64 source requires a supported image MIME type' unless %w[image/jpeg image/png image/gif image/webp].include?(media_type)
              # A possessive scan validates the alphabet without decoding/copying
              # the payload or backtracking over attacker-controlled input.
              raise Legion::LLM::Errors::InvalidRequest, 'Malformed base64 image data' unless (data.bytesize % 4).zero? && %r{\A[A-Za-z0-9+/]*+={0,2}\z}.match?(data)
            when :url
              uri = URI.parse(data)
              raise Legion::LLM::Errors::InvalidRequest, 'Image URL must be an absolute HTTP(S) URL' unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
            else
              raise Legion::LLM::Errors::InvalidRequest, 'Unsupported image source type'
            end

            { type: 'image', data: data, media_type: media_type, source_type: source_type }.compact
          rescue URI::InvalidURIError
            raise Legion::LLM::Errors::InvalidRequest, 'Malformed image URL'
          end

          # The pipeline envelope's tokens member is a plain Hash (or {} when
          # no usage was observed) — one shape, no dual reader (G3).
          def token_value(tokens, *keys)
            return 0 if tokens.nil?

            keys.each do |key|
              value = tokens.is_a?(Hash) ? (tokens[key] || tokens[key.to_s]) : nil
              return value.to_i unless value.nil?
            end
            0
          end

          # G3: the envelope carries the provider's Canonical::Thinking — the
          # thinking text is the .content member (the former String/Hash/
          # duck-typed branches were the split-world seam).
          def extract_thinking_text(value)
            return '' if value.nil?

            value.content.to_s
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

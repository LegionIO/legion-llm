# frozen_string_literal: true

require 'securerandom'

require 'legion/logging/helper'
require 'legion/extensions/llm'

module Legion
  module LLM
    module Call
      # Canonical module convenience aliases (lex-llm 0.5.0+).
      Canonical = Legion::Extensions::Llm::Canonical

      # DEPRECATED(P6): Hash-key compatibility adapters for Canonical types.
      # These exist ONLY to avoid wholesale rewrites in the P4a batch. They are
      # deleted in Phase 6 — do NOT build new code against hash-key access on
      # Canonical::Response, Canonical::ToolCall, or Canonical::Usage.
      # Each access logs a deprecation breadcrumb so P6 can find survivors.
      module CanonicalResponseCompat
        KEY_MAP = { content: :text, result: :text, text: :text }.freeze

        def [](key)
          Legion::Logging.log.debug do
            "[llm][DEPRECATED(P6)] canonical_hash_access key=#{key} caller=#{caller_locations(1, 1)&.first}"
          end
          sym = key.to_sym
          sym = KEY_MAP[sym] || sym
          public_send(sym) if respond_to?(sym)
        end

        def has_key?(key) # rubocop:disable Naming/PredicatePrefix -- Hash API compat requires this name
          Legion::Logging.log.debug do
            "[llm][DEPRECATED(P6)] canonical_has_key? key=#{key} caller=#{caller_locations(1, 1)&.first}"
          end
          sym = key.respond_to?(:to_sym) ? key.to_sym : key.to_s.to_sym
          sym = KEY_MAP[sym] || sym
          respond_to?(sym)
        end

        def dig(key, *rest)
          Legion::Logging.log.debug do
            "[llm][DEPRECATED(P6)] canonical_dig key=#{key} caller=#{caller_locations(1, 1)&.first}"
          end
          val = self[key]
          return val if rest.empty?
          return nil unless val.respond_to?(:dig)

          val.dig(*rest)
        end
      end

      # DEPRECATED(P6): Hash-key compatibility adapter for Canonical::ToolCall.
      # Deleted in Phase 6.
      module CanonicalToolCallCompat
        def [](key)
          Legion::Logging.log.debug do
            "[llm][DEPRECATED(P6)] tool_call_hash_access key=#{key} caller=#{caller_locations(1, 1)&.first}"
          end
          sym = key.to_sym
          public_send(sym) if respond_to?(sym)
        end
      end

      # DEPRECATED(P6): Monkey-patch canonical types for Hash-like access.
      # These adapters exist ONLY to avoid wholesale rewrites in the P4a batch.
      # They are deleted in Phase 6 — do not build new code against hash-key access.
      if defined?(Canonical::Response)
        Canonical::Response.include(CanonicalResponseCompat)
        Canonical::Response.class_eval do
          def [](key)
            Legion::Logging.log.debug do
              "[llm][DEPRECATED(P6)] response_hash_access key=#{key} caller=#{caller_locations(1, 1)&.first}"
            end
            sym = key.respond_to?(:to_sym) ? key.to_sym : key.to_s.to_sym
            if %i[result content].include?(sym)
              txt = text
              return txt unless txt.to_s.empty?

              metadata[:raw_result] if respond_to?(:metadata) && metadata.is_a?(Hash) && metadata[:raw_result]
            elsif sym == :text
              text
            else
              super
            end
          end
        end
      end
      Canonical::ToolCall.include(CanonicalToolCallCompat) if defined?(Canonical::ToolCall)
      Canonical::Usage.include(CanonicalResponseCompat) if defined?(Canonical::Usage)

      module Dispatch
        extend self
        extend Legion::Logging::Helper

        # Mapping of supported capability names to extension method names.
        CAPABILITY_METHODS = {
          chat:         :chat,
          stream:       :stream,
          responses:    :responses,
          embed:        :embed,
          image:        :image,
          count_tokens: :count_tokens
        }.freeze

        # Generic dispatch entry point. Routes to the appropriate extension method
        # based on the capability name.
        #
        # @param provider   [Symbol, String] provider name
        # @param capability [Symbol, String] one of :chat, :stream, :embed, :count_tokens
        # @param instance   [Symbol, String, nil] provider instance (nil = default)
        # @param model      [String, nil] model identifier forwarded to the extension
        # @param block      [Proc, nil] block forwarded to the extension (e.g. for streaming)
        # @return [Canonical::Response] canonical provider response
        # @raise [Legion::LLM::ProviderError] if provider is not registered or capability is unsupported
        def call(provider:, capability:, instance: nil, model: nil, **, &)
          cap_sym = capability.to_sym
          method_name = CAPABILITY_METHODS[cap_sym]
          raise Legion::LLM::ProviderError, "unsupported capability: #{capability}" unless method_name

          ext = fetch_extension!(provider, instance: instance)
          raise Legion::LLM::ProviderError, "unsupported capability #{capability} for provider #{provider}" if ext.respond_to?(:supports?) && !ext.supports?(cap_sym)

          log.info("[llm][dispatch] capability=#{cap_sym} provider=#{provider} " \
                   "instance=#{instance || 'default'} model=#{model}")

          raw = ext.public_send(method_name, model: model, **, &)
          normalize_response(raw)
        end

        # --- Deprecated per-type dispatch methods ---
        # These delegate to #call and emit a one-time deprecation warning.

        # @deprecated Use {#call} with `capability: :chat` instead.
        def dispatch_chat(provider:, model:, messages:, **)
          unless @chat_deprecation_warned
            log.warn('[llm][dispatch] DEPRECATED: dispatch_chat — use Dispatch.call(capability: :chat)')
            @chat_deprecation_warned = true
          end
          call(provider: provider, capability: :chat, model: model, messages: messages, **)
        end

        # @deprecated Use {#call} with `capability: :embed` instead.
        def dispatch_embed(provider:, model:, text:, **)
          unless @embed_deprecation_warned
            log.warn('[llm][dispatch] DEPRECATED: dispatch_embed — use Dispatch.call(capability: :embed)')
            @embed_deprecation_warned = true
          end
          call(provider: provider, capability: :embed, model: model, text: text, **)
        end

        # @deprecated Use {#call} with `capability: :stream` instead.
        def dispatch_stream(provider:, model:, messages:, **, &)
          unless @stream_deprecation_warned
            log.warn('[llm][dispatch] DEPRECATED: dispatch_stream — use Dispatch.call(capability: :stream)')
            @stream_deprecation_warned = true
          end
          call(provider: provider, capability: :stream, model: model, messages: messages, **, &)
        end

        # @deprecated Use {#call} with `capability: :count_tokens` instead.
        def dispatch_count_tokens(provider:, model:, messages:, **)
          unless @count_tokens_deprecation_warned
            log.warn('[llm][dispatch] DEPRECATED: dispatch_count_tokens — use Dispatch.call(capability: :count_tokens)')
            @count_tokens_deprecation_warned = true
          end
          call(provider: provider, capability: :count_tokens, model: model, messages: messages, **)
        end

        # Returns true when the provider is registered in Registry.
        #
        # @param provider [Symbol, String]
        # @return [Boolean]
        def available?(provider)
          Registry.registered?(provider)
        end

        private

        def fetch_extension!(provider, instance: nil)
          ext = Registry.for(provider, instance: instance)
          return ext if ext

          if instance && instance.to_s != 'default'
            ext = Registry.for(provider, instance: :default)
            if ext
              log.warn("[llm][native] instance_fallback provider=#{provider} requested=#{instance} using=default")
              return ext
            end
          end

          instance_suffix = instance ? "/#{instance}" : ''
          log.error("[llm][native] provider_not_registered provider=#{provider}#{instance_suffix}")
          raise Legion::LLM::ProviderError,
                "Native provider not registered: #{provider}#{instance_suffix}. " \
                'Ensure the lex-* extension is loaded before dispatching.'
        end

        # Normalize a raw extension response into a Canonical::Response.
        #
        # Expected extension return shapes (any subset is acceptable):
        #   { content:, usage: { input_tokens:, output_tokens: }, model: }
        #   { result:, usage: ... }
        #
        # @return [Canonical::Response]
        def normalize_response(raw)
          # Already a canonical response — no conversion needed
          return raw if defined?(Canonical::Response) && raw.is_a?(Canonical::Response)

          # Non-hash objects (object with .content) or plain values → hash first
          raw = coerce_to_hash(raw) unless raw.is_a?(Hash)

          text = extract_response_text(raw)
          raw_usage = raw[:usage] || {}

          # Preserve non-string payload (e.g., image URLs, embedding vectors as metadata)
          # so the compat adapter can return [:result] / [:content] for non-chat results.
          metadata = raw[:metadata] || raw[:offering_metadata] || {}
          raw_result = [raw[:result], raw[:content], raw[:response]].find { |v| !v.nil? && !v.is_a?(String) }
          metadata[:raw_result] = raw_result if raw_result

          usage = coerce_usage(raw_usage)

          log.debug("[llm][native] normalized_response usage_class=#{usage.class}")
          text, thinking = extract_thinking_payload(text, raw, metadata)

          tool_calls = to_canonical_tool_calls(
            raw[:tool_calls] || raw['tool_calls'] || raw[:tools] || raw['tools'] || text
          )
          stop_reason = to_canonical_stop_reason(raw[:stop_reason] || raw['stop_reason'], tool_calls)

          Canonical::Response.new(
            text:        text.to_s,
            thinking:    thinking,
            tool_calls:  tool_calls,
            usage:       usage,
            stop_reason: stop_reason,
            model:       raw[:model] || raw['model'],
            routing:     {},
            metadata:    metadata
          )
        end

        # Extract the text content from a raw hash response.
        # Returns the first String value from :result, :content, :response keys.
        # For non-String text (arrays/embeddings), stores as metadata and returns ''.
        def extract_response_text(raw)
          text_val = [raw[:result], raw[:content], raw[:response]].find { |v| !v.nil? && v.is_a?(String) }
          return text_val || '' if text_val

          # Non-string payload (images, embeddings) — preserve in metadata
          raw[:raw_payload] = [raw[:result], raw[:content], raw[:response]].find { |v| !v.nil? }
          ''
        end

        # Coerce a non-hash raw response (object with reader methods or a plain value) to a hash.
        def coerce_to_hash(raw)
          {
            result:      raw.respond_to?(:content) ? raw.content : raw,
            usage:       {
              input_tokens:       raw.respond_to?(:input_tokens) ? raw.input_tokens.to_i : 0,
              output_tokens:      raw.respond_to?(:output_tokens) ? raw.output_tokens.to_i : 0,
              cache_read_tokens:  raw.respond_to?(:cached_tokens) ? raw.cached_tokens.to_i : 0,
              cache_write_tokens: raw.respond_to?(:cache_creation_tokens) ? raw.cache_creation_tokens.to_i : 0
            },
            metadata:    raw.respond_to?(:metadata) && raw.metadata.is_a?(Hash) ? raw.metadata : {},
            tool_calls:  raw.respond_to?(:tool_calls) ? raw.tool_calls : nil,
            stop_reason: raw.respond_to?(:stop_reason) ? raw.stop_reason : nil,
            thinking:    raw.respond_to?(:thinking) ? raw.thinking : nil
          }.compact
        end

        # Convert raw usage to Canonical::Usage with best-effort field mapping.
        def coerce_usage(raw_usage)
          return raw_usage if defined?(Canonical::Usage) && raw_usage.is_a?(Canonical::Usage)

          hash = if raw_usage.is_a?(Hash)
                   raw_usage
                 elsif raw_usage.respond_to?(:input_tokens)
                   { input_tokens: raw_usage.input_tokens, output_tokens: raw_usage.respond_to?(:output_tokens) ? raw_usage.output_tokens : 0,
                     cache_read_tokens: raw_usage.respond_to?(:cache_read_tokens) ? raw_usage.cache_read_tokens : 0,
                     cache_write_tokens: raw_usage.respond_to?(:cache_write_tokens) ? raw_usage.cache_write_tokens : 0 }
                 else
                   {}
                 end
          Canonical::Usage.new(
            input_tokens:       (hash[:input_tokens] || hash['input_tokens'] || 0).to_i,
            output_tokens:      (hash[:output_tokens] || hash['output_tokens'] || 0).to_i,
            cache_read_tokens:  (hash[:cache_read_tokens] || hash['cache_read_tokens'] || 0).to_i,
            cache_write_tokens: (hash[:cache_write_tokens] || hash['cache_write_tokens'] || 0).to_i,
            thinking_tokens:    (hash[:thinking_tokens] || hash['thinking_tokens'] || 0).to_i,
            units:              raw_units(hash[:units] || hash['units'])
          )
        end

        def raw_units(value)
          value.is_a?(Hash) ? value : {}
        end

        # Normalize thinking payload to Canonical::Thinking | nil.
        # Returns [cleaned_text, Canonical::Thinking | nil].
        def extract_thinking_payload(text, raw, metadata)
          content_out = nil
          sig_out     = nil
          cleaned_text = text
          thinking_param = raw[:thinking] || raw['thinking']

          thinker = defined?(::Legion::Extensions::Llm::Responses::ThinkingExtractor) &&
                    ::Legion::Extensions::Llm::Responses::ThinkingExtractor

          if thinker
            extraction = thinker.extract(text.to_s, metadata: metadata || {})
            cleaned_text = extraction.content || ''
            content_out = extraction.thinking || ''
            sig_out     = extraction.signature
            explicit_thinking = normalize_thinking_value(thinking_param)
            merged = if explicit_thinking && content_out.to_s.empty?
                       explicit_thinking
                     else
                       {
                         content:   [explicit_thinking&.dig(:content), content_out].compact.reject(&:empty?).join,
                         signature: sig_out || explicit_thinking&.dig(:signature)
                       }
                     end
            thinking_param = merged
          else
            thinking_param = normalize_thinking_value(thinking_param) ||
                             normalize_thinking_value(metadata[:thinking] || metadata['thinking'])
          end

          [cleaned_text, build_canonical_thinking(thinking_param)]
        end

        # Normalize a raw thinking value to { content: String, signature: String? } | nil.
        def normalize_thinking_value(value)
          return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

          if value.is_a?(Hash)
            normalized = value.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
            content = normalized[:content] || normalized[:text] || ''
            signature = normalized[:signature]
          elsif value.respond_to?(:text)
            content = value.text
            signature = value.respond_to?(:signature) ? value.signature : nil
          else
            content = value.to_s
            signature = nil
          end

          content = content.to_s.strip unless content.nil?
          return nil if content.to_s.empty? && (signature || '').to_s.empty?

          { content: content, signature: signature }
        end

        # Build a Canonical::Thinking or nil.
        def build_canonical_thinking(payload)
          return nil if payload.nil? || payload.to_s.empty?

          content   = payload[:content] || payload['content'] || ''
          signature = payload[:signature] || payload['signature']
          return nil if content.to_s.empty? && signature.to_s.empty?

          Canonical::Thinking.new(content: content.to_s, signature: signature&.to_s)
        end

        # Convert raw tool_calls to Array<Canonical::ToolCall>.
        def to_canonical_tool_calls(value)
          raw_calls = inner_tool_calls(value)
          raw_calls.filter_map { |entry| to_single_canonical_tool_call(entry) }.compact
        end

        # Extract an array of raw tool-call entries from various shapes.
        def inner_tool_calls(value)
          case value
          when Array
            value
          when Hash
            return [value] if tool_call_hash?(value)
            return value.values if value.values

            []
          else
            return [] unless value.respond_to?(:values)

            value.values
          end
        end

        # Convert a single raw tool call entry to Canonical::ToolCall.
        def to_single_canonical_tool_call(entry)
          # Canonical::ToolCall has many required fields; normalize them with defaults.
          normalized = if entry.respond_to?(:name)
                         {
                           id:        entry.respond_to?(:id) ? entry.id : nil,
                           name:      entry.name,
                           arguments: entry.respond_to?(:arguments) ? entry.arguments : {}
                         }
                       elsif entry.is_a?(Hash)
                         symbolized = entry.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
                         func       = if symbolized[:function].is_a?(Hash)
                                        symbolized[:function].transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
                                      else
                                        {}
                                      end
                         name       = symbolized[:name] || func[:name]
                         args_raw   = symbolized[:arguments] || symbolized[:input] || func[:arguments] || {}
                         return nil if name.to_s.empty?

                         {
                           id:                           symbolized[:id],
                           name:                         name.to_s,
                           arguments:                    parse_arguments(args_raw),
                           source:                       symbolized[:source],
                           status:                       symbolized[:status],
                           result:                       symbolized[:result],
                           duration_ms:                  symbolized[:duration_ms],
                           error:                        symbolized[:error],
                           started_at:                   symbolized[:started_at],
                           finished_at:                  symbolized[:finished_at],
                           category:                     symbolized[:category],
                           data_handling_classification: symbolized[:data_handling_classification],
                           policy_decision:              symbolized[:policy_decision]
                         }
                       end
          return nil unless normalized && normalized[:name] && !normalized[:name].to_s.empty?

          args_already_parsed = normalized[:arguments].is_a?(Hash) ||
                                (normalized[:arguments].is_a?(String) && normalized[:arguments].empty?)
          normalized[:arguments] = parse_arguments(normalized[:arguments]) unless args_already_parsed

          Canonical::ToolCall.new(
            id:                           normalized[:id] || "tc_#{SecureRandom.hex(8)}",
            exchange_id:                  normalized[:exchange_id],
            name:                         normalized[:name].to_s,
            arguments:                    normalized[:arguments] || {},
            source:                       normalized[:source] || { type: :client },
            status:                       normalized[:status],
            duration_ms:                  normalized[:duration_ms],
            result:                       normalized[:result],
            error:                        normalized[:error],
            started_at:                   normalized[:started_at],
            finished_at:                  normalized[:finished_at],
            category:                     normalized[:category],
            data_handling_classification: normalized[:data_handling_classification],
            policy_decision:              normalized[:policy_decision]
          )
        end

        # Map stop reason to canonical stop_reason enum.
        def to_canonical_stop_reason(reason, tool_calls)
          return :tool_use if reason.nil? && tool_calls.any?
          return :end_turn if reason.nil?

          sym = reason.respond_to?(:to_sym) ? reason.to_sym : reason.to_s.to_sym
          Canonical::STOP_REASONS.include?(sym) ? sym : :end_turn
        end

        def parse_arguments(arguments)
          return arguments unless arguments.is_a?(String)
          return {} if arguments.strip.empty?

          parsed = Legion::JSON.parse(arguments)
          parsed.is_a?(Hash) ? parsed : {}
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.dispatch.parse_arguments')
          {}
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      # Wraps a native dispatch result hash so Pipeline::Executor and
      # ConversationStore can consume a stable provider response object.
      class NativeResponseAdapter
        attr_reader :content, :model, :input_tokens, :output_tokens,
                    :cache_read_tokens, :cache_write_tokens, :usage, :metadata,
                    :tool_calls, :stop_reason, :thinking

        HASH_KEY_MAP = {
          result: :content, content: :content,
          input_tokens: :input_tokens, output_tokens: :output_tokens,
          cache_read_tokens: :cache_read_tokens, cache_write_tokens: :cache_write_tokens,
          usage: :usage, metadata: :metadata,
          tool_calls: :tool_calls, stop_reason: :stop_reason, thinking: :thinking,
          data: :content, model: :model
        }.freeze

        def initialize(result_hash)
          result_hash = self.class.coerce_result(result_hash)
          @content             = result_hash[:result].to_s
          @model               = result_hash[:model]
          @metadata            = result_hash[:metadata] || {}
          @tool_calls          = result_hash[:tool_calls] || []
          @stop_reason         = result_hash[:stop_reason]
          @thinking            = result_hash[:thinking]
          usage                = self.class.coerce_usage(result_hash[:usage])
          @usage               = usage
          @input_tokens        = usage.input_tokens
          @output_tokens       = usage.output_tokens
          @cache_read_tokens   = usage.cache_read_tokens
          @cache_write_tokens  = usage.cache_write_tokens
        end

        def [](key)
          attr = HASH_KEY_MAP[key.to_sym]
          attr ? public_send(attr) : nil
        end

        def dig(*keys)
          value = self[keys.first]
          return value if keys.length == 1
          return nil unless value.respond_to?(:dig)

          value.dig(*keys[1..])
        end

        def self.coerce_result(raw)
          return raw if raw.is_a?(Hash)

          {
            result:      raw.respond_to?(:content) ? raw.content : raw,
            usage:       Usage.new(
              input_tokens:       raw.respond_to?(:input_tokens) ? raw.input_tokens.to_i : 0,
              output_tokens:      raw.respond_to?(:output_tokens) ? raw.output_tokens.to_i : 0,
              cache_read_tokens:  raw.respond_to?(:cached_tokens) ? raw.cached_tokens.to_i : 0,
              cache_write_tokens: raw.respond_to?(:cache_creation_tokens) ? raw.cache_creation_tokens.to_i : 0
            ),
            metadata:    raw.respond_to?(:metadata) && raw.metadata.is_a?(Hash) ? raw.metadata : {},
            tool_calls:  raw.respond_to?(:tool_calls) ? raw.tool_calls : [],
            stop_reason: raw.respond_to?(:stop_reason) ? raw.stop_reason : nil,
            thinking:    raw.respond_to?(:thinking) ? raw.thinking : nil
          }.compact
        end

        def self.coerce_usage(raw_usage)
          return raw_usage if raw_usage.is_a?(Usage)
          return Usage.new unless raw_usage.is_a?(Hash)

          Usage.new(
            input_tokens:       (raw_usage[:input_tokens] || raw_usage['input_tokens']).to_i,
            output_tokens:      (raw_usage[:output_tokens] || raw_usage['output_tokens']).to_i,
            cache_read_tokens:  (raw_usage[:cache_read_tokens] || raw_usage['cache_read_tokens']).to_i,
            cache_write_tokens: (raw_usage[:cache_write_tokens] || raw_usage['cache_write_tokens']).to_i
          )
        end
      end

      module Dispatch
        extend self
        extend Legion::Logging::Helper

        # Mapping of supported capability names to extension method names.
        CAPABILITY_METHODS = {
          chat:         :chat,
          stream:       :stream,
          embed:        :embed,
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
        # @return [Hash] standardized { result:, usage: } hash
        # @raise [Legion::LLM::ProviderError] if provider is not registered or capability is unsupported
        def call(provider:, capability:, instance: nil, model: nil, **, &)
          cap_sym = capability.to_sym
          method_name = CAPABILITY_METHODS[cap_sym]
          raise Legion::LLM::ProviderError, "unsupported capability: #{capability}" unless method_name

          ext = fetch_extension!(provider, instance: instance)

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

          instance_suffix = instance ? "/#{instance}" : ''
          log.error("[llm][native] provider_not_registered provider=#{provider}#{instance_suffix}")
          raise Legion::LLM::ProviderError,
                "Native provider not registered: #{provider}#{instance_suffix}. " \
                'Ensure the lex-* extension is loaded before dispatching.'
        end

        # Normalize a raw extension response into a standard hash.
        #
        # Expected extension return shapes (any subset is acceptable):
        #   { content:, usage: { input_tokens:, output_tokens: }, model: }
        #   { result:, usage: ... }
        #
        # Normalizes to: { result:, usage: Usage }
        def normalize_response(raw)
          return NativeResponseAdapter.coerce_result(raw) unless raw.is_a?(Hash)

          result    = raw[:result] || raw[:content] || raw[:response]
          raw_usage = raw[:usage] || {}

          usage = if raw_usage.is_a?(Usage)
                    raw_usage
                  elsif raw_usage.is_a?(Hash)
                    Usage.new(
                      input_tokens:       raw_usage[:input_tokens].to_i,
                      output_tokens:      raw_usage[:output_tokens].to_i,
                      cache_read_tokens:  raw_usage[:cache_read_tokens].to_i,
                      cache_write_tokens: raw_usage[:cache_write_tokens].to_i
                    )
                  else
                    Usage.new
                  end

          log.debug("[llm][native] normalized_response usage_class=#{usage.class}")
          metadata = raw[:metadata] || raw[:offering_metadata] || {}

          tool_calls = normalize_tool_calls(raw[:tool_calls] || raw['tool_calls'] || raw[:tools] || raw['tools'] || result)
          stop_reason = raw[:stop_reason] || raw['stop_reason'] || (tool_calls.any? ? :tool_use : nil)

          { result: result, usage: usage, metadata: metadata, tool_calls: tool_calls, stop_reason: stop_reason }.compact
        end

        def normalize_tool_calls(value)
          case value
          when Hash
            return value.values.filter_map { |entry| normalize_tool_call(entry) } unless tool_call_hash?(value)

            [normalize_tool_call(value)].compact
          when Array
            value.filter_map { |entry| normalize_tool_call(entry) }
          else
            return value.values.filter_map { |entry| normalize_tool_call(entry) } if value.respond_to?(:values)

            []
          end
        end

        def tool_call_hash?(hash)
          normalized = hash.respond_to?(:transform_keys) ? hash.transform_keys(&:to_sym) : hash
          normalized.key?(:name) || normalized.key?(:function) || normalized[:type].to_s == 'tool_use'
        end

        def normalize_tool_call(entry)
          if entry.respond_to?(:name)
            return {
              id:        entry.respond_to?(:id) ? entry.id : nil,
              name:      entry.name,
              arguments: entry.respond_to?(:arguments) ? entry.arguments : {}
            }.compact
          end

          return nil unless entry.is_a?(Hash)

          normalized = entry.respond_to?(:transform_keys) ? entry.transform_keys(&:to_sym) : entry
          function = normalized[:function].is_a?(Hash) ? normalized[:function].transform_keys(&:to_sym) : {}
          name = normalized[:name] || function[:name]
          arguments = normalized[:arguments] || normalized[:input] || function[:arguments] || {}
          arguments = parse_arguments(arguments)
          return nil if name.to_s.empty?

          { id: normalized[:id], name: name.to_s, arguments: arguments || {} }.compact
        end

        def parse_arguments(arguments)
          return arguments unless arguments.is_a?(String)

          Legion::JSON.parse(arguments)
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.dispatch.parse_arguments')
          arguments
        end
      end
    end
  end
end

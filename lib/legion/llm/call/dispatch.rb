# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      # Wraps a native dispatch result hash so Pipeline::Executor and
      # ConversationStore can consume a stable provider response object.
      class NativeResponseAdapter
        attr_reader :content, :input_tokens, :output_tokens,
                    :cache_read_tokens, :cache_write_tokens, :usage, :metadata,
                    :tool_calls, :stop_reason

        def initialize(result_hash)
          result_hash = self.class.coerce_result(result_hash)
          @content             = result_hash[:result].to_s
          @metadata            = result_hash[:metadata] || {}
          @tool_calls          = result_hash[:tool_calls] || []
          @stop_reason         = result_hash[:stop_reason]
          usage                = self.class.coerce_usage(result_hash[:usage])
          @usage               = usage
          @input_tokens        = usage.input_tokens
          @output_tokens       = usage.output_tokens
          @cache_read_tokens   = usage.cache_read_tokens
          @cache_write_tokens  = usage.cache_write_tokens
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
            stop_reason: raw.respond_to?(:stop_reason) ? raw.stop_reason : nil
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

        # Dispatch a chat request to a registered lex-* extension.
        #
        # @param provider [Symbol, String] provider name
        # @param model    [String, nil]   model identifier forwarded to the extension
        # @param messages [Array<Hash>]   array of { role:, content: } message hashes
        # @return [Hash] standardized { result:, usage: } hash
        # @raise [Legion::LLM::ProviderError] if provider is not registered
        def dispatch_chat(provider:, model:, messages:, **)
          ext = fetch_extension!(provider)
          log.info("[llm][native] dispatch_chat provider=#{provider} model=#{model} messages=#{messages.size}")
          raw = ext.chat(model: model, messages: messages, **)
          normalize_response(raw)
        end

        # Dispatch an embedding request to a registered lex-* extension.
        #
        # @param provider [Symbol, String] provider name
        # @param model    [String, nil]   model identifier
        # @param text     [String]        text to embed
        # @return [Hash] standardized { result:, usage: } hash
        # @raise [Legion::LLM::ProviderError] if provider is not registered
        def dispatch_embed(provider:, model:, text:, **)
          ext = fetch_extension!(provider)
          log.info("[llm][native] dispatch_embed provider=#{provider} model=#{model} text_chars=#{text.to_s.length}")
          raw = ext.embed(model: model, text: text, **)
          normalize_response(raw)
        end

        # Dispatch a streaming chat request to a registered lex-* extension.
        #
        # @param provider [Symbol, String] provider name
        # @param model    [String, nil]   model identifier
        # @param messages [Array<Hash>]   message hashes
        # @param block    [Proc]          receives each chunk as it arrives
        # @return [Hash] standardized { result:, usage: } hash
        # @raise [Legion::LLM::ProviderError] if provider is not registered
        def dispatch_stream(provider:, model:, messages:, **, &)
          ext = fetch_extension!(provider)
          log.info("[llm][native] dispatch_stream provider=#{provider} model=#{model} messages=#{messages.size}")
          raw = ext.stream(model: model, messages: messages, **, &)
          normalize_response(raw)
        end

        # Dispatch a token count request to a registered lex-* extension.
        #
        # @param provider [Symbol, String] provider name
        # @param model    [String, nil]   model identifier
        # @param messages [Array<Hash>]   message hashes
        # @return [Hash] standardized { result:, usage: } hash
        # @raise [Legion::LLM::ProviderError] if provider is not registered
        def dispatch_count_tokens(provider:, model:, messages:, **)
          ext = fetch_extension!(provider)
          log.debug("[llm][native] dispatch_count_tokens provider=#{provider} model=#{model} messages=#{messages.size}")
          raw = ext.count_tokens(model: model, messages: messages, **)
          normalize_response(raw)
        end

        # Returns true when the provider is registered in Registry.
        #
        # @param provider [Symbol, String]
        # @return [Boolean]
        def available?(provider)
          Registry.registered?(provider)
        end

        private

        def fetch_extension!(provider)
          ext = Registry.for(provider)
          return ext if ext

          log.error("[llm][native] provider_not_registered provider=#{provider}")
          raise Legion::LLM::ProviderError,
                "Native provider not registered: #{provider}. " \
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
        rescue StandardError
          arguments
        end
      end
    end
  end
end

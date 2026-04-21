# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      # Wraps a native dispatch result hash so it exposes the same interface
      # that RubyLLM response objects expose (used by Pipeline::Executor and
      # ConversationStore after a provider call).
      class NativeResponseAdapter
        attr_reader :content, :input_tokens, :output_tokens,
                    :cache_read_tokens, :cache_write_tokens, :usage

        def initialize(result_hash)
          @content             = result_hash[:result].to_s
          usage                = result_hash[:usage] || Usage.new
          @usage               = usage
          @input_tokens        = usage.input_tokens
          @output_tokens       = usage.output_tokens
          @cache_read_tokens   = usage.cache_read_tokens
          @cache_write_tokens  = usage.cache_write_tokens
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
          unless raw.is_a?(Hash)
            log.debug("[llm][native] normalize_scalar_response class=#{raw.class}")
            return { result: raw, usage: Usage.new }
          end

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
          { result: result, usage: usage }
        end
      end
    end
  end
end

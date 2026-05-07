# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module EnrichmentInjector
        module_function

        extend Legion::Logging::Helper

        def inject(system:, enrichments:)
          parts = []

          # Settings-driven baseline (universal foundation, overridable via config)
          baseline = resolve_baseline
          parts << baseline if baseline

          # GAIA system prompt (highest priority enrichment)
          if (gaia = enrichments.dig('gaia:system_prompt', :content))
            parts << gaia
          end

          # Prior conversation history loaded by the context step.
          if (history = enrichments['context:conversation_history'])
            history_text = Array(history).map { |msg| format_history_message(msg) }.reject(&:empty?).join("\n")
            parts << "Prior conversation history:\n#{history_text}" unless history_text.empty?
          end

          # RAG context
          if (rag = enrichments.dig('rag:context_retrieval', :data, :entries))
            context_text = rag.map { |e| "[#{e[:content_type]}] #{e[:content]}" }.join("\n")
            parts << "Relevant context:\n#{context_text}" unless context_text.empty?
          end

          # Skill injection — active skill's step output appended after the RAG context
          if (skill = enrichments['skill:active'])
            parts << skill
          end

          # Tool call history — BEFORE the empty-parts guard so it reaches the LLM
          # even when no other enrichments are present
          if (history_block = enrichments.dig('tool:call_history', :content))
            parts << history_block
          end

          return system if parts.empty?

          parts << system if system
          log.info("[llm][pipeline] enrichments_injected parts=#{parts.size} baseline=#{!baseline.nil?} system_present=#{!system.nil?}")
          parts.join("\n\n")
        end

        def resolve_baseline
          value = Legion::LLM::Settings.value(:system_baseline)
          value.is_a?(String) && !value.strip.empty? ? value : nil
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.enrichment_injector.resolve_baseline')
          nil
        end

        def format_history_message(message)
          return message.to_s unless message.is_a?(Hash)

          role = message[:role] || message['role'] || 'unknown'
          content = message[:content] || message['content']
          content = content.filter_map { |part| part.is_a?(Hash) ? part[:text] || part['text'] : part.to_s }.join if content.is_a?(Array)
          "[#{role}] #{content}"
        end
      end
    end
  end
end

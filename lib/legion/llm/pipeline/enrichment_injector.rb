# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
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

          # RAG context
          if (rag = enrichments.dig('rag:context_retrieval', :data, :entries))
            context_text = rag.map { |e| "[#{e[:content_type]}] #{e[:content]}" }.join("\n")
            parts << "Relevant context:\n#{context_text}" unless context_text.empty?
          end

          # Skill injection — active skill's step output appended after the RAG context
          if (skill = enrichments['skill:active'])
            parts << skill
          end

          return system if parts.empty?

          parts << system if system
          log.info("[llm][pipeline] enrichments_injected parts=#{parts.size} baseline=#{!baseline.nil?} system_present=#{!system.nil?}")
          parts.join("\n\n")
        end

        def resolve_baseline
          return nil unless defined?(Legion::Settings)

          value = Legion::Settings.dig(:llm, :system_baseline)
          value.is_a?(String) && !value.strip.empty? ? value : nil
        rescue StandardError
          nil
        end
      end
    end
  end
end

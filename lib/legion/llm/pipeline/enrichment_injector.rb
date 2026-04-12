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

          # GAIA system prompt (highest priority)
          if (gaia = enrichments.dig('gaia:system_prompt', :content))
            parts << gaia
          end

          # RAG context
          if (rag = enrichments.dig('rag:context_retrieval', :data, :entries))
            context_text = rag.map { |e| "[#{e[:content_type]}] #{e[:content]}" }.join("\n")
            parts << "Relevant context:\n#{context_text}" unless context_text.empty?
          end

          # Skill injection — active skill's step output prepended to context
          if (skill = enrichments['skill:active'])
            parts << skill
          end

          return system if parts.empty?

          parts << system if system
          log.info("[llm][pipeline] enrichments_injected parts=#{parts.size} system_present=#{!system.nil?}")
          parts.join("\n\n")
        end
      end
    end
  end
end

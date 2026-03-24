# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module EnrichmentInjector
        module_function

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

          return system if parts.empty?

          parts << system if system
          parts.join("\n\n")
        end
      end
    end
  end
end

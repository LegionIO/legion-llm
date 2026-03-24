# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Profile
        GAIA_SKIP = %i[
          idempotency conversation_uuid context_load rbac classification
          billing gaia_advisory mcp_discovery context_store post_response
        ].freeze

        SYSTEM_SKIP = %i[
          idempotency conversation_uuid context_load rbac classification
          billing gaia_advisory rag_context mcp_discovery context_store
          post_response
        ].freeze

        module_function

        def derive(caller_hash)
          return :external if caller_hash.nil?

          requested_by = caller_hash[:requested_by] || {}
          type = requested_by[:type]&.to_sym
          identity = requested_by[:identity].to_s

          return :external unless type == :system

          identity.start_with?('gaia:') ? :gaia : :system
        end

        def skip?(profile, step)
          case profile
          when :external then false
          when :gaia     then GAIA_SKIP.include?(step)
          when :system   then SYSTEM_SKIP.include?(step)
          else false
          end
        end
      end
    end
  end
end

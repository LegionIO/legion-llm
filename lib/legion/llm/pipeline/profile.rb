# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Profile
        GAIA_SKIP = %i[
          idempotency conversation_uuid context_load rbac classification
          billing gaia_advisory trigger_match tool_discovery context_store post_response
        ].freeze

        SYSTEM_SKIP = %i[
          idempotency conversation_uuid context_load rbac classification
          billing gaia_advisory rag_context trigger_match tool_discovery context_store
          post_response
        ].freeze

        QUICK_REPLY_SKIP = %i[
          idempotency conversation_uuid context_load classification
          gaia_advisory rag_context trigger_match tool_discovery confidence_scoring
          tool_calls context_store post_response knowledge_capture
        ].freeze

        HUMAN_SKIP = %i[].freeze

        SERVICE_SKIP = %i[
          conversation_uuid context_load gaia_advisory
          rag_context trigger_match tool_discovery confidence_scoring
          tool_calls context_store knowledge_capture
        ].freeze

        module_function

        def derive(caller_hash)
          return :external if caller_hash.nil?

          requested_by = caller_hash[:requested_by] || {}
          type = requested_by[:type]&.to_sym
          identity = requested_by[:identity].to_s

          return :quick_reply if type == :quick_reply
          return :human       if %i[human user].include?(type)
          return :service     if type == :service
          return :external    unless type == :system

          identity.start_with?('gaia:') ? :gaia : :system
        end

        def skip?(profile, step)
          case profile
          when :gaia        then GAIA_SKIP.include?(step)
          when :system      then SYSTEM_SKIP.include?(step)
          when :quick_reply then QUICK_REPLY_SKIP.include?(step)
          when :human       then HUMAN_SKIP.include?(step)
          when :service     then SERVICE_SKIP.include?(step)
          else false
          end
        end
      end
    end
  end
end

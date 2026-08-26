# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module Inventory
      # Live capability/model facts over the inventory registry. Selection
      # itself is owned by the SSOT router (Router.next_lane is the sole
      # selection authority); Discovery answers two read-only questions
      # against the same registry lanes the router reads — no state, no
      # second selection domain.
      module Discovery
        extend Legion::Logging::Helper

        class << self
          # M4: SSOT :embed routing (Call::Embeddings → Router.next_lane via
          # RequestRequirements(operation: :embed, required_capabilities:
          # [:embedding])) is the SOLE selection authority for embeddings.
          # can_embed? answers one capability FACT against the registry lanes —
          # the same lanes the router reads: is there an embedding-type lane the
          # router can select? (Live query — no boot-time detection state.)
          def can_embed?
            Legion::LLM::Inventory.snapshot.each_lane.any? do |lane|
              Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: lane.operation) == :embedding
            end
          end

          # Check whether a specific model is available from any registered provider.
          # Reads the registry lanes — no discovery cache.
          def model_available?(model, provider: nil, instance: nil)
            psym = provider&.to_sym
            isym = instance&.to_sym
            Legion::LLM::Inventory.snapshot.each_lane.any? do |l|
              name_matches?(l.model, model.to_s) &&
                (psym.nil? || l.provider_family == psym) &&
                (isym.nil? || l.instance_id.to_s == isym.to_s)
            end
          end

          # Return the size in bytes for a discovered model, or nil if unknown.
          # After P3, size_bytes is not stored on lanes; always nil.
          def model_size(_model, **)
            nil
          end

          private

          # Match model names allowing prefix matching for tagged variants (e.g. "llama3" matches "llama3:8b")
          def name_matches?(discovered_name, query_name)
            return false if discovered_name.nil? || query_name.nil?

            dn = discovered_name.to_s
            qn = query_name.to_s
            dn == qn || dn.start_with?("#{qn}:")
          end
        end
      end
    end
  end
end

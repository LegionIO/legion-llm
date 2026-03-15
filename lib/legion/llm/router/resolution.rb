# frozen_string_literal: true

module Legion
  module LLM
    module Router
      class Resolution
        attr_reader :tier, :provider, :model, :rule, :metadata

        def initialize(tier:, provider:, model:, rule: nil, metadata: {})
          @tier     = tier.to_sym
          @provider = provider.to_sym
          @model    = model
          @rule     = rule
          @metadata = metadata
        end

        def local?
          @tier == :local
        end

        def fleet?
          @tier == :fleet
        end

        def cloud?
          @tier == :cloud
        end

        def to_h
          {
            tier:     @tier,
            provider: @provider,
            model:    @model,
            rule:     @rule,
            metadata: @metadata
          }
        end
      end
    end
  end
end

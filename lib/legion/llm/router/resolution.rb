# frozen_string_literal: true

module Legion
  module LLM
    module Router
      class Resolution
        attr_reader :tier, :provider, :model, :rule, :metadata, :compress_level

        def initialize(tier:, provider:, model:, rule: nil, metadata: {}, compress_level: 0)
          @tier           = tier.to_sym
          @provider       = provider.to_sym
          @model          = model
          @rule           = rule
          @metadata       = metadata
          @compress_level = compress_level.to_i
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
            tier:           @tier,
            provider:       @provider,
            model:          @model,
            rule:           @rule,
            metadata:       @metadata,
            compress_level: @compress_level
          }
        end
      end
    end
  end
end

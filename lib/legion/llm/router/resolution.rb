# frozen_string_literal: true

module Legion
  module LLM
    module Router
      class Resolution
        attr_reader :tier, :provider, :model, :rule, :metadata, :compress_level,
                    :offering_id, :offering_metadata

        def initialize(tier:, provider:, model:, rule: nil, metadata: {}, compress_level: 0,
                       offering_id: nil, offering_metadata: nil)
          @tier              = tier.to_sym
          @provider          = provider.to_sym
          @model             = model
          @rule              = rule
          @metadata          = metadata
          @compress_level    = compress_level.to_i
          @offering_id       = offering_id&.to_s
          @offering_metadata = normalize_offering_metadata(offering_metadata || metadata[:offering] || metadata['offering'])
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

        def frontier?
          @tier == :frontier
        end

        def openai_compat?
          @tier == :openai_compat
        end

        def external?
          %i[cloud frontier openai_compat].include?(@tier)
        end

        def to_h
          hash = {
            tier:           @tier,
            provider:       @provider,
            model:          @model,
            rule:           @rule,
            metadata:       @metadata,
            compress_level: @compress_level
          }
          hash[:offering_id] = @offering_id if @offering_id
          hash[:offering_metadata] = @offering_metadata unless @offering_metadata.empty?
          hash
        end

        private

        def normalize_offering_metadata(value)
          return {} unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, metadata_value), normalized|
            normalized[key.respond_to?(:to_sym) ? key.to_sym : key] = metadata_value
          end
        end
      end
    end
  end
end

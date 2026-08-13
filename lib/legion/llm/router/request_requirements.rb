# frozen_string_literal: true

module Legion
  module LLM
    module Router
      # Immutable selector input (SSOT v3 §9.3). Built once per logical request
      # from the canonical Request. Pins come from trusted constraints plus the
      # honored body-model decision (trusted model wins); the routing seed, max
      # attempts, and affinity strength come from the ingress-captured settings
      # snapshot / routing context. No default provider or model exists here.
      class RequestRequirements
        include Legion::Logging::Helper

        attr_reader :operation, :required_capabilities, :provider_pin, :instance_pin, :model_pin,
                    :tier_constraint, :tier_preference, :estimated_input_bound, :required_output_tokens,
                    :required_context_budget, :requested_embedding_dimensions, :policy_context,
                    :routing_affinities, :affinity_strength_bps, :routing_seed, :maximum_attempts,
                    :body_model_hint_decision

        def self.build(request:, operation:, required_capabilities:, estimated_input_bound:,
                       required_output_tokens:, requested_embedding_dimensions: nil,
                       tier_constraint: nil, tier_preference: nil, routing_affinities: [], policy_context: {})
          new(request: request, operation: operation, required_capabilities: required_capabilities,
              estimated_input_bound: estimated_input_bound, required_output_tokens: required_output_tokens,
              requested_embedding_dimensions: requested_embedding_dimensions, tier_constraint: tier_constraint,
              tier_preference: tier_preference, routing_affinities: routing_affinities, policy_context: policy_context)
        end

        def initialize(request:, operation:, required_capabilities:, estimated_input_bound:,
                       required_output_tokens:, requested_embedding_dimensions:, tier_constraint:,
                       tier_preference:, routing_affinities:, policy_context:)
          snapshot = request.routing_settings_snapshot
          trusted = request.trusted_constraints
          decision = request.body_model_hint_decision

          @operation = validate_operation!(operation)
          @required_capabilities = Legion::Extensions::Llm::Capabilities.normalize(required_capabilities).freeze
          @estimated_input_bound = nonneg_int!(estimated_input_bound, :estimated_input_bound)
          @required_output_tokens = nonneg_int!(required_output_tokens, :required_output_tokens)
          @required_context_budget = @estimated_input_bound + @required_output_tokens
          @requested_embedding_dimensions = validate_dimensions!(requested_embedding_dimensions)

          @provider_pin = trusted.provider&.to_sym
          @instance_pin = trusted.instance_id
          @model_pin = resolve_model_pin(trusted, decision)
          @tier_constraint = validate_tier!(tier_constraint || trusted.tier)
          @tier_preference = validate_tier!(tier_preference)

          @routing_seed = validate_seed!(request.routing_context.routing_seed)
          @maximum_attempts = positive_int!(trusted.maximum_attempts || snapshot.maximum_attempts, :maximum_attempts)
          @affinity_strength_bps = snapshot.affinity_strength_bps
          @routing_affinities = normalize_affinities(routing_affinities)
          @policy_context = deep_freeze(symbolize(policy_context))
          @body_model_hint_decision = decision
          freeze
        end

        private

        def resolve_model_pin(trusted, decision)
          return trusted.model unless trusted.model.nil?
          return decision.model_constraint if decision.disposition == :honored

          nil
        end

        def validate_operation!(operation)
          op = operation.to_sym
          raise ArgumentError, "invalid operation #{operation.inspect}" unless Legion::Extensions::Llm::Taxonomies::OPERATIONS.include?(op)

          op
        end

        def validate_tier!(tier)
          return nil if tier.nil?

          sym = tier.to_sym
          raise ArgumentError, "invalid tier #{tier.inspect}" unless Legion::Extensions::Llm::Taxonomies::TIERS.include?(sym)

          sym
        end

        def validate_dimensions!(value)
          return nil if value.nil?

          int = Integer(value)
          raise ArgumentError, 'requested_embedding_dimensions must be positive' unless int.positive?

          int
        end

        def validate_seed!(seed)
          raise Legion::LLM::Errors::InvalidRoutingContext, 'requirements built without a trusted routing seed' unless seed.is_a?(String) && seed.match?(/\A[0-9a-f]{32}\z/)

          seed
        end

        def nonneg_int!(value, field)
          int = Integer(value)
          raise ArgumentError, "#{field} must be >= 0" if int.negative?

          int
        end

        def positive_int!(value, field)
          int = Integer(value)
          raise ArgumentError, "#{field} must be positive" unless int.positive?

          int
        end

        # Trusted internal affinities only (client input cannot create them — the
        # caller/adapter builds this array). Reject duplicate (source,kind,target).
        def normalize_affinities(affinities)
          seen = {}
          normalized = Array(affinities).map do |entry|
            key = [entry.fetch(:source), entry.fetch(:target_kind), entry.fetch(:target)]
            raise ArgumentError, "duplicate affinity entry #{key.inspect}" if seen[key]

            seen[key] = true
            score = Integer(entry.fetch(:score_bps))
            raise ArgumentError, "score_bps out of range: #{score}" unless score.between?(-10_000, 10_000)

            { source: entry[:source], target_kind: entry[:target_kind].to_sym,
              target: entry[:target], score_bps: score }.freeze
          end
          normalized.freeze
        end

        def symbolize(value)
          return value unless value.is_a?(Hash)

          value.each_with_object({}) do |(k, v), acc|
            acc[k.respond_to?(:to_sym) ? k.to_sym : k] = v.is_a?(Hash) ? symbolize(v) : v
          end
        end

        def deep_freeze(obj)
          case obj
          when Hash then obj.each_value { |v| deep_freeze(v) }.freeze
          when Array then obj.each { |v| deep_freeze(v) }.freeze
          else obj.freeze
          end
        end
      end
    end
  end
end

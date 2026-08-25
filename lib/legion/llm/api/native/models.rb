# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/api/native/tiers'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module API
      module Native
        module Models
          extend Legion::Logging::Helper

          AUTO_ROUTING_MODEL_ID = 'legionio'
          AUTO_ROUTING_MODEL_DISPLAY = 'LegionIO'
          AUTO_ROUTING_OFFERING_ID = 'legionio:auto:inference:legionio'
          AUTO_ROUTING_CAPABILITIES = %w[auto_routing chat completion json_schema tools].freeze

          def self.registered(app)
            log.debug('[llm][api][models] registering model inventory routes')

            app.get '/api/llm/models' do
              log.debug('[llm][api][models] action=list_models')
              require_llm!

              filters = Legion::LLM::API::Native::Models.request_filters(params)
              offerings = Legion::LLM::API::Native::Models.lane_entries(filters)
              offerings = Legion::LLM::API::Native::Models.with_auto_routing_offering(offerings, filters)

              json_response({
                              models:    Legion::LLM::API::Native::Models.model_summaries(offerings),
                              offerings: offerings,
                              summary:   Legion::LLM::API::Native::Models.summary(offerings)
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.list')
              json_error('model_inventory_error', e.message, status_code: 500)
            end

            app.get '/api/llm/models/:id' do
              model_id = params[:id]
              log.debug("[llm][api][models] action=get_model id=#{model_id}")
              require_llm!

              filters = { model: model_id }
              offerings = Legion::LLM::API::Native::Models.lane_entries(filters)
              offerings = Legion::LLM::API::Native::Models.with_auto_routing_offering(offerings, filters)
              halt json_error('model_not_found', "Model '#{model_id}' not found", status_code: 404) unless offerings.any?

              json_response({
                              model:     Legion::LLM::API::Native::Models.summarize_model(model_id, offerings),
                              offerings: offerings
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.get')
              json_error('model_inventory_error', e.message, status_code: 500)
            end

            app.get '/api/llm/providers/:name/models' do
              provider = params[:name]
              log.debug("[llm][api][models] action=list_provider_models provider=#{provider}")
              require_llm!

              filters = Legion::LLM::API::Native::Models.request_filters(params).merge(provider: provider)
              offerings = Legion::LLM::API::Native::Models.lane_entries(filters)

              json_response({
                              provider:  provider,
                              models:    Legion::LLM::API::Native::Models.model_summaries(offerings),
                              offerings: offerings,
                              summary:   Legion::LLM::API::Native::Models.summary(offerings)
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.provider')
              json_error('model_inventory_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][models] model inventory routes registered')
          end

          # ── v0.15.2 lane-hash projection (the single shared shaping) ──────────
          #
          # Projects registry lanes onto the v0.15.2 lane-hash shape the models
          # routes have always returned:
          #   id, tier, provider_family, instance_id, model, canonical_model_alias,
          #   type, capabilities, limits, enabled, cost, lane_weight,
          #   health{circuit_state,denied,available,adjustment}
          # `id`/`offering_id` are the 5-tuple lane id (tier:provider_family:
          # instance_id:type:model — composed only by
          # Inventory::Identity.compose_lane_id at the writer). Every models
          # route (native tree, namespaced tree, cross-namespace
          # /api/llm/providers/:name/models, flat /v1/models tree) reads through
          # lane_entries — there is no second projection.
          def self.lane_entries(filters = {})
            snapshot = Legion::LLM::Inventory.snapshot
            normalized = normalize_filter_hash(filters)
            inst_by_key = {}
            snapshot.each_instance { |inst| inst_by_key[inst.instance_key] = inst }

            snapshot.each_lane.filter_map do |lane|
              next unless lane_matches_filters?(lane, normalized)
              # Compliance-by-absence: a policy-denied model never
              # appears in the API surface (the registry publishes the full
              # catalog; the display applies the same policy the router does).
              next unless Legion::LLM::API::Native::Offerings.policy_permits?(lane)

              lane_entry(lane, inst_by_key[lane.instance_key]&.availability)
            end
          end

          def self.lane_entry(lane, availability)
            {
              id:                    lane.lane_id,
              offering_id:           lane.lane_id,
              model:                 lane.model,
              provider_family:       lane.provider_family.to_s,
              provider_instance:     lane.instance_id.to_s,
              instance_id:           lane.instance_id.to_s,
              tier:                  lane.tier.to_s,
              type:                  lane_type(lane).to_s,
              canonical_model_alias: lane.metadata[:canonical_model_alias],
              model_family:          lane.metadata[:model_family],
              capabilities:          Legion::LLM::API::Native::Tiers.lane_capabilities(lane),
              limits:                Legion::LLM::API::Native::Tiers.lane_limits(lane),
              enabled:               true,
              cost:                  {},
              lane_weight:           lane_weight_for(lane, availability),
              health:                health_display(availability),
              metadata:              lane.metadata
            }
          end

          # The 4-key legacy display shape (the same shape the provider actors
          # write to the settings health hash), derived from the snapshot
          # AvailabilityFact. Display only — selection reads the
          # AvailabilityFact itself, never this projection.
          def self.health_display(availability)
            available = availability&.state == :available
            {
              circuit_state: if available
                               :closed
                             else
                               (availability ? :open : :half_open)
                             end,
              denied:        false,
              available:     available,
              adjustment:    available ? 0 : -50
            }
          end

          # v0.15.2 display law: lane_weight = tier_w × provider_w ×
          # instance_w × model_w (the write-time base_weight stored on the
          # lane) × health multiplier. Available → ×1; unavailable (open
          # circuit) → ×−1. Display only — the router reads the stored scalar
          # and the AvailabilityFact, never this value.
          def self.lane_weight_for(lane, availability)
            multiplier = availability&.state == :available ? 1 : -1
            lane.base_weight * multiplier
          end

          def self.lane_type(lane)
            Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: lane.operation)
          end

          def self.lane_matches_filters?(lane, filters)
            provider = filters[:provider]
            return false if provider && !provider.to_s.empty? && lane.provider_family.to_s != provider.to_s

            instance = filters[:instance_id]
            return false if instance && !instance.to_s.empty? && lane.instance_id.to_s != instance.to_s

            type = filters[:type]
            return false if type && !type.to_s.empty? && normalized_type(type) != lane_type(lane)

            model = filters[:model]
            return false if model && !model.to_s.empty? && lane.model.to_s != model.to_s

            offering_id = filters[:offering_id]
            return false if offering_id && !offering_id.to_s.empty? && lane.lane_id != offering_id.to_s

            family = filters[:model_family]
            return false if family && !family.to_s.empty? && lane.metadata[:model_family].to_s != family.to_s

            capability = filters[:capability]
            if capability && !capability.to_s.empty?
              caps = Legion::LLM::API::Native::Tiers.lane_capabilities(lane)
                                                    .map { |c| Legion::Extensions::Llm::Capabilities.canonical(c) }
              return false unless caps.include?(Legion::Extensions::Llm::Capabilities.canonical(capability.to_s))
            end

            true
          end

          # Request filter spellings for the coarse lane type: the embedding
          # spellings collapse to :embedding, 'chat' to :inference (the
          # v0.15.2 request vocabulary), everything else passes through as a
          # Taxonomies::TYPES symbol.
          def self.normalized_type(value)
            case value.to_s
            when 'embedding', 'embeddings', 'embed' then :embedding
            when 'chat' then :inference
            else value.to_sym
            end
          end

          def self.normalize_filter_hash(filters)
            filters.transform_keys(&:to_sym).compact
          end

          def self.request_filters(params)
            {
              provider:     params[:provider],
              instance_id:  params[:instance_id] || params[:instance],
              type:         params[:type] || params[:purpose],
              model:        params[:model],
              offering_id:  params[:offering_id],
              model_family: params[:model_family],
              capability:   params[:capability]
            }
          end

          def self.model_summaries(offerings)
            summaries = offerings.group_by { |offering| offering[:model] }.map do |model, rows|
              summarize_model(model, rows)
            end
            summaries.sort_by { |model| [auto_routing_model?(model[:id]) ? 0 : 1, model[:id]] }
          end

          def self.summarize_model(model, offerings)
            summary = {
              id:             model.to_s,
              types:          offerings.map { |offering| offering[:type].to_s }.uniq.sort,
              providers:      offerings.map { |offering| offering[:provider_family] }.uniq.sort,
              model_families: offerings.filter_map { |offering| offering[:model_family] }.uniq.sort,
              offering_ids:   offerings.filter_map { |offering| offering[:offering_id] }.uniq.sort,
              instances:      offerings.map { |offering| offering[:instance_id] }.uniq.sort,
              capabilities:   offerings.flat_map { |offering| offering[:capabilities] }.uniq.sort,
              max_context:    offerings.filter_map { |offering| offering.dig(:limits, :context_window) }.max,
              enabled:        offerings.any? { |offering| offering[:enabled] != false }
            }
            if auto_routing_model?(model)
              first_display = offerings.filter_map { |o| o[:display_name] }.first
              summary[:display_name] = first_display || AUTO_ROUTING_MODEL_DISPLAY
              summary[:auto_route] = true
              summary[:default] = model.to_s == AUTO_ROUTING_MODEL_ID
            end
            summary
          end

          def self.summary(offerings)
            {
              total_offerings: offerings.size,
              models:          offerings.map { |offering| offering[:model] }.uniq.size,
              providers:       offerings.map { |offering| offering[:provider_family] }.uniq.size,
              by_type:         offerings.group_by { |offering| offering[:type].to_s }
                                        .transform_values(&:size)
            }
          end

          def self.with_auto_routing_offering(offerings, filters = {})
            return offerings unless auto_routing_offering_matches?(filters)
            return offerings if offerings.any? { |offering| auto_routing_model?(offering[:model]) }

            [auto_routing_offering, auto_routing_alias_offering, *offerings]
          end

          def self.auto_routing_alias_offering
            base = auto_routing_offering
            base.merge(
              id:                    'legionio:auto:inference:auto',
              offering_id:           'legionio:auto:inference:auto',
              model:                 'auto',
              display_name:          'LegionIO (auto)',
              canonical_model_alias: 'auto'
            )
          end

          def self.auto_routing_offering
            ctx = Legion::Settings[:llm][:context_window]
            max_out = Legion::Settings[:llm][:max_output_tokens]
            {
              id:                    AUTO_ROUTING_OFFERING_ID,
              offering_id:           AUTO_ROUTING_OFFERING_ID,
              model:                 AUTO_ROUTING_MODEL_ID,
              display_name:          AUTO_ROUTING_MODEL_DISPLAY,
              model_family:          'legionio',
              canonical_model_alias: AUTO_ROUTING_MODEL_ID,
              type:                  :inference,
              provider_family:       'legionio',
              provider_instance:     'auto',
              instance_id:           'auto',
              tier:                  :auto,
              transport:             :internal,
              enabled:               true,
              capabilities:          AUTO_ROUTING_CAPABILITIES,
              limits:                { context_window: ctx, max_output_tokens: max_out },
              health:                { circuit_state: 'available' },
              metadata:              { auto_route: true, placeholder: true, display_name: AUTO_ROUTING_MODEL_DISPLAY },
              routing_metadata:      { strategy: 'auto' },
              source:                'static'
            }
          end

          def self.auto_routing_offering_matches?(filters)
            normalized = request_filters(filters)
            type = normalized[:type]
            return false if type && !type.to_s.empty? && type.to_s != 'inference' && type.to_s != 'chat'

            provider = normalized[:provider]
            return false if provider && !provider.to_s.empty? && !%w[legionio auto].include?(provider.to_s.downcase)

            instance = normalized[:instance_id]
            return false if instance && !instance.to_s.empty? && !%w[auto legionio].include?(instance.to_s.downcase)

            model = normalized[:model] || normalized[:offering_id]
            return false if model && !model.to_s.empty? && !auto_routing_model?(model) && model.to_s != AUTO_ROUTING_OFFERING_ID

            family = normalized[:model_family]
            return false if family && !family.to_s.empty? && family.to_s.downcase != 'legionio'

            capability = normalized[:capability]
            return false if capability && !AUTO_ROUTING_CAPABILITIES.include?(capability.to_s)

            true
          end

          def self.auto_routing_model?(model)
            m = model.to_s.strip.downcase
            # SSOT v4: read auto_routing_model_aliases from the canonical
            # [:llm][:router] home (default in settings/router.rb) so the catalog
            # view agrees with ingress (request.rb) and the Router (filter.rb).
            configured = Legion::Settings[:llm][:router][:auto_routing_model_aliases]
            aliases = Array(configured).map { |entry| entry.to_s.strip.downcase }.reject(&:empty?)
            aliases = [AUTO_ROUTING_MODEL_ID] if aliases.empty?
            aliases.include?(m)
          end
        end
      end
    end
  end
end

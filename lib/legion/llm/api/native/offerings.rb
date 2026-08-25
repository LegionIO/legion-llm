# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/api/native/tiers'
require 'legion/llm/routing/settings_state'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module API
      module Native
        module Offerings
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][offerings] registering offering inventory routes')

            app.get '/api/llm/offerings' do
              log.debug('[llm][api][offerings] action=list_offerings')
              require_llm!

              filters = Legion::LLM::API::Native::Offerings.request_filters(params)
              raw_offerings = Legion::LLM::API::Native::Offerings.snapshot_offerings(filters)
              grouped = Legion::LLM::API::Native::Offerings.group_offerings(raw_offerings)

              json_response({
                              offerings: grouped,
                              summary:   Legion::LLM::API::Native::Offerings.summary(raw_offerings)
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.offerings.list')
              json_error('offering_inventory_error', e.message, status_code: 500)
            end

            app.get '/api/llm/offerings/:id' do
              offering_id = params[:id]
              log.debug("[llm][api][offerings] action=get_offering id=#{offering_id}")
              require_llm!

              offering = Legion::LLM::API::Native::Offerings.snapshot_offering(offering_id)
              halt json_error('offering_not_found', "Offering '#{offering_id}' not found", status_code: 404) unless offering

              json_response({ offering: offering })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.offerings.get')
              json_error('offering_inventory_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][offerings] offering inventory routes registered')
          end

          def self.request_filters(params)
            {
              provider:     params[:provider] || params[:provider_family],
              instance_id:  params[:instance_id] || params[:instance],
              type:         params[:operation] || params[:type] || params[:purpose],
              model:        params[:model],
              offering_id:  params[:offering_id],
              model_family: params[:family] || params[:model_family],
              capability:   params[:capability],
              tier:         params[:tier],
              healthy:      params[:healthy]
            }
          end

          # Offerings are projected from the registry snapshot — the single
          # bucket of 5-tuple lanes. Display only; selection reads the
          # AvailabilityFact itself, never these projections.
          def self.snapshot_offerings(filters)
            snapshot = Legion::LLM::Inventory.snapshot
            inst_by_key = {}
            snapshot.each_instance { |inst| inst_by_key[inst.instance_key] = inst }

            snapshot.each_lane.filter_map do |lane|
              instance = inst_by_key[lane.instance_key]
              next unless policy_permits?(lane)
              next unless lane_matches_filters?(lane, instance, filters)

              offering_entry(lane, instance&.availability)
            end
          end

          # Resolves the 5-tuple id at /api/llm/offerings/:id.
          def self.snapshot_offering(offering_id)
            snapshot = Legion::LLM::Inventory.snapshot
            lane = snapshot.lane(lane_id: offering_id.to_s)
            return nil unless lane && policy_permits?(lane)

            availability = snapshot.instance(instance_key: lane.instance_key)&.availability
            offering_entry(lane, availability)
          end

          # Fail-closed model policy — same semantics as
          # ModelCatalog.policy_permits?: a nonempty effective whitelist requires
          # a case-insensitive substring match; a blacklist match always denies.
          # The registry publishes the full provider catalog (policy is
          # applied at selection time via SettingsState); the display surfaces
          # apply it here so a denied model never appears in the API surface
          # (compliance-by-absence invariant).
          def self.policy_permits?(lane)
            policy = Legion::LLM::Routing::SettingsState.current.model_policy_for(offering: lane)
            whitelist = policy[:whitelist]
            blacklist = policy[:blacklist]
            model_lc = lane.model.to_s.downcase

            return false if whitelist.any? && whitelist.none? { |e| model_lc.include?(e.to_s.downcase) }
            return false if blacklist.any? { |e| model_lc.include?(e.to_s.downcase) }

            true
          end

          def self.lane_matches_filters?(lane, instance, filters)
            ik = lane.instance_key
            return false if filters[:provider] && ik.provider_family.to_s != filters[:provider].to_s
            return false if filters[:instance_id] && ik.instance_id.to_s != filters[:instance_id].to_s
            return false if filters[:model] && lane.model.to_s != filters[:model].to_s
            return false if filters[:tier] && lane.tier.to_s != filters[:tier].to_s
            return false if filters[:offering_id] && lane.lane_id != filters[:offering_id].to_s
            return false if filters[:model_family] && lane.metadata[:model_family].to_s != filters[:model_family].to_s

            return false if filters[:type] && normalize_offering_type(filters[:type]) != lane_type(lane)

            if filters[:capability]
              caps = Legion::LLM::API::Native::Tiers.lane_capabilities(lane)
              return false unless caps.include?(filters[:capability].to_s)
            end
            if filters[:healthy]
              want_healthy = filters[:healthy].to_s != 'false'
              is_healthy = instance&.availability&.state == :available
              return false if want_healthy != is_healthy
            end

            true
          end

          # The offering shape: same field names as v0.15.2, with
          # offering_id/id set to the 5-tuple lane id. Registry lanes are
          # always published (enabled).
          def self.offering_entry(lane, availability)
            {
              offering_id:       lane.lane_id,
              id:                lane.lane_id,
              model:             lane.model.to_s,
              provider_family:   lane.instance_key.provider_family.to_s,
              provider_instance: lane.instance_key.instance_id.to_s,
              instance_id:       lane.instance_key.instance_id.to_s,
              tier:              lane.tier.to_s,
              type:              lane_type(lane).to_s,
              model_family:      lane.metadata[:model_family],
              capabilities:      Legion::LLM::API::Native::Tiers.lane_capabilities(lane),
              limits:            Legion::LLM::API::Native::Tiers.lane_limits(lane),
              enabled:           true,
              cost:              {},
              health:            Legion::LLM::API::Native::Models.health_display(availability),
              metadata:          lane.metadata
            }
          end

          def self.lane_type(lane)
            Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: lane.operation)
          end

          # Request filter spellings for the coarse lane type: the embedding
          # spellings collapse to :embedding, 'chat' to :inference (the
          # v0.15.2 request vocabulary), everything else passes through as a
          # Taxonomies::TYPES symbol.
          def self.normalize_offering_type(value)
            case value.to_s
            when 'embedding', 'embeddings', 'embed' then :embedding
            when 'chat' then :inference
            else value.to_sym
            end
          end

          def self.group_offerings(offerings)
            grouped = {}

            offerings.each do |offering|
              tier = (offering[:tier] || :unknown).to_s
              provider = (offering[:provider_family] || :unknown).to_s
              instance = (offering[:instance_id] || offering[:provider_instance] || :default).to_s

              grouped[tier] ||= {}
              grouped[tier][provider] ||= {}
              grouped[tier][provider][instance] ||= []
              grouped[tier][provider][instance] << compact_offering(offering)
            end

            grouped
          end

          def self.compact_offering(offering)
            {
              id:           offering[:offering_id] || offering[:id],
              model:        offering[:model].to_s,
              type:         offering[:type].to_s,
              model_family: offering[:model_family]&.to_s,
              capabilities: Array(offering[:capabilities]).map(&:to_s),
              limits:       offering[:limits] || {},
              enabled:      offering[:enabled] != false,
              cost:         offering[:cost] || {},
              health:       offering[:health] || {}
            }.compact
          end

          def self.summary(offerings)
            {
              total:     offerings.size,
              tiers:     offerings.map { |o| (o[:tier] || :unknown).to_s }.uniq.size,
              providers: offerings.map { |o| (o[:provider_family] || :unknown).to_s }.uniq.size,
              instances: offerings.map { |o| (o[:instance_id] || :default).to_s }.uniq.size,
              models:    offerings.map { |o| o[:model] }.uniq.size
            }
          end
        end
      end
    end
  end
end

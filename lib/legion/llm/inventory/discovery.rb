# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'
require 'legion/llm/inventory/discovery/system'
module Legion
  module LLM
    module Inventory
      module Discovery
        extend Legion::Logging::Helper

        # Providers that populate lanes via live discovery (::Every actor polling local endpoints).
        # These are distinguished from static-catalog providers (bedrock, anthropic, openai) which
        # write lanes on boot and don't need runtime probing.
        DISCOVERABLE_PROVIDERS = %i[ollama mlx vllm].freeze

        # Per-(provider,instance) discovery status — lock-free reads, atomic writes.
        @discovery_status = Concurrent::Map.new
        # Version/tag delimiters that separate a model family base from its concrete
        # discovered id (Ollama "model:tag", Bedrock "family-YYYYMMDD-v1:0" / "family-6").
        MODEL_FAMILY_DELIMITERS = %w[: -].freeze
        # Cap how many discovered ids a divergence warning prints — multi-model cloud
        # providers (Bedrock lists ~90) otherwise dump an unreadable single log line.
        MODEL_DIVERGENCE_SAMPLE_SIZE = 10

        class << self
          # M4: SSOT :embed routing (Call::Embeddings → Router.next_lane via
          # RequestRequirements(operation: :embed, required_capabilities:
          # [:embedding])) is the SOLE selection authority for embeddings.
          # Discovery no longer selects a provider/instance/model — the
          # settings-pin → tier-rank → default_model chain was a second
          # selection domain, and the @embedding_* state it wrote (and the
          # facade getters that projected it) is gone. can_embed? answers one
          # capability FACT against the live Inventory lane store — the same
          # lanes the router reads: is there an embedding-capable lane the
          # router can select? (Live query — no boot-time detection state.)
          def can_embed?
            Legion::LLM::Inventory.lanes.any? do |lane|
              Array(lane[:capabilities]).any? { |c| c.to_s == 'embedding' }
            end
          end

          def discovery_status(provider:, instance: nil)
            @discovery_status[discovery_status_key(provider, instance)] || :unknown
          end

          def record_discovery_status(provider:, status:, instance: nil)
            @discovery_status[discovery_status_key(provider, instance)] = status.to_sym
          end

          def run
            log.debug '[llm][discovery] run.enter'
            Legion::LLM::Inventory::Discovery::System.refresh! if discovery_enabled?
            log.info "[llm][discovery] system total_mb=#{Legion::LLM::Inventory::Discovery::System.total_memory_mb} " \
                     "available_mb=#{Legion::LLM::Inventory::Discovery::System.available_memory_mb}"
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.discovery.run')
          end

          # Check whether a specific model is available from any registered provider.
          # Reads the live Inventory lane store — no discovery cache.
          def model_available?(model, provider: nil, instance: nil)
            return false unless defined?(Legion::LLM::Inventory)

            psym = provider&.to_sym
            isym = instance&.to_sym
            Legion::LLM::Inventory.lanes.any? do |l|
              name_matches?(l[:model].to_s, model.to_s) &&
                (psym.nil? || l[:provider_family].to_sym == psym) &&
                (isym.nil? || l[:instance_id].to_sym == isym)
            end
          end

          # Return the size in bytes for a discovered model, or nil if unknown.
          # After P3, size_bytes is not stored on lanes; always nil.
          def model_size(_model, **)
            nil
          end

          def fetch_offering_models(entry)
            adapter = entry[:adapter]
            return [] unless adapter.respond_to?(:offerings)

            begin
              models = Array(adapter.offerings(live: true)).map do |offering|
                data = normalize_offering(offering)
                {
                  model:              (data[:id] || data[:name] || data[:model]).to_s,
                  provider:           entry[:provider],
                  instance:           normalize_instance_id(data[:instance_id] || data[:provider_instance] || entry[:instance]),
                  tier:               data[:tier] || entry.dig(:metadata, :tier),
                  size_bytes:         data[:size_bytes] || data[:size],
                  capabilities:       source_aware_capabilities(data, entry),
                  capability_sources: data[:capability_sources],
                  context_length:     data[:context_length] || data[:max_model_len] || data.dig(:limits, :context_window),
                  parameter_count:    data[:parameter_count] || data.dig(:metadata, :parameter_count),
                  health:             data[:health] || data['health'] || data.dig(:metadata, :health),
                  loaded:             extract_loaded_field(data)
                }
              end

              record_discovery_status(
                provider: entry[:provider],
                instance: entry[:instance],
                status:   models.empty? ? :empty : :ok
              )
              warn_on_model_divergence(entry, models)
              models
            rescue StandardError => e
              report_discovery_failure(entry, e)
              []
            end
          end

          def reset!
            log.debug '[llm][discovery] reset'
            @discovery_status = Concurrent::Map.new
          end

          private

          def discovery_status_key(provider, instance)
            "#{provider}/#{instance || :default}"
          end

          # Observability guardrail: when an instance's live discovered models do not
          # include its configured default_model, the backend is almost certainly
          # stale or misconfigured (e.g. a vLLM node behind a load balancer that
          # wasn't restarted after a model swap). Pure logging — no effect on routing.
          # Rescue-guarded so it can never break discovery.
          def warn_on_model_divergence(entry, models)
            return if models.empty?

            metadata = entry[:metadata]
            configured = metadata.is_a?(Hash) ? (metadata[:default_model] || metadata['default_model']) : nil
            return if configured.nil? || configured.to_s.empty?

            configured = configured.to_s
            discovered = models.map { |model| model[:model].to_s }
            return if discovered.any? { |name| model_family_match?(name, configured) }

            sample = discovered.first(MODEL_DIVERGENCE_SAMPLE_SIZE)
            overflow = discovered.size - sample.size
            discovered_detail = overflow.positive? ? "#{sample.join(',')},+#{overflow} more" : sample.join(',')
            log.warn "[llm][discovery] action=model_divergence provider=#{entry[:provider]} " \
                     "instance=#{entry[:instance] || :default} configured=#{configured} " \
                     "discovered_count=#{discovered.size} discovered=#{discovered_detail} — backend may be stale or misconfigured"
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.discovery.model_divergence')
          end

          # A configured default is "present" when a discovered id equals it or extends
          # it as a versioned family member (e.g. configured "anthropic.claude-sonnet-4"
          # matches discovered "anthropic.claude-sonnet-4-6" / "...-20250514-v1:0").
          # Without this, every multi-model cloud provider false-warns because its
          # default is a family base while discovery returns fully-versioned ids.
          def model_family_match?(discovered_name, configured)
            return true if discovered_name == configured

            MODEL_FAMILY_DELIMITERS.any? { |delimiter| discovered_name.start_with?("#{configured}#{delimiter}") }
          end

          def extract_loaded_field(data)
            return data[:loaded] if data.key?(:loaded)
            return data['loaded'] if data.key?('loaded')

            metadata = data[:metadata] || data['metadata']
            return nil unless metadata.is_a?(Hash)

            metadata.key?(:loaded) ? metadata[:loaded] : metadata['loaded']
          end

          # Build capabilities from offering data. When the offering carries
          # capability_sources, its capabilities are authoritative and registry
          # metadata must NOT blindly override them. Registry metadata is only
          # merged when no source-tagged data is present.
          def source_aware_capabilities(data, entry)
            offering_caps = data[:capabilities]
            sources = data[:capability_sources]

            if sources.is_a?(Hash) && sources.any?
              # Offering has source-tagged capabilities — authoritative.
              Capabilities.normalize(offering_caps)
            else
              # Legacy path: merge offering + registry metadata.
              Capabilities.merge(offering_caps, entry.dig(:metadata, :capabilities))
            end
          end

          def report_discovery_failure(entry, error)
            provider = entry[:provider]
            instance = entry[:instance]
            connection_error = error.is_a?(Faraday::ConnectionFailed) ||
                               error.is_a?(Faraday::TimeoutError) ||
                               error.message.match?(/connection refused|connect.*timeout|no route to host/i)

            if connection_error
              log.warn("[llm][discovery] provider=#{provider} instance=#{instance} unreachable: #{error.message}")
            else
              handle_exception(error, level: :warn, handled: true,
                                      operation: "discovery.offerings.#{provider}/#{instance}")
            end

            record_discovery_status(provider: provider, instance: instance,
                                    status: connection_error ? :unreachable : :error)
          end

          def normalize_offering(offering)
            data = if offering.is_a?(Hash)
                     offering
                   elsif offering.respond_to?(:to_hash)
                     offering.to_hash
                   elsif offering.respond_to?(:to_h)
                     offering.to_h
                   else
                     return {}
                   end
            return {} unless data.is_a?(Hash)

            data.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          end

          def normalize_instance_id(value)
            return nil if value.nil?

            value.respond_to?(:to_sym) ? value.to_sym : value
          end

          # Match model names allowing prefix matching for tagged variants (e.g. "llama3" matches "llama3:8b")
          def name_matches?(discovered_name, query_name)
            return false if discovered_name.nil? || query_name.nil?

            dn = discovered_name.to_s
            qn = query_name.to_s
            dn == qn || dn.start_with?("#{qn}:")
          end

          def discovery_enabled?
            Legion::Settings[:llm][:discovery][:enabled] != false
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'
require 'legion/llm/inventory/discovery/system'
require 'legion/llm/discovery/rule_generator'

module Legion
  module LLM
    module Inventory
      module Discovery
        extend Legion::Logging::Helper

        @can_embed = nil
        @embedding_provider = nil
        @embedding_model = nil
        @embedding_instance = nil
        @embedding_fallback_chain = nil
        # Per-(provider,instance) discovery status — lock-free reads, atomic writes.
        @discovery_status = Concurrent::Map.new
        EMBEDDING_TIER_ORDER = %w[local direct fleet cloud frontier].freeze
        # Version/tag delimiters that separate a model family base from its concrete
        # discovered id (Ollama "model:tag", Bedrock "family-YYYYMMDD-v1:0" / "family-6").
        MODEL_FAMILY_DELIMITERS = %w[: -].freeze
        # Cap how many discovered ids a divergence warning prints — multi-model cloud
        # providers (Bedrock lists ~90) otherwise dump an unreadable single log line.
        MODEL_DIVERGENCE_SAMPLE_SIZE = 10

        class << self
          attr_reader :embedding_provider, :embedding_model, :embedding_instance, :embedding_fallback_chain

          def can_embed?
            @can_embed == true
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

          def detect_embedding_capability
            log.debug '[llm][discovery] action=detect_embedding_capability.enter'

            if detect_embedding_from_registry
              log.debug '[llm][discovery] action=detect_embedding_capability registry_hit=true'
              return
            end

            embedding_settings = self.embedding_settings
            found = find_embedding_provider(embedding_settings)
            if found
              @can_embed = true
              @embedding_provider = found[:provider]
              @embedding_model = found[:model]
              @embedding_fallback_chain = build_embedding_fallback_chain(embedding_settings)
              log.info "[llm][discovery] embedding available provider=#{@embedding_provider} model=#{@embedding_model}"
            else
              @can_embed = false
              @embedding_fallback_chain = []
              log.info '[llm][discovery] no embedding provider available'
            end
          rescue StandardError => e
            @can_embed = false
            @embedding_fallback_chain = []
            handle_exception(e, level: :warn, operation: 'llm.discovery.detect_embedding_capability')
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
          def model_size(_model, provider: nil, instance: nil) # rubocop:disable Lint/UnusedMethodArgument
            nil
          end

          def fetch_offering_models(entry)
            adapter = entry[:adapter]
            return [] unless adapter.respond_to?(:offerings)

            begin
              models = Array(adapter.offerings(live: true)).map do |offering|
                data = normalize_offering(offering)
                report_discovery_health(entry, data)
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
            @can_embed = nil
            @embedding_provider = nil
            @embedding_model = nil
            @embedding_instance = nil
            @embedding_fallback_chain = nil
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

          def report_discovery_health(entry, offering_data)
            return unless defined?(Router) && Router.respond_to?(:health_tracker)

            provider = entry[:provider]
            instance = normalize_instance_id(
              offering_data[:instance_id] || offering_data[:provider_instance] || entry[:instance]
            )
            health = offering_data[:health] || offering_data['health'] || {}
            health = {} unless health.is_a?(Hash)
            status = (health[:status] || health['status'] || health[:circuit_state] || health['circuit_state']).to_s
            latency_ms = health[:latency_ms] || health['latency_ms']

            if %w[healthy ready closed available].include?(status) || health[:ready] == true || health['ready'] == true
              Router.health_tracker.report(provider: provider, instance: instance, signal: :success, value: 1,
                                           metadata: { source: :discovery })
            elsif %w[unhealthy down unavailable open tripped].include?(status)
              Router.health_tracker.report(provider: provider, instance: instance, signal: :error, value: 1,
                                           metadata: { source: :discovery, status: status })
            end

            return unless latency_ms.to_i.positive?

            Router.health_tracker.report(provider: provider, instance: instance, signal: :latency,
                                         value: latency_ms.to_i, metadata: { source: :discovery })
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'discovery.report_health')
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

            return unless defined?(Router) && Router.respond_to?(:health_tracker)

            trip_on_unreachable = Legion::Settings[:llm].dig(:discovery, :trip_circuit_on_unreachable) != false
            if connection_error && trip_on_unreachable
              Router.health_tracker.trip_circuit(
                provider: provider, instance: instance,
                reason: "discovery_unreachable: #{error.class.name}"
              )
            else
              Router.health_tracker.report(
                provider: provider, instance: instance,
                signal: :error, value: 1,
                metadata: { reason: error.class.name, source: :discovery }
              )
            end
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

          def detect_embedding_from_registry
            return false unless defined?(Call::Registry)

            embedding_instances = Call::Registry.with_capability(:embedding)
            return false if embedding_instances.empty?

            log.debug "[llm][discovery] action=detect_embedding_from_registry candidates=#{embedding_instances.size}"

            # Honor an explicitly configured embedding pin (provider and/or instance) before any
            # tier-based auto-selection, but only when the pinned instance actually has its model.
            # An empty pinned instance falls through to ranking so we never commit to a dead pin.
            selected = select_pinned_embedding_instance(embedding_instances) ||
                       select_ranked_embedding_instance(embedding_instances)

            unless selected
              log.debug '[llm][discovery] action=detect_embedding_from_registry no_usable_candidate ' \
                        '— falling through to legacy probe'
              return false
            end

            @embedding_provider = selected[:provider]
            @embedding_model    = selected[:model]
            @embedding_instance = selected[:instance]
            @can_embed          = true
            @embedding_fallback_chain = build_registry_embedding_fallback(embedding_instances)

            log.info "[llm][discovery] embedding available provider=#{@embedding_provider} " \
                     "instance=#{@embedding_instance} model=#{@embedding_model} source=registry"
            true
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.discovery.detect_embedding_from_registry')
            false
          end

          # Select the configured embedding instance when llm.embedding.instance (and optionally
          # .provider) is set and that instance is registered, embedding-capable, and actually
          # serves its resolved model. Returns { provider:, instance:, model: } or nil.
          def select_pinned_embedding_instance(embedding_instances)
            settings = embedding_settings
            pinned_instance = settings[:instance]
            pinned_provider = settings[:provider]
            return nil if pinned_instance.nil? && pinned_provider.nil?

            candidate = embedding_instances.find do |i|
              (pinned_instance.nil? || i[:instance].to_s == pinned_instance.to_s) &&
                (pinned_provider.nil? || i[:provider].to_s == pinned_provider.to_s)
            end

            unless candidate
              log.debug '[llm][discovery] action=detect_embedding_from_registry pin_not_registered ' \
                        "provider=#{pinned_provider} instance=#{pinned_instance} — ignoring pin"
              return nil
            end

            resolved = resolve_embedding_model_for(candidate)
            unless usable_embedding_instance?(candidate, resolved)
              log.debug '[llm][discovery] action=detect_embedding_from_registry pin_unusable ' \
                        "provider=#{candidate[:provider]} instance=#{candidate[:instance]} " \
                        "model=#{resolved} — ignoring pin, falling back to tier ranking"
              return nil
            end

            log.debug '[llm][discovery] action=detect_embedding_from_registry pin_honored ' \
                      "provider=#{candidate[:provider]} instance=#{candidate[:instance]} model=#{resolved}"
            { provider: candidate[:provider], instance: candidate[:instance], model: resolved }
          end

          # Walk candidates in tier order (local-first) and return the first whose resolved model is
          # actually present on that specific instance. Per-instance verification keeps the local-first
          # preference for users who genuinely run a populated local Ollama while skipping an instance
          # that merely ranks higher but does not have the model. Returns { provider:, instance:, model: }.
          def select_ranked_embedding_instance(embedding_instances)
            ranked = embedding_instances.sort_by do |i|
              EMBEDDING_TIER_ORDER.index(i.dig(:metadata, :tier).to_s) || 99
            end

            ranked.each do |candidate|
              resolved = resolve_embedding_model_for(candidate)
              next unless usable_embedding_instance?(candidate, resolved)

              return { provider: candidate[:provider], instance: candidate[:instance], model: resolved }
            end
            nil
          end

          # Resolve the embedding model for a single registry candidate using the same precedence the
          # legacy single-best path used: per-instance default_model, then the configured embedding
          # default_model, then the first embedding-capable discovered model on that instance.
          def resolve_embedding_model_for(candidate)
            candidate.dig(:metadata, :default_model) ||
              embedding_settings[:default_model] ||
              first_embedding_model_for(candidate[:provider], candidate[:instance])
          end

          # A candidate is usable only when it resolves to a model that is actually present on that
          # specific instance — guarding against committing to an empty instance (e.g. an auto-added
          # local Ollama with no embedding model pulled).
          def usable_embedding_instance?(candidate, resolved)
            return false unless resolved.to_s.length.positive?

            model_available?(resolved, provider: candidate[:provider], instance: candidate[:instance])
          end

          def build_registry_embedding_fallback(instances)
            instances.sort_by { |i| EMBEDDING_TIER_ORDER.index(i.dig(:metadata, :tier).to_s) || 99 }
                     .map do |i|
              {
                provider: i[:provider],
                model:    i.dig(:metadata, :default_model),
                instance: i[:instance]
              }
            end
          end

          def first_embedding_model_for(provider, instance)
            return nil unless defined?(Legion::LLM::Inventory)

            embedding_caps = %w[embedding embeddings embed].freeze
            Legion::LLM::Inventory.lanes_for(provider: provider.to_sym, instance: instance.to_sym).find do |l|
              Array(l[:capabilities]).any? { |c| embedding_caps.include?(c.to_s) }
            end&.dig(:model)
          end

          def find_embedding_provider(embedding_settings)
            fallback = embedding_settings[:provider_fallback] || %w[ollama bedrock openai]
            provider_models = embedding_settings[:provider_models] || {}
            ollama_preferred = embedding_settings[:ollama_preferred] ||
                               %w[mxbai-embed-large bge-large snowflake-arctic-embed]

            log.debug "[llm][discovery] find_embedding_provider fallback=#{fallback}"
            fallback.each do |provider_name|
              provider = provider_name.to_sym
              model = provider_models[provider_name.to_sym] || provider_models[provider_name]
              available = probe_embedding_provider(provider, ollama_preferred)
              log.debug "[llm][discovery] find_embedding_provider provider=#{provider} available=#{available.inspect}"
              next unless available

              resolved_model = available.is_a?(String) ? available : model&.to_s
              next unless verify_embedding(provider, resolved_model)

              log.debug "[llm][discovery] find_embedding_provider result provider=#{provider} model=#{resolved_model}"
              return { provider: provider, model: resolved_model }
            end
            nil
          end

          def verify_embedding(provider, model)
            log.debug "[llm][discovery] verify_embedding provider=#{provider} model=#{model}"
            return true unless model

            model_available?(model, provider: provider)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.discovery.verify_embedding', provider: provider, model: model)
            false
          end

          def probe_embedding_provider(provider, ollama_preferred)
            log.debug "[llm][discovery] probe_embedding_provider provider=#{provider}"
            case provider
            when :ollama then detect_ollama_embedding(ollama_preferred)
            else detect_cloud_embedding(provider)
            end
          end

          def detect_ollama_embedding(preferred_models)
            log.debug "[llm][discovery] detect_ollama_embedding preferred=#{preferred_models}"
            return nil unless provider_enabled?(:ollama)

            preferred_models.each do |m|
              log.debug "[llm][discovery] detect_ollama_embedding checking model=#{m}"
              return m if model_available?(m, provider: :ollama)
            end
            nil
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.discovery.detect_ollama_embedding')
            nil
          end

          def detect_cloud_embedding(provider)
            log.debug "[llm][discovery] detect_cloud_embedding provider=#{provider}"
            ps = providers_settings
            provider_config = ps[provider.to_sym] || ps[provider.to_s]
            return nil unless provider_config.is_a?(Hash) && provider_config[:enabled] != false
            return nil unless provider_supports_embeddings?(provider)

            true
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.discovery.detect_cloud_embedding', provider: provider)
            nil
          end

          def build_embedding_fallback_chain(embedding_settings)
            fallback = embedding_settings[:provider_fallback] || %w[ollama bedrock openai]
            provider_models = embedding_settings[:provider_models] || {}
            ollama_preferred = embedding_settings[:ollama_preferred] ||
                               %w[mxbai-embed-large bge-large snowflake-arctic-embed]

            log.debug "[llm][discovery] build_embedding_fallback_chain fallback=#{fallback}"
            fallback.filter_map do |provider_name|
              provider = provider_name.to_sym
              next unless provider_enabled?(provider)
              next unless provider_supports_embeddings?(provider)

              available = probe_embedding_provider(provider, ollama_preferred)
              next unless available

              model = available.is_a?(String) ? available : (provider_models[provider_name.to_sym] || provider_models[provider_name])&.to_s
              log.debug "[llm][discovery] fallback chain entry provider=#{provider} model=#{model}"
              { provider: provider, model: model }
            end
          end

          def provider_supports_embeddings?(provider)
            provider = provider&.to_sym
            return false unless provider
            return true if %i[ollama azure].include?(provider)
            return false if provider == :anthropic

            adapter = Call::Registry.for(provider)
            return true if adapter.respond_to?(:embed)

            %i[openai bedrock gemini vertex azure_foundry vllm mlx].include?(provider)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.discovery.provider_supports_embeddings', provider: provider)
            false
          end

          def provider_enabled?(provider)
            ps = providers_settings
            config = ps[provider.to_sym] || ps[provider.to_s]
            config.is_a?(Hash) && config[:enabled] != false
          end

          def embedding_settings
            Legion::Settings[:llm][:embedding]
          end

          def providers_settings
            ext = Legion::Settings[:extensions]
            return ext[:llm] if ext.is_a?(Hash) && ext[:llm].is_a?(Hash)

            {}
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.discovery.providers_settings')
            {}
          end

          def discovery_enabled?
            Legion::Settings[:llm][:discovery][:enabled] != false
          end
        end
      end
    end
  end
end

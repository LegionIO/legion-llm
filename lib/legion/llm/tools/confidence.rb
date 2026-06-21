# frozen_string_literal: true

require 'legion/cache/helper'
require 'legion/logging/helper'
module Legion
  module LLM
    module Tools
      module Confidence
        extend Legion::Logging::Helper
        extend ::Legion::Cache::Helper

        OVERRIDE_THRESHOLD = 0.8
        SHADOW_THRESHOLD = 0.5
        SUCCESS_DELTA = 0.05
        FAILURE_DELTA = -0.1

        @overrides_l0 = {}
        @mutex = Mutex.new

        module_function

        def cache_namespace = ''

        def record(tool:, lex:, confidence:)
          @mutex.synchronize do
            @overrides_l0[tool] = {
              tool: tool, lex: lex, confidence: confidence.clamp(0.0, 1.0),
              hit_count: 0, miss_count: 0, created_at: Time.now, updated_at: Time.now
            }
          end
          sync_to_l1(tool)
        end

        def record_success(tool)
          @mutex.synchronize do
            entry = @overrides_l0[tool]
            return unless entry

            entry[:confidence] = (entry[:confidence] + SUCCESS_DELTA).clamp(0.0, 1.0)
            entry[:hit_count] += 1
            entry[:updated_at] = Time.now
          end
          sync_to_l1(tool)
        end

        def record_failure(tool)
          @mutex.synchronize do
            entry = @overrides_l0[tool]
            return unless entry

            entry[:confidence] = (entry[:confidence] + FAILURE_DELTA).clamp(0.0, 1.0)
            entry[:miss_count] += 1
            entry[:updated_at] = Time.now
          end
          sync_to_l1(tool)
        end

        def lookup(tool)
          @mutex.synchronize { @overrides_l0[tool]&.dup } ||
            lookup_l1(tool) ||
            lookup_l2(tool)
        end

        def should_override?(tool)
          entry = lookup(tool)
          entry.is_a?(Hash) && entry[:confidence] >= OVERRIDE_THRESHOLD
        end

        def should_shadow?(tool)
          entry = lookup(tool)
          entry.is_a?(Hash) && entry[:confidence] >= SHADOW_THRESHOLD && entry[:confidence] < OVERRIDE_THRESHOLD
        end

        def all_overrides
          @mutex.synchronize { @overrides_l0.values.map(&:dup) }
        end

        def pending_l2_sync
          []
        end

        def hydrate_from_l2
          return unless defined?(Legion::Data::Local)

          rows = Legion::Data::Local.query('SELECT * FROM override_confidence')
          @mutex.synchronize do
            rows.each do |row|
              @overrides_l0[row[:tool]] = row.merge(updated_at: Time.now)
            end
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.tools.confidence.hydrate_from_l2')
        end

        def hydrate_from_apollo
          return unless defined?(Legion::Extensions::Apollo::Runners::Knowledge)

          results = Legion::Extensions::Apollo::Runners::Knowledge.handle_retrieve(
            tags:             %w[override mesh_confirmed],
            knowledge_domain: 'system',
            limit:            100
          )
          return unless results.is_a?(Array)

          results.each do |entry|
            ctx = entry[:context] || entry['context']
            next unless ctx.is_a?(Hash)

            tool = ctx[:tool] || ctx['tool']
            next unless tool

            @mutex.synchronize do
              next if @overrides_l0.key?(tool)

              @overrides_l0[tool] = {
                tool: tool,
                lex: ctx[:lex] || ctx['lex'],
                confidence: ((ctx[:confidence] || ctx['confidence']).to_f * 0.8).clamp(0.0, 1.0),
                hit_count: 0, miss_count: 0,
                created_at: Time.now, updated_at: Time.now
              }
            end
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.tools.confidence.hydrate_from_apollo')
        end

        def reset!
          @mutex.synchronize do
            @overrides_l0.clear
          end
        end

        class << self
          private

          def sync_to_l1(tool)
            return unless local_cache_available?

            entry = @mutex.synchronize { @overrides_l0[tool] }
            return unless entry

            l1_cache_set("override:#{tool}", Legion::JSON.dump(entry), ttl: 3600)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.tools.confidence.sync_l1', tool: tool)
            nil
          end

          def lookup_l1(tool)
            return nil unless local_cache_available?

            raw = l1_cache_get("override:#{tool}")
            return nil unless raw

            Legion::JSON.load(raw)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.tools.confidence.lookup_l1', tool: tool)
            nil
          end

          def local_cache_available?
            local_cache_backend? || shared_cache_backend?
          end

          def l1_cache_get(key)
            return local_cache_get(key) if local_cache_backend?

            cache_get(key)
          end

          def l1_cache_set(key, value, ttl:)
            return local_cache_set(key, value, ttl: ttl) if local_cache_backend?

            cache_set(key, value, ttl: ttl)
          end

          def local_cache_backend?
            respond_to?(:local_cache_connected?) && local_cache_connected?
          rescue StandardError => e
            log.debug("[llm][tools][confidence] action=local_cache_backend error=#{e.class}")
            false
          end

          def shared_cache_backend?
            respond_to?(:cache_connected?) && cache_connected?
          rescue StandardError => e
            log.debug("[llm][tools][confidence] action=shared_cache_backend error=#{e.class}")
            false
          end

          def lookup_l2(tool)
            return nil unless defined?(Legion::Data::Local)

            rows = Legion::Data::Local.query('SELECT * FROM override_confidence WHERE tool = ?', tool)
            rows&.first
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.tools.confidence.lookup_l2')
            nil
          end
        end
      end
    end
  end
end

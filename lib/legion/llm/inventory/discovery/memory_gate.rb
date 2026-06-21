# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inventory
      module Discovery
        module MemoryGate
          extend Legion::Logging::Helper

          LOCAL_PROVIDERS = %i[ollama mlx].freeze

          module_function

          def allow?(provider:, instance: nil, model: nil)
            return true if provider.nil?
            return true unless LOCAL_PROVIDERS.include?(provider.to_sym)

            available = available_memory_mb
            cost = estimated_model_mb(model, provider: provider, instance: instance)
            floor = memory_floor_mb

            fits = (cost + floor) <= available
            unless fits
              log.info("[llm][memory_gate] rejected model=#{model} provider=#{provider}/#{instance} " \
                       "cost_mb=#{cost} available_mb=#{available} floor_mb=#{floor}")
            end
            fits
          end

          def available_memory_mb
            Discovery::System.available_memory_mb
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'memory_gate.available')
            4096
          end

          def estimated_model_mb(model, provider: nil, instance: nil)
            file_mb = Discovery.model_size(model.to_s, provider: provider&.to_sym, instance: instance&.to_sym)
            file_mb = file_mb.to_i / (1024 * 1024) if file_mb && file_mb > 1_000_000
            return 4096 unless file_mb&.positive?

            overhead = Legion::Settings[:llm][:discovery][:memory_overhead_factor]
            (file_mb * overhead).ceil
          end

          def memory_floor_mb
            Legion::Settings[:llm][:discovery][:memory_floor_mb]
          end
        end
      end
    end
  end
end

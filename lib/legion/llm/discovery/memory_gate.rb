# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Discovery
      module MemoryGate
        extend Legion::Logging::Helper

        LOCAL_PROVIDERS = %i[ollama mlx].freeze

        module_function

        def allow?(provider:, instance: nil, model: nil)
          return true unless LOCAL_PROVIDERS.include?(provider.to_sym)

          available = available_memory_mb
          cost = estimated_model_mb(model)
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
          handle_exception(e, level: :debug, handled: true, operation: 'memory_gate.available')
          4096
        end

        def estimated_model_mb(model)
          file_mb = nil
          if defined?(Discovery::Ollama)
            file_mb = Discovery::Ollama.model_size(model.to_s)
            file_mb = file_mb.to_i / (1024 * 1024) if file_mb && file_mb > 1_000_000
          end
          return 4096 unless file_mb&.positive?

          overhead = Legion::LLM::Settings.value(:discovery, :memory_overhead_factor) || 1.4
          (file_mb * overhead).ceil
        end

        def memory_floor_mb
          Legion::LLM::Settings.value(:discovery, :memory_floor_mb) || 2048
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      module Registry
        extend Legion::Logging::Helper

        # @registry structure: { provider_sym => { instance_sym => { adapter:, metadata: } } }
        @registry = {}
        @mutex = Mutex.new

        module_function

        def register(name, extension_module, instance: :default, metadata: {})
          provider = name.to_sym
          inst = instance.to_sym
          @mutex.synchronize do
            @registry[provider] ||= {}
            @registry[provider][inst] = { adapter: extension_module, metadata: metadata }
          end
          log.info("[llm][registry] registered provider=#{provider} instance=#{inst}")
          extension_module
        end

        def for(name, instance: nil)
          provider = name.to_sym
          @mutex.synchronize do
            entries = @registry[provider]
            return nil unless entries

            entry = if instance
                      entries[instance.to_sym]
                    else
                      entries[:default] || entries.values.first
                    end
            entry&.[](:adapter)
          end
        end

        def instances_for(name)
          provider = name.to_sym
          @mutex.synchronize do
            entries = @registry[provider] || {}
            entries.each_with_object({}) { |(inst, entry), h| h[inst] = entry[:adapter] }
          end
        end

        def available
          @mutex.synchronize { @registry.keys.dup }
        end

        def registered?(name, instance: nil)
          provider = name.to_sym
          @mutex.synchronize do
            return false unless @registry.key?(provider)
            return true unless instance

            @registry[provider].key?(instance.to_sym)
          end
        end

        def metadata_for(name, instance = :default)
          provider = name.to_sym
          inst = instance.to_sym
          @mutex.synchronize do
            entry = @registry.dig(provider, inst)
            entry ? entry[:metadata] : {}
          end
        end

        def deregister_provider(name)
          provider = name.to_sym
          @mutex.synchronize do
            removed = @registry.delete(provider)
            count = removed ? removed.size : 0
            log.info("[llm][registry] deregister_provider provider=#{provider} count=#{count}")
            count
          end
        end

        def with_capability(capability)
          cap = capability.to_sym
          @mutex.synchronize do
            results = []
            @registry.each do |provider, entries|
              entries.each do |inst, entry|
                caps = entry[:metadata][:capabilities]
                next unless caps.is_a?(Array) && caps.include?(cap)

                results << { provider: provider, instance: inst, adapter: entry[:adapter], metadata: entry[:metadata] }
              end
            end
            results
          end
        end

        def all_instances
          @mutex.synchronize do
            results = []
            @registry.each do |provider, entries|
              entries.each do |inst, entry|
                results << { provider: provider, instance: inst, adapter: entry[:adapter], metadata: entry[:metadata] }
              end
            end
            results
          end
        end

        def providers
          @mutex.synchronize { @registry.dup.freeze }
        end

        def disconnect_all!
          @mutex.synchronize do
            count = 0
            @registry.each_value do |entries|
              entries.each_value do |entry|
                adapter = entry[:adapter]
                next unless adapter.respond_to?(:provider) && adapter.provider.respond_to?(:disconnect)

                adapter.provider.disconnect
                count += 1
              rescue StandardError => e
                log.warn("[llm][registry] disconnect failed: #{e.message}")
              end
            end
            log.info("[llm][registry] disconnect_all count=#{count}")
          end
        end

        def reset!
          @mutex.synchronize do
            count = @registry.values.sum(&:size)
            @registry.clear
            log.info("[llm][registry] reset count=#{count}")
          end
        end
      end
    end
  end
end

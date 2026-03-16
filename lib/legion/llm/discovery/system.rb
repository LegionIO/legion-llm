# frozen_string_literal: true

module Legion
  module LLM
    module Discovery
      module System
        class << self
          def total_memory_mb
            ensure_total_fresh
            @total_memory_mb
          end

          def available_memory_mb
            ensure_available_fresh
            @available_memory_mb
          end

          def memory_pressure?
            avail = available_memory_mb
            return false if avail.nil?

            floor = discovery_settings[:memory_floor_mb] || 2048
            avail < floor
          end

          def platform
            @platform ||= detect_platform
          end

          def refresh!
            @total_fetched_at = nil
            @available_fetched_at = nil
            @total_memory_mb = nil
            @available_memory_mb = nil
            @last_refreshed_at = Time.now
          end

          def reset!
            @total_memory_mb = nil
            @available_memory_mb = nil
            @total_fetched_at = nil
            @available_fetched_at = nil
            @last_refreshed_at = nil
            @platform = nil
          end

          def stale?
            return true if @last_refreshed_at.nil?

            ttl = discovery_settings[:refresh_seconds] || 60
            Time.now - @last_refreshed_at > ttl
          end

          private

          def ensure_total_fresh
            refresh! if stale?
            return unless @total_fetched_at.nil?

            fetch_total
            @total_fetched_at = Time.now
          end

          def ensure_available_fresh
            refresh! if stale?
            return unless @available_fetched_at.nil?

            fetch_available
            @available_fetched_at = Time.now
          end

          def fetch_total
            case platform
            when :macos then fetch_macos_total
            when :linux then fetch_linux_total
            end
          end

          def fetch_available
            case platform
            when :macos then fetch_macos_available
            when :linux then fetch_linux_available
            end
          end

          def detect_platform
            case RbConfig::CONFIG['host_os']
            when /darwin/i then :macos
            when /linux/i  then :linux
            else :unknown
            end
          end

          def fetch_macos_total
            raw = `sysctl -n hw.memsize`.strip.to_i
            @total_memory_mb = raw / 1024 / 1024
          rescue StandardError
            @total_memory_mb = nil
          end

          def fetch_macos_available
            vm_output = `vm_stat`
            page_size = vm_output[/page size of (\d+) bytes/, 1]&.to_i || 16_384
            free     = vm_output[/Pages free:\s+(\d+)/, 1].to_i
            inactive = vm_output[/Pages inactive:\s+(\d+)/, 1].to_i
            @available_memory_mb = (free + inactive) * page_size / 1024 / 1024
          rescue StandardError
            @available_memory_mb = nil
          end

          def fetch_linux_total
            meminfo = File.read('/proc/meminfo')
            total_kb = meminfo[/MemTotal:\s+(\d+)/, 1].to_i
            @total_memory_mb = total_kb / 1024
          rescue StandardError
            @total_memory_mb = nil
          end

          def fetch_linux_available
            meminfo = File.read('/proc/meminfo')
            free_kb     = meminfo[/MemFree:\s+(\d+)/, 1].to_i
            inactive_kb = meminfo[/Inactive:\s+(\d+)/, 1].to_i
            @available_memory_mb = (free_kb + inactive_kb) / 1024
          rescue StandardError
            @available_memory_mb = nil
          end

          def discovery_settings
            return {} unless Legion.const_defined?('Settings')

            Legion::Settings[:llm][:discovery] || {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end

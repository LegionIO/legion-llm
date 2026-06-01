# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Tools
      module Interceptor
        extend Legion::Logging::Helper

        @registry = {}
        @mutex = Mutex.new

        module_function

        def register(name, matcher:, &block)
          @mutex.synchronize { @registry = @registry.merge(name.to_sym => { matcher: matcher, rewrite: block }) }
        end

        def intercept(tool_name, **args)
          snapshot = @mutex.synchronize { @registry.dup }
          snapshot.each do |name, entry|
            next unless entry[:matcher].call(tool_name)

            log.info "[llm][interceptor] action=interceptor_fired interceptor=#{name} tool=#{tool_name}"
            rewritten_args = entry[:rewrite].call(tool_name, **args)
            unless rewritten_args.is_a?(Hash)
              raise ArgumentError,
                    "interceptor #{name.inspect} must return a Hash, got #{rewritten_args.class}"
            end

            changed_keys = rewritten_args.keys.reject { |k| rewritten_args[k] == args[k] }
            if changed_keys.any?
              log.debug "[llm][interceptor] action=args_rewritten interceptor=#{name} " \
                        "tool=#{tool_name} changed_keys=#{changed_keys.join(',')}"
            end
            args = rewritten_args
          end
          args
        end

        def registered
          @mutex.synchronize { @registry.keys }
        end

        def reset!
          @mutex.synchronize { @registry = {} }
        end

        def load_defaults
          require_relative 'interceptors/python_venv'
          Interceptors::PythonVenv.register!
        end
      end
    end
  end
end

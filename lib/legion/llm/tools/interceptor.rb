# frozen_string_literal: true

module Legion
  module LLM
    module Tools
      module Interceptor
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

            rewritten_args = entry[:rewrite].call(tool_name, **args)
            unless rewritten_args.is_a?(Hash)
              raise ArgumentError,
                    "interceptor #{name.inspect} must return a Hash, got #{rewritten_args.class}"
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

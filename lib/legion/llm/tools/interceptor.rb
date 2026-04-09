# frozen_string_literal: true

module Legion
  module LLM
    module Tools
      module Interceptor
        @registry = {}

        module_function

        def register(name, matcher:, &block)
          @registry[name.to_sym] = { matcher: matcher, rewrite: block }
        end

        def intercept(tool_name, **args)
          @registry.each_value do |entry|
            next unless entry[:matcher].call(tool_name)

            args = entry[:rewrite].call(tool_name, **args)
          end
          args
        end

        def registered
          @registry.keys
        end

        def reset!
          @registry = {}
        end

        def load_defaults
          require_relative 'interceptors/python_venv'
          Interceptors::PythonVenv.register!
        end
      end
    end
  end
end

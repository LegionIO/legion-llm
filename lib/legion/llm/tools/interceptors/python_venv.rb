# frozen_string_literal: true

require 'legion/llm/tools/special'

module Legion
  module LLM
    module Tools
      module Interceptors
        module PythonVenv
          TOOL_PATTERN = /\A(python3?|pip3?)\z/i

          module_function

          def register!
            Interceptor.register(:python_venv, matcher: method(:match?)) do |_tool_name, **args|
              rewrite(**args)
            end
          end

          def match?(tool_name)
            TOOL_PATTERN.match?(tool_name.to_s)
          end

          def venv_available?
            Special.python_available? || File.exist?("#{venv_dir}/pyvenv.cfg")
          end

          def rewrite(**args)
            return args unless venv_available?

            command = args[:command]
            return args unless command.is_a?(String)

            args.merge(command: rewrite_command(command))
          end

          def rewrite_command(command)
            command
              .sub(/\Apython3?(\s|\z)/, "#{python_path}\\1")
              .sub(/\Apip3?(\s|\z)/,    "#{pip_path}\\1")
          end

          def python_path
            Special.python_path || "#{venv_dir}/bin/python3"
          end

          def pip_path
            Special.pip_path || "#{venv_dir}/bin/pip3"
          end

          def venv_dir
            configured = Legion::Settings[:llm][:tools][:python_venv_dir]
            File.expand_path(ENV['LEGION_PYTHON_VENV'] || configured)
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Legion
  module LLM
    module Tools
      module Interceptors
        module PythonVenv
          VENV_DIR = File.expand_path('~/.legionio/python').freeze
          PYTHON   = "#{VENV_DIR}/bin/python3".freeze
          PIP      = "#{VENV_DIR}/bin/pip3".freeze

          TOOL_PATTERN = /\A(python|pip)/i

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
            File.exist?("#{VENV_DIR}/pyvenv.cfg")
          end

          def rewrite(**args)
            return args unless venv_available?

            command = args[:command]
            return args unless command.is_a?(String)

            args.merge(command: rewrite_command(command))
          end

          def rewrite_command(command)
            command
              .sub(/\Apython3(\s|\z)/, "#{PYTHON}\\1")
              .sub(/\Apip3(\s|\z)/,    "#{PIP}\\1")
          end
        end
      end
    end
  end
end

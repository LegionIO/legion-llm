# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'shellwords'
require 'timeout'

require 'legion/json'
require 'legion/logging/helper'
require 'legion/llm/types'

module Legion
  module LLM
    module Tools
      module Special
        extend Legion::Logging::Helper

        LIST_SPECIAL_TOOLS_NAME = 'legion_list_special_tools'
        LIST_ALL_TOOLS_NAME = 'legion_list_all_tools'
        DEFAULT_TIMEOUT_MS = 120_000
        MAX_TIMEOUT_MS = 600_000
        PYTHON_PACKAGES = %w[
          python-pptx
          python-docx
          openpyxl
          pandas
          pillow
          requests
          lxml
          PyYAML
          tabulate
          markdown
        ].freeze

        module_function

        def pinned_definitions
          definitions = [special_tools_definition, all_tools_definition, ruby_definition]
          definitions.concat(python_definitions) if python_available?
          definitions
        end

        def dispatch(tool_name, **args)
          case normalize_tool_name(tool_name)
          when LIST_SPECIAL_TOOLS_NAME
            { status: :success, result: Legion::JSON.dump(inventory) }
          when LIST_ALL_TOOLS_NAME
            { status: :success, result: Legion::JSON.dump(all_tools_inventory(**args)) }
          when 'ruby'
            dispatch_runtime('ruby', ruby_path, **args)
          when 'python', 'python3'
            dispatch_runtime('python', python_path, **args)
          when 'pip', 'pip3'
            dispatch_runtime('pip', pip_path, **args)
          else
            { status: :error, result: "Unknown Legion special tool: #{tool_name}" }
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.tools.special.dispatch', tool_name: tool_name)
          { status: :error, result: e.message }
        end

        def inventory
          {
            special_tools:             special_tool_summaries,
            settings_extensions_tools: settings_extensions_tools,
            runtime:                   runtime_inventory
          }
        end

        def all_tools_inventory(**args)
          tools = settings_extensions_tools
          extension_filter = args[:extension] || args['extension']
          deferred_filter = args.key?(:deferred) ? args[:deferred] : args['deferred']

          if extension_filter
            normalized_filter = extension_filter.to_s.tr('-', '_').delete_prefix('lex_')
            tools = tools.select { |t| t[:extension].to_s.tr('-', '_').delete_prefix('lex_').include?(normalized_filter) }
          end

          tools = tools.select { |t| t[:deferred] == deferred_filter } unless deferred_filter.nil?

          grouped = tools.group_by { |t| t[:extension] || 'unknown' }
          {
            total:      tools.size,
            extensions: grouped.transform_values do |ext_tools|
              ext_tools.group_by { |t| t[:runner] || 'default' }.transform_values do |runner_tools|
                runner_tools.map { |t| { name: t[:name], description: t[:description], deferred: t[:deferred] } }
              end
            end
          }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.tools.special.all_tools_inventory')
          { total: 0, extensions: {}, error: e.message }
        end

        def python_available?
          !python_path.to_s.empty?
        end

        def ruby_path
          process_path = process_ruby_path
          return process_path if legionio_packaged_ruby?(process_path) && executable_file?(process_path)

          path_ruby || process_path
        end

        def python_path
          @python_path ||= begin
            candidates = []
            candidates << ENV.fetch('LEGION_PYTHON', nil)
            candidates << File.join(python_venv_dir, 'bin', 'python3')
            candidates.compact.find { |path| executable_file?(path) }
          end
        end

        def pip_path
          @pip_path ||= begin
            candidates = []
            candidates.concat(pip_candidates_for(File.dirname(python_path))) if python_available?
            candidates.concat(pip_candidates_for(File.join(python_venv_dir, 'bin')))
            candidates.compact.uniq.find { |path| executable_file?(path) }
          end
        end

        def reset_runtime_cache!
          @python_path = nil
          @pip_path = nil
        end

        def python_venv_dir
          ENV['LEGION_PYTHON_VENV'] || File.expand_path('~/.legionio/python')
        end

        def special_tools_definition
          Types::ToolDefinition.build(
            name:        LIST_SPECIAL_TOOLS_NAME,
            description: 'Show all Legion special tools available to this LLM from the current Legion::Settings::Extensions inventory.',
            parameters:  {
              type:       'object',
              properties: {}
            },
            source:      { type: :special, handler: :settings_extensions_inventory, pinned: true }
          )
        end

        def all_tools_definition
          Types::ToolDefinition.build(
            name:        LIST_ALL_TOOLS_NAME,
            description: 'List ALL registered Legion tools from all loaded extensions, grouped by extension and runner. ' \
                         'Use this to discover what tools are available for a specific domain (e.g. Teams, Apollo, identity).',
            parameters:  {
              type:       'object',
              properties: {
                extension: { type: 'string', description: 'Filter by extension name (e.g. "microsoft_teams", "apollo"). Omit for all.' },
                deferred:  { type: 'boolean', description: 'Filter by deferred status. Omit for all.' }
              }
            },
            source:      { type: :special, handler: :all_tools_inventory, pinned: true }
          )
        end

        def ruby_definition
          Types::ToolDefinition.build(
            name:        'ruby',
            description: "Run Ruby with the current Legion Ruby environment. Current path: #{ruby_path}.",
            parameters:  runtime_schema('Ruby'),
            source:      { type: :special, handler: :ruby_runtime, pinned: true, executable: ruby_path }
          )
        end

        def python_definitions
          [
            Types::ToolDefinition.build(
              name:        'python',
              description: "Run Python with the Legion-managed Python environment from `legionio setup python`. Current path: #{python_path}.",
              parameters:  runtime_schema('Python'),
              source:      { type: :special, handler: :python_runtime, pinned: true, executable: python_path }
            ),
            Types::ToolDefinition.build(
              name:        'pip',
              description: "Run pip inside the Legion-managed Python environment from `legionio setup python`. Current path: #{pip_path || 'unavailable'}.",
              parameters:  pip_schema,
              source:      { type: :special, handler: :pip_runtime, pinned: true, executable: pip_path }
            )
          ]
        end

        def runtime_schema(language)
          {
            type:       'object',
            properties: {
              code:    { type: 'string', description: "#{language} code to execute with -e/-c." },
              command: { type: 'string', description: "#{language} command arguments, such as a script path plus args." },
              args:    { type: 'array', items: { type: 'string' }, description: 'Additional argv entries.' },
              cwd:     { type: 'string', description: 'Working directory. Defaults to the current process directory.' },
              timeout: { type: 'integer', description: 'Timeout in milliseconds.' },
              stdin:   { type: 'string', description: 'Optional stdin content.' }
            }
          }
        end

        def pip_schema
          {
            type:       'object',
            properties: {
              command: { type: 'string', description: 'pip arguments, such as `install pandas` or `list`.' },
              args:    { type: 'array', items: { type: 'string' }, description: 'pip argv entries.' },
              cwd:     { type: 'string', description: 'Working directory. Defaults to the current process directory.' },
              timeout: { type: 'integer', description: 'Timeout in milliseconds.' },
              stdin:   { type: 'string', description: 'Optional stdin content.' }
            }
          }
        end

        def special_tool_summaries
          pinned_definitions.map do |definition|
            {
              name:        definition.name,
              description: definition.description,
              parameters:  definition.parameters,
              source:      'legion-special'
            }
          end
        end

        def settings_extensions_tools
          return [] unless defined?(Legion::Settings::Extensions) && Legion::Settings::Extensions.respond_to?(:tools)

          Array(Legion::Settings::Extensions.tools).filter_map { |entry| normalize_inventory_entry(entry) }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.tools.special.settings_extensions_inventory')
          []
        end

        def normalize_inventory_entry(entry)
          return unless entry.respond_to?(:transform_keys)

          normalized = entry.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          name = normalized[:name].to_s
          return if name.empty?

          {
            name:          name,
            description:   normalized[:description].to_s,
            deferred:      normalized[:deferred] == true,
            extension:     normalized[:extension],
            runner:        normalized[:runner],
            function:      normalized[:function],
            trigger_words: Array(normalized[:trigger_words]).map(&:to_s),
            parameters:    normalized[:input_schema] || normalized[:parameters] || {},
            source:        normalized[:tool_class] ? 'registry' : 'extension'
          }.compact
        end

        def runtime_inventory
          {
            ruby:   {
              path:            ruby_path,
              path_ruby:       path_ruby,
              process_ruby:    process_ruby_path,
              description:     RUBY_DESCRIPTION,
              bundler_version: defined?(Bundler) ? Bundler::VERSION : nil,
              bundle_gemfile:  ENV.fetch('BUNDLE_GEMFILE', nil),
              bundle_bin_path: ENV.fetch('BUNDLE_BIN_PATH', nil)
            }.compact,
            python: {
              available:        python_available?,
              path:             python_path,
              venv_dir:         python_venv_dir,
              pip:              pip_path,
              default_packages: PYTHON_PACKAGES
            }.compact
          }
        end

        def dispatch_runtime(runtime_name, executable, **args)
          return { status: :error, result: "#{runtime_name} runtime is unavailable." } unless executable_file?(executable)

          argv = runtime_argv(runtime_name, **args)
          return { status: :error, result: "#{runtime_name} tool requires `code`, `command`, or `args`." } if argv.empty?

          output, status = run_process(executable, argv, **args)
          result = "command=#{Shellwords.join([executable, *argv])}\nexit=#{status.exitstatus}\n#{output}"
          { status: status.success? ? :success : :error, result: result }
        rescue Timeout::Error
          { status: :error, result: "#{runtime_name} tool timed out after #{timeout_ms(args)}ms." }
        end

        def runtime_argv(runtime_name, **args)
          code = args[:code] || args['code']
          return [runtime_name == 'python' ? '-c' : '-e', code.to_s, *array_args(args)] unless code.to_s.empty?

          command = args[:command] || args['command']
          command_args = command.to_s.empty? ? [] : Shellwords.split(command.to_s)
          command_args + array_args(args)
        end

        def array_args(args)
          raw = args[:args] || args['args']
          case raw
          when Array
            raw.map(&:to_s)
          when String
            Shellwords.split(raw)
          else
            []
          end
        end

        def run_process(executable, argv, **args)
          Timeout.timeout(timeout_ms(args) / 1000.0) do
            Open3.capture2e(executable, *argv, chdir: process_cwd(args), stdin_data: process_stdin(args))
          end
        end

        def process_cwd(args)
          cwd = args[:cwd] || args['cwd']
          cwd.to_s.empty? ? Dir.pwd : cwd.to_s
        end

        def process_stdin(args)
          stdin = args[:stdin] || args['stdin']
          stdin.nil? ? '' : stdin.to_s
        end

        def timeout_ms(args)
          requested = (args[:timeout] || args['timeout'] || DEFAULT_TIMEOUT_MS).to_i
          return DEFAULT_TIMEOUT_MS unless requested.positive?

          [requested, MAX_TIMEOUT_MS].min
        end

        def pip_candidates_for(bin_dir)
          return [] if bin_dir.to_s.empty?

          [File.join(bin_dir, 'pip'), File.join(bin_dir, 'pip3')]
        end

        def process_ruby_path
          RbConfig.ruby
        end

        def path_ruby
          executable_from_path('ruby')
        end

        def legionio_packaged_ruby?(path)
          normalized = path.to_s
          normalized.include?('/Cellar/legionio/') || normalized.include?('/libexec/bin/ruby')
        end

        def executable_from_path(command)
          ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).filter_map do |dir|
            path = File.join(dir, command)
            path if executable_file?(path)
          end.first
        end

        def executable_file?(path)
          !path.to_s.empty? && File.file?(path.to_s) && File.executable?(path.to_s)
        end

        def normalize_tool_name(tool_name)
          tool_name.to_s.tr('.', '_')
        end
      end
    end
  end
end

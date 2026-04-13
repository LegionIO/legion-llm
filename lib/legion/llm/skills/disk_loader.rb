# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Skills
      module DiskLoader
        extend Legion::Logging::Helper

        module_function

        def load_from_directories(directories)
          loaded = 0
          Array(directories).each do |dir|
            expanded = ::File.expand_path(dir)
            next unless ::File.directory?(expanded)

            loaded += load_directory(expanded)
          end
          loaded
        end

        def load_directory(dir)
          loaded = 0
          ::Dir.glob(::File.join(dir, '*.rb')).each do |path|
            require path
            loaded += 1
          rescue StandardError => e
            log.warn("[skills][disk_loader] failed to load #{path}: #{e.message}")
          end
          ::Dir.glob(::File.join(dir, '*.md')).each do |path|
            load_md_skill(path)
            loaded += 1
          rescue StandardError => e
            log.warn("[skills][disk_loader] failed to load #{path}: #{e.message}")
          end
          ::Dir.glob(::File.join(dir, '*/SKILL.md')).each do |path|
            load_md_skill(path, skill_name: ::File.basename(::File.dirname(path)))
            loaded += 1
          rescue StandardError => e
            log.warn("[skills][disk_loader] failed to load #{path}: #{e.message}")
          end
          loaded
        end

        # Public for testing. Accepts an optional content: kwarg to avoid disk reads in specs.
        def load_md_skill(path, skill_name: nil, content: nil)
          raw = content || ::File.read(path)
          meta, body = parse_frontmatter(raw)
          name      = skill_name || meta[:name] || ::File.basename(path, '.md')
          ns        = (meta[:namespace] || 'disk').to_s
          desc      = (meta[:description] || '').to_s
          trig      = (meta[:trigger] || 'on_demand').to_sym
          words     = Array(meta[:trigger_words] || []).map(&:to_s)
          klass     = build_md_skill_class(name: name, namespace: ns, description: desc,
                                           trigger: trig, trigger_words: words, content: body)
          Registry.register(klass)
        end

        def parse_frontmatter(text)
          return [{}, text] unless text.start_with?('---')

          parts = text.split(/^---\s*$/, 3)
          return [{}, text] unless parts.size >= 3

          require 'yaml'
          meta = ::YAML.safe_load(parts[1], permitted_classes: [], symbolize_names: true) || {}
          [meta, parts[2].lstrip]
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.skills.disk_loader.parse_frontmatter')
          [{}, text]
        end

        def build_md_skill_class(name:, namespace:, description:, trigger:, trigger_words:, content:)
          raw_content = content
          klass = Class.new(Legion::LLM::Skills::Base)
          klass.send(:define_method, :present_content) do |context: {}| # rubocop:disable Lint/UnusedBlockArgument
            Legion::LLM::Skills::StepResult.build(inject: raw_content)
          end
          klass.skill_name(name)
          klass.namespace(namespace)
          klass.description(description)
          klass.trigger(trigger)
          klass.trigger_words(*trigger_words) if trigger_words.any?
          klass.steps(:present_content)
          klass
        end
      end
    end
  end
end

# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      class Executor
        # ToolInjection methods extracted from Executor verbatim (P4b §1.5, refactor-under-green).
        # Builds the per-request native tool catalog (special-pinned + caller-supplied + registry-
        # discovered + GAIA-triggered) with passthrough policy gating, dedup variants, and
        # per-tier injection limits. Memoized via @native_dispatch_tools / @native_tool_definitions
        # — those memos are invalidated implicitly by Executor lifecycle (one Executor per request).
        module ToolInjection
          def native_dispatch_options
            injected_system = if @native_tool_loop_round.to_i.positive?
                                @cached_injected_system
                              else
                                @cached_injected_system = EnrichmentInjector.inject(
                                  system:      @request.system,
                                  enrichments: @enrichments
                                )
                              end

            record_system_accounting(injected_system) if @native_tool_loop_round.to_i.zero?

            options = {
              system:            injected_system,
              offering_id:       @resolved_offering_id,
              offering_metadata: @resolved_offering_metadata
            }
            options[:system] = native_tool_loop_system(options[:system])
            options[:tools] = native_dispatch_tools if native_dispatch_tools.any?
            options[:tool_prefs] = native_tool_prefs if native_dispatch_tools.any? && native_tool_prefs
            options[:thinking] = native_dispatch_thinking if native_dispatch_thinking
            apply_generation_params!(options)
            options.compact
          end

          def native_tool_loop_system(system)
            return system unless @native_tool_loop_round.to_i.positive? && native_dispatch_tools.any?

            [system, native_tool_loop_continuation_prompt].compact.join("\n\n")
          end

          def native_tool_loop_continuation_prompt
            <<~PROMPT.strip
              Tool-use continuation rule:
              - You just received tool results.
              - If a tool failed or produced incomplete information and another available tool can continue the user's request, call that tool now.
              - Do not say you will use a tool unless you are actually making the tool call in this response.
              - Only provide a final answer when no further tool call is needed or possible.
            PROMPT
          end

          # Propagate generation sampling params from the canonical request into
          # the dispatch options hash. Uses .key? so that explicit 0 values are
          # preserved (0 is a valid temperature, not the same as absent/nil).
          GENERATION_PARAMS = %i[temperature top_p top_k frequency_penalty presence_penalty seed].freeze

          def apply_generation_params!(options)
            generation = @request.generation
            return unless generation.is_a?(Hash)

            GENERATION_PARAMS.each do |param|
              options[param] = generation[param] if generation.key?(param)
            end
          end

          def native_dispatch_chat_options
            opts = { model: @resolved_model, provider: @resolved_provider }
            opts[:instance] = @resolved_instance if @resolved_instance
            opts[:thinking] = native_dispatch_thinking if native_dispatch_thinking
            opts.compact
          end

          def native_dispatch_thinking
            return @request.thinking if @request.thinking

            nil
          end

          def native_dispatch_tools
            @native_dispatch_tools ||= native_tool_definitions.to_h { |tool| [tool.name.to_sym, tool.to_h] }
          end

          def native_tool_definitions
            @native_tool_definitions ||= begin
              definitions = []
              add_pinned_special_tool_definitions(definitions)
              Array(@request.tools).each { |tool| add_native_tool_definition(definitions, tool) }
              add_registry_tool_definitions(definitions) if registry_tool_injection_requested?
              record_tool_accounting(definitions)
              log.debug "[llm][executor] action=native_tool_definitions.built count=#{definitions.size}"
              log_native_tool_definitions(definitions)
              definitions
            end
          end

          def registry_tool_injection_requested?
            return false if @request.respond_to?(:suppress_tools) && @request.suppress_tools

            # Always inject LegionIO tools (special + extension). Client passthrough
            # is handled by the tool loop, which executes LegionIO tools server-side
            # and returns only client tools to the client.
            true
          end

          def client_tool_passthrough_enabled?
            if @request.respond_to?(:metadata)
              metadata = @request.metadata || {}
              value = metadata.key?(:client_tool_passthrough) ? metadata[:client_tool_passthrough] : metadata['client_tool_passthrough']
              return value if [true, false].include?(value)
            end

            Legion::Settings.dig(:llm, :tools, :trigger, :client_tool_passthrough) == true
          end

          def client_tool_passthrough_allowed?(definition)
            names = client_tool_passthrough_name_variants(definition)
            whitelist = client_tool_passthrough_list(:client_tool_passthrough_whitelist)
            blacklist = client_tool_passthrough_list(:client_tool_passthrough_blacklist)

            return false if whitelist.any? && !names.intersect?(whitelist)
            return false if names.intersect?(blacklist)

            true
          end

          def client_tool_passthrough_list(key)
            Array(Legion::Settings.dig(:llm, :tools, :trigger, key)).flat_map do |entry|
              client_tool_policy_variants(entry)
            end.uniq
          end

          def client_tool_passthrough_name_variants(definition)
            source = definition.respond_to?(:source) ? definition.source : {}
            raw_name = source[:raw_name] || source['raw_name'] if source.is_a?(Hash)
            [definition.name, raw_name].compact.flat_map { |name| client_tool_policy_variants(name) }.uniq
          end

          def client_tool_policy_variants(value)
            raw = value.to_s.strip.downcase
            sanitized = Types::ToolDefinition.sanitize_tool_name(value).downcase
            compact = raw.gsub(/[^a-z0-9]/, '')

            [raw, sanitized, compact].reject(&:empty?).uniq
          end

          def non_executable_client_tool?(definition)
            source = definition.respond_to?(:source) ? definition.source : {}
            return false unless source.is_a?(Hash)

            source_type = source[:type] || source['type']
            executable = source.key?(:executable) ? source[:executable] : source['executable']
            source_type.respond_to?(:to_sym) && source_type.to_sym == :client && executable != true
          end

          def add_pinned_special_tool_definitions(definitions)
            Tools::Special.pinned_definitions.each do |definition|
              next if definitions.any? { |existing| existing.name == definition.name }

              @native_tool_source_map[definition.name] = definition.source
              definitions << definition
            end
          end

          def add_native_tool_definition(definitions, tool)
            source = request_tool_source(tool)
            definition = case tool
                         when Types::ToolDefinition
                           source == tool.source ? tool : tool.with(source: source)
                         when Hash
                           Types::ToolDefinition.from_hash(tool, source: source)
                         else
                           Types::ToolDefinition.from_tool_class(tool)
                         end
            if non_executable_client_tool?(definition) && !client_tool_passthrough_enabled?
              log.info(
                "[llm][tools][inject] action=client_tool_skipped request_id=#{request_log_value(:id, 'unknown')} " \
                "conversation_id=#{request_log_value(:conversation_id, 'none') || 'none'} name=#{definition.name} " \
                'reason=client_passthrough_not_enabled'
              )
              return
            end
            if non_executable_client_tool?(definition) && !client_tool_passthrough_allowed?(definition)
              log.info(
                "[llm][tools][inject] action=client_tool_skipped request_id=#{request_log_value(:id, 'unknown')} " \
                "conversation_id=#{request_log_value(:conversation_id, 'none') || 'none'} name=#{definition.name} " \
                'reason=client_passthrough_policy'
              )
              return
            end
            return if gaia_tool_suppressed?(definition.name)
            return if native_tool_definition_duplicate?(definitions, definition)

            @injected_tool_map[definition.name] = definition.source[:tool_class] if definition.source[:tool_class]
            @native_tool_source_map[definition.name] = definition.source
            definitions << definition
          rescue StandardError => e
            @warnings << "Failed to define tool: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.native_tool_definition')
          end

          def request_tool_source(tool)
            explicit_source = if tool.respond_to?(:source)
                                tool.source
                              elsif tool.respond_to?(:[])
                                tool[:source] || tool['source']
                              end

            source = explicit_source.is_a?(Hash) ? explicit_source : {}
            source_type = source[:type] || source['type']

            client_like_source = source.empty? ||
                                 (source_type.respond_to?(:to_sym) && source_type.to_sym == :client)

            # Allow client-shaped declarations to be reclassified to LegionIO sources
            # when they match tools registered on this node.
            if client_like_source
              resolved_source = resolve_registry_tool_source(tool)
              return resolved_source if resolved_source
            end

            source.empty? ? { type: :client, executable: false } : source
          end

          def resolve_registry_tool_source(tool)
            tool_name = request_tool_names(tool).find { |name| !name.to_s.empty? }
            return nil unless tool_name
            return nil unless Legion::Settings::Extensions.respond_to?(:find_tool)

            entry = request_tool_names(tool).filter_map do |candidate|
              Legion::Settings::Extensions.find_tool(candidate)
            end.first
            return nil unless entry.is_a?(Hash)

            tool_class = entry[:tool_class] || entry['tool_class']
            extension = entry[:extension] || entry['extension']
            runner = entry[:runner] || entry['runner']
            function = entry[:function] || entry['function']

            if tool_class
              return {
                type:       :registry,
                tool_class: tool_class,
                extension:  extension,
                runner:     runner,
                function:   function
              }.compact
            end

            return nil unless extension.to_s.length.positive? && runner.to_s.length.positive? && function.to_s.length.positive?

            {
              type:     :extension,
              lex:      extension,
              runner:   runner,
              function: function
            }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.native_tool_source.resolve', tool_name: tool_name)
            nil
          end

          def request_tool_names(tool)
            explicit_source = if tool.respond_to?(:source)
                                tool.source
                              elsif tool.respond_to?(:[])
                                tool[:source] || tool['source']
                              end
            source = explicit_source.is_a?(Hash) ? explicit_source : {}
            raw_name = source[:raw_name] || source['raw_name']
            declared_name = if tool.respond_to?(:name)
                              tool.name
                            elsif tool.respond_to?(:[])
                              tool[:name] || tool['name']
                            end

            [raw_name, declared_name].compact.flat_map do |name|
              raw = name.to_s
              sanitized = Types::ToolDefinition.sanitize_tool_name(raw)
              dotted_legion = sanitized.sub(/\Alegion_/, 'legion.')
              [raw, sanitized, dotted_legion]
            end.uniq
          end

          def add_registry_tool_definitions(definitions)
            return unless registry_tool_sources_available?

            count_before = definitions.size
            add_settings_extensions_tool_definitions(definitions)
            count_after = definitions.size
            log.info(
              "[llm][tools] registry_injection count_before=#{count_before} count_after=#{count_after} " \
              "added=#{count_after - count_before} limit=#{registry_tool_limit}"
            )
          rescue StandardError => e
            @warnings << "Tool definition error: #{e.message}"
            handle_exception(e, level: :error, operation: 'llm.pipeline.native_registry_tools')
          end

          def native_tool_definition_duplicate?(definitions, definition)
            candidate_names = native_tool_definition_name_variants(definition)
            definitions.any? do |existing|
              native_tool_definition_name_variants(existing).intersect?(candidate_names)
            end
          end

          def native_tool_definition_name_variants(definition)
            variants = client_tool_passthrough_name_variants(definition)
            source = definition.respond_to?(:source) ? definition.source : {}
            source_type = nil
            source_type = source[:type] || source['type'] if source.is_a?(Hash)
            variants += Tools::Special.aliases_for(definition.name).flat_map { |name| client_tool_policy_variants(name) } if source_type.respond_to?(:to_sym) && source_type.to_sym == :special
            variants.uniq
          end

          def add_settings_extensions_tool_definitions(definitions)
            existing_names = definitions.map(&:name)
            inject_limit = registry_tool_limit
            registry_added = 0

            always_entries = Legion::Settings::Extensions.filter_tools(deferred: false)
            gaia_entries = gaia_advisory_tool_entries
            triggered_entries = @triggered_tools.any? ? Array(@triggered_tools) : []
            prioritized = if local_provider?
                            gaia_entries + triggered_entries + always_entries
                          else
                            always_entries + gaia_entries + triggered_entries
                          end

            prioritized.each do |entry|
              break if inject_limit && registry_added >= inject_limit

              definition = if entry.is_a?(Hash) && entry[:name]
                             Types::ToolDefinition.from_registry_entry(entry)
                           else
                             Types::ToolDefinition.from_tool_class(entry)
                           end
              next if gaia_tool_suppressed?(definition.name)
              next if existing_names.include?(definition.name)

              tool_class = entry.is_a?(Hash) ? entry[:tool_class] : entry
              @injected_tool_map[definition.name] = tool_class if tool_class
              @native_tool_source_map[definition.name] = definition.source
              definitions << definition
              existing_names << definition.name
              registry_added += 1
            end

            add_requested_deferred_tool_definitions_from_settings(definitions, existing_names)
          end

          def add_requested_deferred_tool_definitions_from_settings(definitions, injected_names)
            requested = requested_deferred_tool_names
            return if requested.empty?

            deferred_entries = Legion::Settings::Extensions.filter_tools(deferred: true)
            deferred_entries.each do |entry|
              definition = Types::ToolDefinition.from_registry_entry(entry)
              next unless requested.include?(definition.name)
              next if gaia_tool_suppressed?(definition.name)
              next if injected_names.include?(definition.name)

              @injected_tool_map[definition.name] = entry[:tool_class] if entry[:tool_class]
              @native_tool_source_map[definition.name] = definition.source
              definitions << definition
              injected_names << definition.name
            end
          end

          def record_tool_accounting(definitions)
            return if definitions.empty?

            tool_tokens = ContextAccounting.estimate_json_tokens(definitions.map(&:to_h))
            @context_accounting[:tokens][:tool_definition_estimated_tokens] = tool_tokens
            @context_accounting[:counts][:tool_definition_count] = definitions.size
            @context_accounting[:component_status][:tools] = :observed
            @context_accounting[:events] << ContextAccounting.event(
              event_type:    :tools_injected,
              component:     :tools,
              before_tokens: 0,
              after_tokens:  tool_tokens,
              before_count:  0,
              after_count:   definitions.size
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.record_tool_accounting')
          end

          def record_system_accounting(injected_system)
            baseline = EnrichmentInjector.resolve_baseline
            baseline_tokens = ContextAccounting.estimate_text_tokens(baseline)
            system_tokens = ContextAccounting.estimate_text_tokens(injected_system)
            @context_accounting[:tokens][:baseline_system_estimated_tokens] = baseline_tokens
            @context_accounting[:tokens][:system_prompt_estimated_tokens] = system_tokens
            @context_accounting[:component_status][:system] = :observed
            @context_accounting[:events] << ContextAccounting.event(
              event_type:    :system_injected,
              component:     :system,
              before_tokens: 0,
              after_tokens:  system_tokens,
              metadata:      { baseline_tokens: baseline_tokens }
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.record_system_accounting')
          end
        end
      end
    end
  end
end

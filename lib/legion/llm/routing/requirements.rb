# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/inference/request'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/routing/request_requirements'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module Routing
      # Request-fact behavior included into Router. Each Router initializes its
      # own immutable facts once, before any Inventory read or lane selection.
      module Requirements
        include Legion::Logging::Helper

        OPERATION_BASE = {
          chat: [].freeze, stream_chat: %i[streaming].freeze,
          embed: %i[embedding].freeze, image: %i[image].freeze,
          transcribe: %i[audio_transcription].freeze, translate: [].freeze,
          speak: %i[audio_speech].freeze, moderate: %i[moderation].freeze,
          count_tokens: [].freeze
        }.freeze
        private_constant :OPERATION_BASE

        attr_reader :operation, :required_capabilities, :input_bound, :required_output_tokens,
                    :context_budget, :requested_embedding_dimensions, :modality,
                    :provider_pin, :instance_pin, :model_pin, :tier_pin,
                    :body_model_hint_decision, :routing_seed, :maximum_attempts

        private

        def requirements_initialize(request:, operation:, body_model:, **)
          raise ArgumentError, 'requirements need an Inference::Request' unless request.is_a?(Legion::LLM::Inference::Request)
          unless request.messages.is_a?(Array) && request.messages.all?(Legion::Extensions::Llm::Canonical::Message)
            raise ArgumentError, 'requirements messages must be Canonical::Message objects'
          end

          operation = Legion::Extensions::Llm::Taxonomies.normalize_operation(value: operation)
          settings = request.routing_settings_snapshot
          trusted = request.trusted_constraints
          hint = requirements_body_model_hint_decision(body_model: body_model, trusted_model: trusted.model, settings: settings)
          input_bound = requirements_input_bound(request: request, framing_overhead: settings.input_framing_overhead_tokens)
          output_limit = request.tokens[:max] if request.tokens.is_a?(Hash)
          output_tokens = output_limit.nil? ? 0 : Integer(output_limit)
          dimensions = request.extra[:embedding_dimensions] if operation == :embed

          # The shared contract validates and freezes the values before they
          # become Router state. Keep no second copy of the requirements record.
          requirements = Legion::Extensions::Llm::Routing::RequestRequirements.new(
            operation: operation, required_capabilities: requirements_capabilities(request: request, operation: operation),
            input_bound: input_bound, required_output_tokens: output_tokens,
            context_budget: operation == :embed ? 0 : input_bound + output_tokens,
            requested_embedding_dimensions: dimensions.nil? ? nil : Integer(dimensions),
            modality: request.modality,
            provider_pin: trusted.provider&.to_sym, instance_pin: trusted.instance_id,
            model_pin: trusted.model || hint.model_constraint, tier_pin: trusted.tier&.to_sym,
            body_model_hint_decision: hint, routing_seed: request.routing_context.routing_seed,
            maximum_attempts: trusted.maximum_attempts || settings.maximum_attempts
          )
          @operation = requirements.operation
          @required_capabilities = requirements.required_capabilities
          @input_bound = requirements.input_bound
          @required_output_tokens = requirements.required_output_tokens
          @context_budget = requirements.context_budget
          @requested_embedding_dimensions = requirements.requested_embedding_dimensions
          @modality = requirements.modality
          @provider_pin = requirements.provider_pin
          @instance_pin = requirements.instance_pin
          @model_pin = requirements.model_pin
          @tier_pin = requirements.tier_pin
          @body_model_hint_decision = requirements.body_model_hint_decision
          @routing_seed = requirements.routing_seed
          @maximum_attempts = requirements.maximum_attempts
          log.debug("[llm][requirements] action=built operation=#{@operation} " \
                    "caps=#{@required_capabilities.inspect} input_bound=#{@input_bound} output_tokens=#{@required_output_tokens}")
        end

        def requirements_capabilities(request:, operation:)
          caps = OPERATION_BASE.fetch(operation).dup
          caps << :tools if requirements_tools?(request: request)
          caps << :thinking if request.thinking&.enabled? ||
                               requirements_messages_contain_type?(messages: request.messages, type: :thinking)
          caps << :vision if requirements_messages_contain_type?(messages: request.messages, type: :image)
          format = request.response_format
          if format.is_a?(Hash) && (%w[json_object json_schema].include?(format[:type].to_s) ||
                                   (format[:schema].is_a?(Hash) && !format[:schema].empty?))
            caps << :structured_output
          end
          Legion::Extensions::Llm::Capabilities.normalize(caps)
        end

        def requirements_tools?(request:)
          return true if request.tools.is_a?(Array) && !request.tools.empty?

          choice = request.tool_choice
          return true if choice.is_a?(Hash) && choice[:mode] && !%w[auto none].include?(choice[:mode].to_s)
          return true if request.messages.any? { |message| message.role == :tool || (message.tool_calls && !message.tool_calls.empty?) }

          requirements_messages_contain_type?(messages: request.messages, type: :tool_use) ||
            requirements_messages_contain_type?(messages: request.messages, type: :tool_result)
        end

        def requirements_messages_contain_type?(messages:, type:)
          messages.any? do |message|
            content = message.content
            case content
            when Legion::Extensions::Llm::Canonical::ContentBlock then content.type == type
            when Array then content.any? { |block| block.type == type }
            else false
            end
          end
        end

        # Provider-neutral byte upper bound; no tokenizer or provider guesses.
        def requirements_input_bound(request:, framing_overhead:)
          total = requirements_text_bytes(request.system)
          request.messages.each do |message|
            total += requirements_content_bytes(message.content)
            total += requirements_serialized_bytes(message.tool_calls) unless requirements_empty?(message.tool_calls)
          end
          [request.tools, request.tool_choice, request.thinking, request.response_format, request.extra].each do |value|
            total += requirements_serialized_bytes(value) unless requirements_empty?(value)
          end
          total + framing_overhead
        end

        def requirements_text_bytes(value)
          return 0 if value.nil?

          value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).bytesize
        end

        def requirements_content_bytes(content)
          case content
          when String then requirements_text_bytes(content)
          when Array then content.sum { |block| requirements_block_bytes(block) }
          when Legion::Extensions::Llm::Canonical::ContentBlock then requirements_block_bytes(content)
          else 0
          end
        end

        def requirements_block_bytes(block)
          case block.type
          when :text, :thinking then requirements_text_bytes(block.text)
          when :tool_use then requirements_text_bytes(block.name) + (requirements_empty?(block.input) ? 0 : requirements_serialized_bytes(block.input))
          when :tool_result then requirements_content_bytes(block.text)
          else 0
          end
        end

        def requirements_serialized_bytes(value)
          Legion::JSON.dump(value).bytesize
        end

        def requirements_empty?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end

        def requirements_body_model_hint_decision(body_model:, trusted_model:, settings:)
          requested = body_model&.to_s&.strip
          requested = nil if requested && requested.empty?
          whitelist = settings.body_model_hint_whitelist
          blacklist = settings.body_model_hint_blacklist
          matched_white = requirements_substring_match(model: requested, entries: whitelist) if requested
          matched_black = requirements_substring_match(model: requested, entries: blacklist) if requested
          disposition = if requested.nil?
                          :absent
                        elsif trusted_model
                          :superseded_by_explicit_model
                        elsif settings.auto_routing_model_aliases.any? { |value| value.casecmp?(requested) }
                          :auto
                        elsif !settings.allow_body_routing_hints
                          :ignored_disabled
                        elsif !whitelist.empty? && matched_white.nil?
                          :ignored_not_whitelisted
                        elsif matched_black
                          :ignored_blacklisted
                        else
                          :honored
                        end
          Legion::Extensions::Llm::Routing::BodyModelHintDecision.new(
            requested_model: requested, disposition: disposition,
            model_constraint: disposition == :honored ? requested : nil,
            matched_whitelist: %i[honored ignored_blacklisted].include?(disposition) ? matched_white : nil,
            matched_blacklist: disposition == :ignored_blacklisted ? matched_black : nil,
            settings_generation: settings.generation
          )
        end

        def requirements_substring_match(model:, entries:)
          down = model.downcase
          entries.find { |entry| down.include?(entry.strip.downcase) }
        end
      end
    end
  end
end

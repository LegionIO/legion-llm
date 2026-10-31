# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/inference/request'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/routing/request_requirements'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module Routing
      # Derives immutable request facts before routing. No inventory reads,
      # candidate evaluation, selection or dispatch belong to this boundary.
      module Requirements
        extend Legion::Logging::Helper

        OPERATION_BASE = {
          chat: [].freeze, stream_chat: %i[streaming].freeze,
          embed: %i[embedding].freeze, image: %i[image].freeze,
          transcribe: %i[audio_transcription].freeze, translate: [].freeze,
          speak: %i[audio_speech].freeze, moderate: %i[moderation].freeze,
          count_tokens: [].freeze
        }.freeze
        private_constant :OPERATION_BASE

        class << self
          def build(request:, operation:, body_model:)
            raise ArgumentError, 'requirements need an Inference::Request' unless request.is_a?(Legion::LLM::Inference::Request)
            unless request.messages.is_a?(Array) && request.messages.all?(Legion::Extensions::Llm::Canonical::Message)
              raise ArgumentError, 'requirements messages must be Canonical::Message objects'
            end

            operation = Legion::Extensions::Llm::Taxonomies.normalize_operation(value: operation)
            settings = request.routing_settings_snapshot
            trusted = request.trusted_constraints
            hint = body_model_hint_decision(body_model: body_model, trusted_model: trusted.model, settings: settings)
            input_bound = input_bound_for(request: request, framing_overhead: settings.input_framing_overhead_tokens)
            output_limit = request.tokens[:max] if request.tokens.is_a?(Hash)
            output_tokens = output_limit.nil? ? 0 : Integer(output_limit)
            dimensions = request.extra[:embedding_dimensions] if operation == :embed

            requirements = Legion::Extensions::Llm::Routing::RequestRequirements.new(
              operation: operation, required_capabilities: required_capabilities(request: request, operation: operation),
              input_bound: input_bound, required_output_tokens: output_tokens,
              context_budget: operation == :embed ? 0 : input_bound + output_tokens,
              requested_embedding_dimensions: dimensions.nil? ? nil : Integer(dimensions),
              modality: request.modality,
              provider_pin: trusted.provider&.to_sym, instance_pin: trusted.instance_id,
              model_pin: trusted.model || hint.model_constraint, tier_pin: trusted.tier&.to_sym,
              body_model_hint_decision: hint, routing_seed: request.routing_context.routing_seed,
              maximum_attempts: trusted.maximum_attempts || settings.maximum_attempts
            )
            log.debug("[llm][requirements] action=built operation=#{operation} " \
                      "caps=#{requirements.required_capabilities.inspect} input_bound=#{input_bound} output_tokens=#{output_tokens}")
            requirements
          end

          private

          def required_capabilities(request:, operation:)
            caps = OPERATION_BASE.fetch(operation).dup
            caps << :tools if tools_required?(request: request)
            thinking = request.thinking
            caps << :thinking if (thinking.is_a?(Hash) && !thinking.empty? && thinking[:enabled] != false) ||
                                 messages_contain_type?(messages: request.messages, type: :thinking)
            caps << :vision if messages_contain_type?(messages: request.messages, type: :image)
            format = request.response_format
            if format.is_a?(Hash) && (%w[json_object json_schema].include?(format[:type].to_s) ||
                                     (format[:schema].is_a?(Hash) && !format[:schema].empty?))
              caps << :structured_output
            end
            Legion::Extensions::Llm::Capabilities.normalize(caps)
          end

          def tools_required?(request:)
            return true if request.tools.is_a?(Array) && !request.tools.empty?

            choice = request.tool_choice
            return true if choice.is_a?(Hash) && choice[:mode] && !%w[auto none].include?(choice[:mode].to_s)
            return true if request.messages.any? { |message| message.role == :tool || (message.tool_calls && !message.tool_calls.empty?) }

            messages_contain_type?(messages: request.messages, type: :tool_use) ||
              messages_contain_type?(messages: request.messages, type: :tool_result)
          end

          def messages_contain_type?(messages:, type:)
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
          def input_bound_for(request:, framing_overhead:)
            total = text_bytes(request.system)
            request.messages.each do |message|
              total += content_bytes(message.content)
              total += serialized_bytes(message.tool_calls) unless empty?(message.tool_calls)
            end
            [request.tools, request.tool_choice, request.thinking, request.response_format, request.extra].each do |value|
              total += serialized_bytes(value) unless empty?(value)
            end
            total + framing_overhead
          end

          def text_bytes(value)
            return 0 if value.nil?

            value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).bytesize
          end

          def content_bytes(content)
            case content
            when String then text_bytes(content)
            when Array then content.sum { |block| block_bytes(block) }
            when Legion::Extensions::Llm::Canonical::ContentBlock then block_bytes(content)
            else 0
            end
          end

          def block_bytes(block)
            case block.type
            when :text, :thinking then text_bytes(block.text)
            when :tool_use then text_bytes(block.name) + (empty?(block.input) ? 0 : serialized_bytes(block.input))
            when :tool_result then content_bytes(block.text)
            else 0
            end
          end

          def serialized_bytes(value)
            Legion::JSON.dump(value).bytesize
          end

          def empty?(value)
            value.nil? || (value.respond_to?(:empty?) && value.empty?)
          end

          def body_model_hint_decision(body_model:, trusted_model:, settings:)
            requested = body_model&.to_s&.strip
            requested = nil if requested && requested.empty?
            whitelist = settings.body_model_hint_whitelist
            blacklist = settings.body_model_hint_blacklist
            matched_white = substring_match(model: requested, entries: whitelist) if requested
            matched_black = substring_match(model: requested, entries: blacklist) if requested
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

          def substring_match(model:, entries:)
            down = model.downcase
            entries.find { |entry| down.include?(entry.strip.downcase) }
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'digest'
require 'legion/logging/helper'
require_relative '../publisher_identity'
module Legion
  module LLM
    module Inference
      module AuditPublisher
        extend Legion::Logging::Helper

        module_function

        def build_event(request:, response:)
          log.debug("[audit_publisher][build_event] action=build request_id=#{response.request_id} conversation_id=#{response.conversation_id}")

          resp_message = response.message
          msg_content = resp_message.is_a?(Types::Message) ? resp_message.text : hash_value(resp_message, :content)
          msg_id = resp_message.is_a?(Types::Message) ? resp_message.id : nil
          msg_task_id = resp_message.is_a?(Types::Message) ? resp_message.task_id : nil
          msg_conversation_id = resp_message.is_a?(Types::Message) ? resp_message.conversation_id : nil

          tools_data = Array(response.tools).map do |tc|
            tc.is_a?(Types::ToolCall) ? tc.to_audit_hash : tc
          end

          audit_data = response.audit || {}
          provider_payload = hash_value(audit_data, :provider_payload) || {}

          event = {
            request_id:        response.request_id,
            conversation_id:   response.conversation_id,
            caller:            response.caller,
            identity:          extract_identity(response.caller),
            routing:           response.routing,
            tokens:            serialize_tokens(response.tokens),
            cost:              response.cost,
            system_prompt:     hash_value(provider_payload, :system_prompt),
            injected_tools:    hash_value(provider_payload, :injected_tools),
            enrichments:       compact_enrichments(response.enrichments),
            audit:             without_provider_payload(audit_data),
            timeline:          compact_timeline(response.timeline),
            classification:    response.classification,
            tracing:           response.tracing,
            messages:          current_turn_messages(request.messages),
            response_content:  msg_content,
            response_thinking: response.thinking,
            tools_used:        tools_data,
            timestamp:         Time.now,
            request_type:      request.respond_to?(:request_type) ? request.request_type : 'chat',
            tier:              hash_value(response.routing, :tier),
            message_context:   build_message_context(request: request, response: response)
          }
          event[:message_id] = msg_id if msg_id
          event[:task_id] = msg_task_id || (request.respond_to?(:task_id) ? request.task_id : nil)
          event[:message_conversation_id] = msg_conversation_id if msg_conversation_id
          provider_metrics = extract_provider_metrics(provider_payload)
          event[:provider_metrics] = provider_metrics if provider_metrics.any?
          event[:agent_id] = request.agent_id if request.respond_to?(:agent_id) && request.agent_id
          event[:node_id] = Legion::LLM.node_id if Legion::LLM.respond_to?(:node_id) && Legion::LLM.node_id
          event.compact
          event
        end

        def publish(request:, response:)
          event = build_event(request: request, response: response)
          Legion::LLM::Audit.emit_prompt(event)
          event
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        def extract_identity(caller_data)
          return Legion::LLM::PublisherIdentity.current if caller_data.nil?
          return Legion::LLM::PublisherIdentity.current unless caller_data.is_a?(Hash) && caller_data.any?

          caller_data
        end

        def serialize_tokens(tokens)
          return tokens.to_h if tokens.respond_to?(:to_h) && !tokens.is_a?(Hash)
          return tokens if tokens.is_a?(Hash)

          {}
        end

        def compact_enrichments(enrichments)
          return {} unless enrichments.is_a?(Hash)

          enrichments.transform_values do |v|
            next v unless v.is_a?(Hash)

            summary = { content: hash_value(v, :content), timestamp: hash_value(v, :timestamp) }
            data = hash_value(v, :data)
            next summary unless data.is_a?(Hash)

            compacted = data.transform_values do |dv|
              dv.is_a?(Array) && dv.size > 1 ? dv.last : dv
            end
            summary.merge(data: compacted)
          end
        end

        def compact_timeline(timeline)
          return [] unless timeline.is_a?(Array)

          timeline.select do |event|
            key = (event[:key] || event['key']).to_s
            key.start_with?('provider:') || key.start_with?('escalation:') || key.start_with?('tool:execute:') ||
              key.start_with?('rbac:') || key.start_with?('classification:') || key.start_with?('billing:') ||
              key.start_with?('confidence:')
          end
        end

        def current_turn_messages(messages)
          return messages unless messages.is_a?(Array)

          max = audit_max_messages
          return messages if messages.size <= max

          truncated = messages.last(max)
          full_hash = Digest::SHA256.hexdigest(messages.map { |m| (m[:content] || m['content']).to_s }.join)
          truncated.unshift({ role: :system, content: "[audit: #{messages.size} messages, showing last #{max}, full_hash=#{full_hash}]" })
          truncated
        end

        def audit_max_messages
          max = Legion::LLM::Settings.value(:compliance, :audit_max_messages)
          max = max.to_i if max.respond_to?(:to_i)
          max.is_a?(Integer) && max.positive? ? max : 20
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.audit_publisher.audit_max_messages')
          20
        end

        def build_message_context(request:, response:)
          ctx = {
            request_id:      response.request_id,
            conversation_id: response.conversation_id
          }

          if request.respond_to?(:message_id) && request.message_id
            ctx[:message_id] = request.message_id
          end
          if request.respond_to?(:message_seq) && request.message_seq
            ctx[:message_seq] = request.message_seq
          end
          if request.respond_to?(:parent_message_id) && request.parent_message_id
            ctx[:parent_message_id] = request.parent_message_id
          end

          ctx.compact
        end

        def without_provider_payload(audit_data)
          return {} unless audit_data.is_a?(Hash)

          audit_data.reject { |key, _| key.to_s == 'provider_payload' }
        end

        def extract_provider_metrics(provider_payload)
          return {} unless provider_payload.is_a?(Hash)

          {
            actual_cost_usd: hash_value(provider_payload, :estimated_cost_usd) || hash_value(provider_payload, :cost_usd),
            actual_input_tokens: hash_value(provider_payload, :input_tokens),
            actual_output_tokens: hash_value(provider_payload, :output_tokens),
            model_version: hash_value(provider_payload, :model_version) || hash_value(provider_payload, :model)
          }.compact
        end

        def nested_value(hash, *keys)
          keys.reduce(hash) do |current, key|
            return nil unless current.respond_to?(:key?)

            hash_value(current, key)
          end
        end

        def hash_value(hash, key)
          return nil unless hash.respond_to?(:key?)

          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)

          hash[key] if hash.key?(key)
        end
      end
    end
  end
end

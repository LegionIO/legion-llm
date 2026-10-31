# frozen_string_literal: true

require 'digest'
require 'legion/logging/helper'
require_relative '../content_hash'
require_relative '../publisher_identity'
module Legion
  module LLM
    module Inference
      module AuditPublisher
        extend Legion::Logging::Helper

        module_function

        def build_event(request:, response:)
          log.debug("[audit_publisher][build_event] action=build request_id=#{response.request_id} conversation_id=#{response.conversation_id}")

          # G3: the envelope's message member is the canonical rendering
          # projection (a plain Hash) and its tools are
          # Array<Canonical::ToolCall> — the audit event serializes the
          # canonical shapes directly (no legacy Types re-wrap at the exit).
          resp_message = response.message
          msg_content = hash_value(resp_message, :content)

          tools_data = Array(response.tools).map do |tc|
            tc.is_a?(Legion::Extensions::Llm::Canonical::ToolCall) ? tc.to_h : tc
          end

          audit_data = response.audit || {}
          provider_payload = hash_value(audit_data, :provider_payload) || {}

          fingerprints = {}.compare_by_identity
          request_digest = semantic_message_digest(messages: request.messages, fingerprints: fingerprints)
          capture = capture_metadata(message_count: request.messages.size)
          capture[:request_digest_algorithm] = 'sha256/canonical-messages-v1'

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
            messages:          audit_messages(messages: request.messages, capture: capture),
            response_content:  msg_content,
            response_thinking: response.thinking,
            tools_used:        tools_data,
            timestamp:         Time.now,
            request_type:      request.respond_to?(:request_type) ? request.request_type : 'chat',
            tier:              hash_value(response.routing, :tier),
            message_context:   build_message_context(request: request, response: response)
          }.merge(capture: capture)
          # task_id rides on the request (the envelope message carries no
          # task identity of its own).
          event[:task_id] = request.respond_to?(:task_id) ? request.task_id : nil

          # Ledger column sources (official_record_writer reads these keys directly).
          routing = response.routing.is_a?(Hash) ? response.routing : {}
          event[:finish_reason] = finish_reason_value(response)
          event[:provider_instance] = hash_value(routing, :instance)
          event[:dispatch_path] = hash_value(routing, :tier)
          event[:latency_ms] = hash_value(routing, :latency_ms)
          event[:route_attempts] = Array(hash_value(routing, :route_attempts)).size
          event[:route_attempt_details] = hash_value(routing, :route_attempts) if hash_value(routing, :route_attempts)
          event[:escalation_chain] = hash_value(routing, :escalation_chain) if hash_value(routing, :escalation_chain)
          event[:request_content_hash] = request_digest
          event[:response_content_hash] = content_hash(msg_content)
          provider_metrics = extract_provider_metrics(provider_payload)
          event[:provider_metrics] = provider_metrics if provider_metrics.any?
          event[:context_accounting] = hash_value(audit_data, :context_accounting) if hash_value(audit_data, :context_accounting)
          event[:agent_id] = request.agent_id if request.respond_to?(:agent_id) && request.agent_id
          event[:node_id] = Legion::LLM.node_id if Legion::LLM.respond_to?(:node_id) && Legion::LLM.node_id
          projected = project_value(value: event, binary_limit: audit_max_binary_data_bytes, capture: capture, fingerprints: fingerprints)
          projected[:capture] = capture
          projected
        end

        def publish(request:, response:)
          event = build_event(request: request, response: response)
          { event: event, status: Legion::LLM::Audit.emit_prompt(event) }
        rescue StandardError => e
          handle_exception(e, level: :warn)
          { event: event, status: :dropped }
        end

        def finish_reason_value(response)
          stop = response.respond_to?(:stop) ? response.stop : nil
          return hash_value(stop, :reason) if stop.is_a?(Hash)

          stop&.to_s
        end

        def content_hash(content)
          Legion::LLM::ContentHash.call(content)
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

        # This identity is intentionally separate from ContentHash's text-only
        # embedding/RAG contract. Generated message IDs and timestamps are not
        # content; roles, tool state and every media fingerprint are.
        def semantic_message_digest(messages:, fingerprints:)
          digest = Digest::SHA256.new
          digest << '['
          messages.each_with_index do |message, index|
            digest << ',' unless index.zero?
            semantic = project_value(value: message.to_h.except(:id, :timestamp),
                                     binary_limit: -1, capture: nil, fingerprints: fingerprints)
            update_semantic_digest(digest: digest, value: semantic)
          end
          digest << ']'
          digest.hexdigest
        end

        def update_semantic_digest(digest:, value:)
          case value
          when Hash
            digest << '{'
            value.keys.sort_by(&:to_s).each_with_index do |key, index|
              digest << ',' unless index.zero?
              digest << Legion::JSON.dump(key.to_s) << ':'
              update_semantic_digest(digest: digest, value: value[key])
            end
            digest << '}'
          when Array
            digest << '['
            value.each_with_index do |item, index|
              digest << ',' unless index.zero?
              update_semantic_digest(digest: digest, value: item)
            end
            digest << ']'
          else
            digest << Legion::JSON.dump(value)
          end
        end

        def capture_metadata(message_count:)
          {
            mode: :full, original_message_count: message_count,
            captured_message_count: message_count, omitted_message_count: 0,
            redacted_binary_count: 0, redacted_binary_bytes: 0, omitted_field_count: 0,
            reasons: []
          }
        end

        def audit_messages(messages:, capture:)
          max = [Legion::Settings[:llm][:compliance][:audit_max_messages], 0].max
          retained = messages.last(max)
          omitted = messages.size - retained.size
          if omitted.positive?
            capture[:captured_message_count] = retained.size
            capture[:omitted_message_count] = omitted
            mark_projection(capture: capture, reason: :message_limit)
          end
          retained.map(&:to_h)
        end

        # Canonical blocks can occur singly, in arrays, or inside tool results,
        # arguments and metadata. Copy containers only; never modify inference
        # objects or copy their binary strings. A fingerprint is not base64 data.
        def project_value(value:, binary_limit:, capture:, fingerprints:, binary_type: nil)
          case value
          when Legion::Extensions::Llm::Canonical::Message,
               Legion::Extensions::Llm::Canonical::ContentBlock,
               Legion::Extensions::Llm::Canonical::ToolCall
            project_value(value: value.to_h, binary_limit: binary_limit, capture: capture, fingerprints: fingerprints)
          when Array
            value.map do |item|
              project_value(value: item, binary_limit: binary_limit, capture: capture, fingerprints: fingerprints)
            end
          when Hash
            project_hash(value: value, binary_limit: binary_limit, capture: capture,
                         fingerprints: fingerprints, binary_type: binary_type)
          else
            value
          end
        end

        def project_hash(value:, binary_limit:, capture:, fingerprints:, binary_type:)
          type = hash_value(value, :type).to_s
          media = binary_type || (%w[image audio video].include?(type) && type)
          projected = value.to_h do |key, item|
            nested_media = media if key.to_s == 'source'
            [key, project_value(value: item, binary_limit: binary_limit, capture: capture,
                                fingerprints: fingerprints, binary_type: nested_media)]
          end
          data = hash_value(value, :data)
          source_type = hash_value(value, :source_type) || (binary_type && hash_value(value, :type))
          return projected unless media && source_type.to_s != 'url' && data.is_a?(String) && data.bytesize > binary_limit

          fingerprint = fingerprints[data] ||= { bytes: data.bytesize, sha256: Digest::SHA256.hexdigest(data) }
          projected.delete(:data)
          projected.delete('data')
          projected.delete(:source_type)
          projected.delete('source_type')
          projected[:binary_fingerprint] = fingerprint.merge(media_type: hash_value(value, :media_type), source_type: source_type).compact
          if capture
            capture[:redacted_binary_count] += 1
            capture[:redacted_binary_bytes] += data.bytesize
            mark_projection(capture: capture, reason: binary_limit.negative? ? :payload_limit : :binary_limit)
          end
          projected
        end

        def mark_projection(capture:, reason:)
          capture[:mode] = :projected
          capture[:reasons] |= [reason]
        end

        def audit_max_binary_data_bytes
          Legion::Settings[:llm][:compliance][:audit_max_binary_data_bytes]
        end

        def build_message_context(request:, response:)
          ctx = {
            request_id:      response.request_id,
            conversation_id: response.conversation_id
          }

          ctx[:message_id] = request.message_id if request.respond_to?(:message_id) && request.message_id
          ctx[:message_seq] = request.message_seq if request.respond_to?(:message_seq) && request.message_seq
          ctx[:parent_message_id] = request.parent_message_id if request.respond_to?(:parent_message_id) && request.parent_message_id

          ctx.compact
        end

        def without_provider_payload(audit_data)
          return {} unless audit_data.is_a?(Hash)

          audit_data.reject { |key, _| key.to_s == 'provider_payload' }
        end

        def extract_provider_metrics(provider_payload)
          return {} unless provider_payload.is_a?(Hash)

          {
            actual_cost_usd:      hash_value(provider_payload, :estimated_cost_usd) || hash_value(provider_payload, :cost_usd),
            actual_input_tokens:  hash_value(provider_payload, :input_tokens),
            actual_output_tokens: hash_value(provider_payload, :output_tokens),
            model_version:        hash_value(provider_payload, :model_version) || hash_value(provider_payload, :model)
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

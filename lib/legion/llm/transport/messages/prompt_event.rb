# frozen_string_literal: true

require_relative '../message'
require 'legion/llm/audit_projection'

module Legion
  module LLM
    module Transport
      module Messages
        class PromptEvent < Legion::LLM::Transport::Message
          ESSENTIAL_AUDIT_FIELDS = %i[
            request_id conversation_id task_id agent_id node_id caller identity
            request_type timestamp routing tokens cost provider_metrics context_accounting
            classification tracing tier message_context finish_reason
            provider model model_id provider_instance dispatch_path latency_ms route_attempts
            request_content_hash response_content_hash capture messages audit
          ].freeze

          def type        = 'llm.audit.prompt'
          def exchange    = Legion::LLM::Transport::Exchanges::Audit
          def routing_key = "audit.prompt.#{@options[:request_type]}"
          def priority    = 0
          def encrypt?    = Legion::Settings[:llm][:compliance][:encrypt_audit] == true
          def expiration  = nil

          def headers
            super.merge(classification_headers).merge(caller_headers).merge(retention_headers).merge(tier_header)
          end

          # Project the attributed body before transport validates the encoded
          # payload. Bound encryption expansion as well as cleartext JSON.
          def encode_message
            return @audit_encoded_message if @audit_encoded_message

            capture = @options[:capture]&.dup ||
                      Legion::LLM::AuditProjection.capture_metadata(message_count: Array(@options[:messages]).size)
            capture[:reasons] = capture[:reasons].dup
            capture[:payload_limit_bytes] = self.class.max_payload_bytes
            @options = Legion::LLM::AuditProjection.project_value(
              value: @options, binary_limit: Legion::LLM::AuditProjection.audit_max_binary_data_bytes,
              capture: capture, fingerprints: {}.compare_by_identity
            )
            @options[:capture] = capture
            @options = inject_runtime_caller_info(@options)
            binary_compacted = false
            # Bound work by candidate fields, message omission, one binary pass,
            # envelope/routing fields, and the final encoding check.
            projection_steps = audit_message_candidates.size + Array(@options[:messages]).size + @options.size + 4
            projection_steps += @options[:audit].size if @options[:audit].is_a?(Hash)
            projection_steps.times do
              encoded = super
              body_bytes = encrypt? ? Legion::JSON.dump(message).bytesize : encoded.bytesize
              return @audit_encoded_message = encoded if [body_bytes, encoded.bytesize].max <= capture[:payload_limit_bytes]

              unless binary_compacted
                @options = Legion::LLM::AuditProjection.project_value(
                  value: @options, binary_limit: -1, capture: capture, fingerprints: {}.compare_by_identity
                )
                @options[:capture] = capture
                binary_compacted = true
                next
              end
              break unless compact_bulky_audit_message(capture: capture) ||
                           omit_bulky_audit_field(capture: capture) || omit_oldest_audit_message(capture: capture)
            end
            raise Legion::Transport::PayloadTooLarge,
                  "minimum explicit prompt audit envelope exceeds limit of #{capture[:payload_limit_bytes]} bytes"
          end

          private

          def compact_bulky_audit_message(capture:, **)
            limit = [Legion::LLM::AuditProjection.audit_max_binary_data_bytes, capture[:payload_limit_bytes]].min
            omit_audit_value(candidates: audit_message_candidates, capture: capture, minimum_bytes: limit)
          end

          def audit_message_candidates(**)
            Array(@options[:messages]).flat_map do |message|
              next [] unless message.is_a?(Hash)

              candidates = message.keys.select { |key| %w[content metadata].include?(key.to_s) }.map { |key| [message, key] }
              calls = Legion::LLM::AuditProjection.hash_value(message, :tool_calls)
              Array(calls).each do |call|
                next unless call.is_a?(Hash)

                # Keep identity and execution state so tool results still link
                # to their calls even when the argument/result payload is large.
                candidates.concat(call.keys.select { |key| %w[arguments result error metadata].include?(key.to_s) }
                                      .map { |key| [call, key] })
              end
              candidates
            end
          end

          def omit_oldest_audit_message(capture:)
            messages = @options[:messages]
            return false unless messages.is_a?(Array) && messages.any?

            messages.shift
            capture[:captured_message_count] = messages.size
            capture[:omitted_message_count] += 1
            Legion::LLM::AuditProjection.mark_projection(capture: capture, reason: :payload_limit)
            true
          end

          def omit_bulky_audit_field(capture:)
            candidates = @options.keys.reject { |key| ESSENTIAL_AUDIT_FIELDS.include?(key) || ENVELOPE_KEYS.include?(key) }
                                 .map { |key| [@options, key] }
            audit = @options[:audit]
            candidates.concat(audit.keys.map { |key| [audit, key] }) if audit.is_a?(Hash)
            routing = @options[:routing]
            if routing.is_a?(Hash)
              candidates.concat(routing.keys.select { |key| %w[route_attempts escalation_chain].include?(key.to_s) }
                                       .map { |key| [routing, key] })
            end
            omit_audit_value(candidates: candidates, capture: capture)
          end

          def omit_audit_value(candidates:, capture:, minimum_bytes: 0, **)
            largest = candidates.filter_map do |container, key|
              value = container[key]
              next if value.is_a?(Hash) && value[:audit_omitted] == true

              serialized = Legion::JSON.dump(value)
              next if serialized.bytesize <= minimum_bytes

              omission = { audit_omitted: true, bytes: serialized.bytesize, sha256: '0' * 64 }
              omission.merge!(value.select { |field, _| %w[outcome severity duration_ms].include?(field.to_s) }) if container.equal?(@options[:audit]) && value.is_a?(Hash)
              saving = serialized.bytesize - Legion::JSON.dump(omission).bytesize
              [saving, container, key, omission, serialized] if saving.positive?
            end.max_by(&:first)
            return false unless largest

            _, container, key, omission, serialized = largest
            omission[:sha256] = Digest::SHA256.hexdigest(serialized)
            container[key] = omission
            capture[:omitted_field_count] += 1
            Legion::LLM::AuditProjection.mark_projection(capture: capture, reason: :payload_limit)
            true
          end

          def message_id_prefix = 'audit_prompt'

          def classification_headers
            cls = @options[:classification] || {}
            h = {}
            h['x-legion-classification'] = cls[:level].to_s if cls[:level]
            h['x-legion-contains-phi']   = cls[:contains_phi].to_s unless cls[:contains_phi].nil?
            h['x-legion-jurisdictions']  = Array(cls[:jurisdictions]).join(',') if cls[:jurisdictions]
            h
          end

          def caller_headers
            caller_raw = @options[:caller] || {}
            return {} unless caller_raw.is_a?(Hash)

            caller_info = caller_raw[:requested_by] || caller_raw['requested_by'] || caller_raw
            caller_info = {} unless caller_info.is_a?(Hash)
            top_id      = @options[:identity] || {}
            top_id      = {} unless top_id.is_a?(Hash)
            extension   = caller_raw[:extension] || caller_raw['extension']
            type        = caller_info[:type] || caller_info['type'] || top_id[:type] || top_id['type'] ||
                          (extension && 'extension')
            h = {}
            h['x-legion-request-caller-type'] = type.to_s if type
            h
          end

          def retention_headers
            cls = @options[:classification] || {}
            h = {}
            h['x-legion-retention'] = cls[:retention].to_s if cls[:retention]
            h
          end

          def tier_header
            h = {}
            h['x-legion-llm-tier'] = @options[:tier].to_s if @options[:tier]
            h
          end
        end
      end
    end
  end
end

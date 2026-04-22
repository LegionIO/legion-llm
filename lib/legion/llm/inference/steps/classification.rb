# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module Classification
          include Legion::Logging::Helper

          LEVELS = %i[public internal confidential restricted].freeze

          PII_PATTERNS_CORE = {
            ssn:   /\b\d{3}-\d{2}-\d{4}\b/,
            email: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
            phone: /\b(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b/
          }.freeze

          PII_PATTERNS_EXTENDED = {
            ip_address:     /\b(?:\d{1,3}\.){3}\d{1,3}\b/,
            date_of_birth:  %r{\b(?:0[1-9]|1[0-2])[/-](?:0[1-9]|[12]\d|3[01])[/-](?:19|20)\d{2}\b},
            zip_code:       /\b\d{5}(?:-\d{4})?\b/,
            mrn:            /\b(?:MRN|mrn)[:\s#]?\s?\d{4,12}\b/,
            account_number: /\b(?:account|acct)[:\s#]?\s?\d{6,20}\b/i,
            license_number: /\b[A-Z]\d{3,8}\b/,
            url:            %r{\bhttps?://[^\s<>"']+}i,
            vin:            /\b[A-HJ-NPR-Z0-9]{17}\b/,
            npi_number:     /\b\d{10}\b/
          }.freeze

          PII_PATTERNS = PII_PATTERNS_CORE.merge(PII_PATTERNS_EXTENDED).freeze

          PHI_KEYWORDS = %w[
            patient diagnosis medication prescription
            dob date-of-birth mrn medical-record
            npi clinical treatment health-plan
            beneficiary insurance-id group-number
            lab-result radiology pathology
            admission discharge procedure
          ].freeze

          def step_classification
            classification = @request.classification || compliance_classification_default || default_classification
            return unless classification_enabled?(classification)

            declared_level  = classification[:level]
            scan            = scan_content_for_sensitive_data
            effective_level = upgrade_if_needed(declared_level, scan)
            upgraded        = effective_level != declared_level

            redact_sensitive_content(scan)
            enforce_phi_cloud_gate(effective_level)

            @enrichments['classification:scan'] = {
              declared_level:    declared_level,
              effective_level:   effective_level,
              contains_pii:      scan[:contains_pii],
              contains_phi:      scan[:contains_phi],
              detected_patterns: scan[:patterns],
              upgraded:          upgraded,
              timestamp:         Time.now
            }

            if upgraded
              @warnings << "Classification upgraded from #{declared_level} to #{effective_level}: " \
                           "sensitive patterns detected (#{scan[:patterns].join(', ')})"
            end

            @audit[:'classification:scan'] = {
              outcome:     :success,
              detail:      "level=#{effective_level}, upgraded=#{upgraded}",
              data:        { declared: declared_level, effective: effective_level, patterns: scan[:patterns] },
              duration_ms: 0,
              timestamp:   Time.now
            }

            @timeline.record(
              category:  :audit, key: 'classification:scan',
              direction: :internal, detail: "level=#{effective_level}, upgraded=#{upgraded}",
              from:      'pipeline', to: 'classification'
            )
          end

          private

          def scan_content_for_sensitive_data
            text     = extract_text_content
            patterns = []
            active_patterns = strict_hipaa_mode? ? PII_PATTERNS : PII_PATTERNS_CORE

            active_patterns.each do |name, regex|
              patterns << name if text.match?(regex)
            end

            phi_found = PHI_KEYWORDS.any? { |kw| text.downcase.include?(kw) }
            patterns << :phi_keyword if phi_found

            {
              contains_pii: patterns.intersect?(active_patterns.keys),
              contains_phi: phi_found,
              patterns:     patterns
            }
          end

          def redact_sensitive_content(scan)
            return unless redaction_enabled?
            return unless scan[:contains_pii] || scan[:contains_phi]

            placeholder = redaction_placeholder
            active_patterns = strict_hipaa_mode? ? PII_PATTERNS : PII_PATTERNS_CORE

            @request.messages.each do |message|
              next unless message[:content].is_a?(String)

              active_patterns.each_value do |regex|
                message[:content] = message[:content].gsub(regex, placeholder)
              end

              next unless scan[:contains_phi]

              PHI_KEYWORDS.each do |kw|
                message[:content] = message[:content].gsub(/\b#{Regexp.escape(kw)}\b/i, placeholder)
              end
            end

            @enrichments['classification:redaction'] = {
              redacted:          true,
              patterns_redacted: scan[:patterns],
              placeholder:       placeholder,
              timestamp:         Time.now
            }
          end

          def extract_text_content
            @request.messages.map { |m| m[:content].to_s }.join(' ')
          end

          def upgrade_if_needed(declared_level, scan)
            return declared_level unless scan[:contains_pii] || scan[:contains_phi]

            current_idx   = LEVELS.index(declared_level) || 0
            threshold_idx = LEVELS.index(:restricted)

            return declared_level if current_idx >= threshold_idx

            LEVELS[threshold_idx]
          end

          def default_classification
            { level: default_classification_level }
          end

          def default_classification_level
            level = Legion::LLM.settings.dig(:compliance, :default_level)
            level ? level.to_sym : :public
          rescue StandardError
            :public
          end

          def classification_enabled?(_classification)
            enabled = Legion::LLM.settings.dig(:compliance, :classification_scan)
            enabled.nil? || enabled
          rescue StandardError
            true
          end

          def compliance_classification_default
            level = Legion::LLM.settings.dig(:compliance, :classification_level)
            return nil unless level

            { level: level.to_sym }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.classification.default')
            nil
          end

          def redaction_enabled?
            setting = Legion::LLM.settings.dig(:compliance, :redact_pii)
            setting == true
          rescue StandardError
            false
          end

          def strict_hipaa_mode?
            setting = Legion::LLM.settings.dig(:compliance, :strict_hipaa)
            setting == true
          rescue StandardError
            false
          end

          def redaction_placeholder
            Legion::LLM.settings.dig(:compliance, :redaction_placeholder) || '[REDACTED]'
          rescue StandardError
            '[REDACTED]'
          end

          def enforce_phi_cloud_gate(effective_level)
            return unless effective_level == :restricted

            provider = resolve_current_provider
            return unless cloud_provider?(provider)

            if phi_block_cloud?
              raise Legion::LLM::PipelineError.new(
                "Restricted/sensitive content (level=restricted) cannot be sent to cloud provider #{provider}. " \
                'Set compliance.phi_block_cloud=false to override, or use a local provider.',
                step: :classification
              )
            end

            log.warn(
              "[classification] Restricted/sensitive content (level=restricted) routing to cloud provider #{provider} — " \
              'compliance.phi_block_cloud is disabled, permitting'
            )
            @warnings << "Restricted/sensitive content routing to cloud provider #{provider} (phi_block_cloud disabled)"
          end

          def phi_block_cloud?
            setting = Legion::LLM.settings.dig(:compliance, :phi_block_cloud)
            setting == true
          rescue StandardError
            false
          end

          def cloud_provider?(provider)
            return false unless provider

            cloud_providers = Legion::LLM.settings.dig(:compliance, :cloud_providers) ||
                              %i[anthropic openai gemini bedrock azure]
            cloud_providers.map(&:to_sym).include?(provider.to_sym)
          rescue StandardError
            false
          end

          def resolve_current_provider
            routing = @request.respond_to?(:routing) ? @request.routing : nil
            provider = routing[:provider] if routing.is_a?(Hash)
            provider ||= Legion::Settings.dig(:llm, :default_provider)
            provider&.to_sym
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end

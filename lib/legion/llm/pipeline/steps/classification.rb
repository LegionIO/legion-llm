# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module Classification
          include Legion::Logging::Helper

          LEVELS = %i[public internal confidential restricted].freeze

          PII_PATTERNS = {
            ssn:   /\b\d{3}-\d{2}-\d{4}\b/,
            email: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
            phone: /\b(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b/
          }.freeze

          PHI_KEYWORDS = %w[
            patient diagnosis medication prescription
            dob date-of-birth mrn medical-record
            npi clinical treatment
          ].freeze

          def step_classification
            return unless @request.classification || compliance_classification_default

            classification  = @request.classification || compliance_classification_default
            declared_level  = classification[:level]
            scan            = scan_content_for_sensitive_data
            effective_level = upgrade_if_needed(declared_level, scan)
            upgraded        = effective_level != declared_level

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

            PII_PATTERNS.each do |name, regex|
              patterns << name if text.match?(regex)
            end

            phi_found = PHI_KEYWORDS.any? { |kw| text.downcase.include?(kw) }
            patterns << :phi_keyword if phi_found

            {
              contains_pii: patterns.intersect?(PII_PATTERNS.keys),
              contains_phi: phi_found,
              patterns:     patterns
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

          def compliance_classification_default
            return nil unless defined?(Legion::Settings)

            level = Legion::Settings.dig(:compliance, :classification_level)
            return nil unless level

            { level: level.to_sym }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.classification.default')
            nil
          end
        end
      end
    end
  end
end

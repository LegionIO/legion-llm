# frozen_string_literal: true

module Legion
  module LLM
    module API
      module Namespaces
        module Anthropic
          # Models provides Anthropic-format model serialization helpers.
          # These are called by the unified /v1/models namespace (OpenAI::Models)
          # when detect_client(env) identifies an Anthropic client.
          # There are NO routes here -- do NOT register this as a Sinatra::Extension
          # under /v1/models; that path is already owned by OpenAI::Models.
          module Models
            MODEL_CREATED_AT = '2025-01-01T00:00:00Z'

            def self.format_model_list(offerings)
              seen = {}
              model_list = offerings.filter_map do |offering|
                id = offering[:model].to_s
                next if seen[id]

                seen[id] = true
                format_model(offering)
              end

              {
                data:     model_list,
                has_more: false,
                first_id: model_list.first&.fetch(:id, nil),
                last_id:  model_list.last&.fetch(:id, nil)
              }
            end

            def self.format_model(offering)
              id = offering[:model].to_s
              {
                id:           id,
                type:         'model',
                display_name: id.split(/[-_]/).map(&:capitalize).join(' '),
                created_at:   MODEL_CREATED_AT
              }
            end
          end
        end
      end
    end
  end
end

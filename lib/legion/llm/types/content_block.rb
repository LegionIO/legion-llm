# frozen_string_literal: true

module Legion
  module LLM
    module Types
      ContentBlock = ::Data.define(
        :type, :text, :data, :source_type, :media_type,
        :detail, :name, :file_id,
        :id, :input, :tool_use_id, :is_error,
        :source, :start_index, :end_index,
        :code, :message, :cache_control
      ) do
        def self.text(content, cache_control: nil)
          build_with(type: :text, text: content, cache_control: cache_control)
        end

        def self.thinking(content)
          build_with(type: :thinking, text: content)
        end

        def self.tool_use(id:, name:, input:)
          build_with(type: :tool_use, id: id, name: name, input: input)
        end

        def self.tool_result(tool_use_id:, content:, is_error: false)
          build_with(type: :tool_result, tool_use_id: tool_use_id, text: content, is_error: is_error)
        end

        def self.image(data:, media_type:, source_type: :base64, detail: nil)
          build_with(type: :image, data: data, media_type: media_type,
                     source_type: source_type, detail: detail)
        end

        def self.from_hash(hash)
          hash = hash.transform_keys(&:to_sym) if hash.respond_to?(:transform_keys)
          build_with(**hash)
        end

        def self.build_with(**overrides)
          defaults = {
            type: nil, text: nil, data: nil, source_type: nil, media_type: nil,
            detail: nil, name: nil, file_id: nil, id: nil, input: nil,
            tool_use_id: nil, is_error: nil, source: nil, start_index: nil,
            end_index: nil, code: nil, message: nil, cache_control: nil
          }
          new(**defaults, **overrides)
        end

        def to_h
          super.compact
        end
      end
    end
  end
end

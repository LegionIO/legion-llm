# frozen_string_literal: true

require 'securerandom'

module Legion
  module LLM
    module Types
      ToolCall = ::Data.define(
        :id, :exchange_id, :name, :arguments, :source,
        :status, :duration_ms, :result, :error,
        :started_at, :finished_at
      ) do
        def self.build(**kwargs)
          new(
            id:          kwargs[:id] || "call_#{SecureRandom.hex(12)}",
            exchange_id: kwargs[:exchange_id],
            name:        kwargs[:name],
            arguments:   kwargs[:arguments] || {},
            source:      kwargs[:source],
            status:      kwargs[:status],
            duration_ms: kwargs[:duration_ms],
            result:      kwargs[:result],
            error:       kwargs[:error],
            started_at:  kwargs[:started_at],
            finished_at: kwargs[:finished_at]
          )
        end

        def self.from_hash(hash)
          hash = hash.transform_keys(&:to_sym) if hash.respond_to?(:transform_keys)
          build(**hash)
        end

        def success?
          status == :success
        end

        def error?
          status == :error
        end

        def with_result(result:, status:, duration_ms: nil, finished_at: nil)
          ToolCall.new(
            id:          id,
            exchange_id: exchange_id,
            name:        name,
            arguments:   arguments,
            source:      source,
            status:      status,
            duration_ms: duration_ms,
            result:      result,
            error:       status == :error ? result : error,
            started_at:  started_at,
            finished_at: finished_at || Time.now
          )
        end

        def to_h
          super.compact
        end

        def to_audit_hash
          { id: id, name: name, arguments: arguments, status: status,
            duration_ms: duration_ms, error: error, exchange_id: exchange_id }.compact
        end
      end
    end
  end
end

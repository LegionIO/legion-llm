# frozen_string_literal: true

module Legion
  module LLM
    module Skills
      SkillRunResult = ::Data.define(:inject, :gated, :gate, :resume_at, :complete) do
        def self.build(inject:, gated:, gate:, resume_at:, complete:)
          new(inject: inject, gated: gated, gate: gate, resume_at: resume_at, complete: complete)
        end
      end
    end
  end
end

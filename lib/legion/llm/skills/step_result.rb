# frozen_string_literal: true

module Legion
  module LLM
    module Skills
      StepResult = Data.define(:inject, :gate, :metadata) do
        def self.build(inject:, gate: nil, metadata: {})
          new(inject: inject, gate: gate, metadata: metadata)
        end
      end
    end
  end
end

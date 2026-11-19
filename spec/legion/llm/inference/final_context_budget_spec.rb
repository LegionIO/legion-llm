# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Final dispatch context budget' do
  def executor_with_headroom(ppm)
    Legion::Settings[:llm][:router][:context_headroom_ppm] = ppm
    Legion::LLM::Routing::SettingsState.reset!
    request = Legion::LLM::Inference::Request.build(messages: ['test'])
    executor = Legion::LLM::Inference::Executor.new(request)
    executor.instance_variable_set(:@resolved_offering_metadata, { limits: { context_window: 1000 } })
    executor
  end

  [800_000, 950_000].each do |ppm|
    [-1, 0, 1].each do |offset|
      it "uses configured headroom #{ppm} at boundary offset #{offset}" do
        executor = executor_with_headroom(ppm)
        threshold = ppm / 1000
        # One message token plus the system payload; use the real estimator.
        options = { system: 's' * ((threshold + offset - 1) * 4) }
        operation = proc { executor.send(:enforce_final_context_budget!, ['test'], options) }

        if offset.positive?
          expect(&operation).to raise_error(Legion::LLM::ContextOverflow, /dispatch threshold #{threshold}/)
        else
          expect(&operation).not_to raise_error
        end
      end
    end
  end

  it 'keeps the request snapshot through a settings reload while new requests use the new budget' do
    existing = executor_with_headroom(950_000)
    newer = executor_with_headroom(800_000)
    options = { system: 's' * 3600 }

    expect { existing.send(:enforce_final_context_budget!, ['test'], options) }.not_to raise_error
    expect { newer.send(:enforce_final_context_budget!, ['test'], options) }
      .to raise_error(Legion::LLM::ContextOverflow, /dispatch threshold 800/)
  end

  it 'still includes tool schemas in the final payload bound' do
    executor = executor_with_headroom(950_000)
    options = { system: 's' * 3600, tools: [{ name: 'lookup', description: 'd' * 400 }] }

    expect { executor.send(:enforce_final_context_budget!, ['test'], options) }
      .to raise_error(Legion::LLM::ContextOverflow, /dispatch threshold 950/)
  end
end

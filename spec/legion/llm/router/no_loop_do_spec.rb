# frozen_string_literal: true

require 'spec_helper'

# D-C / G26 / sonnet B4 — P5 commit 1 implementation (updated for SSOT v3)
RSpec.describe 'Executor bounded iteration — no loop do (P5)' do
  it 'executor uses bounded iteration; no loop do; no retry/redo inside attempts loop' do
    src = File.read('lib/legion/llm/inference/executor.rb')
    expect(src).not_to match(/^\s*loop do\b/)
    expect(src).not_to match(/^\s*retry\b/)
    expect(src).not_to match(/^\s*redo\b/)
  end

  it 'escalation module uses bounded maximum_attempts iteration; no loop do; no retry/redo' do
    # SSOT v3: the RoutingSession loop is bounded by maximum_attempts.times do,
    # replacing the legacy while remaining.positive? pattern. The invariant
    # that matters is bounded iteration — no loop do, no retry, no redo.
    src = File.read('lib/legion/llm/inference/executor/escalation.rb')
    expect(src).to match(/maximum_attempts\.times do/)
    expect(src).not_to match(/^\s*loop do\b/)
    expect(src).not_to match(/^\s*retry\b/)
    expect(src).not_to match(/^\s*redo\b/)
  end
end

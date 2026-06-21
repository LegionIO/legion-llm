# frozen_string_literal: true

require 'spec_helper'

# D-C / G26 / sonnet B4 — P5 commit 1 implementation
RSpec.describe 'Executor bounded iteration — no loop do (P5)' do
  it 'executor uses bounded iteration; no loop do; no retry/redo inside attempts loop' do
    src = File.read('lib/legion/llm/inference/executor.rb')
    expect(src).not_to match(/^\s*loop do\b/)
    expect(src).not_to match(/^\s*retry\b/)
    expect(src).not_to match(/^\s*redo\b/)
  end

  it 'escalation module uses while remaining.positive? not attempts.times do or loop do' do
    src = File.read('lib/legion/llm/inference/executor/escalation.rb')
    expect(src).to match(/while remaining\.positive\?/)
    expect(src).not_to match(/attempts\.times do/)
    expect(src).not_to match(/^\s*loop do\b/)
    expect(src).not_to match(/^\s*retry\b/)
    expect(src).not_to match(/^\s*redo\b/)
  end
end

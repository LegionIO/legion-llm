# frozen_string_literal: true

require 'spec_helper'

# D-C / G26 / sonnet B4 — pending P5 commit 1
RSpec.describe 'Executor bounded iteration — no loop do (P5)' do
  before { skip 'P5: executor stateless loop' }

  it 'executor uses bounded iteration; no loop do; no retry/redo inside attempts loop' do
    src = File.read('lib/legion/llm/inference/executor.rb')
    expect(src).not_to match(/^\s*loop do\b/)
    expect(src).not_to match(/^\s*retry\b/)
    expect(src).not_to match(/^\s*redo\b/)
  end
end

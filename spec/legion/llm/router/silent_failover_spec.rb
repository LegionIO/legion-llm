# frozen_string_literal: true

require 'spec_helper'

# G30 / N×N invariant 5 — pending P5 commit 3
RSpec.describe 'Mid-stream failover is silent (P5)' do
  before { skip 'P5: executor stateless loop' }

  def capture_sse_events_during_failover
    raise NotImplementedError, 'implement SSE capture fixture in P5'
  end

  def response_trailers
    raise NotImplementedError, 'implement response_trailers accessor in P5'
  end

  it 'mid-stream failover emits debug trailers, not a wire-level SSE event' do
    events = capture_sse_events_during_failover
    expect(events.map { _1[:type] }).not_to include(:'provider-switch')
    expect(response_trailers).to include('x-legion-failover-from', 'x-legion-failover-to')
  end
end

# frozen_string_literal: true

require 'spec_helper'

# G31 / opus M7 — pending P5 commit 2
RSpec.describe 'Header validation strict (P5)' do
  before { skip 'P5: executor stateless loop' }

  def minimal_body
    { model: 'gemma-12b', messages: [{ role: 'user', content: 'hi' }] }
  end

  it 'returns 400 for unknown x-legion-tiers value' do
    resp = post('/v1/chat/completions', body: minimal_body, headers: { 'x-legion-tiers' => 'xyz' })
    expect(resp.status).to eq(400)
    expect(resp.body).to include('invalid_header')
    expect(resp.body).to include('x-legion-tiers')
    expect(resp.body).to include('valid')
  end
end

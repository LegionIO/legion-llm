# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/body_model_hint_policy'

RSpec.describe Legion::LLM::Router::BodyModelHintPolicy do
  # Lightweight stub of our own (not-yet-integrated) settings snapshot. Phase 1
  # BodyModelHintDecision is the REAL released type.
  let(:snap_class) do
    Struct.new(
      :allow_body_routing_hints, :body_model_hint_whitelist, :body_model_hint_blacklist,
      :auto_routing_model_aliases, :generation, keyword_init: true
    )
  end

  def snap(allow: true, whitelist: [], blacklist: [], aliases: %w[legionio auto copilot-utility-small], gen: 3)
    snap_class.new(allow_body_routing_hints: allow, body_model_hint_whitelist: whitelist,
                   body_model_hint_blacklist: blacklist, auto_routing_model_aliases: aliases, generation: gen)
  end

  def call(body:, trusted: nil, **snap_opts)
    described_class.call(body_model: body, trusted_model: trusted, settings_snapshot: snap(**snap_opts))
  end

  it 'blank body → absent with nil requested_model' do
    d = call(body: '   ')
    expect(d.disposition).to eq(:absent)
    expect(d.requested_model).to be_nil
    expect(d.model_constraint).to be_nil
    expect(d.settings_generation).to eq(3)
  end

  it 'nil body → absent' do
    expect(call(body: nil).disposition).to eq(:absent)
  end

  it 'body + trusted model → superseded_by_explicit_model, no constraint' do
    d = call(body: 'claude-haiku', trusted: 'gpt-5')
    expect(d.disposition).to eq(:superseded_by_explicit_model)
    expect(d.model_constraint).to be_nil
    expect(d.requested_model).to eq('claude-haiku')
  end

  it 'auto aliases (legionio/auto/copilot-utility-small) → auto, no constraint' do
    %w[legionio auto copilot-utility-small LEGIONIO  Auto ].each do |m|
      expect(call(body: m).disposition).to eq(:auto)
    end
  end

  it 'allow_body_routing_hints=false → ignored_disabled' do
    d = call(body: 'claude-haiku', allow: false)
    expect(d.disposition).to eq(:ignored_disabled)
    expect(d.model_constraint).to be_nil
  end

  it 'empty whitelist+blacklist honors any non-auto model' do
    d = call(body: 'gemma4')
    expect(d.disposition).to eq(:honored)
    expect(d.model_constraint).to eq('gemma4')
  end

  it 'nonempty whitelist with no match → ignored_not_whitelisted (case-insensitive substring)' do
    expect(call(body: 'claude-haiku', whitelist: %w[qwen]).disposition).to eq(:ignored_not_whitelisted)
    honored = call(body: 'QWEN-32B', whitelist: %w[qwen])
    expect(honored.disposition).to eq(:honored)
    expect(honored.matched_whitelist).to eq('qwen')
  end

  it 'blacklist match → ignored_blacklisted (substring, not regex)' do
    d = call(body: 'claude-3-5-haiku-20241022', blacklist: %w[haiku])
    expect(d.disposition).to eq(:ignored_blacklisted)
    expect(d.matched_blacklist).to eq('haiku')
    exact = call(body: 'gpt-5-nano', blacklist: %w[gpt-5-nano])
    expect(exact.disposition).to eq(:ignored_blacklisted)
  end

  it 'blacklist wins even when whitelist matches' do
    d = call(body: 'claude-haiku', whitelist: %w[claude], blacklist: %w[haiku])
    expect(d.disposition).to eq(:ignored_blacklisted)
  end
end

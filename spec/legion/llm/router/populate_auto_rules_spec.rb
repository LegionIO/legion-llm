# frozen_string_literal: true

require 'spec_helper'

# G8 / L4: populate_auto_rules is a one-release no-op stub (P5 commit 5).
# Paired GitHub issues: #155 (remove stub, blocked-by #154), #154 (9-gem checklist).
RSpec.describe 'Router.populate_auto_rules no-op stub (P5)' do
  before { Legion::LLM::Router.reset! }

  it 'is a no-op — returns nil, does not raise' do
    expect { Legion::LLM::Router.populate_auto_rules }.not_to raise_error
    expect(Legion::LLM::Router.populate_auto_rules).to be_nil
  end

  it 'emits a one-time deprecation warning' do
    allow(Legion::LLM::Router).to receive(:log).and_return(
      instance_double('Logger', warn: nil, debug: nil, info: nil)
    )
    Legion::LLM::Router.populate_auto_rules
    expect(Legion::LLM::Router.log).to have_received(:warn).with(/deprecated/).once
  end

  it 'does NOT warn on the second call (one-time only)' do
    allow(Legion::LLM::Router).to receive(:log).and_return(
      instance_double('Logger', warn: nil, debug: nil, info: nil)
    )
    Legion::LLM::Router.populate_auto_rules
    Legion::LLM::Router.populate_auto_rules
    expect(Legion::LLM::Router.log).to have_received(:warn).once
  end

  it 'accepts kwargs + ** without raising (lex-llm-* callers pass discovered_instances)' do
    expect { Legion::LLM::Router.populate_auto_rules(discovered_instances: [:h200], extra: 'ignored') }
      .not_to raise_error
  end

  it 'resets the warned flag on Router.reset!' do
    allow(Legion::LLM::Router).to receive(:log).and_return(
      instance_double('Logger', warn: nil, debug: nil, info: nil)
    )
    Legion::LLM::Router.populate_auto_rules
    Legion::LLM::Router.reset!
    Legion::LLM::Router.populate_auto_rules
    expect(Legion::LLM::Router.log).to have_received(:warn).twice
  end
end

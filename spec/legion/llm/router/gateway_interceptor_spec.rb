# frozen_string_literal: true

require 'spec_helper'

# Custom OpenAI-compatible endpoints (corporate proxies, Kong AI Gateway, UAIS, etc.)
# are not a separate tier. They register as :cloud (org-internal proxy) or :frontier
# (direct frontier model access) — the tier describes topology, not wire format.
# Wire format (OpenAI /v1/chat/completions vs /v1/responses) is a provider capability
# declared on the adapter via LexLLMAdapter#supports?(:responses).

RSpec.describe 'Custom OpenAI-compatible provider routing' do
  before do
    Legion::LLM::Router.reset!
    Legion::LLM::Call::Registry.reset!
    allow(Legion::LLM::Router).to receive(:privacy_mode?).and_return(false)

    # Register only the custom proxy provider (no competing cloud providers)
    Legion::LLM::Call::Registry.register(
      :openai,
      Module.new,
      instance: :corp_proxy,
      metadata: {
        tier:          :cloud,
        default_model: 'proxy-gpt-4o',
        api_base:      'https://proxy.example.com/v1',
        source:        'lex-llm-openai'
      }
    )
  end

  it 'resolves a custom OpenAI-compatible proxy registered as cloud tier' do
    result = Legion::LLM::Router.resolve(tier: :cloud)

    expect(result).not_to be_nil
    expect(result.provider).to eq(:openai)
    expect(result.instance).to eq(:corp_proxy)
    expect(result.model).to eq('proxy-gpt-4o')
    expect(result.metadata).to include(
      api_base: 'https://proxy.example.com/v1',
      source:   'lex-llm-openai'
    )
  end

  it 'reports cloud tier as external' do
    result = Legion::LLM::Router.resolve(tier: :cloud)
    expect(result.external?).to be true
  end
end

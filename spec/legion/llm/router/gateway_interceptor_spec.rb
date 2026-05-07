# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'OpenAI-compatible provider-instance routing' do
  before do
    Legion::LLM::Router.reset!
    allow(Legion::LLM::Router).to receive(:privacy_mode?).and_return(false)

    Legion::LLM::Call::Registry.register(
      :openai,
      Module.new,
      instance: :corp_proxy,
      metadata: {
        tier:          :openai_compat,
        default_model: 'proxy-gpt-4o',
        api_base:      'https://proxy.example.com/v1',
        source:        'lex-llm-openai'
      }
    )
  end

  it 'makes openai_compat available from a lex-llm-openai provider instance' do
    expect(Legion::LLM::Router.tier_available?(:openai_compat)).to be true
  end

  it 'resolves openai_compat to the registered OpenAI-compatible provider instance' do
    result = Legion::LLM::Router.resolve(tier: :openai_compat)

    expect(result.provider).to eq(:openai)
    expect(result.instance).to eq(:corp_proxy)
    expect(result.model).to eq('proxy-gpt-4o')
    expect(result.metadata).to include(
      api_base: 'https://proxy.example.com/v1',
      source:   'lex-llm-openai'
    )
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Providers, 'native provider config preparation' do
  let(:host) do
    Class.new do
      include Legion::LLM::Providers
      include Legion::Logging::Helper

      def settings
        Legion::LLM.settings
      end
    end.new
  end

  before do
    hide_const('Legion::Identity::Broker')
  end

  it 'resolves and stores Anthropic API keys without provider-global config writes' do
    config = { api_key: 'sk-ant', base_url: 'https://gateway.example.com' }

    host.send(:configure_anthropic, config)

    expect(config[:api_key]).to eq('sk-ant')
    expect(config[:base_url]).to eq('https://gateway.example.com')
  end

  it 'resolves and stores OpenAI API keys from string-keyed config' do
    config = { 'api_key' => 'sk-oai', 'base_url' => 'https://gateway.example.com' }

    host.send(:configure_openai, config)

    expect(config['api_key']).to eq('sk-oai')
    expect(config['base_url']).to eq('https://gateway.example.com')
  end

  it 'resolves and stores Gemini API keys without touching provider-global state' do
    config = { api_key: 'gem-key', base_url: 'https://gateway.example.com' }

    host.send(:configure_gemini, config)

    expect(config[:api_key]).to eq('gem-key')
    expect(config[:base_url]).to eq('https://gateway.example.com')
  end
end

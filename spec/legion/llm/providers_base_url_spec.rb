# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Providers, 'base_url forwarding' do
  let(:host) do
    Class.new do
      include Legion::LLM::Providers
      include Legion::Logging::Helper

      def settings
        Legion::LLM.settings
      end
    end.new
  end

  let(:ruby_llm_config) { double('config') }

  before do
    allow(RubyLLM).to receive(:configure).and_yield(ruby_llm_config)
    hide_const('Legion::Identity::Broker')
  end

  describe '#configure_anthropic' do
    before do
      allow(ruby_llm_config).to receive(:anthropic_api_key=)
      allow(ruby_llm_config).to receive(:anthropic_api_base=)
    end

    it 'sets anthropic_api_base when base_url is present' do
      host.send(:configure_anthropic, { api_key: 'sk-ant', base_url: 'https://gateway.example.com' })
      expect(ruby_llm_config).to have_received(:anthropic_api_base=).with('https://gateway.example.com')
    end

    it 'does not set anthropic_api_base when base_url is absent' do
      host.send(:configure_anthropic, { api_key: 'sk-ant' })
      expect(ruby_llm_config).not_to have_received(:anthropic_api_base=)
    end
  end

  describe '#configure_openai' do
    before do
      allow(ruby_llm_config).to receive(:openai_api_key=)
      allow(ruby_llm_config).to receive(:openai_api_base=)
    end

    it 'sets openai_api_base when base_url is present' do
      host.send(:configure_openai, { api_key: 'sk-oai', base_url: 'https://gateway.example.com' })
      expect(ruby_llm_config).to have_received(:openai_api_base=).with('https://gateway.example.com')
    end

    it 'does not set openai_api_base when base_url is absent' do
      host.send(:configure_openai, { api_key: 'sk-oai' })
      expect(ruby_llm_config).not_to have_received(:openai_api_base=)
    end
  end

  describe '#configure_gemini' do
    before do
      allow(ruby_llm_config).to receive(:gemini_api_key=)
      allow(ruby_llm_config).to receive(:gemini_api_base=)
    end

    it 'sets gemini_api_base when base_url is present' do
      host.send(:configure_gemini, { api_key: 'gem-key', base_url: 'https://gateway.example.com' })
      expect(ruby_llm_config).to have_received(:gemini_api_base=).with('https://gateway.example.com')
    end

    it 'does not set gemini_api_base when base_url is absent' do
      host.send(:configure_gemini, { api_key: 'gem-key' })
      expect(ruby_llm_config).not_to have_received(:gemini_api_base=)
    end
  end
end

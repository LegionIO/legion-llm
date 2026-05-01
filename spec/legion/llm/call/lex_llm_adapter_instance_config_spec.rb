# frozen_string_literal: true

require 'spec_helper'

begin
  require 'legion/extensions/llm'
  require 'legion/extensions/llm/provider' unless defined?(::Legion::Extensions::Llm::Provider)
  require 'legion/extensions/llm/ollama'
rescue LoadError
  nil
end

RSpec.describe Legion::LLM::Call::LexLLMAdapter, 'per-instance config' do
  before do
    skip 'lex-llm ollama provider not available' unless defined?(::Legion::Extensions::Llm::Ollama)
    # Ensure ollama_api_base= is available — provider gem must have registered its options
    config_probe = Legion::Extensions::Llm::Configuration.new
    skip 'ollama_api_base= not registered on Configuration — provider options not loaded' unless config_probe.respond_to?(:ollama_api_base=)
  end

  let(:namespace) { ::Legion::Extensions::Llm }

  let(:provider_class) do
    ns = namespace
    Class.new(ns::Provider) do
      define_method(:llm_namespace) { ns }
      def api_base = @config.ollama_api_base

      def complete(_messages, model:, **)
        llm_namespace::Message.new(role: :assistant, content: "hello #{model.id}", model_id: model.id,
                                   input_tokens: 7, output_tokens: 3)
      end
    end
  end

  it 'applies instance_config to produce a provider with that config value' do
    adapter = described_class.new(:ollama, provider_class, instance_config: { ollama_api_base: 'http://localhost:11434' })
    result = adapter.chat(model: 'test', messages: [{ role: 'user', content: 'hi' }])
    expect(result[:result]).to eq('hello test')
  end

  it 'produces distinct providers for different instance configs' do
    adapter_local = described_class.new(
      :ollama, provider_class,
      instance_config: { ollama_api_base: 'http://localhost:11434' }
    )
    adapter_remote = described_class.new(
      :ollama, provider_class,
      instance_config: { ollama_api_base: 'http://10.11.164.92:11434' }
    )

    # Force provider creation by calling chat
    adapter_local.chat(model: 'test', messages: [{ role: 'user', content: 'hi' }])
    adapter_remote.chat(model: 'test', messages: [{ role: 'user', content: 'hi' }])

    local_base = adapter_local.send(:provider).instance_variable_get(:@config).ollama_api_base
    remote_base = adapter_remote.send(:provider).instance_variable_get(:@config).ollama_api_base

    expect(local_base).to eq('http://localhost:11434')
    expect(remote_base).to eq('http://10.11.164.92:11434')
    expect(local_base).not_to eq(remote_base)
  end

  it 'does not mutate the global config' do
    global_base_before = namespace.config.ollama_api_base

    described_class.new(
      :ollama, provider_class,
      instance_config: { ollama_api_base: 'http://custom:9999' }
    ).chat(model: 'test', messages: [{ role: 'user', content: 'hi' }])

    expect(namespace.config.ollama_api_base).to eq(global_base_before)
  end

  it 'uses the global config when instance_config is empty (backward compatible)' do
    adapter = described_class.new(:ollama, provider_class)
    adapter.chat(model: 'test', messages: [{ role: 'user', content: 'hi' }])

    provider_config = adapter.send(:provider).instance_variable_get(:@config)
    expect(provider_config).to eq(namespace.config)
  end

  it 'warns about unknown config keys and skips them' do
    log_double = instance_double('Logger')
    allow(log_double).to receive(:warn)

    adapter = described_class.new(
      :ollama, provider_class,
      instance_config: { totally_bogus_option: 'whatever', ollama_api_base: 'http://localhost:11434' }
    )

    # The adapter includes Legion::Logging::Helper which provides #log
    allow(adapter).to receive(:log).and_return(log_double)

    adapter.chat(model: 'test', messages: [{ role: 'user', content: 'hi' }])

    expect(log_double).to have_received(:warn).with(/unknown config option totally_bogus_option/)
  end
end

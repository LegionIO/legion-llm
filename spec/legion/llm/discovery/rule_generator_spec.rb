# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/rule_generator'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Discovery::RuleGenerator do
  before do
    Legion::LLM::Router.reset!
  end

  let(:ollama_instances) do
    {
      default: {
        models: [
          { 'name' => 'llama3.1:8b', 'size' => 4_700_000_000,
            'capabilities' => %i[completion tools], 'context_length' => 131_072,
            'parameter_count' => 8_000_000_000 },
          { 'name' => 'qwen2.5:32b', 'size' => 20_000_000_000,
            'capabilities' => %i[completion vision tools thinking], 'context_length' => 262_144 },
          { 'name' => 'nomic-embed-text', 'size' => 274_000_000,
            'capabilities' => [:embedding], 'context_length' => 8_192 }
        ]
      }
    }
  end

  let(:vllm_instances) do
    {
      gpu1: {
        models: [
          { name: 'Qwen/Qwen2.5-72B-Instruct', id: 'Qwen/Qwen2.5-72B-Instruct',
            context_length: 131_072 },
          { name: 'text-embedding-ada-002', id: 'text-embedding-ada-002' }
        ]
      }
    }
  end

  let(:discovered) do
    { ollama: ollama_instances, vllm: vllm_instances }
  end

  describe '.generate' do
    subject(:rules) { described_class.generate(discovered) }

    it 'returns an array of rule hashes' do
      expect(rules).to be_an(Array)
      expect(rules).to all(be_a(Hash))
    end

    it 'generates embed rules for embedding models (Ollama name-match)' do
      embed_rules = rules.select { |r| r[:name].include?('nomic-embed-text') }
      expect(embed_rules.size).to eq(1)
      expect(embed_rules.first[:when]).to eq({ capability: :embed })
    end

    it 'generates chat + stream rules for inference models' do
      llama_rules = rules.select { |r| r[:name].include?('llama3.1:8b') }
      capabilities = llama_rules.map { |r| r[:when][:capability] }
      expect(capabilities).to contain_exactly(:chat, :stream)
    end

    it 'does not generate stream rules for embedding models' do
      embed_stream = rules.select { |r| r[:name].include?('nomic-embed-text') && r[:when][:capability] == :stream }
      expect(embed_stream).to be_empty
    end

    it 'assigns :local tier for ollama models' do
      ollama_rule = rules.find { |r| r[:name].include?('ollama') }
      expect(ollama_rule[:then][:tier]).to eq(:local)
    end

    it 'assigns :fleet tier for vllm models' do
      vllm_rule = rules.find { |r| r[:name].include?('vllm') }
      expect(vllm_rule[:then][:tier]).to eq(:fleet)
    end

    it 'includes instance in the target' do
      rule = rules.find { |r| r[:name].include?('gpu1') }
      expect(rule[:then][:instance]).to eq(:gpu1)
    end

    it 'sorts rules by descending priority' do
      priorities = rules.map { |r| r[:priority] }
      expect(priorities).to eq(priorities.sort.reverse)
    end

    it 'skips cloud providers not in DISCOVERABLE_PROVIDERS' do
      cloud_discovered = { bedrock: { default: { models: [{ name: 'claude-v3' }] } } }
      cloud_rules = described_class.generate(cloud_discovered)
      expect(cloud_rules).to be_empty
    end

    it 'skips providers with non-Hash instances' do
      bad = { ollama: 'not a hash' }
      expect(described_class.generate(bad)).to be_empty
    end

    it 'skips models with empty names' do
      empty_name = { ollama: { default: { models: [{ 'name' => '' }] } } }
      expect(described_class.generate(empty_name)).to be_empty
    end

    it 'handles vllm embedding models via name pattern matching' do
      vllm_embed = rules.select { |r| r[:name].include?('text-embedding-ada-002') }
      expect(vllm_embed.size).to eq(1)
      expect(vllm_embed.first[:when][:capability]).to eq(:embed)
    end
  end

  describe '.embedding_model?' do
    it 'uses capability data when available - embedding' do
      model = { 'name' => 'custom-embed', 'capabilities' => [:embedding] }
      expect(described_class.embedding_model?(model)).to be true
    end

    it 'uses capability data when available - not embedding' do
      model = { 'name' => 'nomic-embed-text', 'capabilities' => %i[completion tools] }
      expect(described_class.embedding_model?(model)).to be false
    end

    it 'falls back to name matching when no capabilities' do
      expect(described_class.embedding_model?('mxbai-embed-large')).to be true
    end

    it 'recognizes nomic-embed as embedding via name' do
      expect(described_class.embedding_model?('nomic-embed-text')).to be true
    end

    it 'recognizes bge- as embedding via name' do
      expect(described_class.embedding_model?('bge-large-en')).to be true
    end

    it 'recognizes snowflake-arctic-embed as embedding via name' do
      expect(described_class.embedding_model?('snowflake-arctic-embed')).to be true
    end

    it 'recognizes text-embedding as embedding via name' do
      expect(described_class.embedding_model?('text-embedding-ada-002')).to be true
    end

    it 'recognizes titan-embed as embedding via name' do
      expect(described_class.embedding_model?('titan-embed-text-v2')).to be true
    end

    it 'does not flag llama3 as embedding' do
      expect(described_class.embedding_model?('llama3:8b')).to be false
    end

    it 'does not flag qwen as embedding' do
      expect(described_class.embedding_model?('qwen2.5:32b')).to be false
    end

    it 'falls back to name matching for hash without capabilities' do
      model = { 'name' => 'nomic-embed-text' }
      expect(described_class.embedding_model?(model)).to be true
    end

    it 'falls back to name matching for hash with empty capabilities' do
      model = { 'name' => 'nomic-embed-text', 'capabilities' => [] }
      expect(described_class.embedding_model?(model)).to be true
    end
  end

  describe '.build_rule' do
    context 'with string model name' do
      subject(:rule) { described_class.build_rule(:ollama, :default, 'llama3:8b', :chat, :local, 100) }

      it 'builds a properly structured rule hash' do
        expect(rule).to include(:name, :when, :then, :priority)
      end

      it 'names the rule with auto: prefix' do
        expect(rule[:name]).to start_with('auto:')
      end

      it 'includes provider, instance, model, and tier in the target' do
        expect(rule[:then]).to eq({ provider: :ollama, instance: :default, model: 'llama3:8b', tier: :local })
      end
    end

    context 'with enriched model hash' do
      let(:model_data) do
        { 'name' => 'qwen3.6:27b', 'capabilities' => %i[completion vision tools thinking],
          'context_length' => 262_144, 'parameter_count' => 27_781_427_952 }
      end

      subject(:rule) { described_class.build_rule(:ollama, :default, model_data, :chat, :local, 100) }

      it 'includes model_capabilities in the target' do
        expect(rule[:then][:model_capabilities]).to eq(%i[completion vision tools thinking])
      end

      it 'includes context_length in the target' do
        expect(rule[:then][:context_length]).to eq(262_144)
      end

      it 'includes parameter_count in the target' do
        expect(rule[:then][:parameter_count]).to eq(27_781_427_952)
      end

      it 'sets model name from hash' do
        expect(rule[:then][:model]).to eq('qwen3.6:27b')
      end
    end
  end

  describe 'enriched metadata in rules' do
    subject(:rules) { described_class.generate(discovered) }

    it 'includes model_capabilities from ollama enrichment' do
      llama_rule = rules.find { |r| r[:name].include?('llama3.1:8b') && r[:when][:capability] == :chat }
      expect(llama_rule[:then][:model_capabilities]).to eq(%i[completion tools])
    end

    it 'includes context_length from ollama enrichment' do
      llama_rule = rules.find { |r| r[:name].include?('llama3.1:8b') && r[:when][:capability] == :chat }
      expect(llama_rule[:then][:context_length]).to eq(131_072)
    end

    it 'includes context_length from vllm models' do
      vllm_rule = rules.find { |r| r[:name].include?('Qwen/Qwen2.5-72B-Instruct') && r[:when][:capability] == :chat }
      expect(vllm_rule[:then][:context_length]).to eq(131_072)
    end

    it 'omits nil metadata fields via compact' do
      vllm_embed = rules.find { |r| r[:name].include?('text-embedding-ada-002') }
      expect(vllm_embed[:then]).not_to have_key(:model_capabilities)
      expect(vllm_embed[:then]).not_to have_key(:parameter_count)
    end
  end

  describe 'configured provider rules without KNOWN_MODEL_CAPABILITIES' do
    before do
      Legion::Settings[:extensions][:llm][:anthropic] = { enabled: true, default_model: 'claude-sonnet-4-6' }
    end

    it 'generates chat and stream rules for enabled configured providers' do
      rules = described_class.generate({})
      anthropic_rules = rules.select { |r| r[:name].include?('anthropic') }
      capabilities = anthropic_rules.map { |r| r[:when][:capability] }
      expect(capabilities).to contain_exactly(:chat, :stream)
    end

    it 'sets correct model name from config' do
      rules = described_class.generate({})
      anthropic_rule = rules.find { |r| r[:name].include?('anthropic') && r[:when][:capability] == :chat }
      expect(anthropic_rule[:then][:model]).to eq('claude-sonnet-4-6')
    end

    it 'does not include model_capabilities without enrichment data' do
      rules = described_class.generate({})
      anthropic_rule = rules.find { |r| r[:name].include?('anthropic') && r[:when][:capability] == :chat }
      expect(anthropic_rule[:then]).not_to have_key(:model_capabilities)
    end
  end

  describe 'integration with Router.populate_auto_rules' do
    before do
      Legion::Settings[:llm] = Legion::Settings[:llm].merge(
        routing: {
          enabled:        true,
          rules:          [],
          default_intent: { privacy: 'normal', capability: 'chat' }
        }
      )
      allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
      allow(Legion::LLM::Router).to receive(:discovery_enabled?).and_return(false)
    end

    it 'populates auto rules from discovered instances' do
      Legion::LLM::Router.populate_auto_rules(discovered)
      expect(Legion::LLM::Router.auto_rules_populated?).to be true
    end

    it 'routes using auto-generated rules when no manual rules exist' do
      Legion::LLM::Router.populate_auto_rules(discovered)
      result = Legion::LLM::Router.resolve(intent: { capability: :chat })
      expect(result).not_to be_nil
      expect(result.model).to include('llama3.1:8b').or include('qwen2.5:32b').or include('Qwen')
    end

    it 'manual rules have higher priority than auto-generated rules' do
      manual_rules = [
        {
          name:     'manual-chat',
          when:     { capability: 'chat' },
          then:     { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6' },
          priority: 10
        }
      ]
      Legion::Settings[:llm][:routing][:rules] = manual_rules
      Legion::LLM::Router.populate_auto_rules(discovered)

      result = Legion::LLM::Router.resolve(intent: { capability: :chat })
      expect(result).not_to be_nil
      # manual rule priority=10 + 1000 = 1010, auto rules max ~100
      expect(result.rule).to eq('manual-chat')
    end
  end

  describe 'Resolution instance: field' do
    it 'stores and returns instance from auto-generated rule' do
      Legion::Settings[:llm] = Legion::Settings[:llm].merge(
        routing: {
          enabled:        true,
          rules:          [],
          default_intent: { privacy: 'normal', capability: 'chat' }
        }
      )
      allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
      allow(Legion::LLM::Router).to receive(:discovery_enabled?).and_return(false)

      small_discovered = { ollama: { my_gpu: { models: [{ 'name' => 'llama3:8b' }] } } }
      Legion::LLM::Router.populate_auto_rules(small_discovered)

      result = Legion::LLM::Router.resolve(intent: { capability: :chat })
      expect(result).not_to be_nil
      expect(result.instance).to eq(:my_gpu)
    end

    it 'includes instance in to_h when present' do
      resolution = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :ollama, model: 'llama3', instance: :gpu1
      )
      expect(resolution.to_h).to include(instance: :gpu1)
    end

    it 'excludes instance from to_h when nil' do
      resolution = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :ollama, model: 'llama3'
      )
      expect(resolution.to_h).not_to have_key(:instance)
    end
  end
end

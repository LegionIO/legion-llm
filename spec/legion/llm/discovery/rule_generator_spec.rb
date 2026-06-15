# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/rule_generator'
require 'legion/llm/discovery'
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
            'capabilities' => %i[completion streaming tools], 'context_length' => 131_072,
            'parameter_count' => 8_000_000_000 },
          { 'name' => 'qwen2.5:32b', 'size' => 20_000_000_000,
            'capabilities' => %i[completion streaming vision tools thinking], 'context_length' => 262_144 },
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
      expect(embed_rules.first[:when]).to eq({ operation: :embed })
    end

    it 'generates chat, stream, and tools rules for capable inference models' do
      llama_rules = rules.select { |r| r[:name].include?('llama3.1:8b') }
      operations = llama_rules.map { |r| r[:when][:operation] }
      # tools rules also use operation: :chat (tools is a capability, not an operation)
      expect(operations).to contain_exactly(:chat, :stream, :chat)
      expect(llama_rules.map { |r| r[:name] }).to include(a_string_matching(/:tools\z/))
    end

    it 'does not generate stream rules for embedding models' do
      embed_stream = rules.select { |r| r[:name].include?('nomic-embed-text') && r[:when][:operation] == :stream }
      expect(embed_stream).to be_empty
    end

    it 'does not generate stream rules when discovered capabilities exclude streaming' do
      no_stream_rules = described_class.generate(
        ollama: { local: { models: [{ name: 'no-stream-model', capabilities: %i[completion tools] }] } }
      )

      operations = no_stream_rules.map { |r| r[:when][:operation] }
      # chat + tools rule (both operation: :chat), no stream
      expect(operations).to contain_exactly(:chat, :chat)
      expect(no_stream_rules.none? { |r| r[:when][:operation] == :stream }).to be(true)
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

    it 'uses configured tier priority when scoring generated rules' do
      Legion::Settings[:llm][:routing][:tier_priority] = %w[direct local fleet cloud frontier]
      direct_first = described_class.generate(
        ollama: { default: { models: [{ name: 'local-model' }] } },
        vllm:   { apollo: { models: [{ name: 'direct-model', tier: 'direct' }] } }
      )

      first_chat_rule = direct_first.find { |rule| rule[:when][:operation] == :chat }
      expect(first_chat_rule[:then][:tier]).to eq(:direct)
    end

    it 'uses top-level tier_order when scoring generated rules' do
      Legion::Settings[:llm][:tier_order] = %w[direct local cloud frontier]
      direct_first = described_class.generate(
        ollama: { default: { models: [{ name: 'local-model' }] } },
        vllm:   { apollo: { models: [{ name: 'direct-model', tier: 'direct' }] } }
      )

      first_chat_rule = direct_first.find { |rule| rule[:when][:operation] == :chat }
      expect(first_chat_rule[:then][:tier]).to eq(:direct)
    end

    it 'falls back to DEFAULT_TIER_PRIORITY when settings raise' do
      Legion::Settings[:llm][:routing] = nil

      rules = described_class.generate(discovered)

      expect(rules).not_to be_empty
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
      expect(vllm_embed.first[:when][:operation]).to eq(:embed)
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

      it 'includes provider, instance, model, tier, and effort in the target' do
        expect(rule[:then]).to eq({ provider: :ollama, instance: :default, model: 'llama3:8b', tier: :local, effort: :low })
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

      it 'normalizes function_calling capability aliases to tools' do
        aliased = described_class.build_rule(
          :vllm,
          :apollo,
          { name: 'qwen-tools', capabilities: %i[completion streaming function_calling] },
          :chat,
          :direct,
          100
        )

        expect(aliased[:then][:model_capabilities]).to include(:function_calling, :tools)
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
      llama_rule = rules.find { |r| r[:name].include?('llama3.1:8b') && r[:when][:operation] == :chat }
      expect(llama_rule[:then][:model_capabilities]).to eq(%i[completion streaming tools])
    end

    it 'includes context_length from ollama enrichment' do
      llama_rule = rules.find { |r| r[:name].include?('llama3.1:8b') && r[:when][:operation] == :chat }
      expect(llama_rule[:then][:context_length]).to eq(131_072)
    end

    it 'includes context_length from vllm models' do
      vllm_rule = rules.find { |r| r[:name].include?('Qwen/Qwen2.5-72B-Instruct') && r[:when][:operation] == :chat }
      expect(vllm_rule[:then][:context_length]).to eq(131_072)
    end

    it 'omits nil metadata fields via compact' do
      vllm_embed = rules.find { |r| r[:name].include?('text-embedding-ada-002') }
      expect(vllm_embed[:then]).not_to have_key(:model_capabilities)
      expect(vllm_embed[:then]).not_to have_key(:parameter_count)
    end
  end

  describe 'instance-level capabilities propagate to chat rules' do
    # Regression test for the claude/vllm legionio_tool_injection symptom:
    # vLLM's lex extension declares `capabilities: %i[completion streaming
    # vision tools]` at the instance tier (DEFAULT_INSTANCE_TIER), but the
    # per-model offerings hash only carries `[:completion]`. Without the
    # instance-level merge, the chat rule's model_capabilities is
    # `[:completion]`, and the router's
    # satisfies_required_capabilities?([:tools]) check rejects every chat
    # rule on every tool request — silently falling through to the default
    # provider chain.
    let(:vllm_with_instance_caps) do
      {
        vllm: {
          gpu1: {
            models:       [{ name: 'qwen3.6-27b', capabilities: [:completion] }],
            capabilities: %i[completion streaming vision tools]
          }
        }
      }
    end

    subject(:rules) { described_class.generate(vllm_with_instance_caps) }

    it 'merges instance-level :tools into the chat rule model_capabilities' do
      chat_rule = rules.find { |r| r[:when] == { operation: :chat } && r[:then][:provider] == :vllm }
      expect(chat_rule[:then][:model_capabilities]).to include(:tools)
    end

    it 'generates a :tools capability rule when the instance advertises tools' do
      tools_rule = rules.find { |r| r[:when] == { operation: :chat } && r[:then][:provider] == :vllm }
      expect(tools_rule).not_to be_nil
    end

    it 'generates a :stream capability rule when the instance advertises streaming' do
      stream_rule = rules.find { |r| r[:when] == { operation: :stream } && r[:then][:provider] == :vllm }
      expect(stream_rule).not_to be_nil
    end
  end

  describe 'configured provider rules without KNOWN_MODEL_CAPABILITIES' do
    before do
      Legion::Settings[:extensions][:llm][:anthropic] = { enabled: true, default_model: 'claude-sonnet-4-6' }
    end

    it 'generates chat and stream rules for enabled configured providers' do
      rules = described_class.generate({})
      anthropic_rules = rules.select { |r| r[:name].include?('anthropic') }
      capabilities = anthropic_rules.map { |r| r[:when][:operation] }
      expect(capabilities).to contain_exactly(:chat, :stream)
    end

    it 'sets correct model name from config' do
      rules = described_class.generate({})
      anthropic_rule = rules.find { |r| r[:name].include?('anthropic') && r[:when][:operation] == :chat }
      expect(anthropic_rule[:then][:model]).to eq('claude-sonnet-4-6')
    end

    it 'does not include model_capabilities without enrichment data' do
      rules = described_class.generate({})
      anthropic_rule = rules.find { |r| r[:name].include?('anthropic') && r[:when][:operation] == :chat }
      expect(anthropic_rule[:then]).not_to have_key(:model_capabilities)
    end
  end

  describe 'integration with Router.populate_auto_rules' do
    before do
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        routing: {
                                          enabled:        true,
                                          rules:          [],
                                          default_intent: { privacy: 'normal', operation: 'chat', effort: 'moderate' }
                                        }
                                      ))
      allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
      allow(Legion::LLM::Router).to receive(:discovery_enabled?).and_return(false)
    end

    it 'populates auto rules from discovered instances' do
      Legion::LLM::Router.populate_auto_rules(discovered)
      expect(Legion::LLM::Router.auto_rules_populated?).to be true
    end

    it 'routes using auto-generated rules when no manual rules exist' do
      Legion::LLM::Router.populate_auto_rules(discovered)
      result = Legion::LLM::Router.resolve(intent: { operation: :chat })
      expect(result).not_to be_nil
      expect(result.model).to include('llama3.1:8b').or include('qwen2.5:32b').or include('Qwen')
    end

    it 'manual rules have higher priority than auto-generated rules' do
      manual_rules = [
        {
          name:     'manual-chat',
          when:     { operation: :chat },
          then:     { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6' },
          priority: 10
        }
      ]
      Legion::Settings[:llm][:routing][:rules] = manual_rules
      Legion::LLM::Router.populate_auto_rules(discovered)

      result = Legion::LLM::Router.resolve(intent: { operation: :chat })
      expect(result).not_to be_nil
      # manual rule priority=10 + 1000 = 1010, auto rules max ~100
      expect(result.rule).to eq('manual-chat')
    end
  end

  describe 'Resolution instance: field' do
    it 'stores and returns instance from auto-generated rule' do
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        routing: {
                                          enabled:        true,
                                          rules:          [],
                                          default_intent: { privacy: 'normal', operation: 'chat', effort: 'moderate' }
                                        }
                                      ))
      allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
      allow(Legion::LLM::Router).to receive(:discovery_enabled?).and_return(false)

      small_discovered = { ollama: { my_gpu: { models: [{ 'name' => 'llama3:8b' }] } } }
      Legion::LLM::Router.populate_auto_rules(small_discovered)

      result = Legion::LLM::Router.resolve(intent: { operation: :chat })
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

  describe 'per-model tier override in .generate' do
    it 'uses model-level tier (symbol key) over TIER_MAP when present' do
      direct_vllm = {
        vllm: {
          gpu1: {
            models: [
              { 'name' => 'llama3:8b', 'tier' => :direct }
            ]
          }
        }
      }
      rules = described_class.generate(direct_vllm)
      chat_rule = rules.find { |r| r[:name].include?('llama3:8b') && r[:when][:operation] == :chat }
      expect(chat_rule[:then][:tier]).to eq(:direct)
    end

    it 'uses model-level tier (string key) over TIER_MAP when present' do
      direct_vllm = {
        vllm: {
          gpu1: {
            models: [
              { 'name' => 'mistral:7b', 'tier' => 'direct' }
            ]
          }
        }
      }
      rules = described_class.generate(direct_vllm)
      chat_rule = rules.find { |r| r[:name].include?('mistral:7b') && r[:when][:operation] == :chat }
      expect(chat_rule[:then][:tier]).to eq(:direct)
    end

    it 'falls back to TIER_MAP when no per-model tier is present' do
      default_vllm = {
        vllm: {
          gpu1: {
            models: [
              { 'name' => 'llama3:8b' }
            ]
          }
        }
      }
      rules = described_class.generate(default_vllm)
      chat_rule = rules.find { |r| r[:name].include?('llama3:8b') && r[:when][:operation] == :chat }
      expect(chat_rule[:then][:tier]).to eq(:fleet)
    end

    it 'applies per-model tier override to stream rules as well' do
      direct_vllm = {
        vllm: {
          gpu1: {
            models: [
              { 'name' => 'llama3:8b', 'tier' => :direct }
            ]
          }
        }
      }
      rules = described_class.generate(direct_vllm)
      stream_rule = rules.find { |r| r[:name].include?('llama3:8b') && r[:when][:operation] == :stream }
      expect(stream_rule[:then][:tier]).to eq(:direct)
    end
  end

  describe 'capability_sources-aware rule generation' do
    it 'does NOT generate streaming rules when capability_sources says streaming: false' do
      discovered = {
        vllm: {
          gpu1: {
            models: [{
              name:               'restricted-model',
              capabilities:       %i[completion],
              capability_sources: {
                streaming: { value: false, source: :default_false },
                tools:     { value: false, source: :default_false }
              }
            }]
          }
        }
      }

      rules = described_class.generate(discovered)
      stream_rules = rules.select { |r| r[:name].include?('restricted-model') && r[:when][:operation] == :stream }
      expect(stream_rules).to be_empty
    end

    it 'does NOT generate tools rules when capability_sources says tools: false' do
      discovered = {
        vllm: {
          gpu1: {
            models: [{
              name:               'restricted-model',
              capabilities:       %i[completion],
              capability_sources: {
                streaming: { value: false, source: :default_false },
                tools:     { value: false, source: :default_false }
              }
            }]
          }
        }
      }

      rules = described_class.generate(discovered)
      tools_rules = rules.select { |r| r[:name].include?('restricted-model') && r[:name].end_with?(':tools') }
      expect(tools_rules).to be_empty
    end

    it 'DOES include tools in generated rule capabilities when capability_sources says tools: true from :instance_override' do
      discovered = {
        vllm: {
          gpu1: {
            models: [{
              name:               'tool-model',
              capabilities:       %i[completion streaming tools],
              capability_sources: {
                tools:     { value: true, source: :instance_override },
                streaming: { value: true, source: :instance_override }
              }
            }]
          }
        }
      }

      rules = described_class.generate(discovered)
      chat_rule = rules.find { |r| r[:name].include?('tool-model') && r[:when][:operation] == :chat && !r[:name].end_with?(':tools') }
      expect(chat_rule[:then][:model_capabilities]).to include(:tools)
    end

    it 'includes capability_sources in generated rule target' do
      discovered = {
        vllm: {
          gpu1: {
            models: [{
              name:               'sourced-model',
              capabilities:       %i[completion tools],
              capability_sources: {
                tools: { value: true, source: :instance_override }
              }
            }]
          }
        }
      }

      rules = described_class.generate(discovered)
      chat_rule = rules.find { |r| r[:name].include?('sourced-model') && r[:when][:operation] == :chat && !r[:name].end_with?(':tools') }
      expect(chat_rule[:then][:capability_sources]).to eq(tools: { value: true, source: :instance_override })
    end

    it 'does not override instance capabilities when model has no capability_sources' do
      discovered = {
        vllm: {
          gpu1: {
            models:       [{ name: 'basic-model', capabilities: [:completion] }],
            capabilities: %i[completion streaming tools]
          }
        }
      }

      rules = described_class.generate(discovered)
      chat_rule = rules.find { |r| r[:name].include?('basic-model') && r[:when][:operation] == :chat && !r[:name].end_with?(':tools') }
      # Legacy merge: instance caps are added
      expect(chat_rule[:then][:model_capabilities]).to include(:tools)
    end
  end
end

RSpec.describe Legion::LLM::Discovery do
  before do
    Legion::LLM::Discovery.reset!
  end

  describe '.normalize_model_for_rules (via discovered_instances)' do
    context 'when model entry has a tier' do
      it 'includes tier in the normalized hash' do
        model_entry = {
          model:    'llama3:8b',
          provider: :vllm,
          instance: :gpu1,
          tier:     :direct
        }
        result = Legion::LLM::Discovery.send(:normalize_model_for_rules, model_entry)
        expect(result['tier']).to eq(:direct)
      end
    end

    context 'when model entry has no tier' do
      it 'omits the tier key entirely' do
        model_entry = {
          model:    'llama3:8b',
          provider: :vllm,
          instance: :gpu1,
          tier:     nil
        }
        result = Legion::LLM::Discovery.send(:normalize_model_for_rules, model_entry)
        expect(result).not_to have_key('tier')
      end
    end

    it 'always includes the model name' do
      model_entry = { model: 'llama3:8b', provider: :vllm, instance: :gpu1 }
      result = Legion::LLM::Discovery.send(:normalize_model_for_rules, model_entry)
      expect(result['name']).to eq('llama3:8b')
    end
  end
end

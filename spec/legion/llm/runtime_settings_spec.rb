# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'legion/llm/cache/response'
require 'legion/llm/context/compressor'
require 'legion/llm/context/curator'
require 'legion/llm/hooks/reflection'
require 'legion/llm/skills/external_discovery'
require 'legion/llm/quality/shadow_eval'
require 'legion/llm/api/native/helpers'
require 'legion/llm/vector_store/storage'

RSpec.describe 'Runtime settings ownership' do
  def settings
    Legion::Settings[:llm]
  end

  describe Legion::LLM::Settings do
    it 'merges missing defaults at registration while preserving explicit false and zero' do
      Legion::Settings.reset!
      Legion::Settings.set_prop(:llm, { prompt_caching: { enabled: false }, shadow: { max_history: 0 } })
      described_class.register_defaults!
      expect(settings[:knowledge_capture][:enabled]).to be false
      expect(settings[:prompt_caching][:enabled]).to be false
      expect(settings[:shadow][:max_history]).to eq(0)
      expect(settings[:shadow][:sample_rate]).to eq(0.1)
      expect { Legion::Settings.validate! }.not_to raise_error
    end

    it 'preserves explicit nil and rejects it during framework validation' do
      settings[:daemon][:read_timeout] = nil
      described_class.register_defaults!
      expect(settings[:daemon][:read_timeout]).to be_nil
      expect { Legion::Settings.validate! }.to raise_error(Legion::Settings::ValidationError, /daemon.read_timeout/)
    end

    it 'rejects dangerous chunk, repetition, timeout, retention and path values during framework validation' do
      [[:embedding, :chunk_target_tokens, 0], [:quality, :repetition_min_chars, 0],
       [:daemon, :read_timeout, Float::INFINITY], [:shadow, :max_history, -1],
       [:files, :storage_path, ''], [:knowledge_capture, :enabled, 'true']].each do |group, key, bad|
        previous = settings[group][key]
        settings[group][key] = bad
        expect { Legion::Settings.validate! }.to raise_error(Legion::Settings::ValidationError, /#{group}\.#{key}/)
        settings[group][key] = previous
      end
    end
  end

  describe 'timeouts and cache timing' do
    it 'uses configured HTTP timeouts and honors the explicit request timeout' do
      settings[:daemon].merge!(url: 'http://daemon.test', health_open_timeout: 3, health_read_timeout: 4,
                               open_timeout: 6, read_timeout: 7, inference_timeout: 9)
      client = Legion::LLM::Call::DaemonClient
      client.reset!
      http = Net::HTTP.new('daemon.test', 80)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:request).and_return(double(code: '200', body: '{}'))
      client.http_get('/api/health')
      expect([http.open_timeout, http.read_timeout]).to eq([3, 4])
      client.http_post('/api/llm/chat', {})
      expect([http.open_timeout, http.read_timeout]).to eq([6, 7])
      client.inference(messages: [])
      expect(http.read_timeout).to eq(9)
      client.inference(messages: [], timeout: 12)
      expect(http.read_timeout).to eq(12)
    ensure
      client&.reset!
    end

    it 'expires health according to the configured TTL' do
      client = Legion::LLM::Call::DaemonClient
      settings[:daemon].merge!(url: 'http://daemon.test', health_cache_ttl: 2)
      client.reset!
      allow(client).to receive(:check_health).and_return(true)
      allow(::Process).to receive(:clock_gettime).with(::Process::CLOCK_MONOTONIC).and_return(10)
      expect(client.available?).to be true
      allow(::Process).to receive(:clock_gettime).with(::Process::CLOCK_MONOTONIC).and_return(11)
      expect(client.available?).to be true
      expect(client).to have_received(:check_health).once
      allow(::Process).to receive(:clock_gettime).with(::Process::CLOCK_MONOTONIC).and_return(13)
      expect(client.available?).to be true
      expect(client).to have_received(:check_health).twice
    ensure
      client&.reset!
    end

    it 'passes the configured generic cache TTL to the backend' do
      cache = Legion::LLM::Cache
      settings[:prompt_caching][:response_cache][:ttl_seconds] = 19
      allow(cache).to receive(:available?).and_return(true)
      expect(cache).to receive(:cache_backend_set).with('key', anything, ttl: 19)
      expect(cache.set('key', { text: 'cached' })).to be true
    end

    it 'polls using the configured interval and retains caller overrides' do
      cache = Legion::LLM::Cache::Response
      settings[:prompt_caching][:response_cache][:poll_interval_seconds] = 0.25
      allow(cache).to receive(:status).and_return(:pending, :done)
      allow(cache).to receive_messages(response: 'done', meta: {})
      expect(cache).to receive(:sleep).with(0.25)
      expect(cache.poll('id')[:status]).to eq(:done)
      allow(cache).to receive(:status).and_return(:pending, :done)
      expect(cache).to receive(:sleep).with(0.5)
      expect(cache.poll('id', interval: 0.5)[:status]).to eq(:done)
    end
  end

  describe 'curation and compression' do
    it 'uses the registered tool-result default when a partial curation tree omits it' do
      settings[:context_curation] = { enabled: true }
      Legion::Settings.merge_settings(:llm, Legion::LLM::Settings.default)
      curator = Legion::LLM::Context::Curator.new(conversation_id: 'settings-test')
      message = { role: :tool, content: 'x' * 3000 }
      expect(curator.distill_tool_result(message)).to equal(message)
      settings[:context_curation].merge!(tool_result_max_chars: 100, tool_preview_chars: 7)
      result = curator.distill_tool_result(message)
      expect(result[:content]).to include('xxxxxxx')
      expect(result[:content]).not_to include('xxxxxxxx')
      expect(result[:original_content]).to eq(message[:content])
    end

    it 'honors configured file previews and command tails' do
      settings[:context_curation].merge!(tool_result_max_chars: 1, file_preview_chars: 3,
                                         command_tail_lines: 1, command_preview_chars: 4)
      curator = Legion::LLM::Context::Curator.new(conversation_id: 'settings-test')
      file = curator.distill_tool_result(role: :tool, tool_name: 'read_file', content: "abcdef\nghijkl")
      command = curator.distill_tool_result(role: :tool, tool_name: 'bash', content: "earlier\nlatest")
      expect(file[:content]).to include('First: abc... Last: ghi')
      expect(command[:content]).to end_with('late')
    end

    it 'uses configured dedup windows and minimum content size' do
      compressor = Legion::LLM::Context::Compressor
      settings[:compressor].merge!(dedup_window: 1, dedup_min_chars: 1)
      messages = [{ role: :user, content: 'repeat' }, { role: :assistant, content: 'different' }, { role: :user, content: 'repeat' }]
      expect(compressor.deduplicate_messages(messages)[:removed]).to eq(0)
      settings[:compressor][:dedup_window] = 2
      expect(compressor.deduplicate_messages(messages)[:removed]).to eq(1)
    end

    it 'honors the configured summary threshold and input clipping multiplier' do
      compressor = Legion::LLM::Context::Compressor
      settings[:compressor].merge!(summary_token_threshold: 2, summary_input_chars_per_token: 3)
      expect(Legion::LLM).to receive(:chat_direct).with(hash_including(message: a_string_ending_with('user: ')))
                                                  .and_return(double(content: 'summary'))
      expect(compressor.summarize_messages([{ role: :user, content: 'abcdefghijk' }])[:summary]).to eq('summary')
    end
  end

  describe 'retained history' do
    it 'evicts token records using the configured cap, including zero' do
      tracker = Legion::LLM::Metering::Tokens
      tracker.reset!
      settings[:metering][:token_history_limit] = 2
      [1, 2, 3].each { |n| tracker.record(input_tokens: n, output_tokens: 0) }
      expect(tracker.total_tokens).to eq(5)
      settings[:metering][:token_history_limit] = 0
      tracker.record(input_tokens: 9, output_tokens: 0)
      expect(tracker.total_tokens).to eq(0)
    ensure
      tracker&.reset!
    end

    it 'honors zero and full shadow sampling rates' do
      settings[:shadow] = { enabled: true, sample_rate: 0 }
      expect(Legion::LLM::Quality::ShadowEval.should_sample?).to be false
      settings[:shadow][:sample_rate] = 1
      expect(Legion::LLM::Quality::ShadowEval.should_sample?).to be true
    end
  end

  describe 'quality and reflection' do
    it 'uses configured quality thresholds and repetition sizes in both scoring paths' do
      settings[:quality].merge!(too_short: true, threshold: 5, repetition: true, repetition_min_chars: 2, repetition_count: 2)
      settings[:confidence][:heuristic_weights][:repetition] = -0.2
      response = Struct.new(:content).new('abab')
      expect(Legion::LLM::Quality::Checker.check(response).failures).to include(:too_short, :repetition)
      score = Legion::LLM::Quality::Confidence::Scorer.score(response)
      expect(score.score).to be_within(0.0001).of(0.5)
    end

    it 'merges partial penalty overrides with registered penalties' do
      settings[:quality][:too_short] = true
      settings[:confidence][:heuristic_weights] = { empty: -0.2 }
      Legion::Settings.merge_settings(:llm, Legion::LLM::Settings.default)
      response = Struct.new(:content).new('short')
      expect(Legion::LLM::Quality::Confidence::Scorer.score(response).score).to eq(0.7)
    end

    it 'applies configured reflection thresholds, confidence, counts and clipping' do
      reflection = Legion::LLM::Hooks::Reflection
      settings[:reflection].merge!(min_response_chars: 10, max_extract_chars: 6, context_chars: 4)
      settings[:reflection][:max_entries][:decision] = 1
      settings[:reflection][:confidence][:decision] = 0.9
      expect(reflection.should_extract?(content: '123456789')).to be false
      expect(reflection.should_extract?(content: '1234567890')).to be true
      entries = reflection.extract_decisions("We decided to use ruby for this service.\nWe chose to use a different tool.")
      expect(entries.size).to eq(1)
      expect(entries.first).to include(content: 'to use...', confidence: 0.9)
      expect(reflection.conversation_context([{ role: :user, content: 'a longer context' }])).to eq('a lo...')
    end
  end

  describe 'discovery and native helpers' do
    it 'leaves discovery disabled when its settings are missing' do
      settings[:skills] = {}
      Legion::Settings.merge_settings(:llm, Legion::LLM::Settings.default)
      expect(Legion::LLM::Skills::ExternalDiscovery).not_to receive(:claude_directories)
      expect(Legion::LLM::Skills::ExternalDiscovery).not_to receive(:codex_directories)
      expect(Legion::LLM::Skills::ExternalDiscovery.discover).to eq([])
    end

    it 'discovers skills only beneath configured roots' do
      Dir.mktmpdir('skills-settings') do |root|
        claude = File.join(root, 'claude')
        plugins = File.join(root, 'plugins')
        codex = File.join(root, 'codex')
        plugin_skills = File.join(plugins, 'one', 'skills')
        FileUtils.mkdir_p([claude, codex, plugin_skills])
        settings[:skills].merge!(auto_discover:   { claude: true, codex: true },
                                 discovery_roots: { claude_skills: claude, claude_plugins: plugins, codex_skills: codex })
        expect(Legion::LLM::Skills::ExternalDiscovery.discover).to contain_exactly(claude, plugin_skills, codex)
      end
    end

    it 'uses configured native grep filters and output caps' do
      host = Class.new { include Legion::LLM::API::Native::ClientToolMethods }.new
      settings[:tools][:native].merge!(grep_include: '*.txt', grep_max_lines: 1, glob_max_matches: 1)
      expect(Open3).to receive(:capture2e).with('grep', '-rn', '--include=*.txt', 'term', '/tmp')
                                          .and_return(["first\nsecond\n", nil])
      expect(host.send(:dispatch_client_tool, 'grep', pattern: 'term', path: '/tmp')).to eq("first\n")
      allow(Dir).to receive(:glob).with('fixture-*').and_return(%w[fixture-a fixture-b])
      expect(host.send(:dispatch_client_tool, 'glob', pattern: 'fixture-*')).to eq('fixture-a')
    end

    it 'chunks vector-store paragraphs at the configured target' do
      settings[:vector_store][:chunk_target_chars] = 6
      expect(Legion::LLM::VectorStore::Storage.chunk_text("aaaa\n\nbbbb")).to eq(%w[aaaa bbbb])
    end
  end

  it 'rejects a zero summary budget and prevents positive fractional budgets from rounding to zero' do
    settings[:compressor][:summary_budget_ratio] = 0
    compressor = Legion::LLM::Context::Compressor
    messages = [{ role: :user, content: 'older' }, { role: :assistant, content: 'recent' }]
    expect { compressor.auto_compact(messages, target_tokens: 1, preserve_recent: 1) }.to raise_error(ArgumentError, /summary_budget_ratio/)
    settings[:compressor][:summary_budget_ratio] = 0.01
    expect(compressor).to receive(:summarize_messages).with([messages.first], max_tokens: 1)
                                                      .and_return(summary: 'older preserved')
    expect(compressor.auto_compact(messages, target_tokens: 1, preserve_recent: 1)).to include(hash_including(content: 'older preserved'))
  end

  it 'registers the escalation quality threshold without overriding operator configuration' do
    settings[:routing][:escalation] = {}
    Legion::Settings.merge_settings(:llm, Legion::LLM::Settings.default)
    expect(settings[:routing][:escalation][:quality_threshold]).to eq(0)
    settings[:routing][:escalation][:quality_threshold] = 23
    Legion::Settings.merge_settings(:llm, Legion::LLM::Settings.default)
    expect(settings[:routing][:escalation][:quality_threshold]).to eq(23)
  end
end

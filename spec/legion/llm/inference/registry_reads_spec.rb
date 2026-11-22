# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor, 'request-owned tool registry reads' do
  let(:registry) { Legion::Settings::Extensions }
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'quartz nebula' }],
      conversation_id: 'registry-request', metadata: { requested_tools: ['probe_requested'] }
    )
  end
  let(:executor) { described_class.new(request) }

  def register(name, deferred: true, **metadata)
    registry.register_tool(name, { deferred: deferred, extension: 'probe', runner: 'jobs', function: 'inspect', **metadata })
  end

  before do
    registry.reset!
    Legion::LLM::Inference::Conversation.reset!
    Legion::LLM::Inference::Conversation.create_conversation(request.conversation_id)
    Legion::Settings[:llm][:tools][:trigger][:tool_limit] = 10
    register('probe_zeta', trigger_words: ['quartz'])
    register('probe_always', deferred: false, trigger_words: ['quartz'])
    register('probe_alpha', trigger_words: %w[quartz nebula])
    register('probe_beta', trigger_words: ['quartz'])
    register('probe_hint')
    register('probe_requested')
    executor.enrichments['gaia:advisory'] = { data: { tool_hint: ['probe_hint'] } }
  end

  after { registry.reset! }

  it 'shares one registry read across consumers between client discovery boundaries' do
    allow(registry).to receive(:tools).and_call_original
    allow(registry).to receive(:filter_tools).and_call_original
    executor.send(:step_trigger_match)
    executor.send(:step_sticky_runners)
    executor.send(:discover_registry_tools)
    definitions = executor.send(:native_tool_definitions)
    executor.send(:step_sticky_persist)
    expect(definitions.map(&:name)).to include('probe_always', 'probe_zeta', 'probe_alpha', 'probe_beta', 'probe_hint', 'probe_requested')
    expect(registry).to have_received(:tools).once
    expect(registry).not_to have_received(:filter_tools)
    expect(executor.warnings).to be_empty
  end

  it 'keeps registry order below the cap and score/name ordering above it' do
    executor.send(:step_trigger_match)
    expect(executor.instance_variable_get(:@triggered_tools).map { |entry| entry[:name] }).to eq(%w[probe_zeta probe_alpha probe_beta])
    Legion::Settings[:llm][:tools][:trigger][:tool_limit] = 2
    capped = described_class.new(request)
    capped.send(:step_trigger_match)
    expect(capped.instance_variable_get(:@triggered_tools).map { |entry| entry[:name] }).to eq(%w[probe_alpha probe_beta])
  end

  it 'does not hash tool schemas while matching and ranking trigger words' do
    schema = { type: 'object', properties: { value: { type: 'string' } } }
    register('probe_schema', trigger_words: ['quartz'], input_schema: schema)
    expect(schema).not_to receive(:hash)
    executor.send(:step_trigger_match)
    expect(executor.warnings).to be_empty
    expect(executor.instance_variable_get(:@triggered_tools).map { |entry| entry[:name] }).to include('probe_schema')
  end

  it 'preserves an in-flight view and observes registrations, replacements and removals on the next request' do
    executor.send(:step_tool_discovery)
    executor.send(:step_trigger_match)
    registry.unregister_tool('probe_always')
    register('probe_new', deferred: false)
    register('probe_alpha', trigger_words: ['quartz'], description: 'replacement definition')
    executor.send(:step_trigger_match)
    first = executor.send(:native_tool_definitions)
    expect(first.map(&:name)).to include('probe_always')
    expect(first.map(&:name)).not_to include('probe_new')
    expect(first.find { |tool| tool.name == 'probe_alpha' }.description).not_to eq('replacement definition')
    following = described_class.new(request)
    following.send(:step_trigger_match)
    next_tools = following.send(:native_tool_definitions)
    expect(next_tools.map(&:name)).to include('probe_new')
    expect(next_tools.map(&:name)).not_to include('probe_always')
    expect(next_tools.find { |tool| tool.name == 'probe_alpha' }.description).to eq('replacement definition')
  end

  it 'does not mutate or freeze nested registry metadata while creating request views' do
    schema = { type: 'object', properties: { value: { type: 'string' } } }
    register('probe_nested', trigger_words: ['quartz'], input_schema: schema)
    entry = registry.find_tool('probe_nested')
    words = entry[:trigger_words].dup
    executor.send(:step_trigger_match)
    executor.send(:step_tool_discovery)
    executor.send(:native_tool_definitions)
    expect(registry.find_tool('probe_nested')).to eq(entry)
    expect(entry[:trigger_words]).to eq(words)
    expect(entry[:trigger_words]).not_to be_frozen
    expect(schema).not_to be_frozen
  end

  [true, false].each do |local|
    it "preserves injection precedence and requested deferred tools beyond the cap, local=#{local}" do
      allow(executor).to receive(:local_provider?).and_return(local)
      allow(executor).to receive(:registry_tool_limit).and_return(2)
      executor.send(:step_trigger_match)
      names = executor.send(:native_tool_definitions).map(&:name).select { |name| name.start_with?('probe_') }
      expected = local ? %w[probe_hint probe_zeta probe_requested] : %w[probe_always probe_hint probe_requested]
      expect(names).to eq(expected)
    end
  end

  it 'preserves sticky reinjection provenance without marking old sticky tools as newly triggered' do
    register('probe_sticky', runner: 'sticky', sticky: true)
    Legion::LLM::Inference::Conversation.write_sticky_state(request.conversation_id, {
                                                              sticky_runners: { 'probe_sticky' => { tier: :executed, expires_after_deferred_call: 5 } }, deferred_tool_calls: 0
                                                            })
    executor.send(:step_trigger_match)
    executor.send(:step_sticky_runners)
    expect(executor.instance_variable_get(:@triggered_tools)).to include(registry.find_tool('probe_sticky'))
    expect(executor.instance_variable_get(:@freshly_triggered_keys)).not_to include('probe_sticky')
    tool = executor.send(:native_dispatch_tools).fetch(:probe_sticky)
    expect(tool.source).to include(type: :extension, extension: 'probe', runner: 'sticky', function: 'inspect')
  end

  it 'keeps always-loaded GAIA hints before deferred hints regardless of hint order' do
    executor.enrichments['gaia:advisory'] = { data: { tool_hint: %w[probe_alpha probe_always] } }
    hinted = executor.send(:gaia_advisory_tool_entries)
    expect(hinted.map { |entry| entry[:name] }).to eq(%w[probe_always probe_alpha])
  end
end

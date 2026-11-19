# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Legion::LLM::Inference::Background do
  let(:pool) { described_class.new }
  let(:entered) { Queue.new }
  let(:release) { Queue.new }
  let(:ran) { Queue.new }

  before do
    Legion::Settings[:llm][:background] = { workers: 1, max_queue: 1, shutdown_timeout: 1 }
  end

  after do
    release << true
    pool.shutdown
  end

  def block_worker
    pool.post(workload: :capture) do
      entered << true
      release.pop
    end
    Timeout.timeout(2) { entered.pop }
  end

  it 'bounds retained jobs and promptly rejects overflow without caller execution' do
    block_worker
    submitting_thread = Thread.current
    expect(pool.post(workload: :capture) { ran << Thread.current }).to be true
    expect(pool.log).to receive(:warn).with(include('action=rejected', 'workload=capture', 'reason=capacity'))
    Timeout.timeout(1) do
      expect(pool.post(workload: :capture) { raise 'must not run on submitting thread' }).to be false
    end
    expect(pool.stats).to include(queue_length: 1, max_queue: 1, rejected_jobs: 1)
    release << true
    expect(pool.shutdown).to be true
    expect(ran.pop).not_to equal(submitting_thread)
  end

  it 'replaces queued curation with the latest pending task without retaining rejected keys' do
    block_worker
    20.times do |index|
      expect(pool.post(workload: :curation, key: 'conversation') { ran << index }).to be true
    end
    expect(pool.post(workload: :curation, key: 'another') { ran << :rejected }).to be false
    expect(pool.stats).to include(queue_length: 1, keyed_jobs: 1, coalesced_jobs: 19)
    release << true
    pool.shutdown
    expect(ran.size).to eq(1)
    expect(ran.pop).to eq(19)
    expect(pool.stats[:keyed_jobs]).to eq(0)
  end

  it 'runs at most the latest follow-up for an active key, even during shutdown' do
    pool.post(workload: :curation, key: 'conversation') do
      entered << true
      release.pop
      ran << :first
    end
    Timeout.timeout(2) { entered.pop }
    20.times { |index| pool.post(workload: :curation, key: 'conversation') { ran << index } }
    expect(pool.stats).to include(queue_length: 0, keyed_jobs: 1, coalesced_jobs: 20)
    release << true
    expect(pool.shutdown).to be true
    expect([ran.pop, ran.pop]).to eq([:first, 19])
    expect(pool.post(workload: :curation, key: 'conversation') { ran << :late }).to be false
    expect(ran).to be_empty
  end

  it 'continues accepted work after an exception and releases keyed admission' do
    block_worker
    expect(pool).to receive(:handle_exception).with(instance_of(RuntimeError), hash_including(workload: :curation))
    pool.post(workload: :curation, key: 'conversation') { raise 'failed curation' }
    release << true
    expect(pool.shutdown).to be true
    expect(pool.stats[:keyed_jobs]).to eq(0)
  end

  it 'runs already queued work before a coalesced follow-up and drains both on shutdown' do
    pool.post(workload: :curation, key: 'busy') do
      entered << true
      release.pop
      ran << :first
    end
    Timeout.timeout(2) { entered.pop }
    pool.post(workload: :capture) { ran << :other }
    pool.post(workload: :curation, key: 'busy') { ran << :latest }
    expect(pool.stats).to include(queue_length: 1, admitted_jobs: 2)
    release << true
    expect(pool.shutdown).to be true
    expect(ran.size).to eq(3)
    expect(3.times.map { ran.pop }).to eq(%i[first other latest])
    expect(pool.stats).to include(keyed_jobs: 0, admitted_jobs: 0, deferred_jobs: 0)
  end

  it 'retains distinct follow-ups for concurrent keys without exceeding admitted capacity' do
    Legion::Settings[:llm][:background].merge!(workers: 2, max_queue: 2)
    %i[a b].each do |key|
      pool.post(workload: :curation, key: key) do
        entered << true
        release.pop
        ran << key
      end
    end
    Timeout.timeout(2) { 2.times { entered.pop } }
    %i[c d].each { |key| pool.post(workload: :capture) { ran << key } }
    pool.post(workload: :curation, key: :a) { ran << :a_latest }
    pool.post(workload: :curation, key: :b) { ran << :b_latest }
    expect(pool.stats).to include(admitted_jobs: 4, queue_length: 2)
    expect(pool.post(workload: :capture) { ran << :overflow }).to be false
    2.times { release << true }
    expect(pool.shutdown).to be true
    expect(ran.size).to eq(6)
    expect(6.times.map { ran.pop }).to match_array(%i[a b c d a_latest b_latest])
    expect(pool.stats).to include(keyed_jobs: 0, admitted_jobs: 0, deferred_jobs: 0)
  end

  it 'captures validated configuration once and reports a timed-out drain without killing jobs' do
    Legion::Settings[:llm][:background][:shutdown_timeout] = 0
    block_worker
    Legion::Settings[:llm][:background][:max_queue] = 20
    pool.post(workload: :capture) { ran << :drained }
    expect(pool.stats[:max_queue]).to eq(1)
    expect(pool.shutdown).to be false
    expect(pool.post(workload: :capture) { ran << :late }).to be false
    release << true
    expect(Timeout.timeout(2) { ran.pop }).to eq(:drained)
  end

  it 'rebuilds the shared pool with new settings only after a completed shutdown' do
    described_class.shutdown
    described_class.start
    first = described_class.shared
    expect(first.stats[:workers]).to eq(1)
    Legion::Settings[:llm][:background][:workers] = 2
    described_class.start
    expect(described_class.shared).to equal(first)
    described_class.shutdown
    expect(described_class.post(workload: :capture) { raise 'late work' }).to be false
    described_class.start
    expect(described_class.shared).not_to equal(first)
    expect(described_class.stats[:workers]).to eq(2)
  ensure
    described_class.shutdown
    described_class.start
  end

  context 'with invalid settings' do
    # Construct the cleanup pool before temporarily corrupting a setting.
    before { pool }

    { workers: [0, -1, 1.5, '4'], max_queue: [0, -1, nil], shutdown_timeout: [-1, Float::INFINITY] }.each do |key, values|
      values.compact.each do |value|
        it "rejects #{key}=#{value.inspect} before creating an executor" do
          Legion::Settings[:llm][:background][key] = value
          expect(Concurrent::FixedThreadPool).not_to receive(:new)
          expect { described_class.new }.to raise_error(ArgumentError, /background.#{key}/)
        end
      end
    end
  end

  context 'at submission boundaries' do
    before { allow(described_class).to receive(:shared).and_return(pool) }

    it 'skips saturated optional capture with an accurate timeline and no foreground ingestion' do
      block_worker
      pool.post(workload: :capture) { ran << :queued }
      local = Module.new do
        def self.started? = true
        def self.ingest(**) = raise('capture unexpectedly ran')
      end
      stub_const('Legion::Apollo::Local', local)
      expect(local).not_to receive(:ingest)
      Legion::Settings[:llm][:knowledge_capture].merge!(enabled: true, local_ingest_enabled: true, writeback_enabled: false)
      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
      executor = Legion::LLM::Inference::Executor.new(request)
      allow(executor).to receive(:current_response).and_return(double(message: { content: 'answer' }))
      Timeout.timeout(1) { expect(executor.step_knowledge_capture).to be false }
      event = executor.timeline.events.find { |entry| entry[:key] == 'knowledge:capture' }
      expect(event[:detail]).to include('skipped')
      expect(event[:data]).to include(status: :skipped)
    end

    it 'publishes audit and runs metering before rejecting optional post steps' do
      Legion::Settings[:llm][:knowledge_capture].merge!(enabled: true, writeback_enabled: true)
      stub_const('Legion::Extensions::Apollo::Helpers::Writeback', Module.new)
      block_worker
      pool.post(workload: :capture) { ran << :queued }
      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
      executor = Legion::LLM::Inference::Executor.new(request)
      steps = Legion::LLM::Inference::Executor::POST_PROVIDER_STEPS - [:post_response]
      steps.each { |step| allow(executor).to receive(:"step_#{step}") }
      allow(executor).to receive(:current_response).and_return(:response)
      expect(Legion::LLM::Inference::AuditPublisher).to receive(:publish)
        .with(request: request, response: :response).and_return(event: nil, status: :published)
      expect(executor).to receive(:step_metering)
      expect(executor).not_to receive(:step_knowledge_capture)
      executor.send(:execute_post_provider_steps_mixed)
      expect(executor.warnings).to include(/capture skipped/)
      expect(executor.timeline.events).to include(hash_including(key: 'audit:publish', data: { status: :published }))
    end

    [false, true].each do |enabled|
      it "does not admit capture when enabled=#{enabled} but no target exists" do
        Legion::Settings[:llm][:knowledge_capture].merge!(enabled: enabled, writeback_enabled: false, local_ingest_enabled: false)
        request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
        executor = Legion::LLM::Inference::Executor.new(request)
        Legion::LLM::Inference::Executor::POST_PROVIDER_STEPS.each { |step| allow(executor).to receive(:"step_#{step}") }
        expect(described_class).not_to receive(:post)
        executor.send(:execute_post_provider_steps_mixed)
        expect(executor.warnings).to be_empty
      end
    end

    it 'performs admitted post-step capture on the worker without a second queue submission' do
      Legion::Settings[:llm][:knowledge_capture].merge!(enabled: true, local_ingest_enabled: false, writeback_enabled: true)
      writeback = Module.new
      stub_const('Legion::Extensions::Apollo::Helpers::Writeback', writeback)
      allow(writeback).to receive(:evaluate_and_route) { ran << Thread.current }
      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
      executor = Legion::LLM::Inference::Executor.new(request)
      (Legion::LLM::Inference::Executor::POST_PROVIDER_STEPS - [:knowledge_capture]).each do |step|
        allow(executor).to receive(:"step_#{step}")
      end
      allow(executor).to receive(:current_response).and_return(double(message: { content: 'answer' }))
      expect(described_class).to receive(:post).with(workload: :post_steps).once.and_call_original
      executor.send(:execute_post_provider_steps_mixed)
      pool.shutdown
      expect(ran.pop).not_to equal(Thread.current)
      expect(pool.stats[:rejected_jobs]).to eq(0)
    end

    it 'retains raw conversation history when curation is rejected, then allows later curation' do
      block_worker
      pool.post(workload: :capture) { ran << :queued }
      Legion::Settings[:llm][:context_curation][:enabled] = true
      conversations = Legion::LLM::Inference::Conversation
      conversations.append('retained', role: :user, content: 'first question')
      conversations.append('retained', role: :assistant, content: 'first answer')
      before = conversations.raw_messages('retained')
      curator = Legion::LLM::Context::Curator.new(conversation_id: 'retained')
      expect(curator.curate_turn(turn_messages: [], assistant_response: nil)).to be false
      expect(conversations.raw_messages('retained')).to eq(before)
      expect(curator.curated_messages).to be_nil
      release << true
      pool.shutdown
      replacement = described_class.new
      allow(described_class).to receive(:shared).and_return(replacement)
      expect(curator.curate_turn(turn_messages: [], assistant_response: nil)).to be true
      expect(replacement.shutdown).to be true
      expect(conversations.messages('retained').map { |message| message[:content] }).to eq(['first question', 'first answer'])
    ensure
      replacement&.shutdown
    end

    it 'coalesces queued curation across curator instances for the same conversation' do
      block_worker
      Legion::Settings[:llm][:context_curation].merge!(enabled: true, preserve_recent_turns: 2)
      conversations = Legion::LLM::Inference::Conversation
      conversations.append('coalesced', role: :user, content: 'old question')
      conversations.append('coalesced', role: :assistant, content: 'old answer')
      conversations.append('coalesced', role: :user, content: 'previous question')
      conversations.append('coalesced', role: :assistant, content: 'previous answer')
      conversations.append('coalesced', role: :user, content: 'latest question')
      conversations.append('coalesced', role: :assistant, content: 'latest answer')
      first = Legion::LLM::Context::Curator.new(conversation_id: 'coalesced')
      latest = Legion::LLM::Context::Curator.new(conversation_id: 'coalesced')
      expect(first).not_to receive(:store_curated)
      expect(latest).to receive(:store_curated).with('coalesced', anything)
      expect(first.curate_turn(turn_messages: [{}], assistant_response: 'older')).to be true
      expect(latest.curate_turn(turn_messages: [{}], assistant_response: 'latest')).to be true
      release << true
      pool.shutdown
      expect(pool.stats[:coalesced_jobs]).to eq(1)
    end
  end
end

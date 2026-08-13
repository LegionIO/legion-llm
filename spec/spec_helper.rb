# frozen_string_literal: true

require 'simplecov'
require 'base64'
ENV['LEGION_DNS_BOOTSTRAP'] = 'false'
SimpleCov.start do
  add_filter '/spec/'
end

require 'webmock/rspec'

require 'legion/logging'
Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false, color: false)
require 'legion/settings'

require 'legion/json'
require_relative 'support/transport_stub'
require 'legion/llm'
require_relative 'support/ssot_v3_snapshot_factory'

def native_dispatch_result(content: 'test response', input_tokens: 10, output_tokens: 5, tool_calls: [])
  canonical = Legion::Extensions::Llm::Canonical
  usage = canonical::Usage.new(
    input_tokens: input_tokens, output_tokens: output_tokens,
    cache_read_tokens: 0, cache_write_tokens: 0, thinking_tokens: 0, units: {}
  )
  canonical_tool_calls = tool_calls.map do |tc|
    if tc.is_a?(canonical::ToolCall)
      tc
    else
      canonical::ToolCall.new(
        id: tc[:id] || "tc_#{SecureRandom.hex(4)}", exchange_id: nil,
        name: tc[:name].to_s, arguments: tc[:arguments] || {},
        source: tc[:source] || { type: :client }, status: tc[:status],
        duration_ms: nil, result: tc[:result], error: nil,
        started_at: nil, finished_at: nil, category: nil,
        data_handling_classification: nil, policy_decision: nil
      )
    end
  end
  stop = canonical_tool_calls.any? ? :tool_use : :end_turn
  canonical::Response.new(
    text: content.to_s, thinking: nil, tool_calls: canonical_tool_calls,
    usage: usage, stop_reason: stop, model: nil, routing: {}, metadata: {}
  )
end

SSOT_TEST_MODEL = 'gemma-12b'
SSOT_TEST_TIERS = { vllm: :local, ollama: :local, anthropic: :frontier,
                    openai: :frontier, bedrock: :cloud, test: :local }.freeze

# A provider callable that returns canonical results for the SSOT engine
# (SelectionDispatch invokes callable.<operation>). Mirrors the real lex-llm-*
# adapter surface + the Phase 1 normalize_dispatch_error/disconnect contract.
class SsotStubCallable
  def initialize(content:, input_tokens:, output_tokens:, tool_calls:)
    @content = content
    @input_tokens = input_tokens
    @output_tokens = output_tokens
    @tool_calls = tool_calls
    @disconnects = 0
  end

  def disconnect = (@disconnects += 1)

  def chat(messages:, model:, **)
    _ = [messages, model]
    native_dispatch_result(content: @content, input_tokens: @input_tokens,
                           output_tokens: @output_tokens, tool_calls: @tool_calls)
  end

  def stream_chat(messages:, model:, **, &block)
    _ = [messages, model]
    result = chat(messages: messages, model: model)
    block&.call(Struct.new(:content).new(@content))
    result
  end

  def embed(text:, model:, **)
    _ = [text, model]
    { result: [Array.new(1024, 0.1)], usage: { input_tokens: @input_tokens, output_tokens: 0 } }
  end

  def count_tokens(messages:, model:, **)
    _ = [messages, model]
    { content: @input_tokens, usage: {} }
  end

  def normalize_dispatch_error(error:)
    llm = Legion::Extensions::Llm
    kind = case error
           when llm::OverloadedError then :overloaded
           when llm::RateLimitError then :rate_limited
           when llm::UnauthorizedError then :authentication
           when llm::ForbiddenError then :authorization
           when llm::BadRequestError then :invalid_request
           else :provider_error
           end
    reason = error.class.name
    reason = 'UnknownError' if reason.nil? || reason.empty?
    llm::Routing::ProviderOutcome.new(kind: kind, reason: reason)
  end
end

# SSOT v3: publish a default set of exact provider instances into the Phase 1
# Registry so the single execution engine (Router.next_lane -> RoutingSession ->
# SelectionDispatch) can select for ordinary chat/stream/embed specs. Replaces
# the legacy Inventory.write_lane fixtures — there is no legacy selector anymore.
def stub_native_provider(content: 'test response', input_tokens: 10, output_tokens: 5, tool_calls: [], **)
  reg = Legion::Extensions::Llm::Inventory::Registry
  reg.reset!
  SSOT_TEST_TIERS.each do |provider, tier|
    SsotV3SnapshotFactory.activate(
      provider_family: provider.to_s,
      instance_id:     'primary',
      callable:        SsotStubCallable.new(content: content, input_tokens: input_tokens,
                                            output_tokens: output_tokens, tool_calls: tool_calls),
      drafts:          [SsotV3SnapshotFactory.offering_draft(
        model:                SSOT_TEST_MODEL,
        tier:                 tier,
        supported:            %i[chat stream_chat embed count_tokens],
        capabilities:         { streaming: :supported, tools: :supported, vision: :supported,
                                thinking: :supported, embedding: :supported },
        context:              200_000,
        max_output:           16_384,
        embedding_dimensions: [1024]
      )]
    )
  end
  native_dispatch_result(content: content, input_tokens: input_tokens,
                         output_tokens: output_tokens, tool_calls: tool_calls)
end

# SSOT v3 shim: publish ONE exact provider instance into the Phase 1 Registry.
# Replaces the legacy Inventory.write_lane fixture — same call sites, but the
# single engine selects it via Router.next_lane. `type`/`capabilities` map to
# operation + capability evidence; unknown kwargs are ignored.
def write_test_lane(provider: :vllm, instance: :default, model: SSOT_TEST_MODEL, tier: :local,
                    type: :inference, capabilities: %i[tools streaming vision thinking], **)
  ops = case type.to_sym
        when :embedding then %i[embed]
        when :image then %i[image]
        when :audio then %i[transcribe translate speak]
        else %i[chat stream_chat count_tokens]
        end
  cap_map = { tools: :tools, streaming: :streaming, vision: :vision, thinking: :thinking,
              embedding: :embedding }
  caps = Array(capabilities).each_with_object({}) do |c, h|
    canon = cap_map[c.to_sym]
    h[canon] = :supported if canon
  end
  SsotV3SnapshotFactory.activate(
    provider_family: provider.to_s,
    # InstanceKey rejects the reserved "default"; map legacy :default fixtures to a valid id.
    instance_id:     (instance.to_s == 'default' ? 'primary' : instance.to_s),
    callable:        SsotStubCallable.new(content: 'test response', input_tokens: 10,
                                          output_tokens: 5, tool_calls: []),
    drafts:          [SsotV3SnapshotFactory.offering_draft(
      model: model.to_s, tier: tier.to_sym, supported: ops, capabilities: caps,
      context: 200_000, max_output: 16_384, embedding_dimensions: (ops.include?(:embed) ? [1024] : nil)
    )]
  )
end

# Seed Discovery's per-provider model cache (a Concurrent::Map keyed by provider)
# the way the provider DiscoveryRefresh ::Every actors do. Accepts a flat list of
# discovered-model hashes (each carrying :provider).
def seed_discovered_models(models)
  map = Concurrent::Map.new
  Array(models).group_by { |m| m[:provider] }.each { |provider, list| map[provider] = list }
  Legion::LLM::Inventory::Discovery.instance_variable_set(:@discovered_models, map)
end

RSpec.configure do |config|
  config.before(:each) do
    Legion::Settings.reset!
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings.merge_settings('transport', Legion::Transport::Settings.default) if
      defined?(Legion::Transport::Settings)
    Legion::Settings[:logging][:level] = :fatal
    Legion::LLM::Call::Registry.reset! if defined?(Legion::LLM::Call::Registry)
    Legion::LLM::Inventory::Discovery.reset! if defined?(Legion::LLM::Inventory::Discovery)
    # Re-register standard providers after reset so router resolution works
    if defined?(Legion::LLM::Call::Registry)
      %i[anthropic test bedrock openai ollama vllm azure_foundry gemini xai].each do |provider|
        Legion::LLM::Call::Registry.register(provider, Module.new) unless
          Legion::LLM::Call::Registry.registered?(provider)
      end
    end
    # Seed the extensions[:llm] path so specs can write provider configs there
    Legion::Settings[:extensions][:llm] ||= {}
    # Keep the full suite deterministic even when local/provider gems are present
    # and services like Ollama are running on the developer machine.
    Legion::Settings[:llm][:provider_layer][:mode] = 'auto'
    Legion::Settings[:llm][:pipeline_async_post_steps] = false
    # Disable system_baseline by default so existing pipeline mocks are unaffected.
    # Specs that test baseline behavior set it explicitly.
    Legion::Settings[:llm][:system_baseline] = nil
    # Reset P1 live inventory store so write_lane tests start clean.
    Legion::LLM::Inventory.reset_live_store! if Legion::LLM::Inventory.respond_to?(:reset_live_store!)
    # SSOT v3: start every example with an empty Phase 1 Registry. Specs that
    # exercise routing publish exact instances via stub_native_provider /
    # write_test_lane / the ssot_v3 factory. (ssot_v3-tagged specs reset again
    # in their own before hook.)
    Legion::Extensions::Llm::Inventory::Registry.reset!

    # Flush the shared cache between examples. A spec that connects Legion::Cache
    # (e.g. cache_spec's Legion::Cache.setup) leaves it connected for the rest of
    # the run; without this, embeddings/response caching would return stale hits
    # and skip provider dispatch in later specs — order-dependent failures.
    Legion::Cache.flush if defined?(Legion::Cache) && Legion::Cache.respond_to?(:flush) &&
                           Legion::Cache.respond_to?(:connected?) && Legion::Cache.connected?
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router_new'

# Fail-forward RELEASE BAR re-encoded against the NEW Legion::LLM::Router CLASS.
#
# Source: ssot_v3_fail_forward_release_bar_spec.rb (the 529 production incident).
# This spec asserts 6 bars on a frozen operator config using the per-request
# Router instance API (Router.new(request:, operation:, body_model:).next_lane)
# instead of the legacy stateless Router.next_lane(requirements:, exclusions:, snapshot:).
#
# API mapping (old -> new):
#   - Router.next_lane(requirements:, exclusions:, snapshot:)
#     -> Router.new(request:, operation:, body_model:).next_lane
#     (instance-per-request; fetches Registry.snapshot LIVE — seed the Registry)
#   - RequestRequirements.build(..., estimated_input_bound: BUDGET)
#     -> context_budget = input_bound_for + tokens[:max]
#     (set input_framing_overhead_tokens = 0 and use tokens[:max] to steer budget)
#   - RequiredCapabilities.call
#     -> Router derives capabilities from request shape (tools, thinking, stream)
#   - Router::SettingsState.reset!
#     -> Settings[:llm][:router] + Settings[:extensions][:llm] set directly
#
# Budget steering strategy:
#   input_framing_overhead_tokens = 0. For exact-seam tests (4_095 vs 4_096),
#   a minimal stream request (nil tools/thinking/system, empty messages) is used
#   so input_bound = 0 and context_budget = tokens[:max] exactly. For large-budget
#   tests (100_000, 200_000), the full CLI request adds a small deterministic
#   input_bound (< 5_000 bytes from tools/system/message serialization) that stays
#   well inside the target preferred band.
SEED_MAIN = 'a1b2c3d4' * 4
SEED_ALT  = '0f1e2d3c' * 4

# The two ollama config names point at the SAME physical endpoint — the
# collapse scenario bar item 3 forbids.
APOLLO_ENDPOINT = '10.0.1.20:11434'
HELIOS_ENDPOINT = '10.0.1.11:8000'

RSpec.describe Legion::LLM::Router, '#next_lane — fail-forward release bar (new Router class)', :ssot_v3 do
  # ------------------------------------------------------------------ #
  # The frozen employee config, byte-for-byte.                          #
  # ------------------------------------------------------------------ #

  def frozen_extensions_llm
    {
      vllm:    {
        enable_thinking:  true,
        enable_streaming: true,
        instances:        {
          'helios-0001' => {
            enable_thinking: true, enable_tools: true, weight: 115,
            preferred_min_context_tokens: 48_000, preferred_max_context_tokens: 262_000,
            default_model: 'helios-model', tier: :direct
          },
          'h200'        => {
            enable_thinking: true, enable_tools: true, weight: 110,
            preferred_min_context_tokens: 4_096, preferred_max_context_tokens: 48_000,
            default_model: 'h200-model', tier: :direct
          },
          'v100'        => {
            enable_thinking: true, enable_tools: true, weight: 111,
            preferred_min_context_tokens: 1, preferred_max_context_tokens: 4_096,
            default_model: 'v100-model', tier: :direct
          }
        }
      },
      bedrock: {
        instances: {
          'uais' => { default_model: 'anthropic.claude-sonnet-4-5', region: 'us-east-1', tier: :cloud }
        }
      },
      ollama:  {
        instances: {
          'apollo'       => { default_model: 'gemma3', tier: :local },
          'apollo-embed' => { default_model: 'nomic-embed', tier: :local }
        }
      }
    }
  end

  before do
    Legion::Settings.loader.settings[:llm] ||= {}
    Legion::Settings.loader.settings[:llm][:router] = Legion::LLM::Settings::Router.defaults.merge(
      input_framing_overhead_tokens: 0
    )
    Legion::Settings.loader.settings[:extensions] ||= {}
    Legion::Settings.loader.settings[:extensions][:llm] = frozen_extensions_llm
  end

  # ------------------------------------------------------------------ #
  # Registry seeding — config NAME identity + derived physical_id       #
  # ------------------------------------------------------------------ #

  def keyed_instance(provider_family:, instance_id:, physical_id:)
    inventory::Identity::InstanceKey.new(
      provider_family: provider_family, instance_id: instance_id, physical_id: physical_id
    )
  end

  def publish(instance_key:, drafts:)
    callable    = SsotV3SnapshotFactory::FactoryCallable.new
    coordinator = inventory::ProbeCoordinator.new(instance_key: instance_key, enqueue: ->(**) { true })
    token       = inventory::Registry.claim_instance(instance_key: instance_key, callable: callable,
                                                     probe_request_handle: coordinator)
    probe       = inventory::Registry.readiness_probe_started(instance_key: instance_key, publisher_token: token)
    inventory::Registry.activate_instance_snapshot(
      publisher_token: token, instance_key: instance_key, offerings: drafts, sequence: 0, probe_token: probe
    )
    token
  end

  def seed_frozen_world!
    # vllm: streaming+tools :supported, thinking :unknown (cannot attest from config).
    vllm_caps = { streaming: :supported, tools: :supported }
    @tokens = {}
    @tokens['vllm/helios-0001'] = publish(
      instance_key: keyed_instance(provider_family: 'vllm', instance_id: 'helios-0001', physical_id: HELIOS_ENDPOINT),
      drafts:       [offering_draft(model: 'helios-model', tier: :direct, supported: %i[chat stream_chat],
                                    capabilities: vllm_caps, context: 294_912,
                                    weight_inputs: { tier: 150, provider: 100, instance: 115,
                                                     model_or_offering: 100 },
                                    base_weight: 172_500_000)]
    )
    @tokens['vllm/h200'] = publish(
      instance_key: keyed_instance(provider_family: 'vllm', instance_id: 'h200', physical_id: '10.0.1.12:8000'),
      drafts:       [offering_draft(model: 'h200-model', tier: :direct, supported: %i[chat stream_chat],
                                    capabilities: vllm_caps, context: 49_152,
                                    weight_inputs: { tier: 150, provider: 100, instance: 110,
                                                     model_or_offering: 100 },
                                    base_weight: 165_000_000)]
    )
    @tokens['vllm/v100'] = publish(
      instance_key: keyed_instance(provider_family: 'vllm', instance_id: 'v100', physical_id: '10.0.1.13:8000'),
      drafts:       [offering_draft(model: 'v100-model', tier: :direct, supported: %i[chat stream_chat],
                                    capabilities: vllm_caps, context: 4_608,
                                    weight_inputs: { tier: 150, provider: 100, instance: 111,
                                                     model_or_offering: 100 },
                                    base_weight: 166_500_000)]
    )
    # bedrock uais: its claude model attests thinking.
    @tokens['bedrock/uais'] = publish(
      instance_key: keyed_instance(provider_family: 'bedrock', instance_id: 'uais', physical_id: 'us-east-1'),
      drafts:       [offering_draft(model: 'anthropic.claude-sonnet-4-5', tier: :cloud, supported: %i[chat stream_chat],
                                    capabilities: { streaming: :supported, tools: :supported, thinking: :supported },
                                    context: 200_000,
                                    weight_inputs: { tier: 110, provider: 100, instance: 100,
                                                     model_or_offering: 100 },
                                    base_weight: 110_000_000)]
    )
    # ollama: two config names on ONE physical endpoint; tools/thinking :unknown.
    @tokens['ollama/apollo'] = publish(
      instance_key: keyed_instance(provider_family: 'ollama', instance_id: 'apollo', physical_id: APOLLO_ENDPOINT),
      drafts:       [offering_draft(model: 'gemma3', tier: :local, supported: %i[chat stream_chat],
                                    capabilities: { streaming: :supported }, context: 32_768,
                                    weight_inputs: { tier: 140, provider: 100, instance: 100,
                                                     model_or_offering: 100 },
                                    base_weight: 140_000_000)]
    )
    # Embedding model: chat is authoritatively :unsupported (decision 6).
    @tokens['ollama/apollo-embed'] = publish(
      instance_key: keyed_instance(provider_family: 'ollama', instance_id: 'apollo-embed', physical_id: APOLLO_ENDPOINT),
      drafts:       [offering_draft(model: 'nomic-embed', tier: :local, supported: %i[embed],
                                    unsupported: %i[chat stream_chat],
                                    capabilities: { embedding: :supported, streaming: :supported },
                                    context: 8_192, embedding_dimensions: [768],
                                    weight_inputs: { tier: 140, provider: 100, instance: 100,
                                                     model_or_offering: 100 },
                                    base_weight: 140_000_000)]
    )
  end

  def trip(provider_family:, instance_id:, physical_id:)
    key = keyed_instance(provider_family: provider_family, instance_id: instance_id, physical_id: physical_id)
    inventory::Registry.dispatch_instance_unavailable(
      instance_key: key, publisher_token_id: @tokens["#{provider_family}/#{instance_id}"].publisher_token_id,
      reason: 'release bar: simulated dispatch failure'
    )
  end

  # ------------------------------------------------------------------ #
  # Request shapes — production derivation                              #
  # ------------------------------------------------------------------ #

  def claude_cli_tools
    Array.new(20) do |i|
      {
        name:         "ops_tool_#{format('%02d', i + 1)}",
        description:  'Operational tool surfaced to the agent.',
        input_schema: { type: 'object', properties: { value: { type: 'string' } }, required: %w[value] }
      }
    end
  end

  # A Claude CLI tools+thinking stream request. Provider pin only when
  # the adversarial scenario sets it. tokens[:max] steers context_budget
  # (with overhead = 0, budget = input_bound + tokens[:max]).
  def claude_cli_request(seed:, pinned_provider: nil, budget_tokens: 100_000)
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed: seed,
      routing:      pinned_provider ? { provider: pinned_provider } : { provider: nil, model: nil },
      messages:     [{ role: :user, content: 'Summarize the incident.' }],
      system:       'You are LegionIO.',
      tools:        claude_cli_tools,
      thinking:     { enabled: true, budget_tokens: 4_096 },
      stream:       true,
      tokens:       { max: budget_tokens }
    )
  end

  # Minimal stream request for budget-precise tests. With overhead = 0 and nil
  # tools/thinking/system/response_format, input_bound = 0 and
  # context_budget = tokens[:max] exactly.
  def precise_budget_request(seed:, budget:)
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed:    seed,
      messages:        [],
      system:          nil,
      tools:           nil,
      tool_choice:     nil,
      thinking:        nil,
      response_format: nil,
      stream:          true,
      tokens:          { max: budget }
    )
  end

  def plain_chat_request(seed:, budget_tokens: 0)
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed:    seed,
      messages:        [],
      system:          nil,
      tools:           nil,
      tool_choice:     nil,
      thinking:        nil,
      response_format: nil,
      stream:          false,
      tokens:          { max: budget_tokens }
    )
  end

  # Build a Router instance from a request. operation derived from stream flag.
  def build_router_for(request, body_model: nil)
    operation = request.stream == true ? :stream_chat : :chat
    Legion::LLM::Router.new(request: request, operation: operation, body_model: body_model)
  end

  def next_lane_for(request, body_model: nil)
    build_router_for(request, body_model: body_model).next_lane
  end

  # ------------------------------------------------------------------ #
  # Bar 1 — Claude CLI tools+thinking does NOT 529                      #
  # ------------------------------------------------------------------ #

  describe 'bar 1 — a Claude CLI tools+thinking stream request routes (no 529)' do
    it 'derives the tools+thinking requirement set from the request shape' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN)
      router  = build_router_for(request)

      expect(router.operation).to eq(:stream_chat)
      expect(router.required_capabilities).to include(:streaming, :tools, :thinking)
      expect(router.provider_pin).to be_nil
    end

    it 'routes to a vllm instance where the operator enable_thinking override satisfies :thinking' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN, budget_tokens: 100_000)
      result  = next_lane_for(request)

      # A Selection, not a Rejection: no unbounded 529 retry loop. The vllm
      # :thinking evidence is :unknown; the operator's config-name keyed
      # enable_thinking: true is what satisfies the axis.
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:vllm)
      expect(result.instance_id).to eq('helios-0001')
      expect(result.model).to eq('helios-model')
      # Name-keyed weight resolved into the decision inputs (150 direct x 115 instance).
      expect(result.weight_inputs).to eq(tier: 150, provider: 100, instance: 115, model_or_offering: 100)
      expect(result.base_weight).to eq(172_500_000)
    end
  end

  # ------------------------------------------------------------------ #
  # Bar 2 — name-keyed tuning resolves (weight ranking + bin seam)      #
  # ------------------------------------------------------------------ #

  describe 'bar 2 — per-instance weight / preferred_context resolve by config NAME' do
    it 'preferred_context steers by config NAME: budget 10_000 routes to h200, not higher-weight helios-0001' do
      seed_frozen_world!
      # With overhead = 0, precise_budget_request gives context_budget = 10_000 exactly.
      # 10_000 is inside h200's [4096, 48000) and outside helios's [48000, 262000).
      request = precise_budget_request(seed: SEED_MAIN, budget: 10_000)
      result  = next_lane_for(request)

      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.instance_id).to eq('h200')
      expect(result.model).to eq('h200-model')
    end

    it 'keeps the bin seam upper-exclusive: budget == preferred_max leaves v100 and enters h200' do
      seed_frozen_world!
      # With precise_budget_request: context_budget = tokens[:max] exactly (input_bound = 0).
      # v100's range is [1, 4096): 4_095 matches, 4_096 does NOT (budget < max).
      # h200's range is [4096, 48000): 4_096 matches (inclusive lower bound).
      req_below   = precise_budget_request(seed: SEED_MAIN, budget: 4_095)
      req_at_seam = precise_budget_request(seed: SEED_MAIN, budget: 4_096)

      below   = next_lane_for(req_below)
      at_seam = next_lane_for(req_at_seam)

      expect(below.instance_id).to eq('v100')
      expect(at_seam.instance_id).to eq('h200')
    end

    it 'per-instance weight ranking decides: with the generalist lanes tripped, helios (115) outranks v100 (111) and h200 (110)' do
      seed_frozen_world!
      trip(provider_family: 'bedrock', instance_id: 'uais', physical_id: 'us-east-1')
      trip(provider_family: 'ollama', instance_id: 'apollo', physical_id: APOLLO_ENDPOINT)

      # Budget 0 matches no preferred range; the full vllm ready set competes
      # purely on name-keyed instance weight: 150 x 115 vs 150 x 111 vs 150 x 110.
      request = plain_chat_request(seed: SEED_MAIN, budget_tokens: 0)
      result  = next_lane_for(request)
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.instance_id).to eq('helios-0001')
      expect(result.weight_inputs).to eq(tier: 150, provider: 100, instance: 115, model_or_offering: 100)
      expect(result.base_weight).to eq(172_500_000)

      # Deterministic across seeds: weight picks the winner, not the rendezvous tie-break.
      again_request = plain_chat_request(seed: SEED_ALT, budget_tokens: 0)
      again = next_lane_for(again_request)
      expect(again.instance_id).to eq('helios-0001')
    end

    it 'ranks every ready lane by weight when no preferred range matches' do
      seed_frozen_world!
      request = plain_chat_request(seed: SEED_MAIN, budget_tokens: 0)
      result  = next_lane_for(request)

      # No band contains zero, so pass 2 ranks all ready lanes. Direct helios
      # (150 tier x 115 instance) outranks local apollo and cloud uais.
      expect(result.provider_family).to eq(:vllm)
      expect(result.instance_id).to eq('helios-0001')
      expect(result.model).to eq('helios-model')
      expect(result.weight_inputs[:tier]).to eq(150)
    end
  end

  # ------------------------------------------------------------------ #
  # Bar 3 — shared endpoint does not collapse config names              #
  # ------------------------------------------------------------------ #

  describe 'bar 3 — apollo and apollo-embed are two distinct instances' do
    it 'keeps both instances published under their config names on the same physical endpoint' do
      seed_frozen_world!
      apollo_key = keyed_instance(provider_family: 'ollama', instance_id: 'apollo', physical_id: APOLLO_ENDPOINT)
      embed_key  = keyed_instance(provider_family: 'ollama', instance_id: 'apollo-embed', physical_id: APOLLO_ENDPOINT)

      snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
      apollo = snap.instance(instance_key: apollo_key)
      embed  = snap.instance(instance_key: embed_key)

      # If identity had collapsed to the derived host:port, the second claim
      # would have superseded the first and one key would be absent.
      expect(apollo).not_to be_nil
      expect(embed).not_to be_nil
      expect(apollo.instance_key.instance_id).to eq('apollo')
      expect(embed.instance_key.instance_id).to eq('apollo-embed')
      expect(apollo.instance_key.physical_id).to eq(APOLLO_ENDPOINT)
      expect(embed.instance_key.physical_id).to eq(APOLLO_ENDPOINT)
      expect(snap.lanes_for(instance_key: apollo_key).map(&:model)).to eq(['gemma3'])
      expect(snap.lanes_for(instance_key: embed_key).map(&:model)).to eq(['nomic-embed'])
    end
  end

  # ------------------------------------------------------------------ #
  # Bar 4 — tripped instance recovers without a restart                 #
  # ------------------------------------------------------------------ #

  describe 'bar 4 — dispatch_instance_unavailable recovers without a restart' do
    it 'probe -> readiness_succeeded -> available -> re-selectable on the next snapshot' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN, budget_tokens: 100_000)
      expect(next_lane_for(request).instance_id).to eq('helios-0001')

      helios_key = keyed_instance(provider_family: 'vllm', instance_id: 'helios-0001', physical_id: HELIOS_ENDPOINT)
      token      = @tokens['vllm/helios-0001']
      inventory::Registry.dispatch_instance_unavailable(
        instance_key: helios_key, publisher_token_id: token.publisher_token_id,
        reason: 'release bar: simulated dispatch failure'
      )
      snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
      expect(snap.instance(instance_key: helios_key).availability.state).to eq(:unavailable)

      # The tripped lane is out; bedrock uais serves the 100k budget.
      expect(next_lane_for(claude_cli_request(seed: SEED_MAIN, budget_tokens: 100_000)).instance_id).to eq('uais')

      # Recovery is the registry's own probe path: the SAME publisher token,
      # no re-claim, no restart.
      probe = inventory::Registry.readiness_probe_started(instance_key: helios_key, publisher_token: token)
      inventory::Registry.readiness_succeeded(instance_key: helios_key, probe_token: probe)

      recovered_snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
      recovered = recovered_snap.instance(instance_key: helios_key)
      expect(recovered.availability.state).to eq(:available)
      expect(recovered.availability.source).to eq(:readiness)

      # Re-selectable on the next snapshot, under the same publisher identity.
      sel = next_lane_for(claude_cli_request(seed: SEED_MAIN, budget_tokens: 100_000))
      expect(sel.instance_id).to eq('helios-0001')
      expect(sel.publisher_token_id).to eq(token.publisher_token_id)
    end
  end

  # ------------------------------------------------------------------ #
  # Bar 5 — embedding model excluded from plain chat                    #
  # ------------------------------------------------------------------ #

  describe 'bar 5 — no misroute from plain chat to the embedding model' do
    it 'never selects the embedding instance/model for a plain chat request' do
      seed_frozen_world!
      request = plain_chat_request(seed: SEED_MAIN, budget_tokens: 10_000)
      result  = next_lane_for(request)

      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.instance_id).not_to eq('apollo-embed')
      expect(result.model).not_to eq('nomic-embed')

      # The exclusion is AUTHORITATIVE operation evidence: chat is :unsupported
      # on the embedding draft. The structural expression is that the ONLY lane
      # on that instance is the embed lane.
      embed_key = keyed_instance(provider_family: 'ollama', instance_id: 'apollo-embed', physical_id: APOLLO_ENDPOINT)
      snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
      expect(snap.lanes_for(instance_key: embed_key).map(&:operation)).to eq([:embed])
    end

    it 'does route an embed request to the embedding instance (the distinction is real)' do
      seed_frozen_world!
      request = Legion::LLM::Inference::Request.build_for_test(
        routing_seed: SEED_MAIN, messages: [], system: nil,
        tools: nil, tool_choice: nil, thinking: nil,
        response_format: nil, stream: false, tokens: { max: 0 },
        extra: { embedding_dimensions: 768 }
      )
      router = Legion::LLM::Router.new(request: request, operation: :embed, body_model: nil)
      result = router.next_lane

      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.instance_id).to eq('apollo-embed')
      expect(result.model).to eq('nomic-embed')
      expect(result.operation).to eq(:embed)
    end
  end

  # ------------------------------------------------------------------ #
  # Bar 6 — adversarial typed failures, never 529                       #
  # ------------------------------------------------------------------ #

  describe 'bar 6 — adversarial: typed failures, never a 529 loop' do
    it 'a provider-PINNED tools+thinking request to ollama (no enable_thinking, evidence :unknown) is typed 400 invalid_request' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN, pinned_provider: 'ollama', budget_tokens: 100_000)
      result  = next_lane_for(request)

      expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      # Terminal settled-unknown on a complete scope is a typed no-lane (400 in
      # every dialect), never a too_early retry that the Anthropic dialect
      # renders as 529 with Retry-After.
      expect(result.kind).to eq(:invalid_request)
      expect(result.http_status).to eq(400)
      expect(result.kind).not_to eq(:too_early)
    end

    it 'a tripped (unavailable) instance reports 503 service_unavailable, not a 529-class overload verdict' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN, budget_tokens: 200_000)
      # Establish the serving lane: only helios-0001 fits the 200k budget at 90%
      # headroom (h200/v100 too small, bedrock's 180k usable < ~200k budget).
      expect(next_lane_for(request).instance_id).to eq('helios-0001')

      trip(provider_family: 'vllm', instance_id: 'helios-0001', physical_id: HELIOS_ENDPOINT)
      result = next_lane_for(claude_cli_request(seed: SEED_MAIN, budget_tokens: 200_000))

      # Tripped reports before unknown: 503, recoverable without a restart.
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      expect(result.kind).to eq(:service_unavailable)
      expect(result.http_status).to eq(503)
    end
  end
end

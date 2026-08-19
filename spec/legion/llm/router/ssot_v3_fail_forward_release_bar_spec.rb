# frozen_string_literal: true

require 'spec_helper'

# SSOT v3 fail-forward RELEASE BAR — behavioral spec on the FROZEN employee config.
#
# Design: legion/docs/legion-llm/ssot_v3/2026-08-16-failforward-release-design.md
# (outcomes only; config is frozen). The bar:
#
#   1. A Claude CLI tools+thinking stream request does NOT 529 — it routes to a
#      vllm instance, where the operator's enable_thinking: true satisfies the
#      :thinking override. [the production bug]
#   2. Name-keyed tuning resolves: per-instance weight / preferred_context, keyed
#      by the config NAME, actually affect the router decision (weight ranking
#      and the bin seam).
#   3. ollama apollo and apollo-embed are TWO distinct instances — a shared
#      endpoint does not collapse them.
#   4. A tripped vllm instance (dispatch_instance_unavailable) recovers WITHOUT
#      a restart: probe -> readiness_succeeded -> available -> re-selectable on
#      the next snapshot.
#   5. An embedding instance/model is EXCLUDED from a plain chat request (no
#      misroute to an embedding model).
#   6. Adversarial: a provider-PINNED tools+thinking request to a provider that
#      cannot serve it (ollama: no enable_thinking, evidence :unknown) is a
#      TYPED failure (400 / invalid_request), NOT 529. A tripped (unavailable)
#      instance reports 503, not 529.
#
# Seeding follows the router/registry spec substrate (SsotV3SnapshotFactory +
# the real Phase 1 Registry API) the same way spec/legion/llm/api/matrix/ drives
# the engine end to end: config NAME as InstanceKey.instance_id, the derived
# host:port as the secondary physical_id, and HONEST capability evidence —
# vllm publishes streaming+tools :supported but :thinking :unknown (the provider
# cannot attest it from config; config is contract-forbidden as evidence),
# bedrock uais attests :thinking for its claude model, ollama tools/thinking
# :unknown (standard Ollama does not return a capabilities field).
#
# Context windows published below are consistent with the operator's preferred
# ranges (preferred_max_context_tokens sits inside the published window; the
# router's 90% headroom then bounds the hard context axis).
#
# This spec asserts the bar and changes no lib code: if it fails, the failure
# is a lib defect to report, not an assertion to weaken.
SEED_MAIN = 'a1b2c3d4' * 4
SEED_ALT  = '0f1e2d3c' * 4

# The two ollama config names point at the SAME physical endpoint — the
# collapse scenario bar item 3 forbids.
APOLLO_ENDPOINT = '10.0.1.20:11434'
HELIOS_ENDPOINT = '10.0.1.11:8000'

RSpec.describe Legion::LLM::Router, '.next_lane — SSOT v3 fail-forward release bar (frozen config)', :ssot_v3 do
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
    Legion::Settings[:extensions][:llm] = frozen_extensions_llm
    # Reset so the first request/selection installs generation 1 from the
    # frozen config (SettingsState.current lazily installs).
    Legion::LLM::Router::SettingsState.reset!
  end

  # ------------------------------------------------------------------ #
  # Registry seeding — config NAME identity + derived physical_id       #
  # ------------------------------------------------------------------ #

  def keyed_instance(provider_family:, instance_id:, physical_id:)
    inventory::Identity::InstanceKey.new(
      provider_family: provider_family, instance_id: instance_id, physical_id: physical_id
    )
  end

  # claim -> readiness_probe_started -> activate_instance_snapshot (startup
  # readiness), mirroring SsotV3SnapshotFactory.activate but with an explicit
  # keyed instance (carrying its secondary physical_id).
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
                                    capabilities: vllm_caps, context: 294_912)]
    )
    @tokens['vllm/h200'] = publish(
      instance_key: keyed_instance(provider_family: 'vllm', instance_id: 'h200', physical_id: '10.0.1.12:8000'),
      drafts:       [offering_draft(model: 'h200-model', tier: :direct, supported: %i[chat stream_chat],
                                    capabilities: vllm_caps, context: 49_152)]
    )
    @tokens['vllm/v100'] = publish(
      instance_key: keyed_instance(provider_family: 'vllm', instance_id: 'v100', physical_id: '10.0.1.13:8000'),
      drafts:       [offering_draft(model: 'v100-model', tier: :direct, supported: %i[chat stream_chat],
                                    capabilities: vllm_caps, context: 4_608)]
    )
    # bedrock uais: its claude model attests thinking.
    @tokens['bedrock/uais'] = publish(
      instance_key: keyed_instance(provider_family: 'bedrock', instance_id: 'uais', physical_id: 'us-east-1'),
      drafts:       [offering_draft(model: 'anthropic.claude-sonnet-4-5', tier: :cloud, supported: %i[chat stream_chat],
                                    capabilities: { streaming: :supported, tools: :supported, thinking: :supported },
                                    context: 200_000)]
    )
    # ollama: two config names on ONE physical endpoint; tools/thinking :unknown.
    @tokens['ollama/apollo'] = publish(
      instance_key: keyed_instance(provider_family: 'ollama', instance_id: 'apollo', physical_id: APOLLO_ENDPOINT),
      drafts:       [offering_draft(model: 'gemma3', tier: :local, supported: %i[chat stream_chat],
                                    capabilities: { streaming: :supported }, context: 32_768)]
    )
    # Embedding model: chat is authoritatively :unsupported (decision 6).
    @tokens['ollama/apollo-embed'] = publish(
      instance_key: keyed_instance(provider_family: 'ollama', instance_id: 'apollo-embed', physical_id: APOLLO_ENDPOINT),
      drafts:       [offering_draft(model: 'nomic-embed', tier: :local, supported: %i[embed],
                                    unsupported: %i[chat stream_chat],
                                    capabilities: { embedding: :supported, streaming: :supported },
                                    context: 8_192, embedding_dimensions: [768])]
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
  # Request shapes — production derivation (executor parity)            #
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

  # A Claude CLI tools+thinking stream request: ~20 tools, thinking enabled,
  # stream on. Provider pin only when the adversarial scenario sets it.
  def claude_cli_request(seed:, pinned_provider: nil)
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed: seed,
      routing:      pinned_provider ? { provider: pinned_provider } : { provider: nil, model: nil },
      messages:     [{ role: :user, content: 'Summarize the incident timeline from the attached logs.' }],
      system:       'You are LegionIO, an internal operations agent with access to the platform tool catalog.',
      tools:        claude_cli_tools,
      thinking:     { enabled: true, budget_tokens: 4_096 },
      stream:       true
    )
  end

  def plain_chat_request(seed:)
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed: seed,
      messages:     [{ role: :user, content: 'What time is it on the node?' }],
      stream:       false
    )
  end

  # Mirror the executor's requirement derivation (operation + RequiredCapabilities),
  # with an exact context budget so each scenario is deterministic.
  def chat_requirements(request, budget:)
    operation = request.stream == true ? :stream_chat : :chat
    Legion::LLM::Router::RequestRequirements.build(
      request:                request,
      operation:              operation,
      required_capabilities:  Legion::LLM::Router::RequiredCapabilities.call(request: request, operation: operation),
      estimated_input_bound:  budget,
      required_output_tokens: 0
    )
  end

  def embed_requirements(seed:)
    request = Legion::LLM::Inference::Request.build_for_test(routing_seed: seed, messages: [])
    Legion::LLM::Router::RequestRequirements.build(
      request:                        request,
      operation:                      :embed,
      required_capabilities:          %i[embedding],
      estimated_input_bound:          0,
      required_output_tokens:         0,
      requested_embedding_dimensions: 768
    )
  end

  def next_lane_for_requirements(reqs)
    described_class.next_lane(requirements: reqs, exclusions: [], snapshot: snapshot)
  end

  # ------------------------------------------------------------------ #
  # Bar 1 — Claude CLI tools+thinking does NOT 529                      #
  # ------------------------------------------------------------------ #

  describe 'bar 1 — a Claude CLI tools+thinking stream request routes (no 529)' do
    it 'derives the tools+thinking requirement set from the request shape' do
      request = claude_cli_request(seed: SEED_MAIN)
      reqs    = chat_requirements(request, budget: 100_000)

      expect(reqs.operation).to eq(:stream_chat)
      expect(reqs.required_capabilities).to eq(%i[streaming tools thinking])
      expect(reqs.provider_pin).to be_nil
    end

    it 'routes to a vllm instance where the operator enable_thinking override satisfies :thinking' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN)
      result  = next_lane_for_requirements(chat_requirements(request, budget: 100_000))

      # A Selection, not a Rejection: no unbounded 529 retry loop. The vllm
      # :thinking evidence is :unknown; the operator's config-name keyed
      # enable_thinking: true is what satisfies the axis.
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.provider_family).to eq(:vllm)
      expect(result.instance_id).to eq('helios-0001')
      expect(result.model).to eq('helios-model')
      # Name-keyed weight resolved into the decision inputs (150 direct x 115 instance).
      expect(result.weight_inputs).to eq(tier: 150, provider: 1, instance: 115, model_or_offering: 1)
      expect(result.base_weight).to eq(17_250)
    end
  end

  # ------------------------------------------------------------------ #
  # Bar 2 — name-keyed tuning resolves (weight ranking + bin seam)      #
  # ------------------------------------------------------------------ #

  describe 'bar 2 — per-instance weight / preferred_context resolve by config NAME' do
    it 'preferred_context steers by config NAME: budget 10_000 routes to h200, not higher-weight helios-0001' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN)
      sel     = next_lane_for_requirements(chat_requirements(request, budget: 10_000))

      # 10_000 is inside h200's [4096, 48000) and outside helios's [48000, 262000).
      # If the preferred ranges were not resolved by name (the identity-drift
      # bug), every lane would be a generalist and weight alone would pick
      # helios-0001 (17_250 > 16_500). The bar requires h200.
      expect(sel).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(sel.instance_id).to eq('h200')
      expect(sel.model).to eq('h200-model')
    end

    it 'keeps the bin seam upper-exclusive: budget == preferred_max leaves v100 and enters h200' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN)
      below   = next_lane_for_requirements(chat_requirements(request, budget: 4_095))
      at_seam = next_lane_for_requirements(chat_requirements(request, budget: 4_096))

      # v100's range is [1, 4096): 4_095 matches, 4_096 does NOT (budget < max).
      # h200's range is [4096, 48000): 4_096 matches (inclusive lower bound).
      # If the seam regressed to inclusive, 4_096 would match BOTH v100 and h200
      # and the name-keyed weights (111 vs 110) would pick v100 — the assertion
      # catches the seam flip AND proves the weights resolve per config name.
      expect(below.instance_id).to eq('v100')
      expect(at_seam.instance_id).to eq('h200')
    end

    it 'per-instance weight ranking decides: with the generalist lanes tripped, helios (115) outranks v100 (111) and h200 (110)' do
      seed_frozen_world!
      trip(provider_family: 'bedrock', instance_id: 'uais', physical_id: 'us-east-1')
      trip(provider_family: 'ollama', instance_id: 'apollo', physical_id: APOLLO_ENDPOINT)

      # Budget 0 matches no preferred range, no generalist survives, so the
      # full vllm ready set competes purely on name-keyed instance weight:
      # 150 x 115 vs 150 x 111 vs 150 x 110.
      sel = next_lane_for_requirements(chat_requirements(plain_chat_request(seed: SEED_MAIN), budget: 0))
      expect(sel).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(sel.instance_id).to eq('helios-0001')
      expect(sel.weight_inputs).to eq(tier: 150, provider: 1, instance: 115, model_or_offering: 1)
      expect(sel.base_weight).to eq(17_250)

      # Deterministic across seeds: weight picks the winner, not the rendezvous tie-break.
      again = next_lane_for_requirements(chat_requirements(plain_chat_request(seed: SEED_ALT), budget: 0))
      expect(again.instance_id).to eq('helios-0001')
    end

    it 'ranks every ready lane by weight when no preferred range matches' do
      seed_frozen_world!
      sel = next_lane_for_requirements(chat_requirements(plain_chat_request(seed: SEED_MAIN), budget: 0))

      # No band contains zero, so pass 2 ranks all ready lanes. Direct helios
      # (150 tier x 115 instance) outranks local apollo and cloud uais; ranged
      # lanes remain eligible when their preferred band does not match.
      expect(sel.provider_family).to eq(:vllm)
      expect(sel.instance_id).to eq('helios-0001')
      expect(sel.model).to eq('helios-model')
      expect(sel.weight_inputs[:tier]).to eq(150)
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

      apollo = snapshot.instance(instance_key: apollo_key)
      embed  = snapshot.instance(instance_key: embed_key)

      # If identity had collapsed to the derived host:port, the second claim
      # would have superseded the first and one key would be absent.
      expect(apollo).not_to be_nil
      expect(embed).not_to be_nil
      expect(apollo.instance_key.instance_id).to eq('apollo')
      expect(embed.instance_key.instance_id).to eq('apollo-embed')
      expect(apollo.instance_key.physical_id).to eq(APOLLO_ENDPOINT)
      expect(embed.instance_key.physical_id).to eq(APOLLO_ENDPOINT)
      expect(snapshot.offerings_for(instance_key: apollo_key).map(&:model)).to eq(['gemma3'])
      expect(snapshot.offerings_for(instance_key: embed_key).map(&:model)).to eq(['nomic-embed'])
    end
  end

  # ------------------------------------------------------------------ #
  # Bar 4 — tripped instance recovers without a restart                 #
  # ------------------------------------------------------------------ #

  describe 'bar 4 — dispatch_instance_unavailable recovers without a restart' do
    it 'probe -> readiness_succeeded -> available -> re-selectable on the next snapshot' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN)
      expect(next_lane_for_requirements(chat_requirements(request, budget: 100_000)).instance_id).to eq('helios-0001')

      helios_key = keyed_instance(provider_family: 'vllm', instance_id: 'helios-0001', physical_id: HELIOS_ENDPOINT)
      token      = @tokens['vllm/helios-0001']
      inventory::Registry.dispatch_instance_unavailable(
        instance_key: helios_key, publisher_token_id: token.publisher_token_id,
        reason: 'release bar: simulated dispatch failure'
      )
      expect(snapshot.instance(instance_key: helios_key).availability.state).to eq(:unavailable)

      # The tripped lane is out; the generalist sibling serves the 100k budget.
      expect(next_lane_for_requirements(chat_requirements(request, budget: 100_000)).instance_id).to eq('uais')

      # Recovery is the registry's own probe path: the SAME publisher token,
      # no re-claim, no restart.
      probe = inventory::Registry.readiness_probe_started(instance_key: helios_key, publisher_token: token)
      inventory::Registry.readiness_succeeded(instance_key: helios_key, probe_token: probe)

      recovered = snapshot.instance(instance_key: helios_key)
      expect(recovered.availability.state).to eq(:available)
      expect(recovered.availability.source).to eq(:readiness)

      # Re-selectable on the next snapshot, under the same publisher identity.
      sel = next_lane_for_requirements(chat_requirements(request, budget: 100_000))
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
      sel = next_lane_for_requirements(chat_requirements(plain_chat_request(seed: SEED_MAIN), budget: 10_000))

      expect(sel).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(sel.instance_id).not_to eq('apollo-embed')
      expect(sel.model).not_to eq('nomic-embed')

      # The exclusion is AUTHORITATIVE operation evidence, not an accident:
      # chat is :unsupported on the embedding offering (decision 6).
      embed_key  = keyed_instance(provider_family: 'ollama', instance_id: 'apollo-embed', physical_id: APOLLO_ENDPOINT)
      offering   = snapshot.offerings_for(instance_key: embed_key).first
      expect(offering.operation_status(operation: :chat)).to eq(:unsupported)
    end

    it 'does route an embed request to the embedding instance (the distinction is real)' do
      seed_frozen_world!
      sel = next_lane_for_requirements(embed_requirements(seed: SEED_MAIN))

      expect(sel).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(sel.instance_id).to eq('apollo-embed')
      expect(sel.model).to eq('nomic-embed')
      expect(sel.operation).to eq(:embed)
    end
  end

  # ------------------------------------------------------------------ #
  # Bar 6 — adversarial typed failures, never 529                       #
  # ------------------------------------------------------------------ #

  # RoutingErrorMapper::STATUS_TABLE renders too_early, service_unavailable,
  # attempts_exhausted, and stale_selection as 529 (overloaded_error) in the
  # Anthropic dialect — the Claude CLI surface. Only invalid_request (400) and
  # the other 4xx kinds are terminal for the client. The bar therefore asserts
  # the router-level kind/status that the mapper turns into a non-529 response.
  describe 'bar 6 — adversarial: typed failures, never a 529 loop' do
    it 'a provider-PINNED tools+thinking request to ollama (no enable_thinking, evidence :unknown) is typed 400 invalid_request' do
      seed_frozen_world!
      request = claude_cli_request(seed: SEED_MAIN, pinned_provider: 'ollama')
      result  = next_lane_for_requirements(chat_requirements(request, budget: 100_000))

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
      request = claude_cli_request(seed: SEED_MAIN)
      # 200_000 fits only helios-0001 (h200/v100 windows and bedrock's 200k
      # window at 90% headroom all reject it) — establish the serving lane first.
      expect(next_lane_for_requirements(chat_requirements(request, budget: 200_000)).instance_id).to eq('helios-0001')

      trip(provider_family: 'vllm', instance_id: 'helios-0001', physical_id: HELIOS_ENDPOINT)
      result = next_lane_for_requirements(chat_requirements(request, budget: 200_000))

      # Tripped reports before unknown (the ollama :unknown evidence is
      # suppressed by the tripped instance): 503, recoverable without a restart.
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      expect(result.kind).to eq(:service_unavailable)
      expect(result.http_status).to eq(503)
    end
  end
end

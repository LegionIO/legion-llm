# Routing ownership and execution

The governing contract is the repository's `RULES.md` (N×N architecture law).
Requirements behavior is included into the per-request Router; callers construct
the Router directly and read request facts through its public accessors.

## Ownership

| Fact or action | Owner |
|---|---|
| Client dialect normalization | `api/client_translators/` |
| Typed execution messages and media source enums | Shared `lex-llm` Canonical constructors |
| Trusted header constraints and settings generation | Request ingress |
| Required capabilities, modality, context/input/output bounds, explicit pins and body-model disposition | `Routing::Requirements`, included into Router |
| Request-fact validation and immutable values | Shared `Legion::Extensions::Llm::Routing::RequestRequirements`, projected once into Router instance fields |
| Published identities, executable evidence, availability and stored weights | Shared Inventory publication/reconciliation |
| Candidate eligibility | `Routing::Filter`, orchestrated by Router |
| Ranking | `Routing::Rank`, using published weights |
| Selection and request-local attempt state | `Router` |
| Exact binding verification and execution | Direct dispatch and shared fleet protocol/worker |
| Provider wire shape | The selected provider's translator |

## Request lifecycle

1. Translate client wire into Canonical, then construct the inference request.
2. Construct one `Router.new(request:, operation:, body_model:, **)` for the logical
   request. The included Requirements module initializes its request facts once.
3. Validate and freeze those facts through the shared contract, retaining the
   resulting values on the Router. Use the ingress settings generation for request policy.
4. Each lane decision reads one current immutable Inventory snapshot and returns
   one authoritative Selection or typed Rejection.
5. Dispatch preserves that Selection. Fleet projection signs its exact binding;
   the worker validates claims, rehydrates Canonical and verifies Inventory before
   invoking the captured callable.
6. Retries retain the requirements and consumed-target state. They do not rebuild
   request semantics or reinterpret a failed exact binding as a routing request.

## Verification

The full RSpec suite includes client canonical equivalence, real requirement and
Inventory selection, actual OpenAI/vLLM callable rendering, signed fleet JSON
round-trips, and pre-invocation rejection of tampered media or mismatched bindings.
Provider-gem suites cover their real chat and streaming callables independently.
Network stubs provide deterministic wire responses; they are not live-service
availability evidence. Run the full RSpec and whole-repository RuboCop release
gates in every changed gem before push.

RULES.md — Legion LLM Architecture Law
These rules apply to every task, file, repository, agent, model, session, test, refactor, migration, incident, and release.
The requested task defines what may change. These rules define how the system ALWAYS works.
Every rule remains active 100% of the time. If requested work conflicts with these rules, stop and surface the conflict before changing code.
These are architecture laws. Scope, compatibility, urgency, convenience, tests, existing behavior, and model judgment do not change them.
1. Canonical is the only internal language.
Every client translates client wire -> Canonical before shared execution.
Shared execution carries Canonical through context, tools, routing, direct dispatch, fleet dispatch, and response handling.
Every provider translates Canonical -> provider wire at the provider boundary, then provider wire -> Canonical before returning to shared execution.
Every internal boundary validates the Canonical type it is defined to receive and raises immediately when that contract is violated.
Client Wire -> Client Translator -> Canonical -> Shared Execution -> Canonical -> Provider Translator -> Provider Wire.
2. Serialization preserves Canonical.
Transport may serialize Canonical state. The receiving transport boundary ALWAYS rehydrates the exact Canonical type before execution continues.
Fleet follows Canonical -> serialize -> wire -> deserialize -> rehydrate Canonical -> Canonical.
Serialization changes encoding only. Ownership, identity, model, operation, capability, selection, and meaning remain exactly the same.
After rehydration, shared execution continues only with Canonical objects.
3. Every authoritative fact has exactly one owner.
The owner creates the fact once. Every downstream layer carries, projects, serializes, rehydrates, verifies, or executes that exact fact.
A downstream layer receiving missing or contradictory authoritative state raises and returns the defect to the owning layer.
Authority ALWAYS moves forward by preservation.
Authority is created once and is never recreated downstream.
4. Requirements describe the request. Inventory describes reality. Router chooses. Dispatch executes.
Canonical request construction owns request semantics. RequestRequirements expresses operation, capabilities, modality, context, output, tools, and explicit pins.
Providers publish exact executable facts into Inventory. Inventory owns canonical instance, offering, lane, capability, context, quota, health, and published weight state.
Router.next_lane consumes Requirements plus one immutable Inventory snapshot and produces one authoritative Selection.
Dispatch executes that Selection exactly. Once Selection exists, routing is finished.
5. Inventory facts are immutable executable facts.
Providers publish exact instances and complete offering snapshots through the Inventory publication contract.
Identity, capability evidence, context evidence, quota domains, availability, and write-time weights are consumed from published Inventory state.
A changed fact becomes authoritative only through the owning publication or reconciliation path and a new Inventory snapshot.
Routing reads Inventory. Dispatch verifies and executes Inventory-backed Selection.
6. Identity, capabilities, weights, and context policy retain exact ownership.
Inventory::Identity owns instance, offering, and lane identity; canonical instance identity is provider family plus the operator/configured instance name; physical endpoint data remains secondary.
Providers publish capability evidence. Requirements state required capabilities. Candidate evaluation compares the two and determines capability eligibility.
The weight owner computes lane weight at publication time; Inventory stores it; ranking consumes that stored weight; a stored zero disables the lane.
Preferred-context binning orders eligible candidates into preference bands and preserves eligibility. Capability, health, binning, and weight ALWAYS retain distinct meanings.
7. Routing chooses exactly once.
Router.next_lane is the sole routing authority.
Candidate evaluation determines eligibility from Requirements and Inventory. Ranking orders eligible candidates from published routing facts.
Selection freezes the exact provider, instance, offering, lane, model, operation, and routing identity required for execution.
Every downstream component consumes the Selection it receives.
Selection is preserved, not reconstructed.
8. Exact execution stays exact through every boundary.
Direct dispatch executes the exact Selection-derived binding it receives.
Fleet dispatch serializes and signs that exact binding; fleet validation verifies it; fleet rehydration restores it; worker resolution verifies it against authoritative Inventory.
The selected provider, instance, offering, lane, model, and operation remain identical through projection, signing, transport, validation, rehydration, resolution, and callable invocation.
A mismatch raises before provider execution.
An exact execution request ALWAYS remains exact execution.
9. Health and errors preserve one authoritative meaning.
Inventory owns exact-instance availability. An authoritative instance-unavailable result removes that exact instance; readiness probing owns recovery; successful readiness republish re-admits it.
Overload, timeout, rate limit, model-not-ready, and transient provider failures remain request-local according to ProviderOutcome semantics.
The first layer that can authoritatively classify an error performs that classification once. Every downstream layer preserves it.
Programming errors remain programming errors. Contract violations remain contract violations. Routing exhaustion remains the defined typed Rejection.
10. Compatibility exists only at explicit edges.
Supported legacy clients and protocols are translated into the current Canonical and SSOT architecture at explicit compatibility boundaries.
Shared execution remains Canonical. Routing remains SSOT-driven. Exact execution remains exact.
Compatibility code adapts an external contract to the current internal architecture.
The current internal architecture ALWAYS has one representation, one routing authority, one identity system, and one execution truth.
11. Fix every defect at its owner.
Trace the incorrect value to the layer that owns it, then fix that owner.
Fix client wire in the client translator; Canonical shape in Canonical construction; Requirements in Requirements construction; provider facts in publication; identity in Inventory identity; weights in publication/reconciliation.
Fix eligibility in candidate evaluation; ordering in ranking; choice in Router.next_lane; execution preservation in dispatch; provider wire in the provider translator.
The layer where a defect becomes visible is evidence. The owning layer is where the correction belongs.
12. A discovered issue remains in its owning domain.
Complete the requested task inside its stated scope.
When investigation exposes a separate defect owned by another architectural domain, record and surface it as separate work unless the requested task is explicitly expanded.
Routing work consumes existing Canonical Requirements and Inventory facts. Canonical work changes Canonical contracts. Provider work changes publication or translation. Transport work changes transport.
Nearby code never changes ownership. “While we are here” never changes architecture.
13. N x N ALWAYS converges through Canonical.
Equivalent client semantics produce equivalent Canonical state before shared execution. Every provider consumes the same Canonical semantics for the same request.
When two paths disagree, capture the state at every involved boundary and locate the FIRST point where Canonical meaning diverges.
Fix that first divergent boundary, then run the exact failing path again.
Client behavior is proven at client-wire <-> Canonical. Provider behavior is proven at Canonical <-> provider-wire. Shared execution is proven with Canonical throughout.
14. Debug from captured authoritative state.
Capture the actual input at the failing boundary before reasoning from symptoms.
For translation or transport defects, capture Canonical immediately before and after every involved boundary.
For routing or dispatch defects, capture Requirements, relevant Inventory facts, Selection, execution binding, and ProviderOutcome.
Compare each captured value to the contract owned by that layer. Find the first divergence. Fix its owner. Re-run the exact path.
Then inspect sibling implementations for the same defect class.
15. Tests prove the real boundary and the invariant.
A boundary test exercises the real boundary it claims to protect.
Fleet tests exercise real serialization, deserialization, Canonical rehydration, signing, validation, exact resolution, and callable dispatch.
Provider tests exercise the real callable boundary and provider translator. Routing tests exercise real Requirements, Inventory records, candidate evaluation, ranking, and Selection.
Regression tests prove the violated invariant, not only the observed symptom.
A green suite is release evidence only when the tested path traverses the real architecture.
16. Shared contracts are consumed directly.
Shared Canonical types own execution representation. Shared Inventory types own inventory state. Shared Routing types own routing state.
Shared taxonomy owns canonical mappings. Shared ProviderOutcome owns provider-neutral outcomes. Shared fleet protocol owns exact execution claims.
Every repository consumes these shared owners directly.
A defect in one shared boundary triggers an audit of every sibling implementation of that boundary. Fix the shared owner centrally whenever the defect belongs to a shared contract.
17. Architecture is the release gate.
Every change preserves every rule in this file.
Tests, compatibility, historical behavior, migration phase, patch urgency, nearby code, task wording, and model judgment are evaluated UNDER these rules.
A contradiction between existing behavior and these rules is surfaced as an architecture conflict and resolved at the owning boundary before release.
Limited scope means do less. Limited scope NEVER means fewer rules apply.
These rules apply 100% of the time.
These are the law.

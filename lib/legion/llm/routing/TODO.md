# routing/ TODO — the Router migration (SSOT v4)

> This file is the operating document for the router/ → routing/ migration.
> A fresh session with zero context should be able to keep working from this
> file alone. It states: what we are doing, what SSOT is, the target flow,
> the working model + hard rules, the verified current state, the LOCKED
> decisions (do not re-litigate), and every pending item as checkboxes.

---

## 0. Pre-work protocol

**This file is the single entry point for the migration.**

1. **Read Appendix A (end of this file) in full before touching
   anything.** It inlines, verbatim, the three law docs: the operating
   rules (how you behave), the N×N architecture law (what the system must
   preserve), and the N×N debugging method (the loop you follow when
   anything is red). No file access needed — it is in here.
2. **Depth references** (absolute paths on this machine — not inlined on
   purpose: they are long and maintained separately). Read the mapped doc
   BEFORE starting the mapped work:

   | Read when you reach… | Doc |
   |---|---|
   | §7.1–§7.4 (the reproduction work) | `/Users/matt.iverson@optum.com/rubymine/legion/docs/legion-llm/llm-routing-build-reference-2026-08-22.md` — conventions + gotchas from the filter/rank build |
   | Anything touching the inventory/discovery boundary | `/Users/matt.iverson@optum.com/rubymine/legion/docs/legion-llm/handoff-inventory-discovery-2026-08-22.md` — the slice this builds on (5-tuple inventory, discovery pipeline) |
   | Any "is this legacy / where did this go?" question | `/Users/matt.iverson@optum.com/rubymine/legion/docs/legion-llm/ssot_v4/ssot-v4-router-retirement-index.md` — the full repo-wide inventory |
   | Any DECISION you need to confirm before acting | `/Users/matt.iverson@optum.com/rubymine/legion/docs/legion-llm/ssot_v4/ssot-v4-router-retirement-attempt-1.md` — Q1–Q40 with DECISION/STEPS/VERIFY/ASSUMPTION |

   **If a path cannot be read, STOP and report it — do not proceed from
   memory of what the doc said.**
3. **In-repo sources of truth for the reproduction work** (relative to
   `legion-llm/`):
   - `lib/legion/llm/router_new.rb` — the new Router CLASS scaffold
     (future content of `router.rb`).
   - `lib/legion/llm/router/` — the legacy sources to reproduce (per
     file; the commented-out ones are in-flight swaps, §5).
   - `lib/legion/llm/inference/routing_session.rb` — the per-request
     state being absorbed into the class (D9).
   - `lib/legion/llm/router.rb` — the legacy MODULE (untouched until the
     swap, §7.5).
   - `spec/legion/llm/router/` — the ORACLE specs (port, don't invent).

---

## THE FLOW + HOMES (read before touching a file — 2026-08-23 lock)

> Added after the body-model-hint REDO left **two live copies of the
> ladder on disk in the wrong home** (request.rb + routing/
> body_model_hint_policy.rb). If a move ever leaves two live copies of
> the same logic, STOP everything and delete the extra copy before
> doing anything else.

```
 client wire (HTTP)
      │
      ▼
 CLIENT EDGE (api/client_translators/*)     ← X-Legion-* header parsing +
      │                                        body parsing live HERE
      │                                        (shared ingress helper)
      ▼
 Inference::Request                          ← FROZEN DATA RECORD + build
      │                                        wiring ONLY. Members:
      │                                        messages, routing_context,
      │                                        trusted_constraints (parsed
      │                                        pins), routing_settings_
      │                                        snapshot, client_model, ...
      │                                        NO derived policy. NO
      │                                        derivation. NO parsing
      │                                        logic. NO ladder. EVER.
      ▼
 Router.new(request:, operation:, snapshot:)  ← ONE per LOGICAL request
      │  computes ONCE in initialize (Router STATE, not request data):
      │    @body_model_hint_decision = body_model_hint_decision(...)
      │        └─ THE LADDER: Filter mixin instance method,
      │           routing/filter.rb — the only copy, the Router is
      │           its only caller
      │    @required_capabilities / @input_bound (Router privates,
      │        computed once per instance)
      │
      ├── attempt loop — SAME Router instance, next_attempt × N ──────┐
      │  1. Routing::Filter (mixin): constraints from Router state +  │
      │     per-lane axes (operation/pins/policy/capability/context/  │
      │     dimensions/availability/exclusions/fleet/weight)          │
      │     → EvaluationSet (routing/evaluation.rb records)           │
      │  2. Routing::Rank (mixin): rank ready lanes → RankedLane      │
      │  3. Router: build_selection → Routing::Selection              │
      │        or reject_no_candidates → Routing::Rejection           │
      ▼                                                               │
 Call::SelectionDispatch.call(attempt_context:)  ← executes exact lane │
      │                                                               │
      ▼                                                               │
 Canonical::Response                                                   │
      │                                                               │
      ▼                                                               │
 Router#classify (Routing::Outcome mixin)                              │
      │                                                               │
      ├─ :success → Response envelope → client translator → wire      │
      ├─ :retry   → consume! / add_exclusion / apply_global_transition ┘
      └─ :terminal → Routing::Rejection → RoutingErrorMapper → HTTP
```

### HOMES table (the only copy of each piece of logic lives HERE)

| Logic | Home (the ONLY copy) | Shape |
|---|---|---|
| body-model-hint ladder (7 dispositions) | `routing/filter.rb` (Filter mixin) | instance method `body_model_hint_decision(body_model:, trusted_model:, settings_snapshot:)` + private helpers; the Router calls it ONCE in initialize |
| the decision's STATE | Router instance (`@body_model_hint_decision`) | computed once per request; the request record NEVER carries it |
| X-Legion-* header → trusted Constraints Value | client edge — `api/client_translators/` shared ingress helper | translators call it; the request carries the parsed Value as data |
| required-capabilities derivation | Router class private | computed once per instance |
| input-bound derivation | Router class private | computed once per instance |
| no-candidate rejection reduction | Router class private | selection-time |
| outcome classification | `routing/outcome.rb` (mixin) | instance `#classify` + `Action`/`GlobalTransition` records (rank.rb shape) |
| lane axes + model-hint ladder | `routing/filter.rb` (Filter mixin) | instance methods |
| ranking | `routing/rank.rb` (Rank mixin) | instance methods + `RankedLane` record |
| attempt state (exclusions/consumed/budget/last_rejection/decision) | Router instance ivars | — |
| request record | `inference/request.rb` | frozen data + build wiring; ZERO logic |

### PRE-FLIGHT protocol (before editing ANY file in a move)

1. Identify the logic being moved.
2. Look up its home in the HOMES table.
3. State in your own message: **"adding to X, deleting Y, the one copy
   lives in Z."**
4. If the home is NOT in the table, or the TODO seems to contradict
   itself, or step 3 doesn't come out clean → **STOP and ask. Do not
   guess-edit.** The 2026-08-23 ladder REDO happened because the home
   was ambiguous and a session guessed with its hands on the keyboard.

### NO-TWO-COPIES rule

At no point may two LIVE copies of the same logic exist on disk. A move
is ONE atomic step: add to the home → delete the old site(s) → verify
green. If you catch a second live copy (the ladder existed in
`request.rb` AND `routing/body_model_hint_policy.rb` simultaneously),
stop everything and delete the extra copy before doing anything else.

## 1. What we are doing

The old router is a **module** (`Legion::LLM::Router` in `router.rb`) with a
stateless `self.next_lane(requirements:, exclusions:, snapshot:)` function, a
separate per-request state object (`Inference::RoutingSession`), and 14
support files under `router/`.

We are replacing it with:
- **`Legion::LLM::Router` — a CLASS** (scaffolded in `router_new.rb`),
  instantiated once per logical request:
  `Router.new(request:, operation:, snapshot:)`. It holds the request's
  attempt state and drives pick → dispatch → retry.
- **`lib/legion/llm/routing/` — stateless mixin modules + records only.**
  They provide behavior to the class; they hold NO state of their own.

When done: `router/` is gone, `routing_session.rb` is gone, `router.rb`
holds the class, and every consumer constructs `Router.new` directly.

## 2. What SSOT is

**Single Source of Truth for routing.** Concretely:
- **One inventory.** The lex-llm `Inventory::Registry` — 5-tuple lanes
  (`tier:provider_family:instance_id:type:model`), immutable snapshots,
  generation-tagged. The daemon never selects from anything else.
- **One router.** `Router#next_lane` is the sole selection authority. It
  consumes (request, operation, exclusions, ONE snapshot generation, ONE
  settings generation) and returns exactly **one `Routing::Selection`**
  (an exact binding: lane_id, provider, instance, model, operation,
  callable handle) or **one typed `Routing::Rejection`** (mapped to HTTP by
  `API::RoutingErrorMapper`). Never nil, never a lane hash, never a chain.
- **One settings generation per request.** Captured at ingress on the
  request (`request.routing_settings_snapshot`); a mid-request reload
  cannot change what the request sees.
- **No second selection domain.** No default-provider/model fallback, no
  operator routing toggle, no legacy `Call::Dispatch` selection path.
  Selection is an exact binding that dispatch (`Call::SelectionDispatch`)
  executes exactly.

## 3. Target flow (how everything goes through the Router when done)

```
client wire
  → client translator (api/client_translators/*)      [Canonical edge]
  → Canonical::Request
  → Inference::Request (the pipeline request). At ingress it CARRIES:
       routing_context          (server-created routing seed — immutable)
       trusted_constraints      (X-Legion-* pins — request-builder
                                 private, D10)
       body_model_hint_decision (D19 policy outcome: honored/auto/ignored…)
       routing_settings_snapshot (THE settings generation for this request)
  → router = Router.new(request:, operation:, snapshot:)
       captures inventory_generation = snapshot.generation   (capture-once)
  → router.next_attempt!(snapshot:)            ← preflight, BEFORE SSE opens
       1. derive request facts:
            required_capabilities = router's private
                                     required_capabilities_for(operation:)
                                     (D10 — selection-time)
            input_bound           = InputBound.call(...)   (+ settings framing overhead)
            context_budget        = input_bound + required_output_tokens
       2. resolve constraints (Routing::Filter, from the request):
            model (trusted pin > honored hint), tier, provider, instance,
            type (operation → Taxonomies.lane_type_for), context, dims
       3. per lane in the snapshot — lane axes (Routing::Filter):
            operation (coarse type match), pins, policy (wl/bl cascade),
            capability (+ enable_* override), context (headroom ppm),
            dimensions, availability, exclusions, fleet contract, weight
         → Routing::Evaluation records (CandidateEvaluation / EvaluationSet)
       4. Routing::Rank over the READY lanes:
            band partition (preferred-context range) →
            base_weight × preference_ppm (affinities) →
            rendezvous SHA256 tie-break → winner
         → RankedLane (wraps the LANE, not an evaluation)
       5. build_selection(ranked:, snapshot:)
         → Routing::Selection          (exact binding)
         or Routing::Rejection         (typed; HTTP via RoutingErrorMapper)
            — with the hint-miss fallback: an HONORED body-model hint that
              matched nothing re-evaluates WITHOUT the pin (trusted pins
              never fall back)
  → dispatch: Call::SelectionDispatch.call(attempt_context:, arguments:)
       executes the lane's exact CallableHandle → Canonical::Response
  → router.classify(dispatch_result:, attempt_context:)
       → Routing::OutcomeClassifier → Action:
            :success  → done
            :retry    → add_exclusion / apply_global_transition,
                        next_attempt(snapshot:) again (fresh snapshot)
            :terminal → Rejection out
  → router.consume!(selection)   (budget increment + consumed target)
  → Response envelope → client translator → client wire
```

## 4. Working model + hard rules

- **NO GIT until told.** All work is local. A per-file swap = create the
  `routing/` file, then remove the old `router/` file (plain `rm`). When
  git is re-enabled these become the add+rm commits.
- **`router.rb` (the module) is untouched until the swap.** The class
  lives in `router_new.rb` until then. It cannot load in a process where
  the legacy module is loaded (same constant) — that is intended.
- **Per-file swap, in order.** Reproduce a `router/` file's logic in the
  new world (a `routing/` file, or the class where the logic belongs),
  THEN remove the old file. Both coexisting as live code is forbidden —
  the old file may sit COMMENTED-OUT as the in-flight state (that is what
  `router/body_model_hint_policy.rb` currently is), never as live duplicate.
- **NO SHIMS.** No re-exports, no aliases, no "class that calls the old
  module" bridges, no `compat` constants. If the new file references the
  old world, that is a bug in the migration.
- **Red mid-build is expected; the tip must be green.** Do not chase green
  at every intermediate step. Validate each swap with its TARGETED specs;
  the full-suite green gate is the tip (§7.7).
- **`routing/` is stateless.** Mixins + immutable records only. No
  singletons, no globals, no settings-state owner here (§6, D2).
- **Reproduce, don't copy-paste blind.** Each method is rewritten at its
  new owner with the locked decisions applied (e.g. `preferred_context_
  match` does NOT come along). Behavior otherwise carries over verbatim —
  the old specs are the oracle.
- House rules: every `rescue` calls `handle_exception` or re-raises;
  `Legion::JSON` never bare `::JSON`; no `|| literal` after a settings
  read (NoInlineSettingDefaults); no `_foo:` kwargs; `frozen_string_literal`
  on every file; rubocop (rubocop-legion) clean on everything you touch.
- Spec conventions: `spec/legion/llm/routing/<module>_spec.rb`
  (SpecFilePathFormat cop); unit specs use an anonymous class that
  `include`s the mixin + stubs whatever it needs; fail-first — the spec
  encodes the contract, a red spec means the implementation is wrong.

## 5. Current state (verified 2026-08-23 — re-verify before relying)

> **2026-08-24 SESSION UPDATE (checked off in §7 below):** the new world is
> BUILT and self-contained. `router_new.rb` is the COMPLETE class (all §7.4
> stubs filled); ctor is now `(request:, operation:, body_model:)` and inventory
> is fetched LIVE per decision (no capture-once snapshot). All `routing/` mixins
> done: filter (axes + ladder + cascades), fleet, evaluation, outcome, rank.
> Every reproduced file was VERIFIED faithful by a per-file audit (10 read-only
> agents). 1:1 `_spec.rb` added for each new lib file.
> **Settings machinery eliminated from the router (supersedes D2 for the
> router):** the class + filter read `Legion::Settings[:llm][:router]` (defaults
> in `settings/router.rb`) + `[:extensions][:llm]` cascades directly — the router
> no longer uses `SettingsState`/`SettingsSnapshot`, so those + `header_constraints`
> + `escalation/history` DIE (per the human), and `resolution` is deletable.
> `request_requirements` logic folded into the ctor (D1).
> STILL PENDING: the §7.5 swap + §7.7 gate + rewiring the 5 out-of-scope
> consumers (`llm.rb`, `request.rb`, `offerings.rb`, `openai/models.rb`, and the
> `settings.rb` `router:` wire). Nothing committed; no rspec/rubocop run yet.

`lib/legion/llm/routing/`:
- [x] `filter.rb` — 12 methods: `filter_type`, `filter_provider`,
      `filter_instance`, `filter_model`, `filter_tier` (constraint
      resolvers from `**opts`); `filter_policy(lane:, whitelist:,
      blacklist:)`, `filter_availability(instance:)`,
      `filter_fleet(lane:)`, `filter_weight(lane:)` (lane classifiers).
- [x] `rank.rb` — COMPLETE mixin (reproduces old `ranker.rb`):
      `rank(lanes:, routing_seed:, routing_affinities:,
      affinity_strength_bps:, context_budget:,
      preferred_context_range_for:)` → `RankedLane | nil`; band
      partition (upper-exclusive), `base × preference_ppm` (affinities,
      ±10_000 clamp, ppm 500k–1.5M), SHA256 rendezvous
      (`"ssot-tie-v1\0"` prefix), winner = max-ew bucket → max score →
      lane_id asc. `RankedLane` wraps the LANE (old `RankedCandidate`
      wrapped an evaluation — the seam build_selection must adapt to).
- [x] `fleet.rb` — done: `fleet_enabled?` + `fleet_lane?(lane:)` (§7.3).
- [x] `router_new.rb` (one dir up) — the class scaffold: ctor
      `(request:, operation:, snapshot:)`, includes Filter/Rank/Fleet,
      state ivars (`@exclusions`, `@consumed_targets`, `@attempts_used`,
      `@last_rejection`), `settings_snapshot` reader delegating to
      `@request.routing_settings_snapshot`, real: `routing_seed`,
      `attempts_remaining`, `rejection?`, `validate_snapshot!`; stubs
      (`NotImplementedError` + source pointer): `next_lane`,
      `next_attempt`/`next_attempt!`, `add_exclusion`, `classify`,
      `consume!`, `apply_global_transition`, `attempts_exhausted`,
      `stale_selection`, `build_selection`, `hint_model_pin_active?`,
      and the 4 class-level status queries.

`lib/legion/llm/router/` (legacy sources; 5 of 15 files still live):
- [x] reproduced: `ranker.rb` (→ `rank.rb`; old file now commented out)
- [~] in flight (D11 MOVE pending — section 7.1 item 1): the ladder exists in
      TWO places on disk — 5 class methods in `inference/request.rb`
      (loaded, called from Request.build) + `routing/
      body_model_hint_policy.rb` (orphaned self.call file, no longer
      required by anything) = the forbidden two-copy state.
      `filter_model` is deleted from `filter.rb` (D4 — done, keep).
      The ladder has NOT yet landed in `filter.rb` (the locked home).
- [ ] not reproduced: `header_constraints.rb`, `input_bound.rb`,
      `outcome_classifier.rb`, `required_capabilities.rb`,
      `candidate_evaluation.rb`, `candidate_evaluator.rb` (split — see §7.2)
- [ ] delete-only (verified dead, zero lib readers): `resolution.rb`,
      `escalation/history.rb`
- [ ] NOT reproduced by design (§6): `request_requirements.rb`,
      `settings_state.rb`, `settings_snapshot.rb`

**Known state right now (2026-08-23, post-REDO stop):** two copies of
the ladder on disk (the forbidden state) — section 7.1 item 1 (the
D11 MOVE) resolves it in one atomic move. The old module path (old
`router.rb` → `request_requirements.rb` → the `request.body_model_
hint_decision` member) still works TODAY because the member still
exists; it goes RED when item 1 removes the member — that is
EXPECTED dismantling red until the section 7.5 swap. Do NOT re-add
the member or keep the ladder in request.rb to keep the old path
green.

## 6. LOCKED decisions (do not re-litigate; challenge via the human)

- **D1 — No `RequestRequirements` record.** It was the input bundle for
  the old stateless module function. The class holds the REQUEST, which
  carries `trusted_constraints`, `routing_context`,
  `body_model_hint_decision`, tokens, and the settings generation.
  Everything the old record held is on the request or derivable from
  (request + settings generation). `router/request_requirements.rb` is
  NOT reproduced. Its validation semantics (operation ∈
  Taxonomies::OPERATIONS, tier ∈ Taxonomies::TIERS, positive dimensions,
  32-hex seed → `Errors::InvalidRoutingContext`, affinities ±10_000) are
  carried by the class ctor / the builders per **D10**.
- **D2 — No `settings_state` / `settings_snapshot` in `routing/`.**
  `routing/` is stateless-only; a process-wide settings singleton is a
  stateful global and does not belong here. The Router gets the settings
  generation from `request.routing_settings_snapshot` (reader exists on
  the class). The legacy `Router::SettingsState` singleton stays where it
  is until a separate concern decides its fate — the new class must never
  reference it.
- **D3 — Ctor contract:** `Router.new(request:, operation:, snapshot:)`.
  `operation:` is a caller fact (chat vs stream_chat vs embed — not a
  request member). No other kwargs.
- **D4 — `filter_model` is deleted** (Q3, DONE in the 2026-08-23
  swap — keep). The body-model disposition ladder is the SOLE
  body-model decider; per **D11** it lives as a Filter mixin instance
  method in `routing/filter.rb` — the Router computes it once in
  initialize and holds it as Router state. The model constraint
  reaches selection via trusted pin > honored decision (the Router
  reads its own `@body_model_hint_decision`). The wl/bl matching core
  stays in `filter_policy` (the lane axis — different inputs,
  different job).
- **D5 — `preferred_context_match` is dead** (zero readers; Rank
  re-derives the band). Do not carry it into `routing/evaluation.rb`.
- **D6 — `ranker.rb` → `rank.rb` is DONE.** Do not re-touch rank math.
  The one seam: `RankedLane` wraps a lane; `build_selection` adapts.
- **D7 — `resolution.rb` and `escalation/history.rb` are dead** (verified
  zero lib readers; spec-only references). Delete-only, no reproduction.
- **D8 — `candidate_evaluator.rb` splits, it does not move.** Three of
  its lane axes already exist in `filter.rb` (availability, fleet,
  weight); six more are added to `filter.rb` (§7.2); the per-lane
  ORCHESTRATION (iterate lanes → build EvaluationSet) and the
  `next_lane` selection core land in the CLASS.
- **D9 — `RoutingSession` is absorbed into the class** (not re-homed).
  Its state (exclusions/consumed targets/budget) and its methods
  (`next_attempt`, `next_attempt!`, `classify`, `consume!`,
  `add_exclusion`, `apply_global_transition`, `attempts_exhausted`,
  `stale_selection`) become class methods; the 14 consumers rewire to
  `Router.new`.
- **D10 — Container shapes in `routing/` are locked: mixins + records
  only, and ingress-vs-selection-time decides the container.** (This is
  the lock the body_model_hint_policy swap on 2026-08-23 exposed as
  missing — the TODO once said "reproduce `self.call`", which imported
  the old world's module-function shape into `routing/`.)
  - A `routing/` file is either **(a) a mixin the Router includes**
    (Filter, Rank, Fleet, Outcome) or **(b) selection records**
    (records live with their mixin file, like `RankedLane` in
    `rank.rb`, or in `routing/evaluation.rb`). **Standalone
    `self.call` module-function files in `routing/` are BANNED — that
    is the old world's shape.** Reproducing a legacy `self.call`
    module into `routing/` is not "reproducing", it is importing the
    old world.
  - **INGRESS-time facts — SUPERSEDED by D11.** (This clause originally
    put ingress logic in `Inference::Request` private builders. The
    2026-08-23 ladder REDO proved that home wrong — the request record
    is DATA ONLY. See D11 for the locked homes.)
  - **The lifecycle, precisely:** `Request.build` creates each ingress
    fact ONCE (stores it as a request member) → ONE `Router.new` per
    LOGICAL REQUEST → all attempts (retries/failovers) run INSIDE that
    one Router instance — the Router is never recreated per attempt
    and the request is never rebuilt. The Router READS the members; it
    never re-derives ingress facts.
  - **No logic is ever reproduced.** A fact has ONE owner (law 3): the
    owner's builder creates it once; every other site reads the
    member/ivar. The REDOs are MOVES (the old copy is deleted in the
    same step), never copy-and-keep. Selection-time derivations
    (required capabilities, input bound) are computed once per Router
    instance and reused across attempts. **If the same derivation ever
    appears in two places, that is a bug — collapse it into the owner.
    A second copy of a derivation is the logic-level twin of the
    banned `self.call` file.**
  - **SELECTION-time facts** — logic that runs inside `next_lane` /
    `classify` / the attempt loop — are **private methods on the
    Router class** (or a mixin if the class gets large — the container
    is the class, never a new module-function file). This covers
    required-capability derivation, input-bound derivation, and the
    no-candidate rejection reduction. Outcome classification becomes
    `routing/outcome.rb` — a **mixin** (instance method `#classify`,
    plus the `Action`/`GlobalTransition` records), shaped exactly like
    `rank.rb`'s mixin+record.
- **D11 — The request record is data only; the ladder home is LOCKED.**
  (Locks the body-model-hint ladder's home, which the 2026-08-23
  mid-REDO left with two live copies in the wrong home.)
  - **`inference/request.rb` = frozen data record + build wiring.
    ZERO routing policy, ZERO derivation, ZERO parsing logic.** It
    carries raw inputs (messages, routing_context, trusted_
    constraints, routing_settings_snapshot, client_model). The
    `body_model_hint_decision` member is REMOVED from the record.
    The 2026-08-23 REDO that put the 104-line ladder into
    request.rb is the anti-example — do not put logic there, ever.
  - **The ladder (7 dispositions) lives in `routing/filter.rb`** as a
    Filter mixin INSTANCE method: public
    `body_model_hint_decision(body_model:, trusted_model:,
    settings_snapshot:)` + private helpers `build_hint_decision` /
    `normalize` / `auto_alias?` / `substring_match`. ONE copy, there.
    No `module_function`, no `self.call` shape, no separate policy
    file, no `require` of the records constant anywhere except here.
  - **The Router is the ladder's only caller:** it computes the
    decision exactly once in `initialize` and stores it as Router
    state (`@body_model_hint_decision`, attr_reader). The hint-miss
    fallback reads it. It is never recomputed per attempt.
  - **Header/trusted-constraint parsing (X-Legion-* → the Value
    record) lives at the client edge** — a shared ingress helper in
    `api/client_translators/` (client translators parse client wire —
    the N×N law). The request record carries the parsed Value as data.
    request.rb never receives parsing logic.
  - **Expected dismantling red:** the old module's path (old
    `router.rb` → `router/request_requirements.rb` reading the removed
    request member) goes RED from this move until the §7.5 swap kills
    it. **Do not re-add the member or duplicate the ladder to keep it
    green.**

## 7. Pending work

### 7.1 `routing/` modules to build (per-file swap: build → remove old)

> **Container shapes per D10/D11 (locked after the 2026-08-23 ladder
> REDO):** the ladder (body-model-hint) → Filter mixin instance method,
> computed ONCE by the Router (D11); ingress parsing → the client edge
> (D11); selection-time logic → Router class privates; `routing/`
> files are mixins + selection records only. NO `self.call`
> module-function files in `routing/`. `request.rb` is DATA ONLY
> (D11). The old world's shape does not travel. THE FLOW + HOMES table
> at the top of this file is the source of truth — run the PRE-FLIGHT
> protocol before touching a file.

- [x] **1. MOVE the body-model-hint ladder to its locked home (D11).** (ladder landed in routing/filter.rb + Router computes it once; steps 3–4 — revert request.rb + delete old policy file — DEFERRED to the §7.5 swap, out of scope this session.)
      PRE-FLIGHT: "adding to routing/filter.rb + router_new.rb,
      deleting the request.rb sites + routing/body_model_hint_policy.rb
      + its spec, the one copy lives in routing/filter.rb."
      CURRENT mid-REDO disk state (verified 2026-08-23): the ladder
      exists as 5 CLASS methods in `inference/request.rb`
      (`build_body_model_hint_decision` ~:231, `build_hint_decision`
      ~:294, `normalize` ~:304, `auto_alias?` ~:313,
      `substring_match` ~:321 + their private_class_method lines)
      AND `routing/body_model_hint_policy.rb` is still live = TWO
      live copies (the forbidden state). ONE atomic move:
      1. Add the ladder to `routing/filter.rb` as a Filter mixin
         INSTANCE method: public
         `body_model_hint_decision(body_model:, trusted_model:,
         settings_snapshot:)` — the 7-step ladder (`:absent` →
         `:superseded_by_explicit_model` → `:auto` →
         `:ignored_disabled` → `:ignored_not_whitelisted` →
         `:ignored_blacklisted` → `:honored`; builds
         `Legion::Extensions::Llm::Routing::BodyModelHintDecision`) +
         private helpers `build_hint_decision`/`normalize`/
         `auto_alias?`/`substring_match` (MOVE the code — one copy).
         The `require 'legion/extensions/llm/routing/records'`
         (BodyModelHintDecision) moves to this file.
      2. `router_new.rb`: `Router#initialize` computes
         `@body_model_hint_decision = body_model_hint_decision(
         body_model: request.client_model,
         trusted_model: request.trusted_constraints&.model,
         settings_snapshot: settings_snapshot)` exactly ONCE; add
         `:body_model_hint_decision` to the class attr_readers; the
         `hint_model_pin_active?` stub reads the ivar.
      3. REVERT `inference/request.rb` to data-only: delete the 5
         class methods + private_class_method lines, delete the build
         site (`body_decision = build_body_model_hint_decision(...)`
         ~:62 + the `body_model_hint_decision:` kwarg ~:70), remove
         `:body_model_hint_decision` from the Data member list (:27),
         delete the added `require 'legion/extensions/llm/routing/
         records'` (:7 — verify nothing else in the file uses it).
      4. DELETE `lib/legion/llm/routing/body_model_hint_policy.rb` +
         `spec/legion/llm/routing/body_model_hint_policy_spec.rb`;
         fold the 9 disposition examples into
         `spec/legion/llm/routing/filter_spec.rb` (anonymous-class-
         includes-Filter pattern); re-target
         `spec/legion/llm/api/client_translators/body_model_hint_join_
         spec.rb` to read `Router.new(...).body_model_hint_decision`
         (keeps the translator-join coverage).
      5. Verify: filter_spec + join spec + request_spec + router_spec
         green; rubocop clean on touched files. EXPECTED RED until
         the §7.5 swap: the old module's path (old `router.rb`
         `hint_model_pin_active?` via `request_requirements.rb`
         reading the removed request member) — do NOT re-add the
         member or duplicate the ladder to keep it green.
      (The earlier swap's other parts stand: `filter_model` deleted
      (D4), its spec examples removed, old `router/` file removed.)

- [x] **2. Required-capability derivation → Router class private**
      (NOT a routing/ file — D10, selection-time). Port from
      `router/required_capabilities.rb` as private methods on the
      Router: `required_capabilities_for(operation:)` (was
      `self.call`) + `OPERATION_BASE` (9 ops) as a class constant +
      helpers `tools_required?`, `tool_choice_requires_tool?`,
      `thinking_required?`, `thinking_config_enabled?`
      (`{enabled: false}` = disabled), `vision_required?`
      (`image`/`image_url` blocks), `structured_output_required?`
      (json_object/json_schema/nonempty schema),
      `messages_contain_block_type?`, `message_content_of`,
      `block_type_of`, `nonempty_array?`. Filled in with §7.4
      `next_lane`. Spec: re-target `required_capabilities_spec.rb` to
      the Router class spec.
- [x] **3. Input-bound derivation → Router class private** (framing overhead now from `Legion::Settings[:llm][:router][:input_framing_overhead_tokens]`; operation_payload byte-count sourced from `request.extra` — verify source.)
      (NOT a routing/ file — D10, selection-time). Port from
      `router/input_bound.rb` as private methods on the Router:
      `input_bound_for(...)` (was `self.call`; byte-bound, no Float, no
      tokenizer) + helpers `text_bytes`, `message_text_bytes`
      (canonical member reads), `content_block_bytes`
      (text/thinking/tool_use/tool_result), `serialized_bytes`
      (`Legion::JSON.dump`), `nil_or_empty?`. Framing overhead comes
      from `settings_snapshot.input_framing_overhead_tokens`. Spec:
      re-target `input_bound_spec.rb` to the Router class spec.
- [ ] **4. Trusted-constraint parsing → the client edge (D11).** (NOT done — out of scope; `header_constraints.rb` stays until the client edge is rewired.)
      (NOT request.rb — D11: request.rb is data-only; client
      translators parse client wire — the N×N law.) Port from
      `router/header_constraints.rb` into a shared ingress module at
      the client edge — `api/client_translators/routing_constraints.
      rb`, INSTANCE-method module, `shared_extractors.rb` convention
      (translators `include` it; NO self.call shape):
      `trusted_constraints_from_headers(headers:, settings_snapshot:)`
      (was `self.call`) + `trusted_constraints_from_internal(...)`
      (was `self.from_internal`) + helpers `fetch_header` (Rack +
      normalized lookup), `normalize_utf8!` (BINARY→UTF-8 trust
      boundary, raises `Errors::InvalidHeader`), `blank_to_nil`,
      `reject_multi!` (commas forbidden), `normalize_provider`,
      `normalize_tier` (Taxonomies::TIERS), `normalize_max_attempts`
      (snapshot ceiling) + `HEADER_KEYS` (5 X-Legion-* names)
      constant. The `Value` record moves to this file (the ingress
      record lives with its parser). Translators call it in
      `build_inference_request`; the request record carries the
      parsed Value as the `trusted_constraints` data member
      (Request.build receiving it as a kwarg is wiring, not logic —
      request.rb gets NO parsing logic).
      Spec: re-target `header_constraints_spec.rb` +
      `header_validation_spec.rb` to the ingress module.

- [x] **5. `routing/outcome.rb` — a MIXIN** ←
      `router/outcome_classifier.rb` (D10, selection-time; shaped
      exactly like `rank.rb`: mixin + records in one file). The Router
      includes it; classification becomes an INSTANCE method (not
      `.call`): `#classify(dispatch_result:, attempt_context:)` core
      + `GlobalTransition` (kind must be `:instance_unavailable`),
      `Action` (`success`/`retry`/`terminal` factories + predicates +
      payload invariants that raise on mismatch), `RETRYABLE`
      (13 kinds), `TERMINAL_REJECTION_KIND` (5 kinds),
      `quota_exclusions` (QuotaDomainKey → request-lifetime exclusion),
      `attempts_exhausted_rejection` (503 rejection),
      `terminal_rejection` (403/400) as the mixin's private methods.
      Spec: re-target `outcome_classifier_spec.rb` to
      `routing/outcome_spec.rb` (anonymous class including the mixin —
      the established pattern).
- [x] **6. `routing/evaluation.rb`** ← `router/candidate_evaluation.rb`
      (immutable records): `CandidateEvaluation` (AXES table — see D5:
      NO `preferred_context_match` member; `ready?` predicate drops that
      check too; `validate!` per axis) and `EvaluationSet` (candidates,
      publication_statuses, inventory_generation, `ready_candidates`).
      Spec: covered by the evaluator re-target (§7.2) — verify.

### 7.2 `filter.rb` gap-fill (the six missing lane axes, per D8)

Port from `router/candidate_evaluator.rb` (logic verbatim; the old spec
`candidate_evaluator_spec.rb` is the oracle):
- [x] `filter_operation(lane:, operation:)` — coarse-type equality via
      `Taxonomies.lane_type_for` (requested op vs lane op) →
      `:supported` / `:unsupported`
- [x] `filter_pins(lane:, ...)` — provider/instance/model/tier pins vs
      lane fields → `:match` / `:mismatch` (pins come from the request's
      trusted constraints + honored hint — D1/D4)
- [x] capability lane check — evidence status via
      `lane.capability_evidence[CAPS.canonical(cap)]` + the
      `enable_<cap>` override from the settings generation (override
      consulted ONLY when evidence is `:unknown`) →
      `:supported`/`:unsupported`/`:unknown`
- [x] context lane check — `budget <= (limit × headroom_ppm) / 1_000_000`
      with `headroom_ppm` from the settings generation; zero budget →
      `:not_applicable`; unknown evidence → `:unknown`
- [x] dimensions lane check — requested dims ∈ evidence set →
      `:match`/`:rejected`; nil request → `:not_applicable`; unknown →
      `:unknown`
- [x] `filter_exclusions(lane:, exclusions:)` — target kinds
      `:attempt_target` (pf+instance+model), `:instance`, `:lane`/
      `:offering` (both = lane_id), `:model`, `:provider`,
      `:quota_domain` → `:clear` / `:excluded`
- [x] remove `filter_model` (D4 — lands with §7.1 item 1)
- [x] spec: extend `filter_spec.rb` with the six axis example sets
      (port from `candidate_evaluator_spec.rb`)

### 7.3 `fleet.rb` (Q1 — minimal, two stateless methods)

- [x] `fleet_enabled?` — `Legion::Settings.dig(:llm, :fleet, :dispatch,
      :enabled) != false` (moves the read out of route_attempts.rb:21)
- [x] `fleet_lane?(lane)` — `lane.tier == :fleet &&
      filter_fleet(lane: lane) == :supported`
- [x] 4 spec examples in `fleet_spec.rb` (enabled default, disabled
      override, non-fleet lane false, fleet lane w/o contract false)

### 7.4 The class (`router_new.rb` — fill the stubs, in this order)

- [x] No-candidate rejection reduction → **Router class private**
      (NOT a routing/ file — D10, selection-time) ←
      `router/rejection_diagnostics.rb`: the ordered reduction
      (steps 0–9, kinds invalid_routing_context/invalid_request/
      policy_denied/failed_dependency/too_early/service_unavailable/
      context_rejected; NEVER infers `:attempts_exhausted` or
      `:stale_selection`) becomes private Router methods
      (`reject_no_candidates(...)` + helpers), inputs adapted to the
      class shape (request + operation replace the old `requirements:`
      kwarg — D1).
      Spec: re-target `rejection_diagnostics_spec.rb`.
- [x] `next_lane` — the selection core (old `router.rb`
      `self.next_lane` as instance method): derive facts
      (§7.1 items 2-3) → filter axes per lane (§7.2) → EvaluationSet →
      ready lanes → `rank(lanes:, routing_seed:
      request.routing_context.routing_seed, routing_affinities: [],
      affinity_strength_bps: settings_snapshot.affinity_strength_bps,
      context_budget:, preferred_context_range_for: ->(lane) {
      settings_snapshot.preferred_context_range_for(lane: lane) })` →
      `build_selection` | `RejectionDiagnostics.call`; WITH the hint-miss
      fallback (honored hint that matched nothing → re-evaluate without
      the pin; trusted pins never fall back).
- [x] `build_selection(ranked:, snapshot:)` — private; the D6 seam
      (`ranked.lane`, not `ranked.evaluation.lane`); builds
      `Legion::Extensions::Llm::Routing::Selection` (lane_id, instance_
      key, provider_family, instance_id, model, operation = the REQUESTED
      fine op, callable_handle, publisher_token_id, evidence, weight
      fields from the RankedLane).
- [x] `hint_model_pin_active?` — private (old `router.rb` private; reads
      `request.body_model_hint_decision` + the model pin).
- [x] Session absorption (D9) ← `inference/routing_session.rb`:
      `next_attempt(snapshot:)`, `next_attempt!(snapshot:)` (raises
      `Errors::RoutingRejected` — the preflight path),
      `add_exclusion(exclusion:)`, `classify(dispatch_result:,
      attempt_context:)` (delegates to `Routing::OutcomeClassifier.call`,
      applies the action), `consume!(selection)`,
      `apply_global_transition(transition)`, `attempts_exhausted(snapshot)`,
      `stale_selection(snapshot)`. Behavior carries verbatim — the old
      behavioral specs are the oracle.
- [x] The 4 class-level status queries (old `router.rb` class methods,
      verbatim): `self.routing_enabled?` (any complete publication),
      `self.tier_priority` (ONE settings spelling:
      `llm.routing.tier_priority` — the `tier_order` spellings are dead),
      `self.tier_available?(tier)`, `self.privacy_mode?` (delegates to
      `Legion::Settings.enterprise_privacy?`).
- [x] ctor validation per D1: operation ∈ Taxonomies::OPERATIONS (raise
      ArgumentError), and whatever the seed/trust validation needs.

### 7.5 The swap (the tip — one coordinated step, not five)

- [ ] `router.rb` module → class: the content of `router_new.rb` (stubs
      filled) becomes `router.rb`; `router_new.rb` is removed (or
      renamed — local, no git). Dead members are NOT reproduced:
      `tier_rank`, `context_headroom`, `default_rng`,
      `canonicalize_capabilities`, `LANE_TYPE_BY_OPERATION` +
      `lane_type_for` (rewire `inference/executor/escalation.rb:298` to
      `Taxonomies.lane_type_for`), `hint_model_pin_active?` in module
      form, the `self.next_lane` function form.
- [ ] delete `lib/legion/llm/router/` (all 15 files, incl. the
      commented-out ones) + `lib/legion/llm/inference/routing_session.rb`.
- [ ] rewire consumers — `RoutingSession` (14 sites): `inference.rb`,
      `context/curator.rb`, `quality/shadow_eval.rb`,
      `call/embeddings.rb`, `call/structured_output.rb`,
      `api/namespaces/anthropic/messages/count_tokens.rb`,
      `api/namespaces/openai/batches.rb`, `inference/executor.rb`,
      `inference/prompt.rb`, `inference/attempt_context.rb`,
      `inference/executor/routing.rb`, `inference/executor/escalation.rb`,
      `errors.rb` (comments), `inference/route_attempts.rb`.
- [ ] rewire constant/require sites: `llm.rb` require block (the 13
      `router/` requires → `routing/` requires; drop
      `router/escalation/history`), `inference/request.rb:5-7`
      (settings_state/header_constraints/body_model_hint_policy requires),
      `api/native/offerings.rb:5`, `api/namespaces/openai/models.rb:9`.
- [ ] `Call::Embeddings` + the executor + `prompt.rb`: construct
      `Router.new(request:, operation:, snapshot:)` (operation: chat/
      stream_chat from the route, `:embed` for embeddings — D3).

### 7.6 Specs (move with the logic; delete with the old file)

- [x] re-targeted unit specs under `spec/legion/llm/routing/`:
      body_model_hint_policy, required_capabilities, input_bound,
      header_constraints (+header_validation), outcome_classifier,
      rejection_diagnostics, evaluation (if it earns its own spec),
      filter (extended, §7.2), fleet (extended, §7.3).
      (DONE where applicable: `outcome_spec`, `evaluation_spec`, `filter_spec`
      (extended), `fleet_spec`, `rank_spec` (augmented), `settings/router_spec`.
      body_model_hint_policy → folded into `filter_spec`; required_capabilities /
      input_bound / rejection_diagnostics → folded into `router_new_spec`.
      header_constraints (+validation) DEFERRED — out of scope, stays at old path.)
- [ ] the 7 BEHAVIORAL specs re-encoded against the Router CLASS (these
      are the regression heart — port every example, do not summarize):
      `next_lane_spec`, `request_lane_spec`,
      `ssot_v3_fail_forward_release_bar_spec`, `silent_failover_spec`,
      `ssot_v3_instance_recovery_regression_spec`,
      `internal_error_terminal_spec`, `no_loop_do_spec` (read it first —
      if it guards "no `loop do`" in router code, re-target its scope to
      `router.rb` + `routing/`).
- [x] `spec/legion/llm/router_spec.rb` (module surface) re-encoded as the
      class spec (status queries + ctor).
      (DONE as `spec/legion/llm/router_new_spec.rb` — mirrors `router_new.rb`;
      becomes `router_spec.rb` at the §7.5 swap.)
- [ ] delete `spec/legion/llm/router/` as its lib files die
      (`candidate_evaluator_spec`, `ranker_spec`,
      `ranker_band_partition_spec`, `ranker_log_identity_spec` — port
      unique cases into `rank_spec.rb` FIRST, diff first;
      `settings_snapshot_spec`/`settings_state_spec`/`settings_spec` —
      NOT re-homed (D2): keep coverage of the legacy singleton where it
      lives, out of this migration; `resolution_spec` + top-level
      `escalation_history_spec` — delete with the dead files).

### 7.7 The tip gate (the only full-green gate)

- [ ] full `bundle exec rspec` in legion-llm — exit 0
- [ ] `bundle exec rubocop` — 0 offenses
- [ ] lex-llm + the 9 provider gem suites still green (shared owners
      touched by the swap? verify — the swap should not touch them)
- [ ] one-oracle check: conformance kit, matrix harness, and e2e
      validators assert the same shapes (the matrix suite exercises the
      real daemon path — it is the integration proof)
- [ ] sibling check: native vs namespaced status endpoints
      (tiers/providers/routing) byte-identical shapes
- [ ] restart manifest per the N×N method (which gems changed; the
      human restarts) + report in the N×N report format

---

## 8. Working notes for the next session

- **If a `router/` source is a `self.call` module, its SHAPE does not
  travel** — translate it per D10 (ingress-time → request-builder
  private; selection-time → Router private; classification → mixin +
  records like `rank.rb`). Creating a `routing/<name>.rb` that is a
  `self.call` module is the exact regression D10 bans — if you catch
  yourself doing it, STOP.
- The old specs under `spec/legion/llm/router/` are the ORACLE for the
  reproduction work — port examples, don't invent new behavior.
- If a `router/` source and the old spec disagree, the spec wins (it is
  the encoded contract); report the disagreement.
- The `Rank` mixin takes READY lanes — the class does the filtering; do
  not put eligibility logic into `rank.rb` (D6).
- Everything in `routing/` is required by `router_new.rb` in the commit
  that lands it (one line, at the top of the file).
- When the human re-enables git: each per-file swap becomes one commit
  (`routing: <file> — reproduced in <home>, legacy removed`); the swap
  (§7.5) is one commit; no force push; exact-path staging; no
  Co-Authored-By.

---

## Appendix A — the law (inlined verbatim — read in full before any code)

> Three documents, copied verbatim from their sources on 2026-08-23.
> If a source doc is amended, this appendix is amended in the same
> change — a session works from THIS file.

### A.1 Operating rules

# Operating Rules

### Rule fidelity
- Apply explicit rules literally before inferring intent; when a stated rule and its likely intent seem to conflict, the literal rule wins.
- When given a deterministic rule or classification, apply membership mechanically; never create exceptions, aliases, precedence rules, special cases, or broader rules that were not specified.
- If a value matches a stated category, do not remove it from that category based on prior convention, likely intent, or your own judgment.
- Derive tests and verification from the literal rule as stated, not from the implementation or your interpretation of it.
- A current explicit instruction overrides any apparent prior convention unless asked to preserve the convention.
- Never silently improve a deterministic policy; if a change seems necessary, ask first.
- Before acting on a rule, check whether your implementation introduces any condition, exception, alias, or assumption not contained in the stated rule; if it does, do not write it.

### Evidence and scope
- Preserve claim boundaries: never broaden scope, timing, frequency, certainty, intent, motive, permanence, or causality beyond what was actually stated.
- Do not invent a claim that was not made and then argue against it.
- Preserve exact nouns, verbs, qualifiers, numbers, negations, and temporal statements before synthesizing.
- Distinguish observed, retrieved, inferred, and unknown; never present one as another.
- When evidence ends, state what is unknown instead of completing the pattern with a plausible story.
- Inspect the relevant files, logs, or tool output before constructing a causal explanation.
- If two observations conflict, surface the conflict; do not invent a narrative that reconciles them.
- Causal language is exact: moved, existed, caused, preceded, correlated, and probably are not interchangeable.
- Once a decision or constraint is closed, do not reopen it unless new evidence makes it impossible.
- Solve the requested problem; do not propose unrequested refactors, cleanup, or alternative architectures.
- Never fabricate reasons for your own prior behavior; stating that you do not know is preferable to invented psychology.
- Ask a question only when the missing answer would materially change the result; otherwise proceed.
- A failed tool call is not task failure; try the next valid evidence path instead of discussing the failure.
- Keep the final answer concise; reasoning effort governs verification depth, not answer length.
- Prefer correction over consistency: new evidence invalidates earlier conclusions, including your own.

### A.2 N×N architecture law (rules v2)

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

### A.3 N×N debugging method

# The N×N Debugging Method — capture first, fix offline, confirm once

> Standalone methodology for working on LegionIO's LLM routing. Written to be read cold, with zero
> prior session context. If you are an AI session being pointed at a broken client×provider cell:
> this document is the law. Deviating from this loop is how hundreds of dollars got burned on
> live-debug ping-pong before it existed.

### 1. The topology you are working in

```
  CLIENTS                     LEGIONIO DAEMON (localhost:4567)                PROVIDERS
  Claude Code ──/v1/messages──┐                                          ┌── lex-llm-anthropic ── Anthropic API
  Codex ───────/v1/responses──┤  client translator                       ├── lex-llm-bedrock ──── AWS Bedrock
  OpenAI SDKs ─/v1/chat/...───┤    ⇅ Canonical::Request/Response/Chunk   ├── lex-llm-openai ───── OpenAI API
                              │  Inference::Executor (pipeline, routing, ├── lex-llm-vllm ─────── vLLM (qwen etc.)
                              │  escalation, tool loop, StreamAssembler) ├── lex-llm-ollama ───── Ollama
                              │    ⇅ Canonical                           └── ...
                              └  provider translator (in each lex-llm-* gem)
```

- **Hub-and-spoke, never per-combo.** Each client format has ONE translator (client ↔ Canonical).
  Each provider has ONE translator (Canonical ↔ wire). N+M translators serve N×M combinations.
  Canonical types live in lex-llm (`lib/legion/extensions/llm/canonical/`).
- **The execution proxy**: LegionIO-registered tools are executed BY the daemon, mid-conversation.
  To the provider they look like normal client tool calls (call + result in the messages). To the
  client they look like server-side tools (visible, with results, never actionable). Both sides
  must always see them — this contract is PINNED (G24 in the implementation plan); no session may
  reinterpret it. If a fix requires changing those shapes, STOP and escalate to the human.
- **Where bug classes live**: wrong wire shape to/from a provider → that provider's translator.
  Wrong client-visible shape/SSE → that client's translator or the StreamAssembler. Tool loop,
  history reconstruction, routing, escalation → executor (legion-llm `lib/legion/llm/inference/`).
  Anything half-translated between Canonical and a legacy shape is the highest-probability site.

### 2. The three test layers (cheapest first — always work at the cheapest layer that can express the bug)

| Layer | Where | What it proves | Cost |
|---|---|---|---|
| **Conformance kit** | lex-llm `spec/legion/extensions/llm/conformance/` (fixtures + shared examples; ships in the gem; provider gems load it via `Gem.loaded_specs['lex-llm'].full_gem_path`) | A single translator honors the canonical contract, both directions, incl. streaming chunk sequences and multi-turn histories | free, ms |
| **In-process matrix harness** | legion-llm `spec/legion/llm/api/matrix/` + `spec/support/fake_provider.rb` (Rack::Test against the real Sinatra app, deterministic FakeProvider) | The FULL daemon request path — route → client translator → executor → tool loop → assembler → response — for every client × scenario, streaming and not, incl. the execution proxy | free, <1s |
| **Live e2e** | `~/rubymine/legion/legionio-e2e` (two-phase: direct provider, then daemon proxy; records every request/response JSON to `results/`) | Real provider wire-truth and real-client behavior. Cloud cells cost money; anthropic cells may be credit-gated — never run them while iterating | $, minutes, needs daemon restart per code change |

**Known blind spot:** the FakeProvider returns canonical objects directly, so the harness does NOT
exercise provider-side streaming/accumulator code in lex-llm. Bugs there need conformance chunk
fixtures (layer 1) built from real captured SSE.

### 3. THE LOOP (mandatory, in order)

When a live e2e cell fails — or any live behavior is wrong:

1. **CAPTURE, don't diagnose from vibes.** Run the single failing spec once
   (`cd ~/rubymine/legion/legionio-e2e && bundle exec rspec <one spec file>`). Collect: HTTP status,
   the recorded request AND response JSON from `legionio-e2e/results/`, and the daemon's error log
   lines (error class + stack). The recorded request — what the daemon actually sent the provider —
   is usually the answer.
2. **Check determinism — and CLASSIFY the variance (the G25 standard).** Run the cell 3×. Compare
   response FINGERPRINTS: stop_reason + tool-call names/count + thinking presence + routing triple
   (provider/instance/model) + HTTP status (the `X-Legion-Format: canonical` header makes the diff
   trivial). Three variance classes:
   - SAMPLING — text differs, fingerprint identical → fine, proceed.
   - STRUCTURAL — fingerprint differs (tool called sometimes, not others) → pin decoding in the
     spec payload (temperature 0, seed where the provider supports it) before diagnosing; if it
     still varies pinned, it is a daemon bug; if a cell inherently can't be pinned, the fix must
     handle ALL observed output modes (capture each).
   - INFRASTRUCTURE — routing triple or status differs on a pinned-provider payload → ALWAYS a
     daemon bug (routing must be deterministic for identical canonical requests); also visible in
     the ledger (identical requests must produce identical provider_instance/dispatch_path/
     route_attempts rows).
   Never patch against one sample of a sampling distribution.
3. **Encode the failure as an OFFLINE spec at the cheapest layer that can express it**, using the
   CAPTURED payloads verbatim (sanitized) — not your reconstruction of them. Translation bug →
   conformance fixture. Pipeline/route bug → matrix harness spec. It must FAIL for the same reason
   the live cell fails. If you cannot make it fail offline, you have not found the bug — keep
   capturing, do not guess-fix.
4. **Fix.** At the architectural boundary (translator / assembler / executor) — never a route-level
   special case, never a provider-name conditional outside a translator, never by weakening the
   contract the spec asserts.
5. **Confirm: new spec green, then the FULL suite of every touched repo** (`bundle exec rspec` —
   0 failures, output to tmp/; `bundle exec rubocop` — 0 offenses). One commit per root cause,
   the cell names and error signature in the message.
6. **Sibling check.** The same code path exists in the other client translators and provider
   translators. Inspect each; state "checked X/Y/Z — present/absent" in your report. A fix that
   closes one cell of a class is whack-a-mole; close the class.
7. **One restart, one run.** All fixes batched → the human restarts the daemon ONCE → ONE e2e run.
   Live e2e is confirmation, never the debugger. **A cell is "healed" only after it passes live —
   claiming healed from offline evidence alone is an overclaim, and overclaims get audited.**
8. **The new offline spec stays forever.** That is the entire point: today's live failure becomes
   tomorrow's free regression test. e2e never has to catch the same bug twice.
9. vLLM and Ollama is consistent and unless down, never the issue, do not assume or point the issue at
   at it being a qwen/vllm/openweight model issue, 99.999999% of times, this is a LegionIO issue with transforming requests
10. For RSpec that tests specific formatting functionality, do not assume the rspec is wrong, assume something broken on the client -> transformation -> provider pipeline
11. NO GAPS, no "fix this later", no lazy answers. Verify everything, read the actual code, no assuming

### 4. Standing rules (these are commitments, not suggestions)

- **One writer per repo at a time.** Before editing, check no other session/agent owns the repo.
- **Restart manifest**: every daemon restart records `git -C <repo> rev-parse --short HEAD` for
  legion-llm, lex-llm, and the five provider gems, next to the run results — "what changed since
  green" must be a diff, never an investigation.
- **Pinned contracts beat local reasoning.** G24 (execution proxy shapes), G5 (thinking never
  crosses providers), G6 (mid-stream failover; conversations never die), G16 (no pipeline
  bypasses), the equivalence invariant (same payload via /v1/messages and /v1/responses parses to
  an IDENTICAL Canonical::Request). All in
  `legion-llm/docs/work/planning/2026-06-09-nxn-canonical-routing-implementation.md`.
- **One oracle.** The conformance kit, the matrix harness, and the e2e validators must assert the
  SAME shapes. If two suites disagree about expected output, that is the bug — reconcile the
  oracles before touching production code.
- **Never restart/stop the daemon from an agent session** — report which gems changed; the human
  restarts. Never run anthropic e2e cells without confirming credits. Never iterate via the full
  live matrix.
- House rules: every rescue calls handle_exception or re-raises; `Legion::JSON` never bare `::JSON`
  (rescue `Legion::JSON::ParseError`); no `_foo:` kwargs, no `**_rest`; every tunable in
  settings.rb, never inline `|| literal`; full rspec+rubocop before every commit; never force push;
  no Co-Authored-By; public repos — no company references anywhere.

### 5. Report format (every session ends with one)

To `legion-llm/docs/work/planning/reports/<batch>.md`: evidence table per cell (status, error
class, captured-payload findings) → root causes (with what CONFIRMED them, and any prior
hypothesis you DISPROVED) → fixes (file:line, commit SHA) → sibling-check results → suite counts →
restart list (which gems changed) → per-cell expected live outcome, marked as EXPECTED until the
human's confirmation run proves it.

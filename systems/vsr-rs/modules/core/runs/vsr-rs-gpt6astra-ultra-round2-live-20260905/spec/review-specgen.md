# Spec Generation Review: vsr-rs

Reviewed on 2026-09-05 against source commit `3ac0104a567092139534c9022205d02281a2da41`. **PASS for the baseline scope selected by the modeling brief**, with two minor completeness improvements. No blocking semantic discrepancy was found by source comparison and the independent checks below.

Scope matters here: [modeling-brief.md](../modeling-brief.md), lines 93–110 and 129–131, explicitly selects **no targeted protocol extensions or hunts**. Scenarios 1–5 remain on executable/API/socket/filesystem/clock verification routes; Scenario 6's simulator/proof defects also remain outside the protocol model. The applicable baseline observer properties are implemented. [brief-coverage.md](brief-coverage.md), lines 9–35, preserves each disposition. Absence of six scenario-specific extensions/configs is therefore intentional, not missing coverage of an authorized modeling task. A high coverage score below means conformity to that brief, not verification of its integration findings.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All six scenarios have explicit, brief-consistent dispositions. Baseline assumptions preserve durable views, recovery of old identities, fresh nonces, and authentic messages; no excluded caller defect is injected. |
| Action Design | 5/5 | Handler names follow Rust functions. Prepare gap/append/duplicate, state-transfer/catch-up, and timer paths retain their distinct guards and updates. One atomic owner call matches the implementation and brief; synchronous helpers correctly remain inside that call. |
| Source Annotations | 4/5 | Protocol helpers and actions have accurate source ranges. Some multi-branch blocks have only a broad function-level citation instead of branch-local references; see issue 1. |
| Invariant Coverage | 4/5 | All five baseline safety contracts are defined and enabled in base, MC, Trace, and baseline-hunt configs. Agreement retains full requests across time/crashes; execution uniqueness is per incarnation. Structural `TypeOK` coverage is incomplete; see issue 2. Excluded integration properties are honestly identified as unverified. |
| MC Spec Structure | 5/5 | Budgets govern external request/timer inputs and injected faults; reactive message handling and recovery completion have no counter gates. Client-only symmetry respects ordered replica IDs. State identity retains enabling counters; constraints count message multiplicity and bound views. Progress is correctly disabled without stabilization/fairness assumptions. |
| Trace Spec Design | 5/5 | Every wrapper invokes the full base action, checks the observed input and mandatory full post-state, and advances the cursor. There are no silent protocol actions. Replay fairness and the enabled eventual-EOF property reject a blocked trace. |
| Instrumentation Mapping | 5/5 | All 19 transition event types plus initialization map to source/owner boundaries, captured fields, and trigger timing. The mapping handles ignored dispatches, independent output queues, full requests, application observers, and equality-preserving nonce normalization. |
| Logical Correctness | 5/5 | No concrete guard, update, temporal-formula, or baseline safety-oracle error found. Base/MC/Trace passed semantic processing through independent TLC runs; the negative replay failed for the intended temporal property. |

## Overall: 38/40

The review compared the generated handlers with the pinned implementation, including rejection side effects (`base.tla:173–241` / `lib.rs:646–837`), suffix and view installation (`base.tla:243–286` / `lib.rs:842–1121`), recovery response selection (`base.tla:298–311` / `lib.rs:1166–1205`), timer/backoff handling (`base.tla:316–348` / `lib.rs:1233–1305`), and client-table reconstruction (`base.tla:71–83` / `lib.rs:1324–1344`). No mismatch was identified in those comparisons.

Independent validation used isolated copies, one TLC worker, and a 2 GiB heap. The reviewed source, tools, and original generated artifacts matched `artifact-manifest.json`; independently tested copies also matched their originals. The source and reviewed specs were left unchanged. Evidence hashes and outcomes are retained in the [review manifest](output/review-specgen-20260905/review-manifest.json).

| Independent check | Result | Evidence |
|---|---|---|
| Shipped `MC_smoke.cfg`, exhaustive BFS, seed `20260905` | Exit 0; 5,180 generated / 1,677 distinct states; queue empty; depth 13 | [MC log](output/review-specgen-20260905/MC-smoke.log) |
| Shipped synthetic positive trace with `Trace.cfg` | Exit 0; 37 tagged records consumed, including initialization; 37 distinct states | [Positive replay log](output/review-specgen-20260905/Trace-positive.log) |
| Shipped synthetic negative application snapshot (`app = 999`) | Expected exit 13; `TraceMatched` violation, blocked at cursor 6; no parser/type-error substitution | [Negative replay log](output/review-specgen-20260905/Trace-negative-state.log) |

These runs also independently parsed and semantically processed all three TLA+ modules. The larger `MC.cfg` and `MC_hunt_baseline.cfg` were inspected, not exhaustively explored in this review. The smoke configuration excludes view changes and recovery (`MC_smoke.cfg:8–15`); their synthetic replay and source comparison do not establish exhaustive behavioral coverage. No Rust simulator bug reproduction was performed.

## Issues Found

- **1. Minor — add branch-local source annotations.** In [base.tla](base.tla), lines 182–200, the single `lib.rs:646–694` citation covers role/status rejection, old request rejection, pending/executed duplicates, and append/broadcast. Lines 350–365 similarly cite `lib.rs:530–639` for the firewall and all dispatch variants. The mappings are accurate, but the checklist asks for every logic block to cite its own source. Add narrower references beside those conditions/branches; arithmetic and observer-only helpers need an abstraction explanation rather than invented Rust locations.
- **2. Minor — complete the structural type invariant.** `TypeOK` in [base.tla](base.tla), lines 502–516, checks selected domains, counters, statuses, sender sets, and network multiplicities, but omits complete log/request/message/client-table/history schemas and Boolean types such as `heard`, `catching`, and `dvcSent`. `MCTypeOK` (`MC.tla:61–65`) inherits this gap. Add reusable request, message, replica, and client type predicates, including nested payloads and observer histories. This would improve detection and diagnosis of malformed model updates. It is not an observed protocol counterexample, and the required behavioral invariants are present.

The following are disclosed confidence limits, not additional defects: the fixtures are synthetic rather than captured Rust executions; implementing the instrumentation handoff and validating real traces remains downstream work. `TraceMatched` proves consumption of the supplied tagged events, while omitted no-op callbacks and terminal truncation require independent capture-integrity evidence (`instrumentation-spec.md:143,153`). `DurableViewConsistent` follows the conforming publication wrapper (`base.tla:386–393,517`); it does not verify example filesystem durability. `ClientProgress` (`MC.tla:67–73`) is intentionally disabled and supplies no liveness result.

## Verdict: PASS

Suitable for the next harness/trace-validation phase within the declared conforming-library baseline. The two minor improvements do not block that handoff. This verdict is a spec-generation assessment, not a proof of library safety, a completed implementation-conformance result, or confirmation of the brief's integration findings.

# Candidate v5 sampled-bound consistency

This note is for the independent reviewer and controller. V5 adds an explicit consistency mode to the v4 collector. It retains v4's execution-ordered stamps, calibration and refusals. It changes no measured bridge, hook, event mapping, scenario, expected outcome or model file. The [v4 analysis](clock-method-v4.md), especially its “Consequences for acceptance and rejection,” remains the starting point. Its global-store and run-wide-clock obligations remain unresolved. V5 changes the permitted claim, not those obligations.

The gate is `INCOMPLETE`, naming v5. This document is an implementation argument awaiting independent review. No candidate execution, clock measurement, generated implementation trace, build, Docker invocation, guest or TLC run occurred. [v5-inputs.json](v5-inputs.json) binds the v4 baseline, protected inputs and still-installed v3 source. [candidate-v5/hashes.json](candidate-v5/hashes.json) binds the frozen candidate.

## Fixed evidence class and claim

Every grouped TraceData object and its collection sidecar carries `evidence_class: "CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND"` and this exact `claim` text. Diagnostic reports, diagnostic event-file envelopes and the collector's result message carry the same label and conditional claim. Diagnostics themselves remain `INELIGIBLE`.

> An accepted TraceSearch.cfg witness shows that the observed per-event arguments and post-states are consistent with some model interleaving that respects each actor's local order and the recorded cross-actor interval constraints after widening by the sampled calibration bound. It does not establish the real global order, store-visibility timing, or a run-wide clock bound. A rejection is a candidate mismatch that must be re-examined against the clock limits before any model or kernel conclusion.

The grouped file remains one JSON object using `asterinas-wait-reap-timebox-v1`. Additional labels live at the top level because `TraceShapeOK` requires exactly seven fields in each event. The 41 decoder arms, argument records and post-states are unchanged. The diagnostic/sidecar calibration retains `run_wide_bound_cycles: null`. Emitting a grouped file leaves its validation `NOT_RUN`, and its sidecar acceptance `NOT_VALIDATED`.

An accepted witness means the specific `TraceNoCompleteMatch` counterexample in `TraceSearch.cfg`, with preceding invariants intact, all cursors exhausted and `TraceEndOK` satisfied. Search exhaustion without that witness is the candidate mismatch described above. A timeout, another invariant failure or an evaluation error is inconclusive. `Trace.cfg` has a different universal property and does not substitute for this existential search.

## Comparison rule

The collector first performs the unchanged calibration on the raw log from this invocation. Let `B` be its `sampled_abs_bound_cycles`, the maximum absolute endpoint across both phase offset intervals. B is not supplied by a caller, reused from a Linux control or chosen from a model result. The fixed 100,000-tick admission threshold remains an operational cutoff.

For events `e` and `f` belonging to different actors, define the retained precedence relation `P`:

```text
If actor_cpu[e] != actor_cpu[f]:
    P(e, f) iff e.end + B < f.start - B
            iff e.end + 2*B < f.start
Otherwise:
    P(e, f) iff e.end < f.start
```

Thus every cross-CPU comparison widens both endpoints, including the reference CPU's endpoint. The extra slack is deliberate. At equality there is no edge, matching the unchanged strict comparison in `ViablePIDs`. Different actors sharing one CPU use the same local clock and need no cross-CPU offset allowance. V4's CPU-affinity assumptions still apply. Per-actor arrays and local order never change.

The raw starts retain the same `lfence; rdtsc; lfence` assembly and compiler barriers. No source stamp is moved, replaced or tightened. The already-approved kernel/user return merge still ends at the observed user completion and still refuses inversion. The scalar integers supplied to TraceData below encode relations between these observed intervals. They are neither new measurements nor a recovered execution schedule. Raw local ticks remain in the diagnostic files.

## Exact encoding with local non-overlap

Writing `[start-B,end+B]` into every event would make nearby events of the same actor overlap. Choosing one CPU shift could instead impose edges not justified by the whole uncertainty interval. V5 therefore represents the widened cross-actor relation directly, without selecting a clock offset or consulting the model.

Create two integer variables `S_e,E_e` for each event in observed array order. A directed edge `u -> v` of weight `d` means `v >= u+d`. The constraints are:

1. `S_e -> E_e` with weight 0 enforces an event's valid interval.
2. `E_e -> S_next` with weight 0 enforces the unchanged actor non-overlap rule.
3. For every ordered pair of different-actor events with `P(e,f)`, `E_e -> S_f` has weight 1. It retains that strict precedence edge.
4. For every such pair without `P(e,f)`, `S_f -> E_e` has weight 0. It prevents the encoding from inventing a precedence edge, including at touching endpoints.

`encode_intervals()` constructs an equivalent sparse graph. Raw starts in each actor are nondecreasing after the existing local check. For each event end and other actor, `bisect_right(starts, end + margin)` splits starts into the nonpreceding prefix and strictly preceding suffix, with `margin = 2B` across CPUs and 0 on the same CPU. Only the last prefix start and first suffix start need edges. The local chain makes all earlier starts no larger and all later starts no smaller. Empty prefixes/suffixes need no corresponding edge.

All weights are 0 or 1. A strongly connected component containing a weight-1 edge implies `x >= x+1` along a cycle, so no scalar encoding can satisfy the exact relation and local shape. Collection records `UNREPRESENTABLE_LOCAL_ORDER`, identifying the strict endpoint pair in that component, in the diagnostic and sidecar. It emits no grouped trace. It neither clips uncertainty nor drops a constraint. Because the graph includes all required comparisons or equivalent boundary constraints, this is an impossibility result for the unchanged scalar interface, not a model mismatch.

Otherwise, all internal component edges have weight 0 and their endpoints can share a rank. Collapse those components and assign longest-path ranks in the resulting acyclic graph. Starting every rank at zero satisfies nonnegativity. For each edge, the destination rank is at least the source rank plus its weight. This satisfies all four constraint classes. The resulting ranks are bounded by the number of endpoints and retain actor array order. They need not retain irrelevant start/start or end/end comparisons across actors.

Before serialization, the collector independently checks every ordered cross-actor pair against `P`, including absent edges, plus every local shape inequality. Therefore a successful encoding has exactly the desired `end < start` relation and satisfies the local interval requirement. The encoder reads timestamps, actor identities and their calibrated CPU mapping. It copies events without interpreting names, arguments or post-states. No model execution or model order participates.

## Sound direction and residual limits

Widening removes cross-CPU precedence edges from the raw comparison. It cannot add them because `B >= 0`. The exact encoding neither adds nor removes an edge from that widened relation. `Trace.tla` searches its interleavings while preserving each actor's array order. A retained complete witness therefore establishes precisely the consistency claim above.

V4's premature-store-end argument remains one-sided under sound starts, comparable clocks and fixed actor order. If an observed end is earlier than a sound visibility end, then any precedence implied by the sound end is also implied by the observed end. This inclusion still holds after adding the same B to both possible ends. The premature end may add false edges and cause rejection. An accepted witness is also compatible with removing those extra edges, but that does not identify the actual visibility order. V5 does not extend store ends or supply a missing visibility guarantee.

Other risks can make the search more permissive than the real execution:

- Finite calibration can miss an offset excursion, rate difference or hypervisor adjustment between samples. A misplaced start or end can remove an actual precedence edge. Matching pre/post intervals do not exclude this.
- The assumed execution-fence contract, affinity compliance and compiler output remain environment/binary obligations. V5 neither observes every kernel CPU assignment nor supplies disassembly.
- Independent endpoint envelopes discard correlations. A witness satisfying all pairwise widened comparisons need not correspond to one fixed offset or a physically realized clock trajectory, even if errors happened to remain within B.
- Instrumentation latency and compiler barriers can alter which schedules occur. Evidence from the instrumented execution is not a weak-memory correctness proof for uninstrumented executions.

These risks weaken the evidential value of a witness. They do not invert or enlarge its fixed claim into a statement about actual global order. Rejection likewise remains a candidate mismatch requiring clock-limit re-examination, not a kernel or model finding.

## Refusals, output and admission

The original calibration and decode functions are retained. Collection still refuses unsupported/missing CPUID, wrong or duplicate actor CPUs, absent pre/post phases or samples, duplicate/reordered indices, local sample inversions/regressions, inconsistent phase intersections, disjoint phase intervals, bounds above threshold, out-of-window events/user calls, incomplete fixture completion, dropped/truncated streams, truncated queues, local event overlap, return-count mismatch and kernel/user inversion. Optional spurious scheduling remains refused. No refusal is bypassed by consistency mode. An optimized Python interpreter is also refused because it removes the existing assertions.

Both entry points check an `APPROVED` v5 receipt and semantic hashes. Grouped mode additionally needs the receipt scope `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND` and the explicit `--consistency` flag. The required hashes cover current source helpers, runner, hooks, cases, installed receipt, model inputs, guide/status, both clock notes, v5 inputs and the frozen v5 manifest. The checker also verifies every snapshot entry. A diagnostic-only receipt cannot enable grouped output. The current gate remains `INCOMPLETE` with no author approval.

After gate and memory admission, `run.sh --consistency` prepares diagnostic JSON, grouped `.ndjson` and `.collection.json` under `.specula-output/traces/`, using attempt-and-case names. All raw logs stay under `harness/evidence/<attempt>/`. If collection refuses, diagnostics and a refusal sidecar survive, no grouped trace is written, and the runner stops. Default/`--diagnostic` collection emits no grouped file. Linux controls remain diagnostic only. No output is overwritten.

Guest `/init` runs the pinned image's static BusyBox `nproc` before executing the unchanged fixture. Each log records `WR_GUEST_NPROC`. Its boot command records the actual `-smp`, and its outcome records both values. Collection requires those values to equal the fixture's CPU count and checks affinity against that count. Linux `nproc` evidence is labelled separately. The runner checks BusyBox applets/static linkage and retains its hash before packaging. This small bootstrap precedes recorder reset and calibration and adds no synchronization to a measured bridge.

Memory admission now precedes application and any execution, with a second live check immediately before kernel build. V4's container prefix, attempt UUID and stage/case suffixes remain. The image remains `asterinas/dev:0.18.1-20260926`, pinned to `sha256:897cb1b354b3d7d28184d7a417c27565390fc3fa6886b328d2588e6de93c1dab`, with `--pull=never`. Actual image/app availability, guest counts and measured bounds remain `NOT_RUN`.

## Independent review boundary

Review the comparison equivalence, sparse-graph reduction, equality handling and impossibility refusal against the unchanged `TraceShapeOK` and `ViablePIDs`. Check that every v4 refusal remains on the shared path and that no gate, diagnostic or Linux-control path can accidentally authorize grouped output. Verify the fixed claim in code and both operational documents, snapshot hashes, exact CPU-count provenance and preservation of source/model inputs. The author ran only syntax and static identity checks recorded in [v5-static-checks.json](v5-static-checks.json). Encoder/collector execution and independent review are `NOT_RUN`.

Any later controller run still needs reviewed installation and installed-file hashes, binary disassembly, the actual calibration/CPUID/affinity records and complete raw evidence. It may yield labelled consistency evidence without resolving the stronger v4 clock/visibility obligations. Preserve v1-v5 and their correction artifacts. Do not report real-global-order validation or Phase 2.5 completion from this static change.

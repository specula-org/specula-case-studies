# Generation validation

Completed 2026-09-05 UTC against `3ac0104a567092139534c9022205d02281a2da41`. All 18 generation checks passed. The repeatable entry point is `python3 checks/run_checks.py`; exact commands, exit codes, tool hashes and log paths are in `validation-results.json` (in this directory). Expected negative runs passed by rejecting the trace with `TraceMatched`, not by returning success.

## Checked

- SANY parsing and semantic analysis: `base.tla`, `MC.tla`, `Trace.tla` all pass.
- Exhaustive tiny safety slice: **473 generated / 289 distinct states**, depth 19, completed with no error. N=3, two clients, one total request, no ticks, retries or faults. All proposed safety invariants were enabled. `MC_tiny.cfg` and `MC-tiny.log` preserve this deliberately narrow check.
- Each actual main/hunt cfg was loaded with its final operator overrides and run for **20 simulated traces**, depth ceiling 150, seed **20260905**, one worker. Seven cfgs give 140 smoke traces; constrained traces may be shorter. No enabled invariant failure, parse error or evaluation exception was reported.

| Run | Traces | Depth ceiling | Generated states | Result |
|---|---:|---:|---:|---|
| `MC-smoke` | 20 | 150 | 3393 | PASS |
| `scenario1-smoke` | 20 | 150 | 3606 | PASS |
| `scenario1_five-smoke` | 20 | 150 | 3630 | PASS |
| `scenario2-smoke` | 20 | 150 | 3137 | PASS |
| `scenario3_recovery-smoke` | 20 | 150 | 3016 | PASS |
| `scenario3_recovery_five-smoke` | 20 | 150 | 3041 | PASS |
| `scenario3_requests-smoke` | 20 | 150 | 3934 | PASS |

- A **133-transition synthetic fixture plus Init** exercises primary/backup normal operation, sequential Put/Get results, client reply acceptance and a later stale reply, memory-losing recovery and replay, retained-state pause/resume, view change with DVC selection, StartView installation, higher-view catch-up through GetState/NewState, same-view StateTransfer after a dropped Prepare, and old-view packet handling. `Fixture.tla` checks its own completion and all safety invariants, then serializes the fixture. `Trace.tla` consumes it with full snapshot/apply validation and `TraceMatched`; **134 distinct trace states** complete successfully. Exact branch counts are in `fixture-coverage.json`.
- Five negative fixture copies are rejected at the intended boundary: altered post-state commit number, altered apply result, altered packet operation number, omitted persistence transition, and a mismatching first event. Every failure is `Temporal property TraceMatched was violated`, rather than an evaluator exception. See `trace-negative-manifest.json` and `trace-negative-*.log`.
- `audit_cfg.py` rereads every actual cfg and verifies that every proposed brief §5 safety name is enabled in at least one hunt. `cfg-audit.json` records all active invariants, properties, scalar bounds and operator overrides.

## Interpretation limits

These are generation checks, **not completed spec convergence, Rust implementation trace validation, or an exhaustive protocol hunt**. The fixture is generated from the model, so its positive replay establishes schema/action wiring only. Its negative copies establish that mandatory observations and cursor completion are enforced. It cannot establish model-to-code fidelity; the next harness phase must instrument the pinned Rust implementation using `instrumentation-spec.md` and run real traces.

The random smoke samples are not exhaustive. They do not establish all target mechanisms were reached, all historical quorum combinations were explored, or that any implementation bug exists. In particular, a five-replica cfg permits two concurrent recoveries; that permission is not a claim of complete two-recovery coverage in these samples.

The temporal hunt cfgs check conditional finite-slice properties. Fair independent ticks, owner progress, delivery deadlines and the stable non-recovering core are explicit premises. `<>BoundHit` discharges paths that reach an exploration limit; those paths are **inconclusive**. No general liveness theorem or proof of service under every unknown finite delay is claimed.

The source checkout remains at the pinned revision with its pre-existing untracked `.codex/` directory; no Rust source, tests, commits or external systems were changed. No simulator bug was reproduced, so the source AGENTS.md simulator-regression instruction was not triggered.

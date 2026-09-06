# Specification validation — vsr-rs

**Result: workflow converged in one round within the prescribed budget; no model-checking finding was produced. Exploration and liveness assurance remain LIMITED.** Source: `3ac0104a567092139534c9022205d02281a2da41`.

## Evidence

1. Phase 0 verified all required inputs, six hunt cfgs, enabled `TraceMatched`, full post-state/application comparisons, and 46/46 inherited provenance hashes. The existing harness needed no regeneration. [Audit](output/phase0-audit.md).
2. The installed `run_trace_validation_parallel` handler replayed all four implementation traces successfully: 474 transitions and 50 nested application calls. A second strict pass and four corrupted controls passed their expected acceptance/rejection checks. Every negative was rejected specifically by `TraceMatched`; no checks were relaxed. The installed `clean_traces` handler found no generated trace artifacts to remove. [Trace results](output/round1-traces/parallel-results.json), [controls](output/round1-traces/controls/results.json).
3. `MC.cfg` ran for 30 minutes with 32 workers and 16 GiB heap + 64 GiB off-heap. The last sample recorded 1,299,398,606 generated states, 232,574,619 distinct states, 128,644,184 queued states and depth 19. No violation or semantic/invariant change occurred. [Convergence record](output/convergence.json).
4. All six hunts ran for 30 minutes in BFS, then 30 minutes in depth-100 simulation. Concurrent runs used explicit worker/memory budgets and separate directories with copied, hash-checked inputs. [Bug report and per-config coverage](bug-report.md), [run summary](output/run-summary.json).

## Interpretation

Preservation, ordered application, logical-request uniqueness and reply soundness were checked where enabled by each supplied config. No counterexample was produced, so Case A/B/C counts are all zero. Source, semantic specifications and config bounds were preserved. There is no bug reproduction or new simulator regression from this phase.

The recorded traces cover all 18 event types, but not every finer dispatch branch. Aggregate search counts do not prove mechanism-specific reachability. Conditional temporal passes discharge bound-reaching behaviors and rely on the explicit timing/fairness environment; they do not establish general service liveness or the shipped example's obligations. The detailed limitations and independently reviewed oracle qualifications are in [the bug report](bug-report.md) and [fidelity audit](output/fidelity-audit.md).

Required artifacts are [changelog.md](changelog.md), [bug-report.md](bug-report.md), [findings.json](findings.json), and the preserved TLC evidence under `output/`. The findings index contains a present empty list, explicitly recording zero model-checking findings rather than a missing phase result.

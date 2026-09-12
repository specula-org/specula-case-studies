# Generation checks and handoff

Generated at source revision `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Final inspection: 2026-09-09T18:34:11.451583+00:00. Scope/methodology: `generation-notes.md`; mandatory brief-driven audit: `brief-coverage.md`; action/trace contract: `instrumentation-spec.md`.

## Deliverables and static audit

All eight requested files exist. There are **89 base actions, 89 direct Trace wrappers and 89 instrumentation entries**, with **8 hunt cfgs** plus the standard `MC.cfg`. All four brief safety invariants and both added durable-handler-outcome checks are enabled in actual hunt configurations. `Trace.cfg` enables `TraceMatched`; every wrapper checks full post-state and exact parameter fields. There are zero silent actions. `checks/artifact-audit.json` and `cfg-audit.json` contain machine-readable checks of these counts and active cfg entries. Counts refer to model actions/configurations, not implementation function or business coverage.

SANY semantic/lint processing succeeded for `base.tla`, `MC.tla` and `Trace.tla`. The six preexisting untracked analysis test files remain; tracked production source is unchanged (`checks/source-final-status.txt`). This phase did not run or alter the Temporal Go tests.

## Bounded evaluation smoke

Each configuration was evaluated with `-simulate num=32 -depth 200 -seed 20260909 -workers 1`, a 1 GiB Java heap, and a 45-second per-command cap (none timed out). This checks executable operators/configuration wiring on sampled finite behaviors. It is **not exhaustive convergence, liveness proof or a hunt pass**. No frontier-pruned search is relabeled as a global result.

| Config | Simulated traces | Maximum depth | Generated states | Result |
|---|---:|---:|---:|---|
| `MC.cfg` | 32 | 200 | 3,711 | exit 0; evaluation smoke only |
| `MC_hunt_CR_5_limit.cfg` | 32 | 200 | 3,910 | exit 0; evaluation smoke only |
| `MC_hunt_MC_4_cache.cfg` | 32 | 200 | 6,233 | exit 0; evaluation smoke only |
| `MC_hunt_scenario_1.cfg` | 32 | 200 | 6,562 | exit 0; evaluation smoke only |
| `MC_hunt_scenario_2.cfg` | 32 | 200 | 6,555 | exit 0; evaluation smoke only |
| `MC_hunt_scenario_2_progress.cfg` | 32 | 200 | 6,269 | exit 0; evaluation smoke only |
| `MC_hunt_scenario_3.cfg` | 32 | 200 | 1,041 | exit 0; evaluation smoke only |
| `MC_hunt_scenario_4.cfg` | 32 | 200 | 6,023 | exit 0; evaluation smoke only |
| `MC_hunt_scenario_4_progress.cfg` | 32 | 200 | 6,735 | exit 0; evaluation smoke only |

Total: 47,039 generated states across 288 sampled behaviors, with no runtime or enabled-invariant error in this smoke batch. This denominator is generated TLC states across independent sampled runs; it is not distinct production executions. Per-command arguments/results are preserved in `checks/final-smoke-results.json`; raw logs are `checks/smoke-*.log`. The original smoke caught a generator mistakenly wrapping the set-valued `WorkerKinds` helper as an action; it was fixed, and the failing pre-fix log is retained as `smoke-mc-model-error-1.log`. That was a specification-generation error, not a Temporal finding.

## Trace-engine positive and negative controls

`TraceFixture.tla` produces a 29-action **synthetic** healthy speculative acceptance/completion trace with waiter observation between outcome and acceptance publication. Replay through the final `Trace.tla` consumes all 29 events (30 distinct replay states, exit 0). Changing the first post-state's committed record version is rejected (exit 13, TraceMatched violation), as is an unknown event name (exit 13). These negative controls establish that mismatched state/event data cannot silently validate. They do not establish implementation/model correspondence.

Artifacts: `checks/synthetic-healthy.ndjson`, `checks/synthetic-corrupt-state.ndjson`, `checks/synthetic-unknown-event.ndjson`; `checks/replay-controls-results.json` contains exact commands, expected exit codes and summaries. Production implementation traces belong in sibling `../traces/`; the synthetic files stay here and are selected through the `JSON` override.

## MC-4 model reachability and control

The exact `MC_hunt_MC_4_cache.cfg` limits permit a **74-action** witness, replayed through the counter-bounded `MC` wrappers (75 distinct states). The final client receipt violates `SuccessfulOutcomeMatchesCommittedResult`: after H1 caches uncommitted A, H2 commits B at the reused event ID/version, and H1 reacquires, a third same-ID invocation for B returns A's cached payload. The witness does not inject a cache entry directly or remove an existing identity/fence guard.

`CacheWitness.tla` fixes the candidate schedule only to audit reachability; `CacheWitness.cfg` retains the hunt's constants, limits, frontier constraints and invariants. Symmetry is disabled for the witness because its schedule names particular hosts/clients/Updates. `checks/cache-witness-schedule.txt` and `checks/cache-witness.log` retain all steps and the final state (exit 12, expected safety violation). A control using actual shard-level cache lifetime (`HostCacheEnabled=FALSE`, `CacheWitnessShardCache.cfg`) follows the same 74 actions and returns the committed B outcome without an invariant violation (75 distinct states, exit 0).

This is an **unvalidated model candidate**, not a confirmed Temporal bug or an independently discovered implementation defect. Its trigger was already the brief's MC-4 question. The next evidence needed is real two-host shard ownership/cache lifetime, physical History lineage and conditional commit/readback, then public Update/Poll receipt with the exact outcome. The upstream cache mechanism is already discussed in [PR #11660](https://github.com/temporalio/temporal/pull/11660); its proposed shard-context cache key differs from the pinned source's five-field key. Novelty and impact for this Update consumer remain open.

## Remaining checks and scope limits

- Exhaustive `MC.cfg` convergence and unrestricted scenario hunts: **not executed**. The deterministic MC-4 witness and random evaluation batch do not replace them.
- Implementation harness generation and real trace validation: **not executed**. All replay controls here are synthetic. The instrumentation mapping gives the next phase source hooks, field definitions and fault schedules.
- Full public/backend confirmation of MC-4, CR-6's deadline/client consequences and CR-5 contract interpretation: **not executed in this phase**. Preserve the prior analysis evidence and its mock/configuration limitations.
- Model slice limits: one active Workflow lease/context and one outstanding write; ownership movement between handlers or after uncertain return; no simultaneously active old/new-owner handlers. Client context cancellation/deadline is not separately modeled (server soft expiration and response loss are). Task-generation rebuild/refresh and future/equal shard-vector-clock schedules are outside the fixed one-run/no-rebuild preconditions. Cross-run transitions, replication, CHASM migration, queue fairness, build-ID changes and callback transport remain excluded.
- Core atomicity/History-selection assumptions need backend trace/readback corroboration. The model distinguishes physical append from logical commit and carries the real completion batch-start reference; it does not simulate SQL/Cassandra storage internals or all history-tail trimming algorithms.

## Refreshed upstream context

The seven requested/relevant issue/PR bodies and issue comments were read through GitHub's API; raw responses are `checks/upstream-refresh.json`. Read-only refresh, no comments/issues/PRs were posted. Current issue states from this refresh:

- [#5349: Apply effects immediately after mutable state is persisted](https://github.com/temporalio/temporal/pull/5349): closed; last update `2024-01-25T11:44:08Z`.
- [#5784: Clear update registry when workflow context is cleared](https://github.com/temporalio/temporal/pull/5784): closed; last update `2024-04-30T23:19:19Z`.
- [#6308: Fix speculative WFT timeout task executor](https://github.com/temporalio/temporal/pull/6308): closed; last update `2024-07-19T00:03:49Z`.
- [#10478: Missing shard ownership check in speculative workflow task  processing may cause incorrect update rejections](https://github.com/temporalio/temporal/issues/10478): open; last update `2026-06-12T02:04:50Z`.
- [#10775: Updater.addWorkflowTaskToMatching may be missing NotFound logging and build-ID assignment handling present in pushWorkflowTask](https://github.com/temporalio/temporal/issues/10775): open; last update `2026-07-05T18:29:22Z`.
- [#11254: Fix hung callers on concurrent Nexus Updates](https://github.com/temporalio/temporal/pull/11254): open; last update `2026-07-27T19:42:38Z`.
- [#11660: Scope events cache entries to the shard context instance](https://github.com/temporalio/temporal/pull/11660): open; last update `2026-08-19T22:45:11Z`.

#5349/#5784/#6308 remain historical mechanism repairs and are preserved in the model. #10478/#10775 do not establish current result loss. #11254 concerns admitted duplicate callback attachment; the pinned Sent-buffer behavior is retained, and callback transport is outside this slice. Discussion state or automated review text is not treated as maintainer confirmation.

## Reproduction commands

From this `spec/` directory:

```sh
python3 checks/audit-artifacts.py
python3 checks/run-smoke.py
python3 checks/run-replay-controls.py
```

The smoke/controls scripts record full Java invocations and use the installed jars at `/home/ubuntu/Specula/tools/tlaplus/tlatools/org.lamport.tlatools/dist/tla2tools.jar` and its sibling `lib/CommunityModules.jar`. Override those script paths if moving the artifact. A production trace replay uses the same classpath and `JSON=/absolute/path/to/implementation.ndjson`, `tlc2.TLC -config Trace.cfg -workers 1 Trace`. `base.cfg` is an unbounded reference configuration; use the MC configs for finite safety exploration.

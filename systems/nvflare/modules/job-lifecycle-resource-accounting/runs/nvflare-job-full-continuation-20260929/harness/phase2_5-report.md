# BYOM Phase 2.5 continuation report: nvflare-job

Phase 2.5 is complete. The adapted supplied harness generates fresh implementation traces at the authorized source pin. **All 30 supplied default scenarios and two added deadline scenarios succeeded; all 32 fresh traces passed the input/report guard and a basic TLC replay.** The ordinary outputs are [run.sh](run.sh), [the instrumentation guide](INSTRUMENTATION.md), [the hook map](HOOKS.md), [instrumentation.patch](patches/instrumentation.patch), the supporting `src/` files and [32 active traces](../traces).

This result is finite compatibility with the adopted model under the documented harness controls. It does not accept the prior model as fully faithful, discharge the adoption audit, establish unbounded correctness, or independently confirm product defects. The next launcher-owned phase is validation/repair/convergence and hunting. Eligible candidates remain queued for the separately configured confirmation phase.

## Fresh evidence

| Check | Result | Evidence |
|---|---|---|
| Fresh scenario generation | 32/32, 2,244 event rows; successful process exits, reports, drain and integrity checks | [generation log](evidence/continuation/suite-generation.log), [frozen traces/reports](evidence/continuation/fresh-suite), [final audit](evidence/continuation/final-audit.json) |
| Event coverage | 64/65 `Trace.tla` event types | [event counts and per-scenario manifest](evidence/continuation/final-audit.json); `CpStartAllocateAppMissing` is deliberately outside the supported default envelope |
| Basic replay | 32/32 PASS; exit code 0 plus TLC success, no error result | [structured replay results](evidence/continuation/suite-replay.json), [replay log](evidence/continuation/suite-replay.log); each row links durable TLC task/log/statistics |
| Resource observation consistency | 11,354 live-client/job projection comparisons, zero mismatches | Each frozen report's `resource_observation`; actual allocate/free caller, token, arguments, result/error and pool values recorded |
| Source-derived scenario mechanisms and controls | 11/11 assertions pass | [scenario assertions](evidence/continuation/scenario-assertions.json), [checker](src/check_scenario_evidence.py) |
| Existing targeted unit tests | 392 passed in each of pristine, patched-disabled and patched-no-op configurations, identical outcomes | [commands/results](evidence/continuation/unit-tests/results.json), three retained pytest logs with import-origin guards |
| Negative controls against fresh `normal_two_jobs` | Four state/order corruptions fail `TraceMatched`; five malformed-record controls fail the input guard; truncated-prefix integrity check fails as intended | [negative-control results](evidence/continuation/negative-controls/results.json), corrupted copies and TLC logs kept separately |
| Syntax/build | 14 harness Python files parse; seven shell scripts pass `bash -n`; all 11 patched product files parse and match the unchanged supplied patch/build bytes | [final audit](evidence/continuation/final-audit.json); fresh `apply.sh` also compiles patched modules |
| Source/original preservation | Source HEAD exact, tracked worktree unchanged; only pre-existing untracked `.agents/`; 4,301 supplied asset hashes and 20 raw conversation hashes verified | [final audit](evidence/continuation/final-audit.json) |
| Specification preservation | All 45 recorded specification/config/mapping files unchanged during this phase | [baseline hashes](evidence/continuation/spec-before.json), final audit |
| Scoped style check | Could not complete: runtime has no `black`; no style PASS claimed | [style-check.log](evidence/continuation/style-check.log) |

The final audit is rerunnable with `source harness/paths.sh` followed by `"$NVF_PYTHON" harness/src/audit_phase2_5.py`. It audits the frozen Phase 2.5 evidence against this spec revision, not a future repaired model.

The resource call totals are 79 allocation calls (78 successful, one expected expired-token exception) and 77 successful frees. One successful allocation belongs to the deliberately frozen dead CP. It is excluded from live-client projection comparisons; this is not evidence that the actual parent-death cleanup contract holds. The normal passing control verifies both jobs complete and the original list-unit capacity and admission slots return.

The negative controls also expose a meaningful limit: **a valid truncated prefix passes raw TLC** when the report check is intentionally bypassed. Frozen hash/count checks detect truncation after collection. Neither a hash nor TraceMatched proves that instrumentation captured every source action. The synthetic corruptions are labeled and kept outside active `traces/`.

## Supplied assets reused and working-copy changes

The existing patch, real-object environment, 30 default scenarios, timing gates, event mappings and trace-inspection helper were reused. The model/Trace suite was not changed. Historical working files and the old build were preserved under [history/pre-continuation-phase2_5](history/pre-continuation-phase2_5); original supplied files remain untouched.

| Change | Reason / semantic classification |
|---|---|
| Pin/path/import guards and fresh isolated build | Replace inaccessible historical paths; ensure traces execute the authorized source and prepared Python 3.12.3 runtime. |
| Failure propagation and budgeted replay driver | Remove ignored validation failures; require actual successful exit and successful TLC result. Isolate scratch outputs and preserve task evidence. |
| Deadline-based CHECK/START waiting | Harness semantic correction: old transport waited up to 120 seconds instead of caller budgets. Wait using one request deadline and discard late replies. |
| Two added deadline scenarios | Coverage addition: delayed handler admission after 16/21 seconds actually crosses the source's 15/20-second deadlines. Measured waits were 15.0002/20.0001 seconds. Timing injection is explicit. |
| Resource call observer | Observation addition: cross-check event-derived allocation ownership against real allocate/free returns; does not enforce or repair product conservation. |
| Strict input/report checks | Prevent malformed/filtered rows, sequence gaps, unknown names, missing fields or truncated files from being accepted silently. |
| Writer freeze, network drain, expected thread-error checks | Trace lifecycle correction: no writes after report hashing; distinguish expected deletion-seed runner death from unexpected harness/product errors. This is still a finite prefix. |
| Random drain timeout now fails | A scenario that cannot settle no longer silently reports success. |
| Dead-client state reduced to `alive=false` | Projection correction: remove pool/registration fields that Trace does not validate after CP death. Reran the affected scenario and preserved its prior version. |
| Fresh mechanism/control assertions and no-op regressions | Check that named scenarios actually exercise their intended mechanism; test inactive hook compatibility. No independent confirmation claim. |

The exact adopted-to-working-copy changes are retained in [working-copy-changes.diff](evidence/continuation/working-copy-changes.diff). Six core runtime modules are preserved by the hashes recorded in reports at [fresh-suite/runtime/index.json](evidence/continuation/fresh-suite/runtime/index.json). Five have one version. `nvf_tracer.py` has two: the sole difference is omission of unchecked fields for a dead CP; the dead-client scenario uses the corrected version. Other scenarios never enter that branch. The earlier version was reconstructed by removing that exact block and checked against its recorded SHA-256 before preservation. Utility/reporting files added after generation are distinguished from runtime modules.

One reporting repair followed successful pytest runs: the first result parser mistook five captured `ERROR` log lines for pytest outcome rows. All three pytest processes had exited 0 with 392 passed. The parser was tightened and the same complete logs were reaggregated; no tests were rerun for that parser correction. [The original aggregation](evidence/continuation/unit-tests/results-before-log-parser-fix.json) and [original driver output](evidence/continuation/unit-controls.log) remain, while `results.json` is the corrected result.

The CP projection correction required only `client_crash_sweep` to be rerun. [Its prior trace/report](evidence/continuation/pre-dead-client-projection) and [rerun log](evidence/continuation/dead-client-projection-rerun.log) are retained. The final 32-trace replay used that corrected trace. Optional old stress rounds and seeds 7–40 were not rerun or counted.

## Commands and provenance

Executed from the target `.specula-output` unless stated otherwise:

```bash
timeout 600 bash harness/run.sh
SCENARIOS=client_crash_sweep bash harness/run.sh
timeout 600 bash harness/validate.sh traces/*.ndjson --results harness/evidence/continuation/suite-replay.json
source harness/paths.sh
"$NVF_PYTHON" harness/src/run_unit_controls.py
"$NVF_PYTHON" harness/src/negative_controls.py
"$NVF_PYTHON" harness/src/check_scenario_evidence.py
"$NVF_PYTHON" harness/src/audit_phase2_5.py
```

The listed controls were invoked with the pinned environment (and command-level timeouts); exact per-scenario commands, Python version, start/finish timestamps, source/patch/hook hashes, scenario configuration and network policies are in reports. Runtime package versions are in [python-packages.txt](evidence/continuation/python-packages.txt). The scoped style command, from the source with the venv first on PATH, was `./runtest.sh -s --skip-install <target-workspace>/harness/src`; it exited 1 on missing `black` without installing dependencies.

Source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Framework/skills: pinned continuation installation at `332cd6e7faad61fca8da439a1b6a8d3fef8ef39e`. Applied pinned [BYOM](../../../../../skills/byom/SKILL.md) and [harness-generation](../../../../../skills/harness-generation/SKILL.md) methodology (full guides read). TLC replays used one sequential task at a time, 2 GiB heap/1 GiB offheap/one worker, within 64 GiB/16-worker aggregate limits. No full service deployment or confirmation task was started; the 80 GiB service budget and one-confirmation-task limit remain unchanged.

This is the authorized **mixed-model continuation**, not an independent pure-model trial. The original Claude run exhausted API credits during validation/hunting, leaving MC-U1 unclassified and the normal confirmation phase incomplete. This phase uses the launcher's GPT-6 Astra/max continuation configuration; later separate confirmation remains assigned to GPT-5.5/xhigh, with no substitution performed here. The original Claude spend is **$180.5573146 including preflight**. This phase's Codex work is subscription usage, separate from that historical spend; no new Claude-account calls were made. Exact continuation token usage or an optional API-equivalent estimate must come from launcher accounting, which is not exposed in these phase tool results; no additional Claude charge or dollar estimate is invented.

## Records inspected and source checks

Started with `handoff/conversations/README.md` and `index.json`, then the four main phase transcripts' line-preserving decision records. Relevant original command/result chunks were read in manageable pieces, not inferred only from a summary:

| Original readable record | Selected command/result lines additionally checked in this phase |
|---|---|
| `01-analysis.md` | 9700–9850: controls, prior missing-method harness correction, lifecycle/delete seeds |
| `02-specification.md` | 13040–13115: synthetic replay/negative controls and initial F16-vs-F1 seed error |
| `03-harness.md` | 16720–16835: seven disabled-hook failures, object-argument correction, prior unit-test claims |
| `04-validation-and-hunting.md` | 13875–14038: final residual/hunt conclusions, VAV, MC-U1 and interruption |
| `analysis-agent-a9b2b77d6bf662997.md` | Initial task and 9810–9875: client-lifetime scope and real CellNet CP-kill retry limits |
| `analysis-agent-ab99a5ff5dbe12529.md` | 7350–7445: token/re-registration probe and authentication-config errors |
| `analysis-agent-ac097fcff7aa25dcb.md` | 9800–9820, 10110–10140: forced-thread control and late update/heartbeat results |
| `analysis-agent-aa05006549b97b289.md` | 8850–8953 and ending index: status/runner/CMP death and lower-priority probes |

The earlier [takeover review](../takeover-review.md) and [findings reconciliation](../adoption/findings-reconciliation.md) retain the wider analysis/deep-analysis record coverage and every lower finding. This phase did not exhaustively reread duplicated source dumps in all transcripts. It inspected every supplied harness source/script and the full patch, Trace wrapper/mapping, and the actual pinned adjacent source controlling resource allocate/free/expiry, request deadlines, startup/registration, process-exit cleanup, fail_run/finalizer, heartbeat and sweeper behavior. Prior commands using inaccessible historical paths were not blindly repeated. No newer source, external answers, upstream discussions, Lite results or unrelated experiments were consulted.

Fresh assertions preserve distinctions among source-derived seeds: F16 witnesses refresh read → acknowledged abort → refresh write to SUBMITTED → later launch, rather than F1's deploy window; F5's two successful CJ launches precede failure report/removal of pending and failed START collection; F3 witnesses terminal publication/removal before a late RUNNING write; both F2 shapes leave the later job SUBMITTED after the expected runner exception. These refresh existing source-derived evidence. They are not new model-checking discoveries, completed MC seed-fidelity checks or public-deployment reproductions.

## Handoff obligations and limits

Read [INSTRUMENTATION.md](INSTRUMENTATION.md) and the existing [model audit](../adoption/model-audit.md) before accepting a PASS. The lock still merges source-visible transitions; REPORT/SJ ABORT use immediate timeout/deferred delivery; the sweep lock prevents live-map mutation; heartbeat bypasses session/auth transport; fake parent death assumes children die; process groups/watchdogs/rc-file lifetimes and default GPU numeric accounting/binding are absent. Resource ownership projections are now cross-checked but still share token identity mapping. Missing/padding/cached fields and finite-prefix limitations are explicit in the L2 table.

V01–V10 remain open validation/repair obligations. Fresh replay and mechanism assertions do not reclassify MC-A–MC-E, MC-U1, F1–F20/R1 or RS/CL/SE/E leads. The full [reconciliation queue](../adoption/findings-reconciliation.md) remains authoritative for what must be rechecked, narrowed, refuted or sent to configured confirmation; unsupported F9/F19 cases remain separate. Do not discard lower findings or treat old residual PASSs as full exclusion coverage.

The launcher must replay fresh traces after semantic repairs, recheck named MC seeds and all residual/hunt exclusions, complete bounded convergence/hunting with honest search bounds, and route every eligible candidate to confirmation. Confirmation must retain real-code evidence, passing controls, injection labels and source provenance, using public APIs and real local deployment where feasible. Repair/evolve/classification and final BYOM modification reporting follow their normal phase ownership. No product logic fix, upstream publication, push or tracker write was performed.

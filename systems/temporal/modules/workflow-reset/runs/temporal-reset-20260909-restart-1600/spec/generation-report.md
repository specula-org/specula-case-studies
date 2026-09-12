# Generation result

Created all eight requested artifacts, 13 hunt configurations, reproducible generation/check scripts, and preserved validation evidence. Source was verified at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. No production source or pre-existing probe test was modified.

The suite contains 57 base actions. Every action has a source mapping, a corresponding Trace wrapper that invokes the full base action, and a matching instrumentation row. The brief audit maps all five scenarios, all six safety invariants and all three model-checkable questions to actual uncommented hunt entries. Scenario 1 is explicitly merged into recovery/replay hunts.

## Checks on the final suite

| Check | Actual outcome | Evidence |
|---|---|---|
| SANY parsing and semantic analysis | base, MC and Trace passed | `validation/{base,mc,trace}-sany.log` |
| Standard `MC.cfg`, complete bounded BFS | **38,577 generated states; 20,277 distinct; 0 queued; depth 46; no invariant failure** | `validation/mc-convergence.log` |
| Strong Trace replay, synthetic model-generated nominal Reset | 30 tagged events; 30 distinct states; TraceMatched passed | `validation/synthetic-fixture.ndjson`, `validation/trace-positive.log` |
| Trace negative control | Altered durable CreateRequestId at the commit event; TraceMatched failed at the mismatch, exit 13 | `validation/synthetic-corrupt.ndjson`, `validation/trace-negative.log` |
| Twelve safety hunt cfg smoke simulations | Seed 753, at most 60 traces per cfg, depth limit 250. Both merged identity/recovery cfgs stopped on the **known T-1 ImmediateRetryIdentity violation**, exit 12. The other ten finished these smoke simulations without a checked invariant failure. | `validation/hunt-smoke-results.json`; per-cfg logs include action occurrence statistics |
| Liveness configuration | Parsing/initialization smoke only, one step; **liveness search NOT COMPLETED** | `validation/liveness-config-smoke.log` |
| Artifact wiring | 57/57 base actions have Trace/instrumentation entries; all six brief safety properties are enabled in at least one hunt | `action-manifest.json`, `validation/coverage-audit.json` |

The 20,277-state result covers the exact small standard configuration: three run symbols, one operation slot, one Start, one Reset request, one CAN, one Delete, and no injected faults or Update/Signal inputs. It is not a proof for the larger hunt configurations or Temporal as a whole. Simulation action occurrences refer to model transitions, not source/business-function coverage. A smoke simulation does not establish that every configured interleaving was exercised.

**New implementation bugs established in this generation: 0.** The identity violations reproduce the behavior already described as T-1 in the supplied brief, within the model. No new Go/backend tests or real execution trace validation were performed in this phase. The synthetic trace and its negative control test the Trace plumbing and state checks only.

## Model issue found and corrected during generation

An earlier S5 simulation let a freshly forked candidate cross the 60-day history-scanner threshold while its original Reset invocation remained active. The scanner observed no execution, planned deletion, the live attempt later committed/acknowledged, and cleanup removed its history. That trace is preserved in `validation/scanner-age-unconstrained-counterexample.log`, with the earlier base/MC/cfg snapshots alongside it.

This exposed a missing model-time relationship. The public History client supplies a 30-second call deadline; new persistence submission rejects an already expired request. Standard configs now require the original candidate attempt to finish/expire before its branch becomes scanner-old, and model explicit pre-write request expiration. Pending uncertain writes still survive caller loss and remain subject to durable fencing. `MC_hunt_scenario5_short_age_sql.cfg` retains the alternative scanner-age-before-request-deadline sensitivity case. Its finite smoke run did not reproduce the earlier violation after the other refinements; it is not exhaustively verified. A real non-default age/deadline schedule remains necessary before interpreting that sensitivity as a Temporal defect.

Other generation fixes corrected TLA expression errors, separated current-termination history append from new-run history append, separated WFT-start boundaries from Start/Update completion, and retained deletion's I/O slot across current/mutable-state stages. Passing results above are from the final implementation of these changes.

## Remaining verification boundary

The full backend-aware hunts, fair recovery/liveness search, public-handler durable fault injection, process-restart acceptance, and real implementation Trace validation remain for the subsequent responsible phases. Read `brief-coverage.md`, `model-notes.md` and `instrumentation-spec.md` before generating that harness. Explicit current limits include buffered events flushed during termination, direct admitted-then-accepted input generation, child-completion redirection (CR-3), legacy zero-version/map-absent initial records, full wall-clock scheduling, history batch transaction-ID details, and non-default Start conflict policies. These are not marked verified or silently treated as successful recovery.

## Reproduce

From this directory:

```bash
python3 generate_base.py
python3 generate_mc.py
python3 generate_coverage.py
python3 generate_trace.py
python3 generate_instrumentation.py
python3 validation/check_suite.py
```

`check_suite.py` explicitly expects the known T-1 violations and the corrupted-trace rejection. It fails on an unexpected parser/runtime error or unexpected invariant failure. It writes machine-readable checks and per-hunt outcomes. The checked jars are TLC `2026.08.11.125311` and the installed CommunityModules dependency jar; their paths are recorded in the script. Real traces default to `../traces/trace.ndjson` and support the `JSON` environment override.

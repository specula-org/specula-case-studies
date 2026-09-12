# Brief coverage self-audit

**Current validation:** 21/21 complete real replays and the completed bounded safety baseline pass. The generation-stage material below is historical; current evidence, coverage and limitations are in [validation-report.md](validation-report.md).

Category A. Audit performed by reading the actual generated `MC_hunt_*.cfg` files and their active invariant lists. `MC.tla` extends `base`; named safety operators are inherited unchanged. The mandatory audit follows the skill guide Phase 2.5 even though its older checklist calls the document optional.

## Brief section 2: scenarios

| Scenario | Base mechanisms | Target config / verification route |
|---|---|---|
| S1 Attempt identity and delayed replies | Separate producer snapshot, Matching enqueue, poll request, History fresh/duplicate/rejected start, SQL acceptance, Matching response reception and worker poll response. Four worker API guards preserve nonzero StartVersion precedence and legacy zero Version compatibility. Transient start errors retain Matching work through its rewrite interface. | `MC_hunt_s1_attempt_identity.cfg`; `MC_hunt_s1_stamp_enabled.cfg` is a configured companion, not a historical-fix mutation. |
| S2 Shared timer cues | Four distinct deadlines, sorted shared scan of every Activity, snapshot attempt guard, heartbeat watermark clearing, retry preserving SCT mask, single earliest-cue generation, later Ack. | `MC_hunt_s2_shared_timers.cfg`; companion `MC_hunt_s2_stamp_enabled.cfg`. Both have two Activities, two attempts, heartbeat input, cache loss, storage uncertainty, and redelivery. |
| S3 Uncertain persistence and recovery | Raw History append, immutable backend requests, atomic execution/task commit, known abort, pending/committed unknown response, same-payload internal retry, late-write ownership/DBVersion fences, cache clear/reload, separate notification and client observation. | `MC_hunt_s3_uncertain_commit.cfg`; S2 config also targets MC-2's recovery composition. |
| S4 Cancellation and WFT obligation | Scheduled/backoff immediate cancel, running request, heartbeat flag delivery, result race, buffer behind Started WFT, flush and follow-up WFT, close barrier and same-command cancellation suppression. | `MC_hunt_s4_cancellation.cfg`; S3 intentionally also enables the terminal WFT property for MC-1. |
| S5 Independent complete observations | Backend receipt versus delivered response, fenced readback, explicit terminal/consumption endpoint. | `MC_hunt_s5_observation.cfg` checks formal receipt/readback consistency. `Trace.tla` checks every captured state field in 56 full-action wrappers and requires a final `FinishTrace`; the instrumentation contract supplies 56 matching entries. Real observation independence is a harness/evidence requirement and cannot be proven by MC. |

## Brief section 5: safety invariants

All six named safety operators (counting TypeOK and SingleTerminalOutcome separately) are defined in `base.tla` and available through `EXTENDS base` in `MC.tla`.

| Brief safety invariant | Active hunt configurations (read from files) |
|---|---|
| `TypeOK` | `MC_hunt_s1_attempt_identity.cfg`, `MC_hunt_s1_stamp_enabled.cfg`, `MC_hunt_s2_shared_timers.cfg`, `MC_hunt_s2_stamp_enabled.cfg`, `MC_hunt_s3_uncertain_commit.cfg`, `MC_hunt_s4_cancellation.cfg`, `MC_hunt_s5_observation.cfg` |
| `SingleTerminalOutcome` | `MC_hunt_s1_attempt_identity.cfg`, `MC_hunt_s1_stamp_enabled.cfg`, `MC_hunt_s2_shared_timers.cfg`, `MC_hunt_s2_stamp_enabled.cfg`, `MC_hunt_s3_uncertain_commit.cfg`, `MC_hunt_s4_cancellation.cfg`, `MC_hunt_s5_observation.cfg` |
| `StaleTokenDoesNotMutateCurrentAttempt` | `MC_hunt_s1_attempt_identity.cfg`, `MC_hunt_s1_stamp_enabled.cfg`, `MC_hunt_s4_cancellation.cfg` |
| `AcknowledgedOutcomeSurvivesFencedReload` | `MC_hunt_s3_uncertain_commit.cfg`, `MC_hunt_s5_observation.cfg` |
| `TimerAndRetryWorkCovered` | `MC_hunt_s2_shared_timers.cfg`, `MC_hunt_s2_stamp_enabled.cfg` |
| `TerminalResultHasWorkflowResponsibility` | `MC_hunt_s3_uncertain_commit.cfg`, `MC_hunt_s4_cancellation.cfg` |

`FencedReadbackAgrees` is additionally enabled for S5. Structural properties remain active in convergence configs; scenario invariants are listed but commented out in `MC.cfg`. `MC_progress.cfg` enables `EligibleWorkEventuallyResolves` under explicit time, persistence, timer, recovery and WFT fairness, with a finite global deadline inside its relative time horizon. It uses no symmetry for liveness. This is a configured property, not an executed proof claim.

## Brief section 6.1: finding reachability

| Finding | Concrete route retained | Target config and property |
|---|---|---|
| MC-1 | Schedule with `KeepInitialWFT=TRUE`; accept a normal WFT start; accept an Activity start; terminal API mutation buffers its result; commit SQL; return unknown or lose response; process an old competing reply; lose/reacquire shard and independently reload; complete held WFT then consume result in follow-up WFT. Internal store retry may also return Condition after known Commit. | `MC_hunt_s3_uncertain_commit.cfg`: `RequestLimit=3`, `CancelLimit=1`, `StorageFaultLimit=1`, `ResponseLossLimit=1`, `CacheLossLimit=1`, `ShardLossLimit=1`; active acknowledgement and terminal-WFT invariants. No store transaction is split. |
| MC-2 | Two scheduled Activities; accepted running starts; heartbeat extends one deadline; an old physical cue clears watermark and scans both Activities; one retry changes attempt and per-attempt mask while later snapshot entries are skipped; close regenerates earliest cue; commit; reload reconstructs watermark; old cue can execute again before Ack. | `MC_hunt_s2_shared_timers.cfg`: `ActivityCount=2`, `MaximumAttempts=2`, `TimeLimit=7`, `StartToClose=4`, `ScheduleToClose=6`, `HeartbeatLimit=1`, `CacheLossLimit=1`, `StorageFaultLimit=1`, `RedeliveryLimit=1`; active `TimerAndRetryWorkCovered`. Stamp-enabled companion preserves the same trigger. |

Config reachability is not a claim that exhaustive search reached every listed combination; verification.md records executed bounds and results. Scenario generation does not introduce previously removed guards, old per-attempt timer bugs, or a fictitious ordinary task-generator storage failure.

## User priorities and explicit scope limits

1. Ordinary late-token replies and dispatch checks are S1. Same-RequestID response metadata omission is represented (zero response versions/details), and remains the known TV-2 test contract; no novel bug claim.
2. STS, STC, SCT and HB applicability/deadline/retry rules are distinct in S2; one cue covers multiple Activities. Delayed and duplicate cues are legal. Integer-millisecond normalized time has no clock-skew/time-skipping model.
3. Execution state, buffered events and generated tasks share the modern SQL DBRecordVersion transaction in S3; uncertain caller outcomes never erase known commits. Cache loss and shard-context loss/fencing are distinct. Process restart, database restart, power loss and legacy DBRecordVersion=0 CAS are unvalidated boundaries.
4. Cancellation is cooperative; a valid completion may win. S4 permits cancellation scheduled/running/backoff and protects preexisting buffered worker results on Workflow close. Worker command cancellation is disabled, so heartbeat is the modeled worker observation path.

TV-1 and S5 require real `Timeout`/`ExecuteAndTimeout`, immutable lease snapshots, independent task-store reads, and complete terminal WFT consumption. No fabricated trace or MC state may stand in for that evidence. TV-3 (pause/unpause/ResetActivity/ByID) is explicitly deferred until ordinary-core fidelity, matching brief section 3.2. CR-1 through CR-5 remain code-review/test items, not artificial fault actions. Payload size conversion, external exactly-once side effects, cross-run behavior, replication, worker routing and Matching internals are excluded as specified by the brief.

## Final generation checks

`evidence/final-audit.json` checks actual cfg enablement and the 56:56:56 transition/wrapper/instrumentation mapping. Five complete synthetic controls exercise the mechanisms, including MC-1 commit/response/reload and MC-2 shared cue/heartbeat/retry/watermark reconstruction. They are specification plumbing checks, not independent implementation evidence. S2's STC=4/SCT=6 constants keep STC from overtaking the extended HB cue. Real fidelity and full hunt/liveness convergence remain INCOMPLETE; see verification.md for final exact bounds, counts and exclusions.

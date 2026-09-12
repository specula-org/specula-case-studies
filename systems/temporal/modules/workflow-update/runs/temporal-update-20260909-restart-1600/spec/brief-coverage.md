> Validation update: **INCOMPLETE**. No complete implementation trace has passed; MC.cfg and all eight hunts remain unrun in Phase 3. The current model has 90 actions after adding the independent normal/speculative start-return boundary. The old 74-action cache witness is historical and has not been revalidated against the modified model. Review R1/R2/R5/R6 remain open; the identity oracle is not counted as independent safety coverage. See [validation-handoff.md](validation-handoff.md).

# Brief coverage self-audit

Audited the actual generated cfg files, not intended coverage. `cfg-audit.json` records parsed active invariants/properties. Methodology phase 2.5; source revision and assumptions are in `generation-notes.md`.

## Brief section 2: scenarios and user priorities

| Scenario / user priority | Concrete modeled mechanism | Target cfgs | Boundary / evidence still required |
|---|---|---|---|
| 1: persistence, effects, client receipt | Physical History append; atomic metadata/task commit; independent DB execution/result; known noncommit vs append timeout vs uncertainty; cache clearing before LIFO cancel; FIFO effects; later handler error; response loss and readback; two host caches | `MC_hunt_scenario_1.cfg`, focused `MC_hunt_MC_4_cache.cfg` | Host cache enabled, one outstanding backend mutation. SQL/Cassandra internal transaction is atomic. Late executing write can settle after timeout until range changes. Implementation trace validation and two-host public lookup reproduction remain open. |
| 2: stale completion/timeout and replacement | Scheduled ID, optional started ID/time/version, attempt; actual deferred sticky Clear->Load->write; submitted/cancelled timer lifetime; pointer identity only for current speculative task; callback-triggered conversion to normal | `MC_hunt_scenario_2.cfg`, `MC_hunt_scenario_2_progress.cfg` | Version/stamp fixed for one cluster/run; no build-ID routing changes. CR-6 exact early deadline and public consequence remain test work. No unconditional pointer/StartedTime timer guard was added. |
| 3: mixed batch and closure | Two Updates; arbitrary interleaving of per-Update protocol messages with acceptance before response; closure last; external termination/final timeout; provisional state; FIFO commit/LIFO rollback; future Set boundaries; late waiters and commit uncertainty | `MC_hunt_scenario_3.cfg`, `MC_hunt_CR_5_limit.cfg` | Final-close command after valid Update commands; cross-run transitions excluded. Forced termination preserves precommit abort and explicit runtime-limit restoration. Failure-then-success is not two conflicting successful outcomes. |
| 4: volatile deduplication and recovery | Immediate volatile admission; same-object duplicate binding; lease release before Matching; swallowed RPC failure/lost response; due STS fallback to normal, resend, retry; Sent callbacks stop automatic rejection loop on first error | `MC_hunt_scenario_4.cfg`, `MC_hunt_scenario_4_progress.cfg` | Callback transport/CHASM excluded; only one buffered duplicate-callback discriminator, including its options event at acceptance. Worker ignore is finite in progress checking. Poll does not recreate admission. |

Every scenario has its own safety hunt; scenarios 2/4 also have explicit progress companions. The primary-question coverage is mechanism coverage, not a claim that all Temporal functions or all source lines are modeled.

## Brief section 5: active safety checks

| Invariant | Definition / MC wiring | Enabled in actual hunt cfg(s) |
|---|---|---|
| `AcceptedReceiptHasDurableAcceptance` | `base.tla:1341`, inherited by `MC` | `MC_hunt_CR_5_limit.cfg`, `MC_hunt_scenario_1.cfg`, `MC_hunt_scenario_3.cfg`, `MC_hunt_scenario_4.cfg` |
| `SuccessfulOutcomeMatchesCommittedResult` | `base.tla:1343`, inherited by `MC` | `MC_hunt_CR_5_limit.cfg`, `MC_hunt_MC_4_cache.cfg`, `MC_hunt_scenario_1.cfg`, `MC_hunt_scenario_3.cfg` |
| `SuccessfulOutcomesAgree` | `base.tla:1346`, inherited by `MC` | `MC_hunt_CR_5_limit.cfg`, `MC_hunt_scenario_1.cfg`, `MC_hunt_scenario_3.cfg` |
| `CurrentTaskOwnsAcceptedCompletion` | `base.tla:1349`, inherited by `MC` | `MC_hunt_scenario_2.cfg`, `MC_hunt_scenario_2_progress.cfg`, `MC_hunt_scenario_4.cfg`, `MC_hunt_scenario_4_progress.cfg` |
| `DurableOutcomeMatchesCommittedResult` | `base.tla:1353`, inherited by `MC` | `MC_hunt_CR_5_limit.cfg`, `MC_hunt_MC_4_cache.cfg`, `MC_hunt_scenario_1.cfg`, `MC_hunt_scenario_3.cfg` |
| `DurableOutcomesAgree` | `base.tla:1356`, inherited by `MC` | `MC_hunt_CR_5_limit.cfg`, `MC_hunt_scenario_1.cfg`, `MC_hunt_scenario_3.cfg` |

The last two checks implement the analysis-review correction for durable worker-handler failures. They do not change the meaning of the four brief safety checks. `MC.cfg` enables core storage safety and structural checks; scenario properties are present there only as comments and are enabled in the named hunts.

## Brief section 6.1: trigger reachability audit

| Candidate | Required schedule / enabling bounds | Expected property | Actual targeting cfg |
|---|---|---|---|
| MC-1 | Two distinct Updates can bind before one WFT starts (`request >= 2`, four client slots in broad S1/S3); command builders interleave their accept/response messages. `uncertain=1` allows a submitted mutation to return error before or after atomic commit. Old object futures survive cache clearing, and callers read/receive independently. `lateError=1` permits error after published effects. | Result match/agreement, including durable handler failure | `MC_hunt_scenario_1.cfg`, `MC_hunt_scenario_3.cfg` |
| MC-2 | Same-ID clients and old worker token survive `clear=2`; direct `matchingFailure=1` is swallowed while a due STS timer can create a normal successor. `timeout=2`, `duplicate=1`, `callback=1` retain a submitted old STC timer across replacement and actual conversion. Retry/handler/reactive queue actions are not count-bounded. | `RetriedEligibleUpdateMakesProgress`; completion identity safety as separate check | `MC_hunt_scenario_2_progress.cfg`, `MC_hunt_scenario_4_progress.cfg`; corresponding safety cfgs |
| MC-3 | Two Updates, two independent waiter slots or more, `close=1`, `uncertain=1`; accept+complete and accept+abort use outcome-before-acceptance. Independent rejection has no durable admission/close requirement. | `AcceptedReceiptHasDurableAcceptance`, `SuccessfulOutcomesAgree`, durable outcome variants | `MC_hunt_scenario_3.cfg` |
| MC-4 | H1 produces A's provisional completion/cache insertion; `noncommit=1` leaves committed next event unchanged. `ownership=2` permits H1->H2->H1 without process restart. H2 admits B and commits its completion at reused event ID/version. `request=3` is three external invocations across two Update IDs: the third query/resubmission for B on H1 reaches lazy GetUpdateOutcome. Two value classes distinguish A/B payloads. `MaxGeneration=7`, `MaxObjects=10`, 22 event IDs allow this prefix. Host-cache eviction is optional and must NOT be forced before lookup. | `SuccessfulOutcomeMatchesCommittedResult`, `DurableOutcomeMatchesCommittedResult` | `MC_hunt_MC_4_cache.cfg`, broad `MC_hunt_scenario_1.cfg` |

A bound allowing a trigger is not evidence of a completed search. The focused MC-4 wrapper schedule reaches the wrong-payload receipt in 74 actions under its exact cfg bounds (see `checks/cache-witness-schedule.txt`); this establishes model reachability only. Generation evaluation checks are recorded in `generation-checks.md`. In particular MC-4 remains an unvalidated model candidate until host ownership, cache lifetime, backend fencing and public receipt are reproduced from the implementation; no fabricated cache insertion is proposed as production confirmation.

## Progress assumptions and exploration limits

`MCProgressSpec` requires fair processing of eligible tasks/timers, backend settlement, Matching, capable workers and each continuing client. Finite injection counters bound requests, cache/process/ownership disruption, lost responses, worker ignoring, close, and limit changes. Ordinary handlers, DB settlement/fencing, FIFO/LIFO effects, retry, soft long-poll expiry and due schedule-to-start timer progress are not bounded. A prior ACCEPTED stage switches the retry to Poll; volatile admission retries Update. Committed-result queryability is conditioned on a still-interested caller, consistent with the API's need for polling. Accepted-only handlers may remain unfinished; admission progress does not assert arbitrary handler termination.

Safety cfgs explicitly constrain finite event/object/task/message/generation prefixes; they can prune further behavior and are not global safety proofs. Progress companions deliberately omit these frontier constraints and symmetry. `MCView` excludes counters for inspection only, and is not enabled as TLC VIEW because different remaining budgets have different enabled actions. Symmetry is over Update IDs, client IDs and outcome values; the designated initial host is not permuted.

## Other findings and exclusions

CR-1's stale-sticky side effect is present and may require additional replay; recovery remains distinct from permanent loss. CR-2's callback discriminator and successor compensation are present. CR-5's limit abort and nondurable failure are retained without a stronger close invariant. CR-6's conditional guard is represented, but no exact-deadline property or public/backend confirmation is claimed. TV-2 is MC-4's reproduction handoff. CR-3 link labeling is code/test work and excluded from MC. CR-4's routing/logging and speculative-skip ownership reports do not justify removing existing guards or declaring a lost result.

Other explicit exclusions: cross-run Reset/Continue-As-New, replication, CHASM migration, queue fairness, changing build-ID routing, pause, arbitrary partial backend commits, durability of ordinary admission, permanent rejection lookup, and callback HTTP delivery. Event/cache IDs and batch IDs are normalized; this slice uses one current branch/version and models batch identity on completion references, with no uncommitted tail promoted into committed execution state. Exact physical batch lineage/trimming is a backend trace/reproduction obligation.

## Additional explicit limits

One active Workflow context/lease is modeled. Ownership movement is between handlers or follows an uncertain write return; concurrent execution by two still-active owners is not covered. The model therefore cannot adjudicate all overlap schedules in #10478. Client server-soft-timeout and response loss are modeled; a distinct client context-deadline/cancellation action is not yet included. Raw task-generation/vector-clock cases outside the fixed single-run/no-rebuild preconditions require extension before trace validation. These are limits on this generated slice, not passing results for the excluded paths.

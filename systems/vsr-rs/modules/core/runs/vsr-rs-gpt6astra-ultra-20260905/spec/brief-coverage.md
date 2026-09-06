# Brief coverage self-audit

Source: `../modeling-brief.md`, revision `3ac0104a567092139534c9022205d02281a2da41`. Category A. This is the mandatory spec-generation Phase 2.5 audit. The guide's explicit requirement governs the older checklist reference's optional wording.

Audited the actual uncommented cfg entries with `python3 checks/audit_cfg.py`; the extracted constants, invariants, and properties are in `checks/cfg-audit.json`. A cfg enabling a mechanism is search coverage, not evidence that its full state space was checked or that the implementation has a defect.

## Brief §2 scenarios

| Scenario | Base implementation and independent observations | Target cfgs | Boundary |
|---|---|---|---|
| S1 historical promises | `OnPrepare`, `OnPrepareOk`, `OnCommit`; separate `OnNewStateTransfer` / `OnNewStateCatchUp`; `RecordDoViewChange`, `OnStartView`, `OnRecoveryResponse`. `PersistView`, one-item `ReleaseMessage` / `ReleaseReply`, `Crash`, `Recover`, `Pause`, `Resume`. `acceptanceHistory`, `ackHistory`, `quorumHistory`, `installedViewHistory`, historical application sequences. | `MC_hunt_scenario1.cfg`, `MC_hunt_scenario1_five.cfg` | Full bounded logs, fresh recovery epochs, authentic released messages survive reboot. Primary self-acks recorded only at actual self-ack sites; distinct configured IDs counted across incarnations. |
| S2 logical service | `ClientOnRequest`, `ClientOnIdle`, `ClientOnReply`, `ClientRetire`; `AppendToLog`, `InstallLog`, `CommitOp`; independent `ReplayState` / `ReplayResults`. | `MC_hunt_scenario2.cfg`; S1 also enables application replay checks for MC2 | Two client identities, two sequential requests per identity, distinct request keys even for equal inputs. Fresh identity is an unused member of the finite identity supply; retirement never reuses it. |
| S3 progress | All four `OnIdle` branches, independent client retry, `Stabilize`, bounded delivery in ticks, bounded clock skew, owner fairness, separate client and recovery obligations. | `MC_hunt_scenario3_requests.cfg`, `MC_hunt_scenario3_recovery.cfg`, `MC_hunt_scenario3_recovery_five.cfg` | Finite conditional liveness slices. Recovery cfgs have zero client requests. No premise that a primary is Normal or that replicas share a view at stabilization. |
| S4 example obligations | **Explicit merger:** the conforming persistence/output boundary is included in S1's cfgs and checked by `PublicationOrder`. Fresh identities/nonces and compatible initial application state are base assumptions. | Merged into `MC_hunt_scenario1.cfg` for the abstract caller boundary only | The brief expressly assigns concrete filesystem, TCP, wall-clock nonce, startup, and identity-reuse candidates to component tests/review. No wrapper that deletes an obligation, no claim that this hunt verifies the shipped example. TV3 / CR1–CR5 remain outside the core model. |

## Brief §5 safety invariants

All names are defined in `base.tla` and inherited unchanged by `MC.tla`. The cfg scan below checks the explicit enabled names, not merely their definitions. Core convergence checks are enabled in `MC.cfg`; all scenario invariants there are commented out.

| Brief name | Meaning of executable check | Enabled hunt cfgs |
|---|---|---|
| TypeOK | IDs, types, statuses, client table domains, ack sender sets, timer quotient | `MC_hunt_scenario1.cfg` |
| CommitBounds | `0 <= commit <= Len(log)`; local source assertions separately latched as `ImplementationAssertions` | All six hunt cfgs |
| PrimaryForView | Arithmetic primary selection and compatible historical primary logs in the same view | All six hunt cfgs |
| HistoricalPrefixAgreement | Every observed committed/applied prefix is a prefix of one append-only canonical history; retains earlier incarnations | All six hunt cfgs |
| ProtectedPrefixSurvives | Same-view acknowledgement content compatibility; actual emitted-quorum prefix support in later eligible histories and every current eligible quorum; received-certificate consistency; installation preserves the old applied prefix | S1 three-replica and five-replica cfgs; S3 five-replica recovery cfg |
| ApplicationMatchesHistory | Actual local application calls equal the committed prefix and independent sequential replay, per incarnation | S1 three-replica cfg and S2 cfg |
| LogicalRequestOnce | Request key `(client, requestNumber)` occurs in at most one committed slot | S2 cfg |
| ReplySoundness | Accepted and released replies have a preceding invocation and canonical sequential result; cached results agree with their committed slot | S2 cfg and S3 requests cfg |

The guide asks hunts to omit structural-only checks, but also explicitly requires every brief §5 Safety row to be enabled in a hunt. `TypeOK` is enabled only in S1 to satisfy the latter requirement; the MC-only structural checks stay in the convergence cfg. No invariant is assumed as an action precondition or used as a state constraint.

## Brief §6.1 questions and reachability setup

| Finding | Mechanism admitted by actions and bounds | Target checks | Target cfgs |
|---|---|---|---|
| MC1 | Reboot after a buffered or released acknowledgement; leave old authenticated packets in transport; recover at persisted view; deliver old responses; compose with view change and transfer. 5 replicas permit two simultaneously Down/Recovering nodes within `f=2`. | `ProtectedPrefixSurvives`, `HistoricalPrefixAgreement` | S1 three/five replica cfgs |
| MC2 | Same-view transfer appends only missing entries; cross-view NewState replaces suffix after exact committed offset; StartView and DVC install full logs; recovery starts a fresh application and replays; all retain historical observations. | `HistoricalPrefixAgreement`, `ApplicationMatchesHistory` | S1 and S2 cfgs |
| MC3 | Two clients can have concurrent requests, each can submit a second after a reply; retries, authentic request/reply replay and loss; one reboot and client retirement; table rebuild retains source's exact cached-reply conditions. | `LogicalRequestOnce`, `ReplySoundness` | S2 cfg |
| MC4 | Request/reply loss and a crash before stabilization; requests may also be invoked after stabilization; unlimited service ticks and client retries thereafter. | `MCRequestEventuallyAnswered` (bounded form of `RequestEventuallyAnswered`) | S3 requests cfg |
| MC5 | One crash/recovery in N=3 or two in N=5; no client work; stable core is non-recovering, possibly changing views; latest-primary response and nonce/floor guards remain active. | `MCRecoveryEventuallyNormal` (bounded form of `RecoveryEventuallyNormal`) | S3 recovery three/five replica cfgs |

Reachability here means that the trigger's required actions and fault budgets are present. It is not a report of a completed targeted bug hunt. Later verification should collect witnesses for installation path and two-concurrent-recovery coverage before making coverage claims about a run.

## Bounds and temporal interpretation

The exact active constants are in `checks/cfg-audit.json`. Safety baseline: N=3, two clients, three register values, four total invocations, at most two per identity, MaxView=3, MaxLog=5, eight idle injections, two retries, one crash, one pause, two losses and two authentic replays. Target cfgs narrow unrelated faults; S1 allows two sequential reboots (or two concurrent reboots in N=5). The union of stopped, paused and Recovering replicas counts against `floor((N-1)/2)` in every supplied cfg. A recovering node does not become eligible merely because it runs ticks.

Reactive delivery, persistence completion, draining, resume and recovery startup have no event quotas. S3 service ticks/retries have no exhausted fault counters after stabilization. Replica IDs cannot be symmetrized because primary selection and BTreeMap tie ordering use arithmetic IDs; only client model values are permuted. Symmetry is disabled for all temporal cfgs. `ProtocolView` is an inspection projection only: cfgs do not discard fault budgets, histories, or timing state from TLC state identity.

For S3, `DelayTicks=1`; one unit is one idle call at any service replica. Publication completes before another service tick. Each continuously queued content is delivered within the age bound; with repeated equal copies the per-occurrence upper bound is `MaxNetwork * DelayTicks`. `ClockSkew=2` bounds the difference in service-replica tick counts, without imposing lockstep order. The temporal premise requires every service replica to tick infinitely often, live clients to retry, and the owner to persist/drain/restart fairly. The three-replica cfg uses timeout 8, the five-replica recovery cfg timeout 12; backoff retains the source's cap of ten doublings. These are explicit tested-environment choices, not a theorem for every unknown finite network delay. Before stabilization, clocks and deliveries are unconstrained except for search budgets.

The stable core is a non-recovering quorum; service nodes include every non-paused node at stabilization, including Down recovery targets. No new faults or client retirements occur after stabilization. A paused node outside the core has no service promise until a later, separately chosen environment includes it. Authentic old traffic can still be delivered.

Finite temporal cfgs check `<>BoundHit \/ <service-property>`. A trace that reaches a view, log, message, or outbox boundary is **inconclusive**, including an atomic handler whose next output batch would exceed a bound. This avoids treating pruned normal actions or view exhaustion as protocol stalls. A bounded pass is not an unbounded liveness result; monitor boundary reachability and assumption satisfaction when interpreting it. The unqualified properties are also defined for use without state pruning.

## Faithfulness and remaining limits

- Only view numbers persist. `Crash` loses application/log/client table/outboxes; `Recover` uses a fresh monotonically increasing observer epoch as a nonce. This representative freshness abstraction is not a wire incarnation check.
- `Pause`/`Resume` retain memory; network state is independent of every replica lifetime. Handlers cannot interleave inside synchronous Rust helper loops. Individual application calls are recorded in order within their enclosing handler event.
- `stable` and `attempts` are saturated at their only comparison/use thresholds; traces normalize raw counts. Waiting counts and view numbers are not wrapped. Integer overflow is outside brief scope.
- Put/Get is a deterministic, order-sensitive finite register from common initial value 0. Put returns the prior value. It is a purpose-built contract workload, not a claim that the example Store or existing accumulator uses that exact API.
- `install_log`'s length assertion is retained without adding a compatible-content guard. Assertion failures latch an invariant failure rather than silently disabling the transition.
- Quorum certificate construction does not assume equal contents. Individual acknowledgements constrain same-view histories, and singly acknowledged suffixes may be replaced in a later view. Historical protection does not mean every accepted request keeps its initial slot.
- TV1's singleton API candidate, TV2's DST monitor/workload comparison, and S4's concrete components remain separate tests/reviews per the brief. No source or simulator regression is written by this generation task.

Validation status is recorded separately in `checks/validation.md` after all phase outputs are complete. Trace schema and hook requirements are in `instrumentation-spec.md`.

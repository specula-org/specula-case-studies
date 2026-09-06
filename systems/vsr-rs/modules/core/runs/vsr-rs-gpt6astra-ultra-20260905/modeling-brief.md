# Modeling Brief: vsr-rs

## 1. System Overview

- **Target:** `penberg/vsr-rs`, Rust, revision `3ac0104a567092139534c9022205d02281a2da41`; inspected 2026-09-05.
- **Category A — Distributed / Message-Passing:** replicas exchange protocol messages; crashes, delivery, and caller-owned persistence are the relevant boundaries. This is crash-fault VSR, not BFT.
- **Scale:** `lib.rs` is 1,476 lines; the secondary TCP key-value example is 764 lines. Membership is fixed; no checkpoints, log compaction, or dynamic membership (`README.md:74-87`, `lib.rs:427-475`).
- **Architecture:** synchronous `&mut self` handlers, buffered messages/replies, no internal threads or I/O; the caller supplies application, transport, persistence, and ticks (`lib.rs:6-21`, `527-641`, `1467-1475`).
- **Implementation choices:** persistent view floor; explicit same-view state transfer versus view catch-up; offset-bearing NewState; cumulative prefix acknowledgements; capped exponential view-change backoff (`lib.rs:167-206`, `379-392`, `505-524`, `1298-1305`).
- **Contract:** authentic messages, deterministic application from compatible initial states, distinct client identities renewed after restart, one outstanding request per client, fresh recovery nonce, and view persistence before outputs (`lib.rs:14-21`, `29-31`, `274-277`, `505-510`).
- **Assurance status:** existing ordered-history/reply checks are substantial; 16 integration and 5 simulator tests passed locally. No new multi-replica safety defect or general liveness theorem is established by this analysis. See [analysis-report.md](analysis-report.md).

## 2. Scenarios

### Scenario 1: Historical protocol promises across state replacement and recovery

**Mechanism:** a replica's reconstructed volatile state must remain compatible with the protocol promises made by its earlier incarnation and with globally protected history.

**Evidence:**
- Historical context only: `4e4b0bb6` corrected distinct-replica acknowledgement counting; `06ba5def` added view change with deferred cross-view suffix replacement; `f8acf515` implemented recovery with a persisted-view floor. All are incorporated; [audit/history.md](audit/history.md) verifies adoption.
- Current paths: `on_prepare_ok` commits a whole prefix using distinct sender IDs (`lib.rs:737-767`); `install_log` preserves only the length lower bound locally (`1321-1344`). Correct prefix contents depend on the surrounding protocol.
- Recovery starts empty and later installs a primary's response after nonce/quorum/view checks (`lib.rs:517-535`, `1159-1205`); view change, StartView, and NewState have distinct installation paths (`842-894`, `948-968`, `1043-1080`).
- Observation boundary: DST keeps a historical canonical prefix, but durability support is examined only for newly observed committed indexes (`simulator/properties.rs:77-102`, `210-245`). Retained Lean separately states historical acknowledgement obligations; preservation is unfinished (report §6).

**Affected code paths:** `on_prepare`, `on_prepare_ok`, `on_commit`, `on_new_state`, `record_do_view_change`, `on_start_view`, `on_recovery_response`, `install_log`, `commit_up_to`.

**Suggested modeling approach:**
- Variables: volatile replica state, `durableView`, replica incarnation, released authentic message history, acknowledgement-prefix evidence, append-only protected logical history.
- Actions: retain all four protocol paths; distinguish retained-state suspension/resumption from state-losing reboot and recovery. Old authentic messages remain deliverable across reboot; incarnation tags are observer metadata, not invented wire validation.
- Granularity: one handler is atomic; separate handler completion, durable view publication, and output release. An unreleased outbox is volatile. Do not split synchronous Rust helpers into inter-replica concurrency.
- Record acceptance, acknowledgement emission, quorum observation, application, and reply separately. Allow replacement of an unprotected suffix; never require every accepted request to retain its first log position.

**Priority:** High. **Rationale:** preservation spans all protocol paths and replica lifetimes; neither local assertions nor one-time support checks establish it independently. This is an open composition question, not a claim that the known fixes are missing.

### Scenario 2: Logical request identity, application replay, and reply reconstruction

**Mechanism:** client-table rebuilding, execution, and cached replies must describe the same sequential logical history despite retries and replica reconstruction.

**Evidence:**
- Historical context only: `dd5bbb8f` added client-table deduplication; `bbcc14dd` added client request retries; `7cf58faf` corrected ordered prefix execution. All are incorporated.
- Current paths: acceptance writes a pending client entry (`lib.rs:658-684`, `1310-1318`); installation reconstructs latest entries and preserves selected cached replies (`1324-1344`); execution always applies the next log entry and conditionally caches its result (`1349-1376`).
- Recovery replays into the caller-supplied application without emitting recovery replies (`lib.rs:518`, `1203-1205`); compatible initial state is a caller assumption. New-primary execution may emit replies (`1066-1070`).
- DST records ordered operations and checks return values. Its duplicate key is a generated `op.id`, whose mapping to a client/request pair is guaranteed by its workload (`simulator/state_machine.rs:26-53`, `simulator/lib.rs:832-848`, `simulator/properties.rs:250-361`).

**Affected code paths:** `Client::on_request/on_reply/on_idle`, replica `on_request`, `append_to_log`, `install_log`, `commit_op`, recovery and new-primary execution.

**Suggested modeling approach:**
- Variables: `(clientId, requestNumber) -> input`, outstanding requests, canonical request sequence, per-incarnation applied sequence, reference application state, expected results, cached/emitted/delivered replies.
- Actions: permit authentic delayed/duplicate requests and replies independently; a client advances only after accepting its pending reply. Client restart allocates a fresh identity.
- Granularity: ordered execution is part of its handler; instrument each application event without making it concurrently interruptible by another replica handler.
- Use a small order-sensitive deterministic machine, such as finite-domain Put/Get, with a specified common initial state. Equal payloads from different requests remain distinct.

**Priority:** High. **Rationale:** the public StateMachine abstraction is broader than one workload; logical uniqueness and result correctness need an oracle independent of implementation client-table choices.

### Scenario 3: Service and recovery progress under suitable timing

**Mechanism:** retries, changing views, and independent caller-driven clocks must eventually complete work once a sufficient stable quorum can communicate and execute steps.

**Evidence:**
- Historical context only: `06ba5def` implemented view changes, `8ab4fffc` added backoff, and `b25372d8` retained it until stable operation; issues #4, #7, #8 document completed retries, timing, and rerouting.
- Current retry paths cover all statuses (`lib.rs:1233-1285`); backoff is capped at ten doublings (`1302-1305`). Recovery requires responses from other replicas and the latest-view primary (`1166-1205`).
- DST uses synchronized idle calls and direct lossless reply delivery (`simulator/lib.rs:891-900`, `944-961`). Its terminal check requires outstanding-request completion and core log convergence, but does not explicitly require recovery completion or Normal status (`786-809`).
- Retained Lean's general `settles` statement is unfinished and uses a synchronous draining scheduler; it is not a theorem that clients eventually receive correct replies (report §6).

**Affected code paths:** both `on_idle` methods, `wait_timed_out`, `note_stable`, view-change initiation/completion, recovery request/response collection.

**Suggested modeling approach:**
- Variables: per-replica logical timer state, outstanding requests, recovery obligations, active stable quorum, communication/event-processing bounds.
- Actions: independent fair ticks, requests, and message/reply delivery; after stabilization retain an available non-recovering quorum and stop state-losing failures there.
- Granularity: one idle call or delivered message per step; do not import the simulator's lockstep batches or assume a normal primary as a premise for proving view establishment.
- State explicit delay/processing bounds relative to timeout configuration; fairness alone does not prevent endless timeouts, and capped backoff does not establish progress for every finite unknown delay bound.
- Check client completion and each eligible recovery separately, including quiescent histories; queue emptiness and equal logs are not their definitions.

**Priority:** High. **Rationale:** service progress is a requested contract question and differs from finite workload convergence. The separate singleton code-level candidate belongs in §6.2, not an expensive protocol search.

### Scenario 4: Example obligations at the library boundary

**Mechanism:** the example must implement the durability, identity, timing, and delivery assumptions on which the library relies.

**Evidence:**
- Known context: issue #9 and open PR #10 cover reconnect backoff, disconnect cleanup, and client-ID reuse. These are not new findings; the PR does not resolve identity policy.
- Verified compensations: one outstanding socket request (`examples/kvstore/main.rs:454-472`), fresh empty application on recovery (`697`), and persist-before-flush ordering (`749-750`).
- Independent candidates: temp-file fsync/rename omits parent-directory fsync (`570-579`); startup collapses read/parse errors into new-replica bootstrap (`686-699`); nonce freshness depends on wall time (`692-695`); all destinations share blocking writes (`342-392`).
- Ticks are produced regularly but consumed through the main event queue (`650`, `673-680`, `716-750`); this is an integration timing assumption, not a missing timer.

**Affected code paths:** `persist_view`, startup, `run_sender`, event/timer loop, client connection lifecycle.

**Suggested modeling approach:** keep conforming integration assumptions in the primary protocol model. Use code review and isolated component verification for these candidates. A later wrapper model, if needed, must label violations of caller obligations separately from library behavior; no socket/parser implementation is needed in this handoff.

**Priority:** Medium for modeling; high relevance to deployment correctness. **Rationale:** concrete code facts are available, while filesystem guarantees and queue progress need platform-specific validation. See [audit/example.md](audit/example.md).

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Fixed-membership normal/view-change/transfer/recovery composition | S1 installation contracts depend on one another | Faithful handler variants, full bounded logs, explicit status and last-normal-view |
| Durable view versus volatile state and message publication | S1 caller boundary | Separate durable publication/output release; fresh recovery nonce; preserve authentic released messages |
| Logical history and sequential application/reply oracle | S1–S2 lifetime obligations exceed current-state agreement | Ghost history by request key and slot; per-incarnation replay; independent deterministic transition function |
| Requests and replies under loss, delay, duplication, reorder | S2–S3 public transport contract | Independent message/reply channels with authentic origins; stable request identity on retry |
| Independent clocks plus conditional progress | S3 scheduler coverage boundary | Per-replica ticks, explicit stabilization assumptions, separate request/recovery temporal properties |

Start with 3 replicas, at least 2 clients and multiple sequential requests per client. Include a bounded 5-replica slice for MC1/MC5: two concurrent recoveries are within its failure budget and cannot be represented with 3 replicas. Bound explored state without wrapping IDs or views into reused values. Report bounds and enabled fault assumptions, not a universal proof.

For the promised-service configuration, let `f=floor((N-1)/2)` and count the union of stopped and recovering replicas against the failure budget. Model paused replicas retaining memory separately. Runs outside that guarantee may explore robustness but cannot substantiate a violation of the bounded-failure service claim. Network partitions affect availability assumptions separately. A live client or eligible recovering replica must itself communicate fairly with the stable quorum and continue processing/retrying; a quorum elsewhere does not guarantee progress for an isolated target.

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Reverting historical fixes or erasing the durable view of a conforming caller | Known-answer targets or violations of the stated contract; historical fixes stay in evidence/reference context |
| Byzantine senders, malformed peer frames, invented membership | Authentic crash-fault messages and fixed membership define this scope |
| Checkpoints, dynamic membership, compaction | Not implemented by the target |
| Non-deterministic application/external irreversible effects | Outside the stated deterministic state-machine semantics; document recovery initialization instead |
| Global ban on repeated `apply` across replica incarnations | Rebuilding lost local state legitimately replays an existing logical prefix |
| TCP bytes, filesystem internals, logging, integer overflow searches | S4 component review/tests; use abstract obligations in the core model |
| All logs equal or all replicas at the same view at all times | Uncommitted suffixes and lagging views are legal; protect committed history instead |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Publication boundary and incarnation observer | `durableView`, `incarnation`, `pendingOutputs`, `released` | Represent caller persistence and lifetime transitions without changing wire guards | 1 |
| Historical certificates and log identity | `ackHistory`, `protectedHistory`, `installedViewHistory` | Relate cumulative acknowledgements and later installed prefixes | 1 |
| Logical service oracle | `requestInput`, `logicalHistory`, `appliedByIncarnation`, `referenceState`, `expectedReply` | Distinguish logical execution, local reconstruction, and client results | 2 |
| Client delivery state | `pendingRequest`, `replyChannel`, `acceptedReplies` | Make lost/reordered replies and retries observable | 2, 3 |
| Progress environment | `clock`, `stableCore`, `stabilized`, `recoveryObligations` | Separate timing assumptions from the service properties | 3 |

## 5. Proposed Invariants

| Invariant / property | Type | Description | Targets |
|---|---|---|---|
| TypeOK / CommitBounds | Safety | Valid IDs/statuses; `0 <= commit <= Len(log)`; fixed membership | Standard |
| PrimaryForView | Safety | A replica serving as primary in view v equals `v mod N`; no same-view conflicting primary histories | Standard, S1 |
| HistoricalPrefixAgreement | Safety | All current and historical committed/applied sequences are prefixes of one append-only logical history, across views and incarnations | S1, MC1–MC2 |
| ProtectedPrefixSurvives | Safety | Observed same-view quorum acknowledgements protect their exact request prefix in later eligible histories; preserve support against legal future quorums | S1, MC1 |
| ApplicationMatchesHistory | Safety | Per-incarnation application sequence and state equal sequential replay of its committed prefix from the common initial state | S2, MC2–MC3 |
| LogicalRequestOnce / ReplySoundness | Safety | One request key occupies at most one committed slot; each accepted reply has that slot's sequential result and a preceding invocation | S2, MC3 |
| RequestEventuallyAnswered | Liveness | Under the explicit stable-service assumptions, a live client's pending request eventually receives its correct reply | S3, MC4 |
| RecoveryEventuallyNormal | Liveness | An eligible non-crashing recovering replica eventually returns to Normal, even with no client work | S3, MC5 |

Liveness rows are temporal properties, not state invariants. Derive acknowledgement evidence from actual emissions and then-held prefixes, plus actual primary self-acknowledgement; count configured replica IDs once across incarnations. Keep emission, primary receipt, application, and reply delivery distinct. Do not assume same-view agreement inside a certificate definition. Individual acknowledgements constrain same-view promises; they do not freeze every uncommitted suffix across later views. Durable-view ordering/floors are faithful action semantics, not a standalone hunt for the already corrected view-regression defect.

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking question | Expected violation if refuted | Scenario |
|---|---|---|---|
| MC1 | Does recovery re-entry preserve earlier same-view acknowledgement promises and quorum-protected history when composed with view change/state transfer, without incorrectly freezing singly acknowledged suffixes? | ProtectedPrefixSurvives / HistoricalPrefixAgreement | 1 |
| MC2 | Do all installation paths preserve already executed history and apply only the compatible newly committed suffix? | HistoricalPrefixAgreement / ApplicationMatchesHistory | 1, 2 |
| MC3 | Under valid client discipline, do table rebuilding and cached replies retain logical uniqueness and sequential results across retries, views, and reconstruction? | LogicalRequestOnce / ReplySoundness | 2 |
| MC4 | Do pending and subsequently submitted requests complete with independent ticks and faulted reply delivery once stated service conditions hold? | RequestEventuallyAnswered | 3 |
| MC5 | Does each eligible recovery finish under those conditions independently of whether any requests remain? | RecoveryEventuallyNormal | 3 |

These are unresolved correctness questions grounded in current code and observation limits, not confirmed bugs. None asks to recreate a closed issue or disable its fix.

### 6.2 Test-Verifiable

| ID | Description | Suggested verification |
|---|---|---|
| TV1 | Singleton request progress lacks a local-quorum completion path (`lib.rs:684`, `737-767`, `1235-1253`); simulator configuration permits one replica (`simulator/lib.rs:259`) | Isolated API contract regression for one member; decide whether to support it or reject/document it |
| TV2 | Incremental DST oracles assume old slots/support remain valid; reply delivery bypasses network faults (`simulator/properties.rs:89-101`, `233-244`; `simulator/lib.rs:950-961`) | Compare incremental monitors with a full historical oracle on controlled fixtures; verify observer event granularity and reply-channel coverage |
| TV3 | Example shares blocking writes across destinations and omits parent-directory fsync (`examples/kvstore/main.rs:342-392`, `570-579`) | Component-level storage/transport contract verification; keep platform assumptions explicit |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | Startup read/parse errors select fresh bootstrap (`examples/kvstore/main.rs:686-699`) | Separate intentional initial bootstrap from unusable existing durable state |
| CR2 | Recovery nonce uses non-monotonic wall time without a freshness policy (`examples/kvstore/main.rs:692-695`) | Specify a restart epoch/freshness guarantee; retain fresh nonces in core modeling |
| CR3 | Recovery/application initialization and single outstanding request are caller obligations, partly implicit in APIs (`lib.rs:53-60`, `312-327`, `505-524`) | Document deterministic compatible initial state, replay semantics, and client discipline at entry points |
| CR4 | Known #9 identity reuse/cleanup, plus related ID-packing constraints (`examples/kvstore/main.rs:454-503`, `726`) | Track existing issue/PR and review packing assumptions; author scope comments do not bind the maintainer |
| CR5 | Example timer consumption bounds and supported filesystem crash semantics (`examples/kvstore/main.rs:650`, `673-680`, `716-750`, `570-579`) | Review queue/storage/clock assumptions separately from unconditional protocol safety |

## 7. Reference Pointers

- Detailed audit: [analysis-report.md](analysis-report.md); [history and adoption](audit/history.md); [existing assurance](audit/assurance.md); [example integration](audit/example.md); [baseline test log](audit/baseline-tests.log).
- Source at the pinned revision: `lib.rs:644-894` normal/transfer; `903-1122` views; `1124-1215` recovery; `1217-1376` retry/application; `examples/kvstore/main.rs:342-392,545-585,683-750` integration.
- All public issues were read: [#1](https://github.com/penberg/vsr-rs/issues/1), [#4](https://github.com/penberg/vsr-rs/issues/4), [#5](https://github.com/penberg/vsr-rs/issues/5), [#7](https://github.com/penberg/vsr-rs/issues/7), [#8](https://github.com/penberg/vsr-rs/issues/8), [#9](https://github.com/penberg/vsr-rs/issues/9). All PRs were read: [#2](https://github.com/penberg/vsr-rs/pull/2), [#3](https://github.com/penberg/vsr-rs/pull/3), [#6](https://github.com/penberg/vsr-rs/pull/6), [#10](https://github.com/penberg/vsr-rs/pull/10).
- Algorithm context: [VSR Revisited §§2–4 and 5.2](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf); [Michael et al. §6](https://drkp.net/papers/recovery-tr17.pdf); [Vanlightly state-transfer analysis](https://jack-vanlightly.com/analyses/2022/12/28/paper-vr-revisited-state-transfer-part-3). The latter two corrections are already recognized by the target.
- Independent assurance context: [retained Lean README at de1a843](https://github.com/penberg/vsr-rs/blob/de1a84376afe1102c197c2e0f4ade41eb4494458/lean/README.md), with actual model/checker sources pinned in `audit/retained-lean-de1a8437/`; proof status is not an implementation-defect finding.

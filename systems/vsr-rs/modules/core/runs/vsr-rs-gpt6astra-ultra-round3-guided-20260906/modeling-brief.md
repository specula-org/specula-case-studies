# Modeling Brief: vsr-rs, correctness pass 3

## 1. System Overview

- **Revision:** `3ac0104a567092139534c9022205d02281a2da41`, verified 2026-09-06; Rust; `lib.rs` 1,476 lines and `examples/kvstore/main.rs` 764 lines.
- **Category A — Distributed / Message-Passing:** fixed-member crash-fault replication; messages, recovery, and persistence boundaries determine correctness. No BFT or Category B overlay applies.
- **Reference:** Liskov/Cowling, *Viewstamped Replication Revisited* (2012), §§2–4, 5.2; [paper](https://pmg.csail.mit.edu/papers/vr-revisited.pdf), [retrieved mirror](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf).
- Library calls are serial local transitions; the caller supplies transport, regular ticks, deterministic application execution, and durable views before output delivery (`lib.rs:6-21,53-60,422-425`).
- Volatile full logs/client tables; persisted view and fresh recovery nonce; round-robin primary; suffix state transfer; timer-driven retransmission/backoff. No reconfiguration or snapshots (`lib.rs:86-98,427-475,505-523,1233-1305`).
- `kvstore` has one owner event loop plus sender, ticker, and connection threads; newline text framing; a file stores the view (`examples/kvstore/main.rs:342-414,545-585,650-750`).
- **Finding status:** one new integration framing defect reproduced with unchanged sender/receiver functions, a real-library continuation, and three unchanged shipped binaries. Core safety questions below remain unproved, with no confirmed core defect.

## 2. Scenarios

### Scenario 1: EOF turns a valid frame prefix into different operation content

**Mechanism:** an unterminated final token is accepted at clean EOF, so loss of the tail of valid traffic changes message content instead of dropping the frame.
**Evidence:**
- Historical: `b97ffdd` introduced this integration; issue [#9](https://github.com/penberg/vsr-rs/issues/9) and open [PR #10](https://github.com/penberg/vsr-rs/pull/10) concern other connection mechanisms, not framing.
- Code: encoder final operation token `main.rs:79-117`; body/newline writes `383-386`; EOF-capable `lines()` dispatch `401-409`; decoder `237-334`; duplicate Prepare preserves existing content `lib.rs:716-730`.
- Reproduction: `evidence/frame-regression/run.log`: a 16,777,216-byte value becomes 2,613,649 bytes; both survivors commit it in view 1; original client's retry succeeds and a later fresh-client GET returns the shorter value. Independent three-binary run: SET succeeds, then a fresh-client GET returns 2,623,764 of 16,777,216 bytes (`evidence/kvstore-process-check-2/result.json`).
**Affected code paths:** `encode`, `run_sender`, `run_peer_acceptor`, `decode`, `on_prepare`, view-change selection, `commit_op`, `deliver_reply`.
**Suggested modeling approach:**
- Variables: optional integration mode, immutable sent-frame provenance, pending transmission, admitted operation variant, original client invocation/result history.
- Actions: admit either the full encoded Prepare or the concrete nonempty ASCII final-value prefix demonstrated by the test, only after partial transmission plus clean EOF. Keep ordinary core transport content-preserving.
- Granularity: separate publication, transmission completion/EOF, handler execution, and client observation. Byte parsing itself remains a Rust test; do not add arbitrary message mutation.
**Priority:** High for integration testing; optional small model composition.
**Rationale:** reproduced client-visible result has no legal sequential explanation. This is one framing root cause, not separate bugs for each message variant.

### Scenario 2: Quorum-selected history across view changes and rolling recovery

**Mechanism:** log installation relies on quorum history while volatile copies and uncommitted suffixes change across recoveries and views.
**Evidence:**
- Historical: imported recovery/state-transfer repairs in `716c5bf`; historical patches `06ba5de` and `f8acf51` explain preservation risks (reference context only).
- Code: a DVC quorum need not contain the new primary's own state (`lib.rs:926-943,1000-1038,1043-1059`), unlike paper §4.2 step 3; majority intersection remains a compensation.
- Code: recovery resets volatile state (`505-523`); `install_log` checks length, preserves executed application state, and rebuilds client metadata (`1324-1345`); commit does not move backwards (`1349-1377`).
**Affected code paths:** `on_do_view_change`, `record_do_view_change`, `recover`, `install_log`, `commit_up_to`, client retry/reply handling.
**Suggested modeling approach:**
- Variables: complete position-indexed logs, last normal view, per-client table/results, durable view, fresh nonce, ghost committed history and client invocation/response order.
- Actions: actual external-only DVC quorum; successive distinct-replica crash/recover cycles; original pending retries and later cross-client requests.
- Granularity: one local handler; crashes between owner steps and output publication. A recovering replica still counts as unavailable until it has rejoined safely.
**Priority:** High.
**Rationale:** safety impact would be severe; own-state omission alone is not a violation. Preserve committed positions while allowing legitimate replacement of uncommitted suffixes.

### Scenario 3: Arrival-order recovery responses during changing views

**Mechanism:** recovery chooses from a per-sender map that can replace newer responses with older authentic responses from the same nonce.
**Evidence:**
- Historical: recovery/persisted-view work `f8acf51` is already present; do not disable its safeguards.
- Code: response replacement `lib.rs:1166-1170`; maximum currently stored view `1174-1179`; persisted floor and exact latest-primary-state guards `1180-1193`; only normal replicas respond `1131-1149`.
**Affected code paths:** `on_recovery`, `on_recovery_response`, `send_recovery`, view-change/catch-up transitions.
**Suggested modeling approach:**
- Variables: multiple in-flight snapshots per sender/nonce, current response map, durable floor, chosen primary snapshot, historical completed operations.
- Actions: generate responses at different times/views; reorder/duplicate them; overwrite by arrival order exactly as code does; combine with view changes and subsequent rolling recovery.
- Granularity: separate generation from receipt; do not coalesce all responses from one sender into a monotone maximum.
**Priority:** High.
**Rationale:** decreasing the maximum ever observed is not itself a promised-view violation; require committed-history harm or non-progress after the stated stability conditions.

### Scenario 4: Durable view with only some output published before a crash

**Mechanism:** one local step can produce multiple messages/replies, whose delivery is not an atomic group even after its view is durable.
**Evidence:**
- Code: caller order `lib.rs:14-21`; separate output drains `1467-1474`; `kvstore` persists before flush `main.rs:749-750`, then queues messages and routes replies individually `551-559`.
- Code: queued messages contain owned snapshots (`lib.rs:1017-1035,1083-1090,1139-1149`), so published traffic may outlive its sender while unpublished output disappears.
**Affected code paths:** owner persistence/flush, DVC and StartView output, recovery requests/responses, commit replies.
**Suggested modeling approach:**
- Variables: durable view, per-replica pending output sequence, published network messages, observed client replies.
- Actions: local step, persist resulting view, publish one output, crash; retain only already published traffic and clear volatile/unpublished state; recover with a fresh nonce.
- Granularity: retain the synchronous handler boundary; split owner persistence and individual publication. No sends before required persistence.
**Priority:** Medium–High.
**Rationale:** this is allowed caller behavior and composes with Scenarios 2–3. A missing result/witness is coverage only.

### Scenario 5: Continued requests with a permanently unavailable minority

**Mechanism:** timer-driven primary rotation and recovery/catch-up must eventually leave a usable quorum serving new requests.
**Evidence:**
- Historical: immediate backoff-reset livelock is already fixed; `0fe2a47` is nonancestor Lean context, not a missing Rust patch.
- Code: round-robin primary `lib.rs:86-98`; prefix acknowledgements `737-768`; retry loops and capped timeout `1233-1305`; acknowledgements after state install `893,967,1381-1388`.
- Existing simulator already chooses a permanently unavailable noncore for convergence, but stops generating new requests when liveness mode begins (`simulator/lib.rs:729-824`). Prior-run broader timeouts are not failures.
**Affected code paths:** `on_idle`, `wait_timed_out`, view-change selection, state transfer, recovery, client broadcast retry.
**Suggested modeling approach:**
- Variables: fixed healthy set after a finite fault prefix, pending/new requests, timer counters/backoff, unavailable/recovering status.
- Actions: skip unavailable round-robin primary; continuously admit bounded fresh work after stabilization; deliver/retry all healthy traffic with explicit timing fairness.
- Granularity: separate timer events and message deliveries. Require a healthy participating majority and bounds allowing a complete view change before the capped timeout expires.
**Priority:** Medium–High.
**Rationale:** checks sustained service rather than only draining old requests; excludes the known shared TCP sender obstruction.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Actual guards, quorum sets and log selection | Scenarios 2–3 rely on implementation choices | Model all statuses, `last_normal_view`, sender-ID sets, exact map replacement and maximum commit selection |
| Rolling recovery with original-position commitments | Scenario 2, user questions 2 and 4 | Use 3 replicas initially, multiple sequential recoveries with fresh nonces; keep ghost history across process resets |
| Recovery concurrent with views | Scenario 3 | Retain old/new responses from the same attempt; test both different-view and same-view snapshot reorder |
| Durable/published/unpublished distinctions | Scenario 4 | Persist-before-send discipline plus per-output release and crash loss |
| Cross-client real-time results | Scenarios 1–4 | Small register Put/Get workload; retain original arguments, return values, invocation/completion order, and pending calls |
| Healthy-majority sustained service | Scenario 5 | Separate liveness configuration with a stable set, continuing clients, and explicit delivery/timer bounds |
| Valid EOF-prefix integration refinement, if needed | Scenario 1 has executable provenance | Restrict to witnessed Prepare.Put truncation; keep separate from the contract-respecting core configuration |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Previously reported view-file fallback, singleton, shared sender stall, directory fsync, nonce freshness, issue #9/PR #10 mechanisms | Explicit novelty exclusions; retain in audit/reference context only |
| Historical pre-fix behavior | Already-fixed bugs are not new targets; do not undo recovery barriers or backoff logic |
| Arbitrary forged/malformed protocol traffic | Outside the documented crash-fault caller contract; EOF variant must have encoder provenance |
| Byte parsing, UTF-8 slicing, OS socket internals | Rust/loopback tests are the appropriate confirmation method; abstract only demonstrated semantics |
| Membership changes, snapshots, disk log persistence, Byzantine behavior, atomics/CAS | Not implemented or not this system category |
| Crash schedules that treat empty recovering replicas as healthy voters | Can destroy every informed quorum outside the intended failure budget |
| Blanket agreement of every uncommitted suffix; quorum live-copy count at every instant | Stronger than required and can flag legitimate suffix replacement or temporary crash losses |
| Claims that reply loss/full history/per-handler observation were absent in prior runs | User states those mechanisms were already modeled; retain them rather than advertise them as additions |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Historical commitment/client observations | `committedHistory`, `invocations`, `responses`, `happensBefore` | Preserve evidence across crashes; check original arguments/results and positions | 1–4 |
| Actual DVC choice | `dvcFrom`, `lastNormalView`, `log`, `commit` | Permit quorum excluding self without assuming safety or failure | 2 |
| Recovery snapshots by arrival | `nonce`, `responseMap`, `networkSnapshots`, `durableView` | Preserve overwrites and latest-primary guards | 2–3 |
| Owner output boundary | `pendingOutput`, `publishedMessages`, `durableView` | Crash after any permitted publication prefix | 4 |
| Stable service phase | `healthySet`, `phase`, `timer`, `backoff`, `pendingClient` | Continued operation despite unavailable minority | 5 |
| Optional tested EOF refinement | `sentFrameId`, `txState`, `admittedValue` | Represent only a proven transport-to-message mapping | 1 |

## 5. Proposed Invariants

| Property | Type | Description | Targets |
|---|---|---|---|
| CommittedPrefixAgreement | Safety | Executed entries agree by position, client/request identity, and original operation | 1–4 |
| CommittedHistorySurvives | Safety | Every later selected/installed history preserves all previously committed positions | 2–4 |
| PreparedPrefixAgreement | Safety | Applicable normal replicas in one view agree on overlapping prepared entries under core transport assumptions | 1–3 |
| DistinctQuorumAndPrimary | Safety | Commit/DVC participants are distinct valid members; designated primary matches the view | 2–3, standard |
| ClientLinearizability | Safety | Observed Put/Get results admit a sequential history respecting cross-client real-time order and original invocations | 1–4 |
| NoDuplicateExecution | Safety | One logical client request occurs at most once in the chosen history; recovery replay rebuilding lost state is allowed | 2–4 |
| DurableViewFloor | Safety | Recovery never adopts below its correctly persisted view; published outputs obey persistence order | 3–4 |
| RecoveryCompletesUnderStability | Liveness | With fresh nonce, enough responsive normal participants, a usable primary and delivery/timer assumptions, recovery eventually completes | 3–5 |
| StableMajorityServesNewWork | Liveness | Each continuing healthy client's request eventually completes after stabilization; finite backoff alone is not a violation | 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking question | Expected violation if defective | Scenario |
|---|---|---|---|
| MC-1 | Can a reachable external-only DVC quorum select a log inconsistent with the new primary's committed/application prefix, including after rolling recovery? | CommittedPrefixAgreement / CommittedHistorySurvives | 2 |
| MC-2 | Can sequential completed recoveries within the unavailable-replica budget erase/reposition a committed or client-completed operation, or change later cross-client results? | CommittedHistorySurvives / ClientLinearizability | 2 |
| MC-3 | Can overwritten or mixed-view responses with fresh nonces pass all existing guards yet cause committed-history harm after further view/recovery steps? | CommittedHistorySurvives / ClientLinearizability | 3 |
| MC-4 | Can authentic traffic released before a crash combine with recovery and lost unpublished output to violate history preservation? | CommittedHistorySurvives / ClientLinearizability | 4 |
| MC-5 | Under explicit stable healthy-majority delivery/timer bounds, can recovery or skipped primaries permanently prevent completion of continuing requests? | RecoveryCompletesUnderStability / StableMajorityServesNewWork | 3, 5 |

### 6.2 Test-Verifiable

| ID | Finding / status | Suggested verification |
|---|---|---|
| TV-1 | EOF partial final token changes a Prepare operation: **reproduced**; one integration defect | Preserve `evidence/frame-regression` tests; require complete framing; verify unchanged source prefix and emitted/received-frame hashes; rerun view-change/client-result continuation |
| TV-2 | Same framing root can shorten a forwarded GET reply; reader-level case reproduced, whole reply-routing case pending | Use actual encoder and receiver; complete SET before GET; stop reply sender during body write; check original request/result semantics and retries |
| TV-3 | Other log-carrying frames admit a shortened last entry; static path established, downstream variants pending | Table in `evidence/integration-analysis.md`; test concrete valid prefixes and install/overlap compensation, without multiplying bug count |

### 6.3 Code-Review-Only

| ID | Question / contract boundary | Suggested action |
|---|---|---|
| CR-1 | `N=2` uses quorum 2, but recovery can hear from only one other replica (`lib.rs:96-98,1171-1173,1404-1409`) | Document/review supported group sizes and recovery availability; paper's two-node group tolerates zero failures, so this alone is not a within-budget protocol defect |
| CR-2 | Caller must supply authentic content/identities, unique client IDs, fresh nonces, deterministic state machine, and correct durable view | Keep explicit assumptions; classify failures in `kvstore` separately; inspect defensive parser validation through ordinary code review |
| CR-3 | Backoff caps at 1,024 times base timeout (`lib.rs:1302-1305`); eventual delivery alone does not specify a usable timing bound | State the liveness timing contract; do not label finite delay or an unconstrained asynchronous schedule a service defect |

## 7. Reference Pointers

- Detailed audit and reproduction limits: [analysis-report.md](analysis-report.md); static subreviews: [core](evidence/core-analysis.md), [integration](evidence/integration-analysis.md), [history](evidence/history-audit.md).
- Executable reproduction and logs: [frame-regression](evidence/frame-regression/append.rs), [test output](evidence/frame-regression/run.log), [three-binary driver](evidence/kvstore-process-check-2.py) and [result](evidence/kvstore-process-check-2/result.json); baseline [workspace tests](evidence/cargo-test-workspace.log).
- Source anchor groups: `lib.rs:311-370,646-894,906-1121,1124-1205,1233-1409,1467-1474`; `examples/kvstore/main.rs:79-334,342-414,526-585,683-750`.
- All six issues and four PRs were read in full; raw discussion/diff snapshots and 21-commit ancestry manifest are in `evidence/`. Closed fixes remain reference context.
- Paper §§2.1–2.2 (fault/quorum assumptions), 4.1–4.3 (protocol), 5.2 (transfer), 8 (correctness); retrieved PDF SHA-256 `1b16284a0a443d08992bd0fd0f032587e34e3e81f61f1871d39a4e4a6e22cfa6`.

# Code Analysis Report: databendlabs/openraft

## Incremental analysis: 2026-09-09 update

The source diff from `0f4e195474e4a902b391b99497bdbb3535b89749` to
`15f927e1358d41ffc1297516f781029dbf8ca86a` is protocol-relevant.
It does not introduce a new external Raft API, but it changes two atomicity
boundaries already modeled by Scenario 2:

- Append completion no longer queues `Notification::LocalIO` directly from the
  storage callback. `IOFlushed::io_completed()` updates a watch channel
  synchronously and preserves the first storage error (`openraft/src/storage/callback.rs:80-115`);
  `io_completion_forwarder()` later forwards the latest observed value to
  RaftCore (`openraft/src/raft/mod.rs:315-359`). Because OpenRaft's storage
  contract serializes write IO, a coalesced successful watch value dominates
  skipped intermediate append completions.
- Initialization now returns from `Engine::initialize()` after appending the
  initial membership (`openraft/src/engine/engine_impl.rs:190-205`). The core
  queues the initialize API response on the accepted IO flush and only then
  starts election (`openraft/src/core/raft_core.rs:697-726`), so the queue order
  is append, respond, save vote/send vote rather than append, save vote/send
  vote, respond.

Model impact: `base.tla` now has `ioWatch` and `ioForwarded`, a constrained
`IOCompletionForwarder` action, and update invariants in `Update.tla`. The
existing trace harness remains a narrow engine-level harness; it was rebased and
extended with a focused initialize/elect ordering scenario.

Validation feedback also required two model-side repairs: guard zero-index
prefix comparisons in `EngineHandleAppendEntries`, and cap
`RaftCoreRunCommandSaveCommittedAndApply` at `min(localCommitted,
submittedIO.log)`, matching `Engine::next_progress_driven_command()`.

## Scope and revision

This report records the four-phase `code-analysis` investigation used to produce `modeling-brief.md`.

- Repository: `databendlabs/openraft`
- Old source input: `0f4e195474e4a902b391b99497bdbb3535b89749`
- New source target: `15f927e1358d41ffc1297516f781029dbf8ca86a`
- Language/protocol: Rust / Raft
- Category: **A — Distributed / Message-Passing**. OpenRaft is crash-fault tolerant, not Byzantine, so the BFT overlay was not applied.
- Working tree at start: clean except pre-existing untracked `.codex/`; it was not modified.
- Target guidance: establish a reusable baseline, favor semantic depth in core transitions, and keep assumptions/gaps explicit.

## Executive conclusions

- The reusable baseline should center on five interacting mechanisms: crash/recovery and read admission; durability-before-ack; extended membership/session fencing; snapshot/membership/purge; and independent heartbeat/replication/read paths.
- The pinned source contains a confirmed Critical consensus-safety defect: snapshot install can retain an effective membership whose backing log is purged (#1808). Its later upstream fix is evidence, not a model target to recreate.
- Other exact-target defects include restored-leader read risk, transfer/read and transfer/freshness path inconsistencies, lost snapshot triggers, defensive/type panics, invalid transfer rollback, unbounded SM work, and unsafe numeric configuration boundaries. They are routed to model checking, tests, code review, or reference-only evidence according to verification value.
- A faithful model is still useful in the presence of implementation bugs, and a green workflow would not prove OpenRaft safe. The brief keeps observed behavior, environment assumptions, closed-fix evidence, and genuinely open questions distinct.

## Method and coverage summary

| Phase | Coverage | Result |
|---|---|---|
| Reconnaissance | 40,401 Rust lines under `openraft/src`; 17,210 non-test production lines in consensus/storage/membership/network paths | Mapped event loops, tasks, RPCs, persistence and atomicity boundaries |
| Git archaeology | 794 exact-head core-path commits scanned; 92 keyword-selected candidates reviewed | 47 substantive correctness/liveness fixes; 45 exclusions |
| GitHub archaeology | 337 issues existed by the target commit; 185 title/keyword candidates collected; 59 issues deeply read with all comments | 27 confirmed bugs, 13 design defects, 9 disputed/false, 8 user errors, 2 uncertain |
| Open PRs | All 8 live open PRs screened | One bug-fix-intent PR, #2075; it applies to target code |
| Deep analysis | RaftCore and public/core command paths read in full locally; three parallel full-file bundles covered Engine/vote, membership/quorum, and storage/replication/snapshot | Five model scenarios, current-head defects, compensating mechanisms and exclusions |
| Verification | `cargo test -p openraft --lib` | 307 passed, 0 failed |

The issue classification totals include two additional full-thread checks (#1747 and #1805) prompted by the deep read of leadership-transfer paths. “Excluded false positives” comprises 9 disputed/false reports plus 8 confirmed user/integration errors; design defects and uncertain reports are counted separately.

## Phase 1 — Reconnaissance

### Structural map

| Concern | Primary implementation | Observed boundary |
|---|---|---|
| Public API / task creation | `openraft/src/raft/mod.rs:294-438` | Builds channels; recovers storage before spawning RaftCore; state-machine and tick tasks are separate |
| Main state machine | `openraft/src/core/raft_core.rs:144-252`, `996-1073` | One event loop serializes API messages, notifications, and Engine command execution |
| Pure protocol transitions | `openraft/src/engine/engine_impl.rs:62-113` and `engine/handler/*` | Engine mutates expected in-memory state and emits commands; runtime performs I/O/network effects |
| Vote/election | `engine/handler/vote_handler/mod.rs`, `proposer/candidate.rs`, `vote/*` | Vote acceptance precedes `SaveVote`; response waits for the IOId to flush |
| Log replication | `openraft/src/replication/mod.rs:82-105` | One independent task per target; serialized payload RPCs; results return via notifications |
| Heartbeat | `openraft/src/core/heartbeat/worker.rs:26-49` | Separate per-target task and network client; watch channel may coalesce heartbeat events |
| Read validation | `openraft/src/core/raft_core.rs:255-445` | ReadIndex spawns a separate quorum task; LeaseRead uses quorum-ack send times |
| Membership | `raft_state/membership_state/mod.rs`, `membership/membership.rs`, `raft/api/management.rs` | Effective on log append, committed later; API may perform joint and uniform phases |
| Log store | `storage/v2/raft_log_storage.rs` | User implementation; all writes submitted by RaftCore; append durability reported by callback |
| State machine | `core/sm/worker.rs` | Apply/install serialized in one worker; snapshot build is spawned and may overlap |
| Snapshot transport/install | `network/snapshot_transport.rs`, `engine/handler/following_handler/mod.rs:230-302` | Chunk/session handling outside core; metadata acceptance, worker install, response and purge are distinct |
| Timers | `core/tick.rs`, leader lease fields | Independent tick task; election, heartbeat and lease time domains interact through notifications |

### Concurrency topology

The repository's own architecture documentation matches the code: RaftCore owns user request handling and all log-store writes; per-peer replication tasks only read storage and send RPCs; the state-machine worker owns apply/install; snapshot building is a short-lived separate task; and heartbeat workers are deliberately separate from replication (`openraft/src/docs/internal/threading.md:3-42`, `openraft/src/docs/internal/architecture.md:14-51`).

The key consequence for modeling is that a “Raft handler” is not atomic. Engine state can move ahead of durable state, independent workers can return stale results, and command conditions delay some effects while other API messages continue to be accepted.

### Atomicity map

| Operation | Logical transition | Durable/visible completion | Interleavings to preserve |
|---|---|---|---|
| Grant vote | `VoteHandler::update_vote` updates leased vote and accepted IO | `save_vote()` returns; LocalIO advances flushed; response condition is released | Crash after accept/before save; delayed vote response; higher vote from another task |
| AppendEntries | Engine accepts vote, checks previous log, truncates/extends logical log and membership | truncate is awaited; append callback reports flush; RPC response waits for accepted IOId | Conflicting leader RPCs, callback reorder, membership effective before durability |
| Leader append/commit | Leader assigns IDs and starts replication; quorum progress advances cluster/local commit | local append callback; `save_committed`; state-machine apply completion; client complete | Remote quorum may exclude local node; crash between saved commit and apply |
| Membership change | first membership entry becomes effective; API waits for apply, then may send NOOP flatten phase | membership log flush/commit/apply | Another caller or leader change between phases; stale session response |
| Snapshot install | in-memory snapshot, IO cursors and membership are accepted; worker install command queued | install response advances snapshot/apply/log progress; purge condition and RPC reply release | Append/vote requests while install barrier is pending; build completion; crash/purge |
| Snapshot build | `building_snapshot` set and command queued | detached builder returns metadata notification | Newer installed snapshot or policy trigger while build is running |
| Heartbeat/read | worker/task sends empty AppendEntries using captured vote/membership | RaftCore accepts fenced notification or read task reaches quorum | Message loss/reorder, membership/session change, higher vote, lease timing |
| Restart | helper reads vote/commit/log/SM/snapshot and may restore/replay | `Raft::new` returns only after helper, but leader role can be restored immediately when core starts | Persisted committed absent/stale, transient SM, old leader still recognized |

### Reference-algorithm deviations

| OpenRaft choice | Evidence | Modeling consequence |
|---|---|---|
| Default advanced LeaderId is total `(term,node_id)` order and permits successive leaders in one term | `docs/data/leader_id.md:1-38`; macro default at `raft/mod.rs:141-200` | Classic per-term ElectionSafety is conditional; model ordered vote plus committed bit |
| Persisted committed pointer | `docs/data/log_pointers.md:74-106` | Separate cluster commit, saved commit and applied; recovery depends on optional implementation |
| Persisted leader can resume without election | `docs/faq/02-core-concepts/01-differences-from-raft.md:3-7`; `engine_impl.rs:145-159` | Crash/recovery and read admission are first-class actions |
| Commit notification decoupled from AppendEntries | `docs/protocol/commit.md:115-180` | Vote-first synchronization and local-vs-cluster commit need explicit state |
| Heartbeats separated from replication | `docs/internal/architecture.md:30-39` | Independent send/result paths and session fencing must be modeled |
| Extended membership | `docs/data/extended-membership.md:1-18`; `membership.rs:268-330` | Effective/committed configurations and multi-step coherent transitions |
| ReadIndex plus LeaseRead | `raft/mod.rs:208-231`; `raft_core.rs:255-445` | Explicit quorum acknowledgments, read barriers and a negligible-clock-drift assumption |
| Async accepted/submitted/flushed IO | `raft_state/io_state.rs:23-72` | Split actions at I/O and notification boundaries rather than atomic RPC handlers |

## Phase 2 — Bug archaeology

### Git mining procedure

The exact-head history was searched across `core`, `engine`, `replication`, `raft_state`, `storage`, `membership`, `quorum`, `proposer`, Raft messages, and network paths. The initial history contained 794 commits. A word-bounded search for `fix`, `bug`, `race`, `panic`, `deadlock`, `correctness`, `crash`, `corrupt`, `leak`, `inconsistent`, `wrong`, `safety`, `hang`, and `overflow` produced 92 candidates. Every candidate was classified; full commit body/diff review was performed for each retained fix.

Hotspots among the 92 candidates were `core/raft_core.rs` (31 touches), `engine/engine_impl.rs` (22), `replication/mod.rs` (20), `core/mod.rs` (12), and `storage/helper.rs`, `membership/membership.rs`, `vote_handler`, and `replication_handler` (8 each).

### Significant core-history fixes (47)

| Commit | Severity | Root cause / effect |
|---|---|---|
| `2bdfae5d` | High | Per-cluster heartbeat predecessor plus reply reorder produced false log reversion and leader panic |
| `54ffb00d` | Medium | Heartbeat conflicts were not returned to core, so reverted followers were never retransmitted |
| `681d04da` | High | Restored sole leader did not advance commit/reapply durable logs |
| `94c820c3` | Critical | Equal observed vote was incorrectly inferred to be granted leadership |
| `ee460f37` | Critical | Vote/AppendEntries replies could precede durable IO completion |
| `b06cbb37` | High | Rejected RequestVote response could overwrite accepted vote state |
| `a9f696a9` | Critical | New leader no-op could be committed without the normal durable append path |
| `5c83e167` | Medium | Obsolete snapshot response waited on unrelated/nonexistent install completion |
| `946dc3f9` | Medium | Snapshot sender did not reset to offset zero after receiver session mismatch |
| `a9e2fc46` | Medium | Independent heartbeat results did not update RaftCore quorum-ack state |
| `5f262198` | Medium | Log-reversion feature retained an assertion that panicked on permitted reversion |
| `f4564fec` | Medium | Vote-derived leader state disagreed with membership-derived server role on restart |
| `86b46a08` | High | Restored leader did not restore its local replication progress |
| `d012705d` | High | Snapshot retry ignored replication shutdown and blocked membership rebuild/removal |
| `04e40606` | High | Restart with purged logs and nonpersistent snapshot left no snapshot for catch-up |
| `26dc8837` | High | Purge protection checked one point rather than overlap with an in-flight range |
| `54aea8a2` | Medium | Greater-log signal was lost across state transition, causing aggressive stale elections |
| `97fa1581` | High | Durable blank heartbeats conflicted with snapshot receive and timing needs |
| `c8fccb22` | High | `add_learner` bypassed the one-outstanding-membership guard |
| `a80579ef` | High | Delayed replication progress entered leader-only handling after stepdown |
| `9dbbe14b` | High | Linearizable-read path swallowed fatal storage failure as an API result |
| `95437748` | Medium | Replication repeatedly selected logs scheduled for purge and could block purge forever |
| `cc8af8cd` | High | Startup conflated no purge with log-zero purged |
| `bc1bfdf8` | High | Snapshot selected before an adequate snapshot existed for follower catch-up |
| `c99782d3` | Medium | Metrics recomputed Leader from vote after startup forced Follower |
| `ff9a9335` | High | Restart exposed Leader role before leader-only internal state existed |
| `0023cff1` | High | Removed leader stepped down before disseminating membership commit |
| `56486a60` | High | Replication rebuild reset preserved matching progress and later regressed/panicked |
| `e4036a0f` | High | Higher-vote handling differed across snapshot/read/replication paths |
| `674e78aa` | Critical | Snapshot installed before conflicting logs were durably removed |
| `71a290cd` | High | Restarted committed/applied mismatch made purged predecessor look conflicting |
| `43dd8b6f` | Medium | Stepdown abandoned client response channels |
| `59ddc982` | Medium | Learner readiness synthesized illegal LogId from absent matching state |
| `8594807c` | Medium | Replication metrics published before internal progress/commands were coherent |
| `941a5add` | High | `allow_lagging` bypassed learner existence and could promote an absent node |
| `918b48bc` | High | Backward membership scan duplicated newest entry and lost previous committed config |
| `ddb07fb9` | Medium | Purging an empty LogIdList indexed absent boundaries and panicked |
| `7605fa86` | Medium | Tracing span guard crossed await in replication loop and leaked async context/resources |
| `a5064712` | Critical | Singleton fast commit ignored that a membership entry changed the quorum |
| `d5c2c55c` | High | Membership effective state was not promoted when its log committed |
| `797fb9b1` | Medium | Metrics said replication stopped before removed task actually joined |
| `ea14fdd0` | Medium | Commit-only/new work could wait for another heartbeat instead of continuing replication |
| `1219a880` | High | Cached replication log bound diverged from authoritative storage state |
| `4015cc38` | High | Candidate seeing higher vote did not always step down immediately |
| `86e2ccd0` | High | Singleton self-vote was never evaluated because no peer response arrived |
| `1a781e1b` | High | Catch-up could send a snapshot older than already-purged logs |
| `8651625e` | Medium | Higher-term AppendEntries saved term but discarded known legal leader identity |

The 45 exclusions comprised 12 documentation/comment/format changes, 11 lint/toolchain/type-only changes, 8 metrics/observability-only changes, 6 test-only changes, 5 API/performance changes, and 3 ambiguous fixup commits without an independent protocol effect. Stable patch-ID comparison found no exact duplicate among the 92 candidates; release-branch cherry-picks were not double-counted.

### GitHub collection and verification

Multiple searches covered bug labels and bug/fix/panic, race/deadlock/crash, safety/correctness/data loss, snapshot, election/vote/leader, replication/log, membership/quorum, and storage/recovery terms. All comments and linked fixes were read for each of the 59 deeply reviewed issues. The compact audit below records the final classification and target disposition.

| Issue | Classification | Exact-target disposition | Mechanism |
|---:|---|---|---|
| 1500 | Confirmed | Fixed in target | Heartbeat/replication reply reorder |
| 1467 | Disputed/false | Intentional | Persisted leader briefly resumes; role metric is not quorum health |
| 1329 | Uncertain | Docs improved; no bug proven | Election/test environment |
| 1246 | Confirmed | Fixed in target | Sole-leader restart replay |
| 994 | User error | Invalid duplicate IDs/divergent bootstrap | Identity/membership |
| 920 | Confirmed | Fixed in target | Vote × membership role inconsistency |
| 898 | User error | Unsafe voter data wipe | Durability assumption |
| 597 | Design defect | Implemented | Retained non-voter leader transition |
| 58 | Confirmed | Fixed, test-only | CI election timing |
| 54 | Confirmed | Fixed in target | Replication loop failed to continue pending work |
| 1429 | Disputed/false | Network fault | Stale candidate under partition |
| 883 | Confirmed | Fixed in target | Restored self replication progress |
| 452 | Design defect | Fixed in target | Greater-log election backoff |
| 357 | Design defect | Fixed in target | Same greater-log backoff mechanism |
| 231 | Confirmed | Fixed in target | Commit-only replication wakeup |
| 96 | Design defect | Fixed in target | Persist known leader on AppendEntries |
| 1722 | Disputed/false | Claimed advanced-ID state unreachable | LeaderId/log ordering |
| 1872 | Confirmed | **Vulnerable target; later fixed** | Standard LeaderId `None` comparison panic |
| 1511 | Design defect | **Live boundary at target; later opt-out mitigation** | Fast leader restore vs transient SM/read |
| 1252 | User error | Invalid store callback ordering | Storage contract |
| 927 | User error | Voter data erased | Durability assumption |
| 912 | Confirmed | Fixed in target | Snapshot metrics before durability |
| 833 | Confirmed | Fixed in target | Replication backoff deadlock |
| 702 | Design defect | Storage API redesign present | Persistence API |
| 607 | Confirmed | Fixed, later superseded | Restart leader internal state |
| 596 | Confirmed | Fixed in target | Snapshot build blocked apply |
| 235 | Confirmed | Fixed in target | Snapshot final-chunk/session retry |
| 216 | Confirmed | Fixed in target | Cached replication range |
| 1261 | Design defect | Fixed in target | Startup key-log lookup API |
| 1260 | Disputed/false | Existing retention/manual purge | Snapshot retention |
| 1249 | Disputed/false | Existing startup wait when commit saved | Recovery expectation |
| 1096 | Confirmed | Fixed, low | Normal shutdown logged as error |
| 1051 | User error | Wrong network error class | Backoff contract |
| 983 | Disputed/false | Version/API question | Snapshot API |
| 826 | Uncertain | Reporter withdrew | User snapshot implementation |
| 1544 | User error | Frozen reader violated visibility | Storage reader contract |
| 1601 | Confirmed | **Vulnerable target; later fixed** | Empty limited read causes panic |
| 1780 | Disputed/false | Assert intentional under contract | Apply reader completeness |
| 1395 | Design defect | **Open/unfixed at target** | Concurrent retain/mixed membership Batch |
| 1336 | Design defect | Open/partly optimized | State-machine scheduling pipeline |
| 1330 | User error | Wrong retry error / 2-node quorum | Network integration |
| 1242 | Confirmed | Fixed in target | Uninitialized membership unwrap |
| 1130 | Disputed/false | Informational question | SM/snapshot concurrency contract |
| 808 | Confirmed | Fixed in target | Snapshot retry prevented replication shutdown |
| 584 | Confirmed | Fixed in target | Progress reset on membership rebuild |
| 550 | Confirmed | Fixed example workaround | TLS setup exceeded tiny RPC timeout |
| 471 | Confirmed | Fixed in target | Absent learner matching state panic |
| 462 | Design defect | Backoff taxonomy implemented | Network failure behavior |
| 1192 | Disputed/false | Docs misunderstanding | Retain existing learners |
| 923 | Design defect | Fixed in target | Non-member leader role consistency |
| 918 | User error | Wrong NodeId→address mapping | Identity trust boundary |
| 875 | Design defect | Unsafe `SetNodes` API added intentionally | Endpoint identity |
| 846 | Confirmed | Fixed in target | Blocking add-learner timeout |
| 608 | Design defect | Old-release limitation fixed | Learner persistence |
| 424 | Confirmed | Fixed in target | Duplicate startup membership scan |
| 1808 | Confirmed | **Vulnerable target; later fixed** | Snapshot purge retains stale effective membership |
| 1829 | Confirmed | **Vulnerable target; later fixed** | In-flight build loses policy trigger |
| 1747 | Confirmed | **Vulnerable target; later fixed** | Transfer path lets reads bypass write gate |
| 1805 | Confirmed | **Vulnerable target; later fixed** | Lagging transfer target starts invalid candidacy/panics |

### Open pull requests

All eight live open PRs were screened. Only #2075 had bug-fix intent. Its full body, sole comment, commit and diff were read. Target `SnapshotPolicy::should_snapshot()` performs `base_log_id.next_index() + threshold` with an unconstrained user `u64` (`openraft/src/config/config.rs:41-63`); #2075 changes this to `saturating_add`. The target is affected. Impact is excessive snapshot creation or debug overflow panic under extreme configuration, so it is test/code-review work rather than a protocol model target.

## Phase 3 — Deep analysis

### Verified target findings

| ID | Severity | Status | Verified implementation path and impact | Disposition |
|---|---|---|---|---|
| CA-1 | Critical safety | Confirmed #1808; later upstream fix absent | Snapshot install only truncates when a local entry exists and conflicts, then `update_committed_membership()` refuses to replace a higher-index stale effective config even if purge removes its backing log (`following_handler/mod.rs:249-300`, `membership_state/mod.rs:92-126`). A later election can use a phantom/disjoint quorum and lose committed entries. | Scenario evidence; model snapshot/membership backing generally, do not recreate closed fix |
| CA-2 | High read consistency | Design defect #1511; later opt-out absent | Recovery may have no saved committed pointer, restore a transient SM only to snapshot, then immediately recreate Leader from persisted vote (`storage/helper.rs:87-148`, `engine_impl.rs:145-159`). A read barrier can race re-confirmation/replay. | Scenario 1; MC-1 asks the documented-read generalization |
| CA-3 | High safety/liveness | Confirmed #1747; later fix absent | Write path rejects while `transfer_to` is set (`raft_core.rs:497-516`), but read path only checks leader role (`:267-303`). LeaseRead may serve stale state; repeated ReadIndex probes can keep follower leases alive and prevent recovery when target is unreachable. | Closed-fix reference; leadership transfer excluded from baseline V1 |
| CA-4 | High availability | Confirmed #1805; later fix absent | Transfer target wait times out but still submits transfer (`raft/api/protocol.rs:144-191`); receiver calls `elect()` without the external-elect voter guard (`raft_core.rs:1373-1397`); self grant expects membership progress entry (`proposer/candidate.rs:92-99`). Lagging promoted learner can panic. | Closed-fix reference/test candidate |
| CA-5 | High liveness/resource | Confirmed #1829; later fix absent | Routine action records `snapshot_tried_at` before knowing trigger was accepted (`raft_core.rs:737-747`); handler rejects during build (`snapshot_handler/mod.rs:28-44`); completion never repairs marker (`engine_impl.rs:524-565`). Quiescence can leave snapshot/purge behind indefinitely. | Regression test; liveness state belongs in Scenario 4 |
| CA-6 | High defensive availability | Confirmed #1601; later fix absent | Replication unconditionally unwraps first/last of `limited_get_log_entries` (`replication/mod.rs:364-368`). Invalid storage violates the nonempty contract, but OpenRaft crashes rather than containing it. | Storage conformance plus robustness test; not valid-system model behavior |
| CA-7 | Medium availability | Confirmed #1872; later fix absent | Standard LeaderId exposes `voted_for: Option`, `node_id()` unwraps it, and equal-term comparison reaches the unwrap. Public/malformed legacy state can panic. | Property/code-review fix; do not model invalid representation |
| CA-8 | High API/transition semantics | Open #1395 | `change_membership()` returns to caller task between joint and flatten phases (`raft/api/management.rs:61-124`); another request with different `retain` can change the base, so completion order rather than request intent determines retained learners. Mixed voter/node Batch can fail validation mid-transition. | Scenario 3 and deterministic test; MC-2 explores additional crash/leader/snapshot composition |
| CA-9 | Low/Medium resource | Open PR #2075 | User threshold addition can overflow at `config/config.rs:55`; no validation bounds it (`:406-425`). | Unit test / saturating arithmetic |
| CA-10 | Low observability | New, directly confirmed | `Notification::ReplicationProgress` display maps `has_payload=true` to `no-payload` and false to `has-payload` (`core/notification.rs:114-116`). | Code-review-only fix and display test |
| CA-11 | Low API docs | New, directly confirmed | Public docs say missing `allow_next_revert` target is ignored (`raft/trigger.rs:97-108`), but handler returns `NodeNotFound` (`replication_handler/mod.rs:233-245`). | Align docs/behavior |
| CA-12 | Low numeric robustness | Code-review candidate | Purge threshold adds `last_purged.next_index() + batch_size` without saturation (`log_handler/mod.rs:92`); config validation does not bound the user value. | Audit with #2075; not a distributed model target |
| CA-13 | High for narrow configured types | New, directly confirmed | Every built-in `RaftTerm`, including `u8/i8`, implements `next()` as unchecked `self + 1` despite the trait requiring strict growth (`vote/raft_term/raft_term_impls.rs:3-19`, `raft_term/mod.rs:20-23`). At max, debug panics; release wraps, vote update rejects, and `Engine::elect()` unwraps that error (`engine_impl.rs:213-226`). | Boundary property test; default `u64` risk is practically remote |
| CA-14 | High availability | Verified; later fix absent | Manual `Trigger::elect()` on the current leader lacks the timer path's leader guard (`raft/trigger.rs:41-47`, `raft_core.rs:1390-1394`). It creates a newer candidate vote while preserving old `leader.committed_vote`; debug invariant later panics and release can keep stale proposer state. | Later fixed upstream; historical path-inconsistency evidence |
| CA-15 | High availability | Verified; later fix absent | Heartbeat acknowledgments refresh `Leader.clock_progress`, but incoming VoteRequest consults only the separate local `state.vote` lease (`proposer/leader.rs:66-79,199-231`, `engine_impl.rs:298-306`). After local lease expiry, a one-way-isolated follower can depose a still quorum-backed leader. | Later fixed upstream; Scenario 5 lease-state evidence |
| CA-16 | High liveness | Verified; later fix absent | Transfer first marks `transfer_to`, disables writes/heartbeat, then broadcasts detached per-voter transfer RPCs (`leader_handler/mod.rs:119-130`, `raft_core.rs:1222-1267`). Target can campaign before another voter receives lease-disable authorization, fail once, and never retry when election is disabled. | Later fixed upstream; closed-fix reference |
| CA-17 | High conditional liveness | New, no guard/rollback found | `transfer_leader(to)` validates neither self/non-voter targets nor delivery, while broadcasts skip self and only iterate voters (`engine_impl.rs:634-647`, `raft_core.rs:1222-1228`). `transfer_to` has no abort path; invalid/lost target can disable writes and heartbeats indefinitely. | Deterministic validation/rollback tests; leadership transfer remains outside baseline V1 |
| CA-18 | High core responsiveness | Verified; later fix absent | Membership rebuild awaits every old replication task inline before spawning replacements (`raft_core.rs:875-897,1937-1952`). A pending RPC observes channel closure only after timeout, so core can stall sequentially across targets; session fencing protects safety but not responsiveness. | Later detach fix is reference; model workers as independent |
| CA-19 | Medium API availability | New, later fix absent | On an uninitialized node, `AddNodes` passes equal committed/effective `None`, leaves voter configs empty, then `Membership::change()` unwraps `configs.pop()` before leader rejection (`change_handler.rs:31-58`, `membership.rs:315-376`). `add_learner()` reaches this path (`raft/api/management.rs:127-143`). | Focused regression/code review; later upstream fix exists |
| CA-20 | Low provenance/model fidelity | Verified; later fix absent | Initialization assigns the first membership `LogId::default()` rather than the actual initializing node's leader ID (`engine_impl.rs:190-203`). Ordering remains safe because the next election is above term zero, but proposer provenance is wrong. | Later upstream correction is reference only |
| CA-21 | High snapshot-transfer liveness | Verified; later fix absent | Chunked sender retries timeout, network, unreachable and remote-fatal results forever against the same snapshot with a fixed 1 ms delay (`network/snapshot_transport.rs:63-147`). It cannot refresh a stale snapshot while this loop is active. | Later bounded/stale-snapshot fix is reference; transport regression test |
| CA-22 | Medium local liveness | New, directly confirmed | `snapshot_max_chunk_size=0` passes `Config::validate`, but chunking repeatedly reads/sends an empty non-final chunk without advancing offset (`config/config.rs:202-204,405-425`, `network/snapshot_transport.rs:78-89,161`). | Reject zero in validation; boundary test |
| CA-23 | Medium resource/liveness | New, directly confirmed | `SnapshotPolicy::LogsSinceLast(0)` passes parsing/validation and is always eligible; each completion can immediately trigger another build (`config/config.rs:42-60,76-100`, `raft_core.rs:1069-1072`). | Define zero semantics or reject; boundary test |
| CA-24 | Critical conditional safety | Verified outside baseline | With `allow_log_reversion`, a heartbeat conflict resets matching but leaves a payload inflight; a delayed same-session payload success can then restore false matching/quorum (`progress/entry/update.rs:45-106`, `progress/inflight/mod.rs:104-120`). Independent heartbeat and replication clients make the reorder feasible. | Later stale-ACK fix is reference; baseline explicitly excludes log reversion |
| CA-25 | High resource availability | Verified design defect | RaftCore sends SM commands through unbounded MPSC (`core/sm/handle.rs:15-30`, `core/sm/worker.rs:58-76`), while the worker serially awaits slow application apply/install work (`worker.rs:98-220`). Sustained commit production can outrun consumption and grow memory without bound. | Load/backpressure test; post-target bounded-channel change is reference |
| CA-26 | Low API robustness | New, directly confirmed | Public `StorageHelper::new()` leaves `id=None`, and fresh-store `get_initial_state()` unwraps it if `with_id()` was omitted (`storage/helper.rs:61-94`). Internal `Raft::new()` supplies ID correctly. | Require ID in constructor or return/document error |

CA-1, CA-3 through CA-7, CA-14 through CA-16, and CA-18 through CA-20 are already fixed in later upstream history. Per the methodology, they are not §6.1 answer-key adversaries. They remain material exact-target findings and evidence that the surrounding mechanisms must be represented faithfully.

### Compensating mechanisms and excluded false positives

| Suspicion | Verification result |
|---|---|
| Heartbeat conflict unwraps `matching=None` | Excluded: follower `ensure_log_consecutive(None)` cannot return conflict, so the unwrap precondition holds (`heartbeat/worker.rs:130-146`, `following_handler/mod.rs:115-134`). |
| Conflict/PartialSuccess counts as a ReadIndex acknowledgment | Excluded: vote is accepted before log-consecutiveness checks; any non-HigherVote response proves the peer recognized this leader for the read's linearization point (`engine_impl.rs:443-457`). |
| Async read task can return after local stepdown | Excluded as a direct bug: acknowledgments sent during the operation define a legal earlier linearization point; MC-3 retains the harder membership/session composition question. |
| Snapshot metadata/membership advances before install durability | Compensated: install command is queued before purge; non-response commands block the command queue on `Condition::Snapshot`, and the RPC response is separately held until snapshot progress (`following_handler/mod.rs:285-302`, `engine_output.rs:42-80`). |
| Old replication/heartbeat progress mutates a new leader or configuration | Compensated: every progress carries committed leader vote and membership log ID; core rejects mismatched sessions (`raft_core.rs:1742-1762`). |
| Out-of-order LocalIO notification regresses progress | Compensated under the store contract: `try_flush` is monotonic and later durable operations imply earlier ordered writes (`io_progress.rs:123-190`, `raft_log_storage.rs:26-31`). |
| `is_leader()` after restart proves active quorum leadership | Excluded: #1467 establishes this is intentionally local persisted-role state; applications must consult quorum-ack freshness or execute a read barrier. |
| Advanced LeaderId can create a short higher-node-ID log that beats a long same-term log (#1722) | Excluded: later same-term leader starts at prior last index + 1, so the hand-built counterexample state is unreachable (`proposer/leader.rs:116-127`). |
| Short `entries_stream` is contract-compliant (#1780) | Excluded: once append returns, every reader must see appended entries (`raft_log_storage.rs:88-102`); the target docs were ambiguous, but the alleged valid trigger is not. |
| Follower/voter storage wipe should auto-recover (#898/#927) | Excluded: erasing acknowledged voter state violates the Raft durability model; `allow_log_reversion` is an explicit unsafe/testing escape hatch. |
| Wrong NodeId→endpoint map should be detected (#918/#994) | Excluded: the application owns stable identity and routing; model assumes an injective correct binding. |
| Joint quorum can count duplicate voter IDs | Excluded: the generic helper does not deduplicate, but every production caller supplies BTreeSet grants or one Progress entry per unique node. |
| Empty Joint vacuously satisfies quorum | Excluded: role checks prevent candidate/leader construction for empty effective membership; CA-19 is the actual reachable pre-validation failure. |
| Multiple membership entries can reach the leader's one-per-batch debug assertion | Excluded: all production callers reviewed submit one membership entry or controlled internal batches; no reachable multi-membership payload path was found. |
| Physical purge runs before snapshot installation | Excluded: `PurgeLog` waits on `Condition::Snapshot`, which is released only after install completion advances snapshot-flushed progress (`engine/command.rs:256,291-323`, `raft_core.rs:1606-1621`). |
| Old background snapshot build can regress Engine metadata | Excluded: build completion uses monotonic progress and `SnapshotHandler::update_snapshot()` rejects older metadata (`engine_impl.rs:533-565`, `snapshot_handler/mod.rs:53-67`). |

### Scenario synthesis

1. **Restored leadership before application recovery** — crash + persistent vote + optional commit persistence + transient SM + read barrier.
2. **Persistence-before-ack pipeline** — accepted/submitted/flushed IO, decoupled commit, saved commit, apply and response ordering.
3. **Extended membership transaction/session fencing** — effective/committed configs, joint/uniform API phases, concurrent intent, stale replication sessions.
4. **Snapshot/membership/purge lifecycle** — build/install progress, membership backing, purge barriers, recovery.
5. **Independent heartbeat/replication/read paths** — delayed messages, lease timing, ReadIndex quorum and session fences.

Priority was based on severity, history density, unresolved target behavior, and TLA+ suitability. Local panics, numeric overflow, logging, invalid adapters, and known leadership-transfer fixes were routed to testing/code review rather than expanding the first model.

## Phase 4 — Handoff details

### Model and trace state

The spec/harness should expose at least:

- node, role, live/crashed, vote `(leaderId, committed)`, and vote durability;
- logical and durable log IDs/entries, accepted/submitted/flushed IOId;
- cluster/local/saved committed, apply submitted/applied, and completed client operations;
- committed/effective membership log IDs, voter sets, learner/node set, change request ID/phase/retain intent;
- replication target, session `(leader vote,membership log)`, matching, conflict, inflight kind;
- snapshot accepted/submitted/flushed, snapshot membership, build-in-progress, tried-at, purge target/durable purge;
- heartbeat/read send time, response kind, ack set, quorum-acked time, read policy and barrier.

Recommended trace event names are `VoteAccepted`, `VoteFlushed`, `AppendAccepted`, `AppendSubmitted`, `AppendFlushed`, `CommitAdvanced`, `CommitSaved`, `ApplySubmitted`, `Applied`, `MembershipAppended`, `MembershipCommitted`, `ReplicationSessionStarted`, `ReplicationProgress`, `HeartbeatSent`, `HeartbeatAcked`, `ReadBarrier`, `SnapshotTrigger`, `SnapshotBuilt`, `SnapshotInstallAccepted`, `SnapshotInstalled`, `PurgeScheduled`, `Purged`, `Crash`, and `RestartRecovered`.

### Harness scenarios for later phases

1. Persist leader vote and logs, vary saved committed and transient/persistent SM, restart, then issue immediate ReadIndex and LeaseRead.
2. Pause one membership caller after joint commit, run a second with a different `retain`, add leader crash/change and resume both.
3. Crash at each boundary among saved commit, apply, snapshot install, and purge; assert recovery retains a source for every committed entry.
4. Delay heartbeat/read acknowledgments across leader and membership-session changes; assert stale sessions cannot establish a lease/read quorum.
5. Vary advanced/standard LeaderId, leader restoration, and effective-membership versions while reordering replication and commit-only responses.
6. For conformance tests only: misorder callbacks, freeze a reader, return empty limited reads, and verify clear failure rather than protocol-model behavior.

### Environment assumptions

- Stable unique node IDs and correct NodeId→endpoint mapping.
- Crash faults only; no Byzantine messages or silent disk corruption.
- Acknowledged vote/log writes survive crash; store write completion order and immediate cross-reader visibility satisfy the documented traits.
- Network may lose, duplicate, delay and reorder RPCs, but does not forge identities/content.
- Monotonic clocks have negligible drift for LeaseRead; otherwise only ReadIndex claims strong consistency.
- State-machine `apply` processes the provided committed stream in order and records log ID/membership as documented.
- `allow_log_reversion` is disabled in the baseline.

### Remaining gaps and confidence limits

- The library unit suite passed, but the full workspace/integration/turmoil/Jepsen suites were not run; archaeology supplied exact regression evidence for those paths.
- The analysis used live GitHub discussions through 2026-09-07. Post-target issues were included only after checking the vulnerable code and fix ancestry against the pinned head.
- The 59 deeply read issues substantially exceed the methodology target but are not every one of 337 historical issues; all 185 keyword candidates were collected and triaged by title before deep selection.
- Reference comparison focused on the Raft paper/local summary and OpenRaft's documented deviations; no sister implementation was audited.
- The initial model should not claim proof of safety. It should establish a faithful baseline, record checked configurations, and leave unsupported feature combinations visible.

## Reference pointers

- Primary handoff: `modeling-brief.md`
- Raft summary: `source/raft-essentials.md`
- Architecture: `source/openraft/src/docs/internal/architecture.md`, `threading.md`
- Core: `source/openraft/src/core/raft_core.rs`
- Engine: `source/openraft/src/engine/engine_impl.rs`, `source/openraft/src/engine/handler/`
- Storage/recovery: `source/openraft/src/storage/helper.rs`, `source/openraft/src/storage/v2/`
- Membership/quorum: `source/openraft/src/membership/`, `source/openraft/src/raft_state/membership_state/`, `source/openraft/src/quorum/`
- Replication/heartbeat: `source/openraft/src/replication/`, `source/openraft/src/core/heartbeat/`
- Snapshot/state machine: `source/openraft/src/network/snapshot_transport.rs`, `source/openraft/src/core/sm/`

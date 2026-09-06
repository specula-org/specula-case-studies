# Code Analysis Report: vsr-rs

## 1. Result and scope

The primary handoff is [modeling-brief.md](modeling-brief.md): four mechanism-based Scenarios and five unresolved model-checkable questions about historical preservation, sequential execution/replies, and conditional service/recovery progress. This review does **not** establish a new multi-replica protocol safety failure. It identifies a statically verified singleton progress gap, independent example integration obligations, and precise limits in the existing assurance. Runtime consequences of the new candidates remain untested.

**Pinned source:** `3ac0104a567092139534c9022205d02281a2da41`, at `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/source`. All unqualified source locations below refer to that revision. **Retained Lean source:** `de1a84376afe1102c197c2e0f4ade41eb4494458`; it is supporting evidence, not the analyzed branch. GitHub discussions were fetched live on 2026-09-05. The source is experimental and does not claim production deployment (`README.md:13-14`). No production incidence is inferred.

**Category A — Distributed / Message-Passing.** VSR replicas exchange messages and rely on caller-provided storage/timing. The applicable threat model is authentic messages and crash failures, not Byzantine behavior. Primary scope is fixed-membership `lib.rs`; secondary scope is the shipped key-value example. No membership protocol or checkpoint implementation was inferred from the paper.

**Validation:** `cargo test --workspace` passed at the pinned source: 16 integration tests and 5 simulator tests, zero failures. [Full log](audit/baseline-tests.log). This is a baseline regression result, not exhaustive protocol verification. No new simulator search, failing reproduction, TLA+ model, or proof run was performed. Consequently no simulator-reproduced new bug triggered the repository's regression-test/seed/commit requirement.

## 2. Method, coverage, and provenance

Read the installed `code-analysis/SKILL.md` in full and followed its `guide.md`, `references/deep-analysis.md`, `distributed-analysis.md`, `bug-archaeology.md`, `modeling-brief-format.md`, and complete example. Category B and the BFT overlay do not apply. The user authorized all four phases; no intermediate phase approval was required.

1. **Reconnaissance:** classified the system, pinned HEAD, checked dirty state, read the public contract, mapped modules and atomicity boundaries.
2. **Archaeology:** searched all required fix/bug/race/panic/deadlock/correctness/crash/corrupt/leak/inconsistent/wrong keywords, catalogued non-keyword commits, read complete issue/PR discussions and diffs, and compared historical implementations with current code.
3. **Deep analysis:** full-file reads split across protocol, example, and simulator/Lean reviewers. All findings were checked against exact callers, guards, retries, historical intent, and contract constraints. Cross-review corrected historical attribution and prefix-direction mistakes before finalization.
4. **Synthesis:** grouped by mechanism, separated model/test/review work, and contained historical fixes in evidence/reference context. No new MC entry asks to undo an existing correction.

| Coverage population | Completed coverage |
|---|---|
| Local Git history | All 21 commits catalogued; target ancestry has 6. Repository is non-shallow. |
| Local protocol/test core changes | 5 using the historical review's explicit path set (`lib.rs`, tests, simulator, verify); includes 2 post-target Lean verification additions. Example introduction was reviewed separately in full. |
| Recovered original history | All 116 commits reachable from the retained original Lean revision catalogued; full commit JSON/file patches retained. 83 touch the defined historical core; 26 match keywords. |
| Substantive historical protocol corrections | 15 implementation commits reviewed: 13 direct fixes plus 2 feature completions addressing demonstrated missing-protocol failures. All incorporated into target. Merge duplicates are not counted twice. |
| Additional historical assurance corrections | 2 simulator/oracle corrections; measurement/viewer/reproducibility changes separately classified in [history audit](audit/history.md). |
| Public issues collected / deeply read | 6 / 6, the complete public issue population: #1, #4, #5, #7, #8, #9. The project does not have 30 issues to read. |
| Public PRs collected / deeply read | 4 / 4: #2, #3, #6, #10. All review/inline-comment endpoints read; all were empty. All full diffs read. |
| Open bug-fix PRs | 1 / 1, PR #10; body, one owner comment, both commits and complete diff reviewed. |
| Issue dispositions | 2 bug-report records (#4 fixed; #9 open/code-supported), 2 acknowledged historical design gaps (#7/#8 resolved), 2 testing architecture requests (#1/#5). Zero debunked bug reports or user-error reports. |
| PR dispositions | #2 merged bug correction; #10 open proposed correction of existing concerns; #3 CI-only; #6 closed/unmerged incomplete feature. Records overlap mechanisms and are not additional distinct bugs. |
| Full pinned files | Protocol `lib.rs` (1,476 lines); example main (764) and README (40); 12 simulator/test/script/README files (3,370 lines). The simulator viewer is excluded as presentation code; its fault semantics are in the fully read simulator library. |
| Retained assurance files | 11 Lean/model/conformance files, 2,783 lines, archived with hashes; no claim that all proof support files were re-proved or fully audited. |

Issue collection used exhaustive all-state enumeration, bug-label filtering, and a combined bug/fix/crash/correctness/recovery/liveness keyword query. Keyword and label results were subsets of the complete six-issue population. Two agents read issue/PR batches concurrently while the protocol and assurance review proceeded independently; the small population did not justify fictional 5–10 issue batches.

The local history was rewritten: its initial commit already contains extensive protocol corrections. Original SHAs mentioned in discussions were absent locally. The retained immutable branch supplied a recoverable 116-commit original ancestry. Original `lib.rs` versus local initial source differs only in import formatting; original tests differ only in rustfmt; original properties equal the local simulator addition. The target then changes vote/DVC vocabulary without protocol behavior changes. Exact mapping and hashes are in [history adoption evidence](audit/history-evidence/original-source-identity.json) and [diff](audit/history-evidence/original-to-local-initial.diff). These populations must not be summed into “137 unique development commits.” Unreachable historical objects beyond the recovered chain remain outside the claim.

Initial and final Git status contain only pre-existing untracked `.codex/`. Tracked source was unchanged; no commit, push, PR edit, issue comment, or other external write occurred. Source/evidence fingerprints are in [audit-manifest.json](audit/audit-manifest.json).

## 3. Structural map and protocol obligations

### 3.1 Modules and atomicity

| Component | Implementation | Atomicity / interaction |
|---|---|---|
| Configuration and protocol data | `lib.rs:63-269` | Fixed ID list, majority quorum, primary from view modulo membership; 11 Message variants plus separate Reply |
| Client proxy | `lib.rs:272-377` | Caller-serialized pending request; cached latest view; retry to all replicas |
| Replica state and dispatch | `lib.rs:379-641` | `&mut self` serializes each handler; Recovering ignores all except recovery responses |
| Replication and state transfer | `lib.rs:644-900` | Log/client table/acks/application updated synchronously; outputs buffered |
| View changes and catch-up | `lib.rs:903-1122` | Latest-normal-view/length selection; protected prefix retained; uncommitted suffix may change |
| Recovery | `lib.rs:1124-1215` | Fresh constructor state plus supplied durable view; collects responses before participation |
| Timers and application helpers | `lib.rs:1217-1414` | Idle drives retry/heartbeat/view timeout; application is invoked synchronously in log order |
| Example integration | `examples/kvstore/main.rs:342-750` | Peer readers, client threads, sender, and timer feed one owner event loop; filesystem/output operations are separate stages |
| Simulator | `simulator/lib.rs:694-978`, `network.rs:147-225` | Shared ticks batch faults, idle calls and delivery; properties observe after the batch |

The library has no internal disk calls, threads, locks, or independent asynchronous apply loop. A TLA+ action should preserve the synchronous handler boundary. The caller then publishes the view durably and releases outputs; these are distinct crash boundaries. A state-losing reboot discards the local application, client/ack tables, and unreleased outputs. Already released authentic messages can survive in the network. A retained-state pause resumes the same object instead of calling recovery. Do not introduce persistence of the entire log, or a crash that retains arbitrary half-updated volatile helper state, as if either were implemented (`lib.rs:14-21`, `478-524`; `simulator/lib.rs:610-625`, `694-708`).

### 3.2 Milestones are different obligations

| Milestone | Exact implementation | Obligation and limit |
|---|---|---|
| Client invocation | `Client::on_request`, `lib.rs:312-326` | Allocate request number, record pending input; this is not a service commit. One outstanding is a caller precondition. |
| Primary acceptance | `on_request`, `lib.rs:658-693` | Append identity/input and self acknowledgement; one replica's acceptance does not make an arbitrary suffix permanent. |
| Backup preparation / acknowledgement | `on_prepare`, `lib.rs:708-730`; `send_prepare_ok`, `1381-1387` | Backup acknowledges its whole current prefix. The emitted promise is historical evidence; delivery to the primary is separate. |
| Primary observes quorum | `on_prepare_ok`, `lib.rs:743-765` | Distinct replica IDs complete the operation's acknowledgement set; the prefix is committed in order. The cumulative acknowledgement's prefix premise must hold. |
| Application execution | `commit_op`, `lib.rs:1362-1376` | Apply the next entry, advance commit count, cache latest matching result. No application-level idempotence is required for ordinary prefix execution. |
| Reply production / acceptance | `lib.rs:1352-1354`, `663-670`, `334-347` | Reply may be duplicated/re-sent. A matching pending request completes at the client; it must have the sequential result for that logical request. |
| Replica reconstruction | `lib.rs:1201-1205` | Replay committed prefix into the caller-supplied application without sending recovery replies. Reapplying an old slot to rebuild lost local state is not a new logical service operation. |

The primary model needs independent history by `(clientId, requestNumber)`, operation payload, and log position. A simulator `op.id` is observer/workload metadata, not the library's protocol identity. Two distinct requests may have equal payloads. A request may be accepted at a position later replaced before commitment. Compatible common initial application state is required; `Replica::recover` accepts an arbitrary `SM` and does not reset it itself (`lib.rs:511-518`).

### 3.3 Handler cross-checks and compensating mechanisms

| Path | Verified guards and actions | Cross-path obligation |
|---|---|---|
| Request | Normal designated primary only; older requests discarded, latest cached reply resent (`lib.rs:651-673`) | Client table must remain consistent with the selected log and pending-client discipline |
| Prepare | `accept_from_primary`; gaps initiate transfer; duplicate preparation re-acknowledges; commit capped at local log (`708-730`) | Same-view prefix compatibility justifies acknowledging current end rather than only the incoming slot |
| PrepareOk | Same view, Normal primary, uncommitted known op; BTreeSet deduplicates sender (`743-765`) | Authentic old messages must still describe promises recovery has honored |
| Commit | Same acceptance helper; missing prefix initiates transfer (`776-784`) | No bypass of ordered application was found |
| GetState | Normal, matching view, legal requested end; returns suffix (`824-837`) | Public handler lacks a primary-role check, but actual `send_get_state` addresses the primary (`1390-1401`); forged routing is outside scope |
| NewState, same view | Matching view; useful overlapping suffix only; append rather than truncate (`850-874`) | Same-view fragment agreement is a protocol property, not an input assumption to hide inside the model |
| NewState, cross view | Only ViewChange/catching_up; response starts at current commit; install suffix then enter Normal (`875-889`) | Preserve already executed prefix; defer suffix replacement until new state arrives |
| StartViewChange / DoViewChange | Older views ignored; adopt newer view; current Normal primary re-sends StartView (`906-942`) | Retry guards compensate for lost StartView; do not infer livelock from one ignored message |
| View formation | Distinct DVC map; select by last-normal-view then length; maximum commit; initialize remaining self acks (`1043-1080`) | Selected log must cover all committed prefixes even if the selecting primary was behind |
| StartView | Same-view replay accepted only while ViewChange; install/commit/enter Normal (`954-967`) | Replay after Normal does not roll back a grown log |
| Recovery request | Newer durable floor starts view change; only Normal replica returns state/view (`1131-1149`) | Recovery participates through recovery traffic, not premature normal votes |
| Recovery response | Status, nonce, distinct senders, maximum view/floor, and latest primary snapshot checked (`1166-1205`) | Re-entry must discharge past eligible promises, not merely copy current application contents |
| Idle | All statuses have retry/timeout paths; stable periods reset capped backoff (`1233-1305`) | Suitable eventual timing and fair processing are needed for progress; no unconditional asynchronous liveness claim |
| Log/app helpers | Length lower bound on installation; table rebuilt; increasing commit cursor applies sequentially (`1324-1376`) | Content preservation and reply-cache sufficiency rely on reachable-path arguments, not length alone |

All relevant assertion/unwrap sites and developer-signal keywords were scanned. No active TODO/FIXME in `lib.rs` supplies a new confirmed defect. Assertions involving log lengths have message construction and status/view guards; arbitrary malformed frames are not used as a correctness finding.

## 4. Archaeology and issue adjudication

The complete 15-row corrective table, root causes, historical impact, exact commit links, current adoption locations, two assurance repairs, explicit nonbug matches, and all 116 original commit inventory rows are in [audit/history.md](audit/history.md). The table is part of this audit trail, not a list of present defects. Major mechanism groups are:

| Mechanism | Reviewed historical implementation commits | Present-target outcome |
|---|---|---|
| Replication/state-transfer response guards | `3fee194c`, `60064921`, `33656b3f`, `329cf649`, `d2700795`, `c149be77` | Required acknowledgements, status/range guards, overlap handling and ordered commits are incorporated |
| Ordered prefix execution | `7cf58faf` | Acknowledged later position commits earlier positions in order |
| Retry coverage | `9a74a74c`, `bbcc14dd` | Replica/client retransmission incorporated |
| Quorum identity and logical request identity | `4e4b0bb6`, `dd5bbb8f` | Distinct sender counting and request-table deduplication incorporated |
| View-change completion and timing | `06ba5def`, `8ab4fffc`, `b25372d8` | View selection, catch-up and stable backoff incorporated |
| State-losing recovery | `f8acf515` | Recovery isolation, nonce, quorum/latest primary and durable view incorporated |

No fix was counted from its subject alone. The local commit `0fe2a47f` sounds like a protocol fix but changes Lean only; its original Rust counterpart `b25372d8` is already in the target. The original `13ac95eb` changes a latent view arithmetic discrepancy, but no reachable prior view-change failure was established; it is excluded from the confirmed correction count. Simulator repairs `949b3d7f` and `08aeab18` concern oracle restart handling and healthy-core selection, respectively, not independent library defects.

| Public record | Full-thread disposition | Treatment |
|---|---|---|
| [Issue #1](https://github.com/penberg/vsr-rs/issues/1) | Testing-framework request, closed after custom simulator | Nonbug design context |
| [Issue #4](https://github.com/penberg/vsr-rs/issues/4) | Missing timeout retransmission, owner-confirmed fixed | Historical bug, no reopened finding |
| [Issue #5](https://github.com/penberg/vsr-rs/issues/5) | Simulator architecture discussion, closed | Nonbug design context; owner's experience is not exhaustive coverage evidence |
| [Issue #7](https://github.com/penberg/vsr-rs/issues/7) | Owner-driven logical timing request, resolved | `on_idle` retaining its name does not mean the behavior is missing |
| [Issue #8](https://github.com/penberg/vsr-rs/issues/8) | Client learns changed primary, resolved | Replies update view; retries reach new primary |
| [Issue #9](https://github.com/penberg/vsr-rs/issues/9) | Open example backoff, disconnect cleanup, restart identity reuse report; no comments | Known code-supported mechanisms; not novel findings from this audit |
| [PR #2](https://github.com/penberg/vsr-rs/pull/2) | Merged duplicate-message correction; no discussion/reviews | Historical correction |
| [PR #3](https://github.com/penberg/vsr-rs/pull/3) | Merged CI configuration; no discussion/reviews | Nonbug infrastructure |
| [PR #6](https://github.com/penberg/vsr-rs/pull/6) | Closed without merge, incomplete old view-change proposal | Not current code and not an unfixed target defect |
| [PR #10](https://github.com/penberg/vsr-rs/pull/10) | Open example lifecycle fix; one owner discussion comment, no reviews/inline comments | All open bug-fix PR coverage; no approval/merge inferred |

PR #10 was inspected at head `03198848859c691a27d950876f5e6d67a05dc364`, live base `a67f1f8b5182fc2871390f75c271394d0538dac2`; this differs from the requested analysis revision. Its two commits address the existing backoff/cleanup mechanisms; identity remains unaddressed. The [owner's comment](https://github.com/penberg/vsr-rs/pull/10#issuecomment-5549729674) discusses changing when reconnect backoff begins. The contributor's statement about identity being outside scope is not a maintainer ruling. [Full example/issue audit](audit/example.md), with raw body/comment/diff files under `audit/raw/`.

## 5. Current findings and verification routes

### 5.1 Protocol questions for model checking

These entries identify verified code interactions whose global correctness is unresolved by this review. They are questions, not suspected defects promoted to confirmed bugs. Every one has an independent service property in the brief; none disables a historical defense.

| ID / Scenario | Evidence and unresolved obligation | Compensations / disposition |
|---|---|---|
| MC1 / S1 | Recovery and log replacement compose with cumulative acknowledgements and DVC promises (`lib.rs:737-767`, `1043-1080`, `1159-1205`) | Nonce, durable floor, status isolation, distinct IDs, and current-primary snapshot exist. Verify same-view promises and later quorum-protected history across valid incarnations; do not freeze singly acknowledged uncommitted suffixes. |
| MC2 / S1–S2 | Four paths install/extend logs while application state and commit cursor survive differently (`842-894`, `948-968`, `1066-1070`, `1203-1205`, `1324-1376`) | Prefix length and status/view guards exist. Independently check historical prefix content and application suffix, allowing lagging replicas and uncommitted replacement. |
| MC3 / S2 | Client entries are overwritten on append, rebuilt on installation, and cached on execution (`658-673`, `1310-1344`, `1362-1369`) | Single outstanding request and fresh client identity are required. Verify logical-key uniqueness and sequential results with an independent oracle; recovery replay is allowed. |
| MC4 / S3 | Retry/view clocks compose with arbitrary request/reply delivery and continued service (`353-369`, `1233-1305`) | Existing retry paths compensate for loss. Specify eventual stable quorum, processing/communication bounds and fair client retry; bounded lockstep testing is not a general liveness result. |
| MC5 / S3 | Recovery response collection and retry are separate from client completion (`1166-1205`, `1255`) | Recovering replicas cannot themselves supply the necessary normal quorum. Verify each eligible recovery finishes, including quiescent state; do not assert progress outside the failure budget. |

Three replicas are the baseline. A bounded five-replica slice is needed to represent two simultaneously recovering replicas within `f=2`; three replicas cannot cover that interaction. Actual message emission and then-held prefix generate observer evidence, with each configured sender ID counted once across incarnations. Do not assume log agreement or recovery preservation in the definition of a certificate; establish them as properties. A sent quorum certificate, the primary observing that quorum, local application, and client acceptance remain distinct observations.

### 5.2 Test-verifiable and code-review findings

| ID | Verified fact and consequence boundary | Verification / next action |
|---|---|---|
| TV1 | A one-member configuration is accepted (`lib.rs:75-107`; `simulator/lib.rs:259`). Primary acceptance inserts self acknowledgement but does not test quorum; only a newly inserted distinct PrepareOk triggers normal commit (`lib.rs:684`, `753-765`). Primary idle only emits messages to other replicas (`1235-1253`, `1404-1408`). Thus the normal no-fault singleton path has no request-completion transition. | High-confidence static progress gap, independently reread by two reviewers; not executed. Verify the API's intended singleton contract with a component regression or explicitly reject/document it. Separate from impossible diskless recovery when the only replica has lost state. |
| TV2 | Existing monitors skip previously verified slots/support and observe only after batches (`simulator/properties.rs:89-101`, `185-195`, `233-244`; `simulator/lib.rs:712-718`). Replies bypass network injection (`950-961`). | Verified assurance limits, not library failures. Compare incremental monitors with full-history fixtures and add event/reply observations as required by service properties. |
| TV3a / S4 | View update syncs a temp file then renames it, without syncing the parent directory (`examples/kvstore/main.rs:570-579`). | Durable name publication for host/power failure is unestablished. Process-level ordering is correct. Review the supported filesystem crash model and component durability contract. |
| TV3b / S4 | One sender handles all destinations through blocking writes with no write timeout (`examples/kvstore/main.rs:342-392`). | A stalled destination is not isolated at this layer; event-loop retries cannot bypass the shared writer. This is separate from #9 backoff. Component progress validation is needed; no permanent cluster outage was demonstrated. |
| CR1 | Any startup read/parse error becomes `None` and selects `Replica::new` (`examples/kvstore/main.rs:686-699`). Later successful publication can replace invalid existing state. | Distinguish first bootstrap from unusable existing durable state. Subsequent write-error exit is a compensation for publication failure, not an initialization discriminator. |
| CR2 | Recovery nonce is wall-clock nanoseconds narrowed to u64 with zero on clock error (`examples/kvstore/main.rs:692-695`); no remembered freshness policy. | Contract-level uniqueness is not established by clock resolution alone. Review restart epoch/freshness policy; no nonce reuse was reproduced. |
| CR3 | `StateMachine` and recovery accept arbitrary application objects; `Client::on_request` overwrites pending without enforcing serialization (`lib.rs:53-60`, `312-327`, `511-518`). | Document compatible initial state, deterministic replay, and single-outstanding caller discipline. This is not a claim that out-of-contract pipelining is a library failure. |
| CR4 | Known example identity/cleanup concerns remain, and ID packing additionally assumes fitting node/counter widths and usize (`examples/kvstore/main.rs:454-503`, `726`). | Track #9/#10. The packing constraints are related review obligations, not all claims already made in #9. No independent novel defect count is assigned to each bit-width concern. |
| CR5 | A timer thread produces ticks, while one event queue determines when they execute (`examples/kvstore/main.rs:650`, `673-680`, `716-750`); filesystem timing is synchronous. | Queue delay and burst consumption constrain wall-clock availability claims. This is an assumption/measurement boundary, not a missing timer or proven livelock. |

Platform facts used for S4: file fsync does not necessarily persist its directory entry ([Linux fsync](https://man7.org/linux/man-pages/man2/fsync.2.html), linked by the [Linux man-pages project](https://www.kernel.org/doc/man-pages/)); `SystemTime` is not monotonic ([Rust documentation](https://doc.rust-lang.org/std/time/struct.SystemTime.html)); no write timeout means writes may block indefinitely ([TcpStream](https://doc.rust-lang.org/std/net/struct.TcpStream.html#method.set_write_timeout)); the event channel is an unbounded asynchronous FIFO ([mpsc::channel](https://doc.rust-lang.org/std/sync/mpsc/fn.channel.html)). The source-specific consequences above are code-review inferences with stated limits.

Example compensations were verified: every event persists before flush (`749-750`); storage publication errors exit (`580-582`); each socket waits for its reply before submitting another request (`454-472`); recovery uses `Store::default()` (`697`); application Put/Get is deterministic (`40-65`); library/client retry ticks are delivered (`739-745`). These prevent several superficially plausible findings.

## 6. Existing assurance: strengths and exact limits

Full definitions, file-level coverage, retained theorem locations, and exclusions are in [audit/assurance.md](audit/assurance.md).

### 6.1 DST properties and environment

- **Historical agreement exists.** `CommittedPrefixAgreement.canonical` survives every reboot; only the per-replica cursor resets (`simulator/properties.rs:210-245`). It is not merely pairwise present-replica agreement.
- **Execution order and replies are checked.** The accumulator retains an ordered `applied` vector (`simulator/state_machine.rs:36-52`); the oracle compares operations at log positions and folds results sequentially (`simulator/properties.rs:153-204`, `291-363`). Commuting final sums do not hide all ordering errors.
- **Incremental assumptions remain.** Old committed slots are not reread; durability support is checked only at first observation (`89-101`, `185-195`, `233-244`). Final core convergence does not assert that its length covers the historical canonical length (`378-407`; `simulator/lib.rs:793-807`). Therefore these checks do not independently establish continuous preservation.
- **Identity coverage is workload-relative.** The generator binds one stable unique operation ID to each request key and permits one outstanding request per client (`simulator/lib.rs:832-848`, `955-960`). Duplicate-ID checks are useful within that mapping; a general service oracle should use the actual request key and retain global logical history across incarnations.
- **Transport is not FIFO.** Independent delay sampling permits same-link reorder (`simulator/network.rs:147-225`). Replies, however, are direct/lossless; faulting client messages affects requests only (`simulator/lib.rs:950-961`).
- **Observation and timing are batched.** One tick submits work, applies faults, ticks every up replica/client, delivers due messages, then observes properties (`simulator/lib.rs:712-718`, `891-926`). Per-message transients, independent clock phases and handler-to-persistence crash windows are outside that schedule.
- **Persistence ordering is modeled correctly within that abstraction.** Flush assigns durable view before output drain (`944-950`); it does not simulate errors or publication latency. A caller that sends before persistence violates the contract and must not be inserted into the primary library model as normal behavior.
- **Pause and reboot differ.** Crash/Restart can retain all state, whereas Reboot reconstructs with durable view and empty application (`610-625`, `694-708`). Random reboot limiting counts recovering replicas; it does not bound every retained-state outage, and explicit scripts can bypass it (`869-880`, `606-637`). Label failure-budget assumptions separately from test stress choices.
- **Convergence includes pending requests but does not define full liveness.** Stable mode chooses a non-recovering quorum first and resumes its core (`729-780`); `pending` checks replies, queue, and committed core log (`786-809`). It does not explicitly check Normal status/recovery completion, and new requests stop in stable mode (`823-825`).
- **Outcome classification matters.** `requests_done` is frozen before the stable drain; later success cannot erase a prior workload-phase timeout (`simulator/lib.rs:566-592`). Such a run outcome is not by itself evidence that work cannot complete after communication becomes suitable.

The recovery-aware durability threshold uses the number of non-recovering participants: `needed = max(0, participants + 1 - quorum)` (`simulator/properties.rs:79-95`). It checks intersection support, not an unconditional “every commit always has a full physical majority.” A progressing service additionally needs a reachable non-recovering quorum; those are different conditions.

### 6.2 Retained Lean and conformance

The [retained README](https://github.com/penberg/vsr-rs/blob/de1a84376afe1102c197c2e0f4ade41eb4494458/lean/README.md) accurately separates local proofs from unfinished global preservation/general liveness. This audit inspected theorem bodies and model/checker definitions; it did not rebuild Lean or independently certify compiled proofs.

| Evidence at retained revision | What it establishes / limitation |
|---|---|
| `lean/Vsr/Safety.lean:184-205` | Local commit bounds/message well-formedness are derived; combined `safety` body remains `sorry`. Missing proof is not a counterexample. |
| `lean/Vsr/Invariant.lean:31-62`, `90-99` | The intended invariant is historical: fragments plus distinct-sender quorum acknowledgements define protected history, and later-view survival is stated over it. |
| `Invariant.lean:121-123`, `181-183`, `201-204` | AcksHold, StartedVotesCover, RecoveryCoversAcks describe promises needed across view changes/recovery; their global preservation is open. Absence of wire incarnation tags alone is not a defect. |
| `lean/Vsr/Check.lean:283-301` | Executable committedSurvives quantifies current replica commit prefixes, a narrower antecedent than all historical quorum-acknowledged entries in the formal invariant. Passing the executable check is not literally checking the entire historical predicate. |
| `lean/Vsr/System.lean:21-32`, `64-73` | Operational steps allow arbitrary historical delivery, request inputs and recovery nonces; public contract assumptions are not identical to generator restrictions. |
| `verify/lib.rs:340-395` | Generator uses sequential clients and increasing nonces but has no recovery failure-budget guard. These choices must not silently define the service contract. |
| `verify/lib.rs:112-189`, `289-307`; `lean/Main.lean:104-117` | Conformance compares statuses, views, logs, commits, ordered applied operations, new messages and replies. It is meaningful sampled operational correspondence. |
| `verify/lib.rs:16-30`; `lean/Main.lean:24-27` | Both sides use a recorder returning history length; matching operational outputs does not independently validate arbitrary sequential application/client semantics. |
| `lean/Vsr/Liveness.lean:50-93` | General settles is unfinished and uses synchronous rounds after discarding prior in-flight messages. Its settlement condition differs from live-client matching replies and individual recovery completion. |

The formal safety theorem does not include an independent logical exactly-once or sequential reply-result theorem (`Safety.lean:25-46`, `202-205`). The existing 40-seed conformance test can skip if `lake` is absent (`verify/verify_tests.rs:88-102`); no claim of a current conformance rerun is made. The archived source/manifest lets a later reviewer inspect these exact distinctions.

### 6.3 CI and coverage reporting

Pinned CI runs workspace check, clippy, tests and one simulator configuration seeded from the commit (`.github/workflows/smoke_test.yml:18-26`). The CLI interprets a 40-character hash as its low 64 bits (`simulator/main.rs:147-155`). Line/region coverage from `scripts/coverage:138-176` measures executed code, not all protocol states, schedules, or service properties. `scripts/simulate:48-65` can aggregate dirty runs with the same base SHA; preserve exact source identity when relying on its reports. This audit executed only the recorded baseline tests, not the broader CI/coverage campaign.

## 7. Reference comparison and modeling decisions

The [2012 VSR reference, §§2–4](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf) supplies crash/authentic-message, quorum, sequential-service, and recovery semantics. It allows uncommitted suffix replacement and distinguishes recovery from a retained-state communication pause. [Michael et al., §6](https://drkp.net/papers/recovery-tr17.pdf) identifies lost view promises in diskless recovery; it does not by itself prove this implementation's composition. [Vanlightly's state-transfer analysis](https://jack-vanlightly.com/analyses/2022/12/28/paper-vr-revisited-state-transfer-part-3) motivates care around prematurely truncating a suffix or promoting its view. The target already cites both corrections (`README.md:68-87`).

Current implementation choices were checked directly: durable view/fresh-nonce contract (`lib.rs:14-21`, `505-510`); cumulative acknowledgements (`737-767`); explicit offset-bearing NewState (`197-206`); delayed cross-view replacement with last-normal-view updated on entry to Normal (`875-889`, `1095-1121`); timed retries/backoff (`1233-1305`); identity renewal instead of reusing restarted client identity (`29-31`). These are the faithful model semantics, not arbitrary fault knobs.

The independent specification should state logical properties first and then map code events to them. Use a small deterministic order-sensitive application to separate payload equality from request identity and sequential result. Model source handler granularity, explicit output publication, genuine network nondeterminism, and valid recovery. Keep platform integration candidates out of the conforming-library fault model. Uncommitted preparation is not irrevocable commitment; recovering replicas may have empty local state; old messages need not vanish on reboot.

For progress, define an eventually stable reachable set with a non-recovering quorum, fair processing/retries, compatible local timers, and suitable delay bounds. The client or recovering replica whose progress is asserted must itself communicate fairly with that quorum and continue processing/retrying; a quorum elsewhere does not guarantee progress for an isolated target. The capped backoff does not support a theorem for all unknown finite delay bounds merely because they are finite. Prove establishment of a usable view rather than assuming a working primary. State request completion and recovery completion separately. A service guarantee need not wait for every unavailable replica to converge or the network to become empty.

## 8. Explicit exclusions and false-positive controls

These are rejected interpretations/candidates, not invented debunked GitHub issues. Full reasoning also appears in the component audits.

| Excluded claim | Why excluded / evidence |
|---|---|
| The source lacks the published recovery/state-transfer corrections | They are cited and implemented; original-to-target adoption checked (history audit, `lib.rs:875-889`, `1131-1205`) |
| Reproduce an old failure by reverting a fix | Adds no new target information; all 15 historical corrections remain reference context |
| Every operation accepted by one replica must survive at its original slot | The log may contain an uncommitted replaceable suffix (`lib.rs:875-886`, `1048-1066`) |
| Every old individual ACK permanently fixes the suffix in all later views | Single-ACK same-view promises and quorum-protected history have different scope |
| Any repeated `apply` after reboot violates exactly-once | A fresh local application reconstructs an existing logical prefix (`lib.rs:1203-1205`) |
| Retained application may be passed to recovery without alignment | Constructor accepts caller state and replays from commit zero; compatible initialization is required (`lib.rs:478-518`) |
| Missing older cached reply after a newer request necessarily blocks a valid client | A client sends the newer request only after accepting the older reply; check that discipline before elevating a table observation (`lib.rs:274-277`, `658-673`) |
| Duplicate ACKs inflate current quorum | BTreeSet insertion deduplicates configured sender IDs (`lib.rs:749-759`) |
| Duplicate StartView rolls back a grown Normal log | Same-view replay is rejected after leaving ViewChange (`lib.rs:954-960`) |
| A missing primary-role check on GetState proves a forged-state flaw | Actual requests address the primary; authentic-message scope excludes invented origins/routes (`lib.rs:1390-1401`) |
| DST has only present-pair agreement or a commutative total oracle | Canonical history, ordered applications and sequential reply checks exist (`simulator/properties.rs:153-245`, `291-363`) |
| DST network is FIFO or omits view persistence | Per-message delays reorder; flush persists before release (`simulator/network.rs:147-225`; `simulator/lib.rs:944-950`) |
| Any up majority guarantees recovery despite too many recovering replicas | Recovery needs Normal responders; the failure budget includes recovery (`lib.rs:1136-1138`, `1171`; `simulator/lib.rs:740-753`) |
| Incomplete Lean proof or model/code agreement proves an implementation failure/success | Proof status and sampled correspondence are separate assurance claims (report §6.2) |
| Example omits timers, serial client discipline, or persist-before-send | All three paths are present (`examples/kvstore/main.rs:454-472`, `673-680`, `739-750`) |
| Every `try_clone` error leaks an existing connection-table entry | Initial clone precedes the first command/table entry; later I/O early returns are the relevant known concern (`main.rs:452-474`, `725-728`) |
| Contributor's PR scope statement resolves maintainer identity priorities | Owner's actual availability discussion is narrower; no identity ruling was made |
| Out-of-contract clients, spoofed/malformed frames, dynamic membership, integer-wrap stress, viewer bugs are core MC targets | They do not answer the requested fixed-membership authentic-message service questions; review/document relevant caller/representation contracts separately |

## 9. Answers to the requester's five questions

1. **Committed preservation across subprotocols:** current guards and historical fixes provide substantial support, but this source review does not establish global preservation. S1/MC1–MC2 check history across acknowledgement, installation and recovery, including incarnations, rather than only current logs.
2. **Execution and replies:** execution is sequential within each handler; existing DST observes order/results. The remaining independent obligation is that each logical request occupies at most one committed slot and has the matching sequential result under valid clients across table reconstruction. Local replay after reboot is legitimate reconstruction (S2/MC3).
3. **Progress:** retries exist, but progress is conditional on a suitable reachable non-recovering quorum and communication/processing/timer bounds. DST finite convergence and retained Lean synchronous settlement are different claims. MC4/MC5 state client and recovery progress separately; TV1 identifies the singleton normal-path gap.
4. **Contract versus testing choices:** message reordering, historical agreement, ordered application and correct persistence ordering are present in DST. Lossless replies, fixed client lifetimes, lockstep ticks, atomic storage abstraction and incremental batch observations restrict its assurance. These restrictions must be explicit in any new model.
5. **Example integration:** correct ordering/client serialization/fresh application initialization were verified. Beyond #9, review durable directory publication, bootstrap error handling, recovery nonce freshness and per-destination writer isolation. Timer consumption and packed identities need explicit constraints. These are integration findings, not violations attributed to a conforming library caller.

## 10. Deliverables and remaining verification

- [modeling-brief.md](modeling-brief.md): 7 required sections, Category A, four Scenarios, proposed extensions/properties, MC1–MC5, TV1–TV3 and CR1–CR5.
- [audit/history.md](audit/history.md): complete archaeology ledger, issue/PR adjudication, corrective mechanisms, adoption evidence and history limitations.
- [audit/assurance.md](audit/assurance.md): exact DST/model/checker/conformance definitions and boundaries.
- [audit/example.md](audit/example.md): every example candidate, compensating path, platform source and live PR facts.
- [audit/baseline-tests.log](audit/baseline-tests.log) and [audit/audit-manifest.json](audit/audit-manifest.json): executed baseline evidence and immutable fingerprints.

Code Analysis is complete. Spec Generation and subsequent verification remain separate phases: the open MC questions require a faithful model, and static example/singleton candidates require their stated component or review validation. No failing trace, confirmed production bug, exhaustive test coverage or universal correctness proof is claimed.

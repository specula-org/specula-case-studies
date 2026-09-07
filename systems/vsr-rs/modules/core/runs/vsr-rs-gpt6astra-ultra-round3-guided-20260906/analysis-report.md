# vsr-rs Code Analysis — correctness pass 3

## Verdict and scope

**One new correctness defect is reproduced in the shipped `kvstore` integration:** clean EOF during a partially transmitted peer frame can make the receiver accept a shorter operation than the one the encoder produced. The resulting operation can commit and be observed by clients. This is an integration breach of the library's content-preserving transport assumption, not a demonstrated defect in the contract-respecting VSR core.

The strongest reproduction runs **three unchanged example binaries**. One client submits a 16,777,216-byte value. After the sending primary stops during a partial peer write, the client's original SET completes with `+OK`; a GET invoked afterwards on a different connection returns a 2,623,764-byte strict prefix. No legal sequential history of those original operations explains that result. The real-function fixture independently records exact encoded-frame provenance and follows the altered Prepare through real VSR handlers.

No core-library safety or sustained-availability defect was confirmed. Five forward-looking model-checkable questions remain, grouped into the Scenarios in [modeling-brief.md](modeling-brief.md). DVC self exclusion, recovery response replacement, and finite timer delay are verified source facts, not standalone correctness findings. No TLC execution or semantic proof was performed in this Code Analysis phase.

## Methodology and immutable target

The installed `code-analysis` skill was used as the methodology: `SKILL.md`, the full `guide.md`, shared deep analysis, Category A distributed analysis, bug archaeology, modeling-brief format, and the complete example brief were read. Step 0 classified the system before deep analysis. All four phases were completed: reconnaissance, archaeology, deep source analysis, and Scenario-based handoff. BFT and Category B references do not apply to this crash-fault message-passing implementation.

| Item | Verified value |
|---|---|
| Repository | `penberg/vsr-rs` |
| Source directory | `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/source` |
| Analysis output | adjacent `.specula-output` |
| HEAD | `3ac0104a567092139534c9022205d02281a2da41` |
| Reference date | 2026-09-06 UTC |
| Initial tracked-source state | Clean; pre-existing untracked local metadata preserved |
| `lib.rs` SHA-256 | `5227cacc78d8e33a122a80cf2d90404ad102525fed5b758279c81881f308ab16` |
| `examples/kvstore/main.rs` SHA-256 | `12564195ce2a6568e69bce42e672d4c5c7b780cb5eb390c0296821da540320bf` |
| Toolchain used for tests | `rustc 1.95.0 (59807616e 2026-04-14)`, Cargo 1.95.0 |
| Reference | Liskov/Cowling, *Viewstamped Replication Revisited* (2012) |

The supplied source anchors match the pin. No tracked implementation was changed, no patch was committed, and no issue/PR/message was published. Output files, evidence, and local build artifacts were created. The user-authorized analysis continued from saved artifacts through provider interruptions; file reviews and issue work were delegated in parallel, then cross-referenced centrally.

The original [paper URL](https://pmg.csail.mit.edu/papers/vr-revisited.pdf) was unavailable during retrieval; the identical-titled primary paper was retrieved from a [Princeton course mirror](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf). The saved PDF's SHA-256 is `1b16284a0a443d08992bd0fd0f032587e34e3e81f61f1871d39a4e4a6e22cfa6`; `evidence/vr-revisited.txt` retains the extraction. Comparisons below use §§2.1–2.2, 4.1–4.3, 5.2 and correctness discussion, not a secondary summary.

## Phase 1 — Structural map and atomicity

| Component | Size and anchors | Execution / responsibility |
|---|---|---|
| Protocol types/configuration | `lib.rs:29-270` | Fixed indexed IDs, majority `N/2+1`, round-robin primary; caller-supplied operation/result types |
| Client proxy | `lib.rs:272-377` | One pending request; retries to every replica; matches request-number replies and learns a larger view |
| Replica | `lib.rs:379-1476` | Single-owner serial handler calls, no I/O/clock/thread; full log, client table, view-change/recovery maps and output queues |
| Normal operation / catch-up | `lib.rs:646-901` | Append, cumulative acknowledgement, ordered commit, status-aware state transfer |
| View change | `lib.rs:903-1122` | Sender sets, latest-normal-view/longest-log selection, monotone local commit, replay guards |
| Recovery | `lib.rs:505-523,1124-1215` | Empty volatile state, durable view floor, fresh nonce, normal-responder quorum including latest primary |
| Timers/output | `lib.rs:1233-1305,1381-1414,1467-1474` | Heartbeats and retries; bounded exponential backoff; individual output publication by caller |
| kvstore | 764 lines, `examples/kvstore/main.rs` | Deterministic in-memory map; both reads/writes replicated; one owner loop plus peer/client/sender/ticker threads |
| Cluster tests | 664 lines, `tests/cluster.rs` | Hand-driven schedules and 16 tests |
| Simulator | 2,800 lines across eight Rust files | Seeded typed-message scheduling, crash/restart/reboot, properties, workload, command line and TUI; five tests |
| Scripts and CI | `scripts/simulate`, `scripts/coverage`, `.github/workflows/smoke_test.yml` | Seed sweeps, line coverage, workspace checks/tests and SHA-seeded simulation |

The entire `lib.rs` and `kvstore` source were read centrally and independently. The delegated test/coverage review read all simulator and cluster-test files. Developer-signal searches covered TODO/FIXME/HACK/XXX/BUG/WARN and panic/unwrap/expect sites; no hidden TODO-defined repair obligation was assumed. Unwraps in quorum selection follow nonempty-map guards (`lib.rs:1045-1059,1171-1179`); assertions on log sizes depend on authentic, correctly encoded protocol input (`609,623,853,1325`).

The core local atomic unit is one synchronous `on_message`/`on_idle` call. `StateMachine::apply` occurs synchronously during commit (`lib.rs:1362-1365`). The owner must then persist `view_number` before delivering outputs (`14-21`). A model must not make all outputs atomic: `drain_messages` and `drain_replies` expose separate items, and `kvstore::flush` queues/routes them one by one (`main.rs:551-565`). After persistence, a crash may leave authentic messages already in transit while discarding the rest.

In `kvstore`, persistence precedes flush at `main.rs:749-750`. Peer writes occur in an independent sender thread (`342-391,655`) and receiver threads parse into the owner event channel (`397-411`). A body write and delimiter write are separate operations (`383-386`), and a single body `write_all` may itself make partial progress. The OS/network can therefore interrupt inside an otherwise valid message. The store has no separate application persistence; recovery constructs a new empty Store and replays the chosen committed prefix (`697`, `lib.rs:1203-1205`).

Caller assumptions for core analysis: fixed consistent membership; authentic messages delivered to the intended recipient without changing their contents; deterministic state machines and the same initial state; distinct client identities with one pending request per client; fresh recovery nonces; correct durable-view order; a failure budget that includes replicas still recovering. These follow the API documentation and paper assumptions, and are not disabled to manufacture core counterexamples.

## Phase 2 — Archaeology coverage and dispositions

| Coverage measure | Result |
|---|---|
| Reachable `git --all` history | 21 commit records / changed-file manifest entries examined |
| Pin ancestry | 6 commits including HEAD; 15 alternate-branch/nonancestor commits separated |
| Operational Rust-touching pin commits | 4: initial implementation, simulator, kvstore, terminology rename |
| Additional nonancestor Rust changes | 2 verifier/harness commits; absent from operational pin |
| Explicit core keyword match | Initial import; historical repairs were consolidated there |
| Recovered historical patch records examined | 4: `9a74a74`, `bbcc14d`, `06ba5de`, `f8acf51` |
| Historical corrective commits reviewed as mechanisms | Those 4 plus nonancestor `0fe2a47`'s backoff description/diff; all five already represented or out of pin, not new fixes to rediscover |
| Issues collected / deeply read | 6 / 6, every issue available in repository listing |
| Confirmed bug-report issues | 2: #4 historical retransmission; #9 three reported integration mechanisms, with source support and maintainer discussion for lifecycle fixes |
| Issues excluded as non-bug proposals/enhancements | 4: #1, #5, #7, #8; not four debunked bug reports |
| Issues debunked/disputed as false positives | 0 in the collected set |
| PRs collected / deeply read | 4 / 4, including body, comments, reviews/review-comments and diffs |
| Open PRs with corrective intent / reviewed | 1 / 1: #10 at `c6969a6242f058f2a7dded67a7be26ff88df14b5` |
| Issue searches | 14 keywords plus bug-label filter; full all-state list also read |

The skill's 30+ issue target is impossible for this six-issue repository; the full available set was read rather than sampled. Searches used fix, bug, race, panic, deadlock, correctness, crash, corrupt, leak, inconsistent, wrong, recovery, view, data loss, and label:bug. Saved results are in `evidence/issue-searches.json`. Every referenced discussion has complete saved JSON; an empty `gh ... --comments` text output does not imply a missing body. PR review-comment arrays were also obtained; they are empty where noted.

The complete per-commit ancestry, severity/root-cause ledger, historical seeds, discussions and coverage map are in [history-audit.md](evidence/history-audit.md). The main mechanisms are summarized here:

| Mechanism | Historical evidence / impact | Current disposition |
|---|---|---|
| Duplicate/stale messages and identity counting | Merged [PR #2](https://github.com/penberg/vsr-rs/pull/2); old layout; assertions and duplicate handling | Current status/view guards, client table, distinct-ID acknowledgement sets; fixed context |
| Lost final Prepare/PrepareOk or state transfer | [Issue #4](https://github.com/penberg/vsr-rs/issues/4), `9a74a74`; indefinite pending work | Retransmission and prefix acknowledgement present; high historical availability impact, not new target |
| Lost client request / obsolete primary routing | `bbcc14d`, `06ba5de`, [issue #8](https://github.com/penberg/vsr-rs/issues/8) | Pending request, broadcast retry and reply view learning implemented |
| View-change history replacement | `06ba5de`; forgotten suffix/commit intersection and failover availability risks | Full-log retention during catch-up, latest-normal selection and replay guards present |
| Lost volatile state and view promise on recovery | `f8acf51`; historical durability/assertion/split-brain failures | Recovering barrier, fresh nonce, durable floor and recovery quorum present |
| Repeated timeout before stabilization | `0fe2a47` description; historical indefinite view churn | Rust backoff fix and regression already in initial import; actual nonancestor diff changes Lean files only |
| Connection lifecycle / ID reuse | [Issue #9](https://github.com/penberg/vsr-rs/issues/9), [PR #10](https://github.com/penberg/vsr-rs/pull/10) | Known user exclusions; PR addresses backoff/disconnect, explicitly not client IDs; pin contains none of PR #10's changes |

[Issue #1](https://github.com/penberg/vsr-rs/issues/1) and [#5](https://github.com/penberg/vsr-rs/issues/5) discuss simulator alternatives, not unresolved bugs. [Issue #7](https://github.com/penberg/vsr-rs/issues/7) resolves ownership of logical timeout handling. [PR #3](https://github.com/penberg/vsr-rs/pull/3) is CI setup; [PR #6](https://github.com/penberg/vsr-rs/pull/6) is a closed old view-change proposal, not a merged patch to assume present. Raw evidence includes all full discussions.

The recurring hotspots are quorum/log installation, recovery versus view transitions, client identity and retry semantics, and transport/owner boundary effects. Historical counting does not yield a meaningful current bugfix-frequency ranking by file: the rewritten initial import bundles repairs. Logical historical mechanisms, rather than inflated commit counts or misleading branch dates, guide Scenarios 2–5.

## Phase 3 — Finding INT-1: incomplete peer frame changes committed content

**Classification:** confirmed example-integration correctness defect; high impact (wrong committed value and non-linearizable client observation). Not a core-library defect under its documented transport contract. Not an exact duplicate of previous excluded mechanisms or issue #9/PR #10.

### Code path and source evidence

1. A legal inline command uses one-word keys and values (`main.rs:424-441`, example README); no value-length limit forbids the ASCII value used by the test. The original command becomes `Op::Put` (`729-734`), and the primary appends that operation before producing Prepare (`lib.rs:675-693`).
2. `encode` puts the operation's final value at the end of a Prepare (`main.rs:79-83,107-117`). `run_sender` calls `write_all(body)` followed by `write_all(newline)` (`383-386`). The reproduced interruption occurs inside the body, not merely between a complete body and its delimiter.
3. `run_peer_acceptor` iterates `BufReader::lines().map_while(Result::ok)` (`401`) and immediately dispatches successfully decoded strings (`402-407`). Clean EOF can yield a final nonempty line without newline. The parser has no delimiter-completion information (`237-240`), and a nonempty final value prefix satisfies `Tokens::word`/`op` (`204-219`).
4. The decoded Prepare retains view, op number, commit number, client ID and request number, but contains the shorter value (`247-254`). A normal backup with the previous log prefix accepts and appends it (`lib.rs:708-718`).
5. A duplicate complete Prepare does not compare or replace the existing operation; it acknowledges the already held prefix (`720-730`). Gap checks and acknowledgement metadata do not compare content (`712-714,1381-1387`). This is safe under content-preserving delivery, but cannot repair an integration-created mismatch.
6. A view change can select that survivor's log using its legitimate greatest `(last_normal_view, length)` (`1048-1066`). The other survivor adopts it and acknowledges (`948-967`); the new primary commits (`737-768`) and applies the shorter Put (`1362-1365`, `main.rs:56-60`).
7. The pending client's unchanged retry has the same client/request identity. The primary answers from its client table (`658-672`); the example formats a SET result as `+OK` (`main.rs:587-591`). A fresh later GET executes through the log and returns the shortened value. This preserves neither the original invocation's write value nor legal sequential results.

### Distinguishing framing outcomes

| Connection/read outcome | Actual receiver result |
|---|---|
| Ordinary fragments, still open | `read_line` accumulates until delimiter/EOF/error; fragmentation alone does not dispatch partial operations |
| Complete body, EOF before newline | Intended content may be accepted; missing delimiter alone does not imply changed content |
| Clean EOF inside a nonempty final ASCII token | Required tokens can remain syntactically complete; a different operation/reply may be accepted |
| EOF before a required token or before all advertised entries | Decoder rejects missing token/entry |
| EOF inside a UTF-8 scalar | Invalid UTF-8 may make `read_line` fail; ASCII fixture avoids this ambiguity |
| Connection-reset/read error before line completion | Failed read is discarded by `map_while(Result::ok)`; do not claim every reset causes truncation acceptance |

The reader fixture supplies two-byte fragments, clean EOF, and an explicit `ConnectionReset` read error through Rust's real `BufReader::lines` path. It observes the complete reply for ordinary fragments, a shortened reply at clean EOF, and no admitted line after the failed read. The OS process-stop fixture supplies the actual clean-EOF behavior for the reproduced sender failure. No claim is made that every OS close, reset or process failure follows the same TCP path.

### Independent confirmation route A: unchanged functions and exact provenance

[evidence/frame-regression](evidence/frame-regression/append.rs) is an isolated Cargo test package depending on the pinned library. Its `frames.rs` begins byte-for-byte with the unchanged 764-line `examples/kvstore/main.rs`; test code is appended after that source. This prefix equality was verified. The sender frame is produced by a real primary's `on_message(Request)` and `drain_messages`, then passed to unchanged `run_sender`. The receiver is unchanged `run_peer_acceptor`.

The receiver child is temporarily descheduled to make a partial socket write observable. The sender child is stopped while that large body write is still pending. The receiver resumes, sees clean EOF, and delivers a parsed event. No intermediary edits, substitutes, or invents message bytes. The sender persists its exact `encode` output as `expected.frame`; the parsed event re-encodes as `received.frame`, verified to be a strict byte prefix of the original. The latter is a re-encoding of the admitted event, not a claimed packet capture.

| Fixture artifact | Bytes / SHA-256 |
|---|---|
| Original encoded Prepare | 16,777,242; `63127ea1866d1a48880c10ffb26257e24b92478102fe09a48766cef816b66acd` |
| Admitted event re-encoded | 2,613,675; `eb0bef834c33cb6340b8be9f54f1b4ad33d3ffc8925d32ac465fec46898de21b` |
| Original value | 16,777,216 ASCII `v` bytes |
| Admitted/committed value | 2,613,649 ASCII `v` bytes |

The public-API continuation keeps replica 0 stopped, drives only replicas 1 and 2 through their actual handlers, and reaches normal view 1 with both survivors committed through the altered Put. The **same retained Client object**, with its original request still pending, retries and receives success; a fresh client's later GET returns the shortened value. Thus the fixture does not rely on client ID reuse or reconstruction of a different logical client.

Command, from the source directory:

```sh
cargo test --manifest-path ../.specula-output/evidence/frame-regression/Cargo.toml -- --test-threads=1 --nocapture
```

Final [run.log](evidence/frame-regression/run.log): **3 tests passed** (including the child-dispatch support test; two substantive tests cover reader distinctions and the sender/receiver plus committed-result sequence). The test asserts existing faulty behavior as an analysis witness; it is not a repaired-behavior regression or a code fix. Exact partial byte count is OS/scheduling dependent; the essential check is strict-prefix provenance plus client-visible harm.

### Independent confirmation route B: three unchanged shipped binaries

The [process driver](evidence/kvstore-process-check-2.py) launches three instances of `target/debug/examples/kvstore` on fresh loopback ports with fresh view files. It uses ordinary inline SET/GET commands and leaves encoding, transport, view persistence, recovery of service, client retry and reply formatting entirely inside the shipped binaries.

Sequence:

1. Connect a client to node 2; temporarily deschedule node 1 without erasing its memory.
2. Submit `SET key <16 MiB ASCII value>` through node 2, which forwards it to primary 0.
3. Wait until the OS socket table shows primary 0's established connection to node 1 with a substantial unsent queue. The saved observation has Send-Q **2,591,040** bytes. This replaced an earlier timing-only attempt.
4. Stop primary 0 during the write and resume node 1. Only primary 0 crashes; the other scheduling pause preserves all state. After this finite prefix, nodes 1 and 2 run normally.
5. The original node-2 client receives `+OK`. Open a different client connection only afterwards and issue `GET key`.
6. The GET returns **2,623,764 bytes**, all a strict prefix of the original **16,777,216 bytes**. All owned test processes are then cleaned up.

Reproduce with `python3 ../.specula-output/evidence/kvstore-process-check-2.py` from the source directory after `cargo build --example kvstore`. The driver now chooses a fresh run directory by default, or accepts `VSR_CHECK_DIR`; the completed original run remains at `evidence/kvstore-process-check-2/`. This output-directory adjustment does not change the tested sequence.

Saved [result.json](evidence/kvstore-process-check-2/result.json) and [stdout](evidence/kvstore-process-check-2.log) record:

- Original value SHA-256: `47e4eb56fd3856c5cacc4f606f6a51afa16d531c6aeac5b14983d6c5237a685b`.
- Observed GET SHA-256: `4aef11982ec7c0ba485ac8ba936ec9caea822f70946f0942a8794c943cfc5b81`.
- `set_reply = "+OK\r\n"`, `get_is_strict_prefix = true`.

There is one write and then a real-time later read; no other operation can explain the returned prefix. The caller receives a syntactically well-formed Redis-like reply whose length is recalculated from the wrong value. The successful result after failover also shows that retransmission/state transfer did not repair this admitted mismatch before observation.

The first [timing-only process attempt](evidence/kvstore-process-check.log) timed out waiting for SET completion; its logs and partial manifest are retained. It did not establish entry into the target partial write and is **inconclusive**, not a second bug or a liveness counterexample. The refined successful run waited for an observed partial write rather than assuming a fixed sleep had reached it. No simulator was used to reproduce INT-1, so the instruction to add a simulator-seed regression under `tests` was not triggered. The standalone integration witness and exact source commit are preserved here.

### Compensation audit, related paths, and proposed repair direction

- Retransmission does not necessarily repair content: duplicate Prepare retains the entry (`lib.rs:716-730`), complete same-view StartView is ignored after normal status (`954-960`), and same-view transfer preserves overlap (`864-869`). Full reinitialization or a later Put can mask the wrong value; neither makes the earlier observed result valid.
- A heartbeat contains only view and commit number (`1239-1242`). It cannot identify equal-length logs with different operations.
- `install_log` preserves the existing state machine and commit index (`1324-1345`); correcting an already executed prefix in the log does not automatically undo or replay its application effects (`1349-1365`).
- `REQUEST`, nonempty `NEWSTATE`, `DOVIEWCHANGE`, `STARTVIEW` and state-bearing `RECOVERYRESPONSE` also end in an operation token. Their local decode paths are established; their distinct compositions remain test candidates, not separately counted confirmed bugs.
- Forwarded `REPLY +value` can shorten even to `+`, parsed as an empty string (`main.rs:317-330`). `Client::on_reply` matches the request number, not result content (`lib.rs:334-344`); the reader-level test reproduces this. A dedicated whole reply-route experiment remains pending under TV-2.
- Numeric final-token truncation generally lowers numbers; some effects are compensated (smaller commit or state-transfer start), while multidigit replica-ID cases require separate concrete schedules. Do not substitute arbitrary ID changes in the core model.

The full per-message final-token map, exact guards, masking paths and static candidates are in [integration-analysis.md](evidence/integration-analysis.md). Its original static-only confirmation boundary is superseded by the executed evidence in this report; it is retained as the independent source review.

A narrow fix direction is to retain delimiter-completion information and reject an EOF tail without its required delimiter before calling `decode`; a length-delimited exact-read frame is another option. Token-count checks alone do not detect a shortened nonempty final value. Combining body and newline into one buffer/write call does not make a TCP write atomic. Repair validation should include full fragmented frames, EOF inside each final token, EOF before required tokens, UTF-8 boundaries, read errors, and the surviving client-result sequence. No repair was applied in this analysis.

## Core question ledger: verified behavior, compensations, and open obligations

| User question | Verified source and compensation | Disposition / independent route |
|---|---|---|
| 1. DVC quorum excluding primary's own state | `lib.rs:1043-1047` requires only map size; own entry arises via separate SVC threshold at `1000-1024`. The two other replicas can exchange SVCs and deliver DVCs before the designated primary receives SVC. Selection is latest-normal/longest, with max reported commit (`1048-1059`). Majority still intersects old commit quorums. | Reachable deviation from paper §4.2 self-inclusion, **not established loss**. MC-1: log/prefix and client-result invariants; replay TLC witness with public APIs and authentic messages. |
| 2. Rolling recovery of different replicas | `recover` loses volatile state and blocks other handlers (`505-523,533-536`). Fresh response quorum and durable floor guard rejoining (`1166-1205`). Log installation assumes committed-prefix compatibility (`1324-1345`). | MC-2: several sequential completed recoveries; preserve committed positions and ghost client history. Keep crashed/recovering within budget; do not count an empty restarted process as healthy. No new violation observed. |
| 3. Recovery overlapping views, response overwrite | Arrival-order map overwrite (`1169-1170`) can lower current maximum; latest view must still be >= durable view and have its exact primary's state (`1180-1193`). A high durable recovery request prompts view change (`1131-1134`). | MC-3: delayed snapshots and multiple responses per nonce across views; require history harm, not merely decreasing an unpromised observed maximum. Liveness needs stable normal respondents and a usable primary. |
| 4. Cross-client real-time order/results | Primary appends/commits in order and caches replies (`646-693,737-768,1362-1377`); new primary replays earlier committed work (`1066-1075`); clients retry one outstanding request (`311-370`). | INT-1 confirms an **integration** violation. Core MC-2/3/4 retain full original operation/result and invocation/completion order; no contract-respecting core violation confirmed. |
| 5. Permanently unavailable minority/skipped primary | Majority uses `N/2+1`; primary rotates modulo N. State install sends cumulative acknowledgement (`893,967,1381-1388`); normal, view-change, transfer and recovery paths retry (`1233-1283`). Backoff is capped (`1302-1305`). | MC-5: stable healthy participating quorum, regular timers and sufficiently bounded delivery to complete view change, continuing new requests. No proof or non-progress lasso obtained. Fixed backoff bug and shared sender blocking excluded. |
| 6. Persisted view with partial output release | Owner persists before flush; individual messages/replies can already be queued or delivered (`main.rs:551-565,749-750`; `lib.rs:1467-1474`). Recover uses durable view and fresh nonce. | MC-4: explicit pending/published output, crash after any permitted prefix, preserve authentic in-flight snapshots. No send-before-persist assumption. Framing experiment is an integration manifestation at a later byte-transfer boundary, not a core proof. |

Two core facts especially constrain false positives. `commit_up_to` never reduces the local commit number (`1349-1355`), so maximum DVC commit being smaller does not itself roll back execution. The recovery floor compares against the correctly persisted view passed into `recover`, not a monotone maximum of all responses ever observed. A model checking the latter as if it were a documented promise would report the wrong property.

For N=2, `quorum() == 2` but a recovering node has one other possible responder. This creates a recovery-availability limitation after a crash even if the other process is up. Paper §2.2 assigns a two-node group failure allowance zero; this fact alone is therefore not a within-budget core defect. It is a contract/documentation question distinct from the excluded singleton finding. For even N in general, use failure allowance `floor((N-1)/2)` and distinguish it from the source's SVC threshold `floor(N/2)` other participants.

Under pure asynchronous eventual delivery, arbitrary delays may keep outrunning finite timeouts. The brief states usable stable timing bounds rather than treating a bounded timeout as a proof of indefinite non-progress. A recovering process is also not a normal quorum participant until recovery completes. Sequential physical restarts that leave every node recovering would make every node ignore Recovery requests (`533-536,1136-1138`); that is not evidence against a guarantee that presumes a participating majority.

## Explicit exclusions and false-positive checks

| Candidate / tempting claim | Why excluded or qualified |
|---|---|
| View-file unreadable/corrupted startup fallback | Exact prior mechanism; `main.rs:687-700`; not a new target |
| Singleton accepted configuration | Exact prior mechanism; not retested/promoted |
| Shared FIFO sender stalls behind one peer | Exact prior mechanism; INT-1 instead demonstrates changed committed data after ordinary service resumes |
| Parent-directory fsync omission | Exact prior mechanism at `main.rs:574-577`; not composed into core assumptions |
| Wall-clock recovery nonce freshness | Exact prior mechanism; fresh nonce assumed for all core questions |
| Reconnect backoff, skipped Disconnect, client ID reuse | Full issue #9 / PR #10 discussions verified; all three excluded as duplicates |
| Immediate backoff-reset livelock | Already fixed in pinned Rust; nonancestor `0fe2a47` is not evidence a Rust fix is missing |
| Ordinary fragmentation corrupts messages | Refuted by reader semantics and executable two-byte fragmentation control |
| Every RST delivers a prefix | Incorrect; read errors are dropped. Only the observed clean-EOF path is admitted |
| Missing newline always changes the message | Complete body with missing delimiter can retain identical content; changed final token is necessary for this witness |
| Parser accepts arbitrary tokens / untrusted identities | Separate defensive boundary, outside authentic core traffic; only real-encoder prefixes used for INT-1 |
| Own state absent in DVC quorum proves data loss | External majority still intersects commit quorum; full execution and invariant violation required |
| Recovery response overwrite violates persisted view promise | Existing durable-floor check survives map overwrite; max ever observed is not the stored floor |
| Every uncommitted operation must survive | Not required; legitimate suffix replacement is explicitly permitted |
| Recovering replicas count as healthy immediately on process restart | Incorrect for the recovery protocol; they cannot vote/respond until recovery completes |
| NewState overlap, StartView replay or duplicate acknowledgements ignored by audit | All compensating branches read; prefix retransmission/replay defenses are already present |
| Missing reply-loss/full-history/per-handler mechanisms in previous runs | User states prior runs already modeled these; retained as existing context, never counted as a new assurance finding |
| Simulator/Lean checks prove the whole implementation | They are bounded/testing/formal-model evidence with explicit scope; no global proof claimed |

These exclusions are not all debunked GitHub reports. They include fixed history, known duplicates, unsupported hypotheses, and wrong fault assumptions; the coverage counts keep those categories separate.

## Validation performed and confidence limits

1. `cargo test --workspace` at the pin passed: **16 cluster tests and 5 simulator tests**, with zero failures; other workspace unit/doc targets contain zero tests. [Full output](evidence/cargo-test-workspace.log).
2. The standalone frame package passed **3 tests**; exact source-prefix integrity, authentic encoder prefix relation, clean EOF versus read-error behavior, committed operation and client results checked. The support child test is counted transparently, not as another independent safety test.
3. The first timing-only three-process experiment timed out and remains inconclusive. The refined three-process experiment observed actual partial-write state, then reproduced original SET success followed by a shorter fresh-client GET.
4. Static verification reread handler guards, state-transfer overlap, log install, client table, persistence/flush order, reference protocol and full relevant discussion/diff context. Source snapshots remained unchanged.
5. No TLC run, new simulator seed sweep, coverage instrumentation, Lean proof run, code repair, or live CI status check was performed. The historical seed reports in the archaeology are attributed to their commit descriptions, not to this run.

The existing simulator already models loss/replay/delay, crashes, intact restart and memory-wiping reboot, with a durable-view handoff. Its stable phase selects a healthy quorum and keeps noncore replicas down. It stops admitting new requests at this transition, so sustained fresh-request service is a distinct question. Its own reply delivery is direct, but the user explicitly says previous external models already included reply loss, full history and per-handler observations. This report does not erase that coverage or claim it was missing.

Prior-run coverage statements supplied by the user are treated as constraints, not reverified artifacts: round 2 completed only its no-crash baseline exhaustively; broader view/crash searches timed out; combinations involving rolling recovery, recovery with changing views, two-replica edges, real-time client order and continued service remain insufficiently established. A timeout or missing trace is not a positive bug finding.

INT-1 has strong local evidence for Linux process/connection behavior, source mapping, committed state and client-visible results. The controlled pause is a deterministic way to create a feasible partial write; the exact prefix length is not portable or essential. The dedicated peer-REPLY variant and other final-token message compositions are unconfirmed independently and remain testing items. Core MC items are hypotheses for the next phase, with independent Rust replay required before any maintainer-facing core bug claim.

## Phase 4 — Handoff and evidence navigation

[modeling-brief.md](modeling-brief.md) is the 174-line primary handoff. It records Category A, five mechanism Scenarios, what to model/exclude, concrete extensions, safety/liveness properties, and separate model-checkable, test-verifiable and code-review-only findings. Model the actual protocol, including its safeguards; introduce the tested framing refinement only in a separate integration configuration. Retain full historical commitments and original client calls across recovery.

Start with the least-established core combinations using small bounded configurations, fresh nonces and correctly persisted views. Explore several rolling recoveries rather than only one crash. For liveness, keep a stable healthy majority, continuing clients and explicit delivery/timer bounds. Report state-space bounds, completed searches and inconclusive searches independently. A returned trace must be replayed against authentic public-API transitions before confirmation; integration byte refinements must retain their encoder provenance.

Evidence directory contents:

- `core-analysis.md`, `integration-analysis.md`, `history-audit.md`: independent detailed source/discussion reviews.
- `issue-*.json`, `issue-*-full.txt`, `pr-*.json`, `pr-*-full.txt`, `pr-*.diff`, review-comment JSON: all issue/PR discussion evidence.
- `git-ancestry-manifest.json`, history/keyword inventories and historical patch records: complete available archaeology and ancestry separation.
- `vr-revisited.pdf` / `.txt`: retrieved reference with recorded checksum.
- `frame-regression/`: source-preserving fixture, appended tests, exact expected/admitted frames, manifest/lockfile and logs.
- `kvstore-process-check-2.py`, corresponding run directory/result/logs: successful three-binary observation; first attempt retained separately as inconclusive.
- `cargo-test-workspace.log`: baseline validation. `artifact-manifest.json` records final hashes and relevant paths.

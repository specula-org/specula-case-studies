# Independent kvstore and GitHub batch audit

Analysis revision: `3ac0104a567092139534c9022205d02281a2da41`, independently checked with `git rev-parse HEAD`. Remote evidence fetched 2026-09-05 17:40-17:46 UTC. Category A: replicas exchange VSR messages over TCP, with a single owner stepping each in-memory state machine and a filesystem persistence obligation. Non-Byzantine fault model. This is the Code Analysis skill's archaeology/deep-analysis handoff, not a simulator reproduction or completed later bug-confirmation phase.

## Method and complete-reading coverage

- Read `/home/ubuntu/.codex/skills/code-analysis/SKILL.md`, `guide.md`, all shared/distributed/archaeology/modeling-brief references, and the complete hashicorp-raft example.
- Read all 764 lines of `examples/kvstore/main.rs`, all 40 lines of its README, and all 282 lines of root `README.md`.
- Re-read exact library contract/call-chain anchors: `lib.rs:14-32`, `74-107`, `470-541`, `644-813`, `815-893`, `945-968`, `1124-1215`, `1347-1387`, `1404-1475`.
- Searched developer signals and all persistence, clock, socket-timeout, nonblocking, and restart paths in the example and root README. There is one example-introduction commit, `b97ffdd3c7f5e7efc6ef66c1ff0f918caf0723c8`, and no later committed modifications to the example at this pin. Full repository history mining belongs to the parent audit.
- Deeply read every assigned GitHub item: issue #9 and PRs #2, #3, #6, #10 (5/5). Read full bodies, all comments, all four diffs, and all commit descriptions. Used required `gh issue view --comments` / `gh pr view --comments`; augmented with JSON metadata and paginated REST issue comments, inline review comments, and reviews. Nothing was truncated or sampled. Every PR has zero reviews and zero inline review comments; only PR #10 has issue comments (2).
- No source edits, simulator run, commits, pushes, or GitHub writes. Existing untracked `.codex/` was observed and left alone. Evidence-only direct Rust/TCP probes were subsequently run at the parent's request; see the confirmation addendum below.

## GitHub dispositions

| Item | Live status / full-thread coverage | Independent disposition and source consequence |
|---|---|---|
| [#2](https://github.com/penberg/vsr-rs/pull/2) | MERGED 2023-04-15; body empty; comments/reviews/inline comments all 0; 1 commit; full 2-file diff read | Confirmed historical duplicate-message handling defect, maintainer-authored fix `33656b3fbdaffd72862d38ef7bdfc753030ca626`, merge `a56e844dd020200719c31e8ce6bee85b15464dc6`. Added duplicate-op early returns for Prepare/NewState, state and older-view guards for Commit, and simulation duplicate delivery. Old `src/replica.rs` architecture; reference context only, not a new model target. |
| [#3](https://github.com/penberg/vsr-rs/pull/3) | MERGED 2023-04-15; full body; comments/reviews/inline comments all 0; 1 commit; full workflow diff read | Non-bug CI introduction (`15785db8e2095fb88b7e067bc2fdbc34c8ceb9b2`, merge `e0c8c45bcff1e986aebedcaf1a7ae3b0be5c47c8`). Excluded from defect count, not a disputed/false bug report. |
| [#6](https://github.com/penberg/vsr-rs/pull/6) | CLOSED unmerged; body empty; comments/reviews/inline comments all 0; 1 commit; full 2-file diff read | Incomplete 2023 view-change feature branch `2b8848e2c9c521790f5a0a36418a215b99e52d89` with explicit TODOs to select best log and install StartView log. Not evidence those TODO defects exist at the 2026 pinned source; excluded as obsolete unmerged feature, not a false bug report. |
| [#9](https://github.com/penberg/vsr-rs/issues/9) | OPEN, created 2026-09-04 15:50 UTC; full body; 0 comments | Three known example findings individually checked below. (1) reset-triggered backoff: acknowledged by maintainer in PR #10. (2) missing Disconnect on read/write errors: exact code path verified; proposed fix in #10. (3) client incarnation collision: exact arithmetic verified; report says DST triggers it; still unfixed and explicitly excluded from #10. Treat all three as known mechanisms, not novel findings. |
| [#10](https://github.com/penberg/vsr-rs/pull/10) | OPEN; base exactly `3ac0104a567092139534c9022205d02281a2da41`; head `c6969a6242f058f2a7dded67a7be26ff88df14b5`; full body; 2 comments, 0 reviews/inline comments; 2 commit descriptions and full diff read | Bug-fix intent reviewed in full. `0487da265886dd9b52fe952158140d6fad75d3ed` removes backoff on live connection write failure, leaving backoff only for failed connect. `c6969a6242f058f2a7dded67a7be26ff88df14b5` restructures the client loop to emit Disconnect after read/write errors. Maintainer proposed immediate reconnect on reset; author agreed and updated branch. The body explicitly leaves client ID issue alone. No writer timeout, per-peer sender isolation, startup error classification, directory fsync, or recovery nonce fix is present. |

Batch counts: 1 issue + 4 PRs collected and deeply read, 2 total discussion comments, 0 reviews, 0 inline review comments. One confirmed historical library fix (#2); one known issue containing 3 independently verified example mechanisms, with 2 addressed by the still-open #10. Two non-bug/obsolete-feature items (#3/#6) excluded; **zero** discussions debunked as false positives. Do not count #10 as three new bugs or count #3/#6 as false-positive reports.

Raw evidence: `agent-example-issue9-{metadata.json,comments.txt,comments.json}`; `agent-example-prN-{metadata.json,comments.txt,issue-comments.json,review-comments.json,reviews.json}` and `agent-example-prN.diff`, N in {2,3,6,10}.

## Concurrency, atomicity, and error paths

The main thread alone owns Replica/Client/Store and processes one Event at a time (`main.rs:711-750`). Each event invokes a state-machine step, persists current view, then flushes outputs. The timer thread enqueues Tick every 100ms (`673-680`); ticks are event-count based, so busy event queues or synchronous persistence can delay processing. Per-connection reader threads feed an unbounded event channel (`397-413`, `478-498`, `650`). One shared sender receives the entire unbounded outgoing queue (`342-392`, `651-655`), including self-directed client requests (`351-359`) and remotely routed replies (`545-565`). Replica replies owned by this node bypass that sender (`554-558`). A client thread reads its next command only after a pending command receives its reply (`454-472`), preserving one outstanding request per connection.

`persist_view` is synchronous on the main event thread. The intended release boundary is after its success and before `flush` (`749-750`). File content write, file sync, rename, and cache update are separate steps (`574-579`); there is no parent-directory sync. Any returned write/sync/rename error terminates the process (`580-583`), which is a compensating fail-stop guard. Startup read/parse errors take a different path and are swallowed (`687-699`).

## Scenario EX-START: Existing view-file failure silently reboots the identity as new

**Mechanism:** Startup collapses missing, unreadable, and unparseable view files to `None`, then constructs a normal, empty replica under the old replica ID.

**Evidence:** `main.rs:683-699` promises existing files mean recovery but `.ok().and_then(parse.ok())` erases both error classes; `lib.rs:478-500` starts `Replica::new` as Normal in view 0 with empty log and client table. The contract requires recovery after a crash (`lib.rs:14-21`). A malformed regular file can be overwritten successfully by `persist_view` (`main.rs:701`, `574-579`). This is independent of #9/#10.

**Affected paths:** main startup -> read/parse -> `Replica::new` -> normal Request/Prepare/PrepareOk -> persist/flush.

**Reachable consequence to verify:** In view 0, primary r0 and backup r1 commit X at index 1. Crash r0; leave a malformed existing `kvstore-node-0.view`; restart r0 before peers leave view 0. It starts normal/empty. A fresh client asks for Y, assigned index 1. r1 already holds X at index 1, so `on_prepare` takes its duplicate-op path (`lib.rs:716-730`) and acknowledges index 1 without replacing X. r0 counts self+r1 and commits Y (`737-765`). Thus the same replica IDs can have different committed entries at index 1. Fresh client IDs can be used; this trace does not depend on the known client-ID collision.

**Compensating checks:** Recovering replicas would ignore non-recovery traffic (`lib.rs:528-535`), but this branch starts Normal. Higher-view peers reject old-view traffic (`795-802`), so use the explicitly reachable all-view-0 restart window. A persistence write error would terminate startup, so use malformed but replaceable file contents, not an unwriteable directory. Duplicate Prepare handling is correct under conforming library recovery; do not report it independently as a library defect.

**Status / route:** High-priority integration/caller-obligation defect supported by separately tested startup branch and direct Rust protocol consequence (confirmation addendum). A single three-process corruption-to-conflicting-history test has not been run; preserve this composition boundary in reporting. Additional Phase 4 subprocess cases can distinguish NotFound vs permission/read errors. Prefer distinguishing only a provably first-use identity from existing-state failures and failing closed on the latter. No model extension is needed to establish the local branch bug; optional model work is valuable only for an unresolved downstream protocol consequence.

## Scenario EX-WRITER: A stalled socket serializes every destination

**Mechanism:** A blocking write to one connected peer holds the sole sender thread, preventing it from dequeuing traffic for healthy peers.

**Evidence:** one `for (dst, frame) in frames` loop and one shared thread (`main.rs:342-392`, `650-655`); 200ms timeout applies only to connecting (`370`); writes at `384-386` have no configured write timeout or nonblocking mode anywhere in the file. The separate Tick thread continues to enqueue failure-detector ticks, with 100ms intervals and primary timeout 5 (`31-35`, `673-680`). Unlimited single-word values and log transfer frames can exceed finite socket buffers (`81-95`, `217-230`, `424-440`).

**Affected paths:** all protocol/reply/client frame producers -> frames channel -> shared `run_sender` -> blocking `TcpStream::write_all`.

**Consequence to verify:** A connected peer is stopped or stops reading. Once its TCP receive/send buffers fill, a queued frame for it blocks sender progress longer than the nominal 500ms failure-detector scale. Healthy-destination heartbeats, view-change frames, and requests queued behind it are delayed; a healthy majority can lose availability due to one stalled member. This is availability/isolation, not a demonstrated safety violation.

**Compensating checks:** Connection timeout and `last_failure` backoff act before connection establishment or after an I/O error, never while a write remains blocked. Per-peer incoming threads do not isolate the one outgoing writer. The protocol can retransmit, but retries use the same blocked queue. Local replies (`554-558`) bypass it, while new self-directed client requests do not (`351-359`).

**Duplicate filter:** #9(1)/#10 concern a write that has already failed and the subsequent 500ms reconnect backoff. EX-WRITER concerns a write that has not returned. PR #10's proposed/current change cannot release a stalled syscall. Keep EX-WRITER separate.

**Status / route:** Medium-priority integration liveness defect reproduced against the exact `run_sender` body with real loopback TCP (confirmation addendum). The test accepts a connection but never reads, fills buffers, queues a healthy-destination frame, then releases the stalled socket to establish the causal dependency. This measures sender isolation, not full-cluster view churn. Per-peer sender isolation or bounded sends are review routes. Do not spend protocol MC on OS write blocking.

## Scenario EX-FSYNC: Atomic rename is treated as durable name publication

**Mechanism:** The example syncs a new file's content then renames it into place, marks the view persisted, and releases outputs without syncing the containing directory.

**Evidence:** `main.rs:574-579`, followed by outputs at `749-750`; view-survival obligation `lib.rs:14-21`. Linux fsync documentation explicitly requires directory fsync to ensure the directory entry is durable; file sync alone is insufficient. [Linux fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html).

**Affected paths:** `persist_view` on initial startup and every changed view -> `flush` -> crash -> startup/recover.

**Consequence and limits:** Under an OS/power-crash filesystem model where an unsynced directory update can roll back, an externally released view can exceed the view reachable through the durable filename after restart; initial publication can disappear, and replacement can restore the earlier view. This violates the example's implementation of the persisted-view obligation. A process-only crash that leaves the kernel/filesystem running is not enough to demonstrate the defect, and not every filesystem/mount guarantees an observable loss in each trial. This report does not claim a crash-reproduced disk rollback.

**Compensating checks:** Content fsync and atomic rename avoid torn visible content and fail-stop on returned I/O errors, but neither is a durability acknowledgment for the parent directory. The in-memory cached `persisted` view suppresses repeated syncs after rename success (`571-572`, `579`). #9/#10 do not discuss this path.

**Status / route:** Medium-priority code-review-only filesystem contract candidate, independently carried to Phase 4. Establish/document the supported crash/filesystem model, inspect syscall order, and use a filesystem crash harness if claiming actual loss. Review opening and syncing the parent directory after rename and before updating `persisted`/releasing outputs. Do not count a filesystem proof gap as a conforming-library protocol bug or force a generic disk adversary into the protocol model.

## Scenario EX-NONCE: Wall-clock recovery nonce does not establish restart freshness

**Mechanism:** Every recovery nonce is current wall-clock nanoseconds truncated to u64, with all before-epoch errors mapped to 0, and no remembered incarnation counter.

**Evidence:** `main.rs:692-695`; explicit lifetime freshness contract at `lib.rs:505-510`; equality is the recovery-response incarnation filter at `1166-1170`. Rust documents that SystemTime is nonmonotonic and can move backward, so wall-clock generation is not a uniqueness guarantee. [Rust SystemTime](https://doc.rust-lang.org/std/time/struct.SystemTime.html).

**Affected paths:** startup clock read -> `Replica::recover` -> `Recovery` retransmission -> `on_recovery_response`.

**Consequence and limits:** Repeated/frozen/rolled-back clock readings or a before-epoch clock can select the same nonce on different recoveries of one replica. In the general library transport contract, a retained earlier RecoveryResponse with matching nonce can then pass the incarnation test. This is an example nonce-policy contract defect candidate, not evidence the library violates its contract with fresh nonces. The same-view/primary/quorum guards remain (`1171-1192`). An end-to-end safety claim for the actual example additionally needs an old-response delivery schedule realizable through its per-destination TCP stream and sender queue; arbitrary message reordering from a generic simulator is not automatically an example transport witness. FIFO delivery and connection teardown can rule out simplistic stale-response traces and must be audited in confirmation.

**Duplicate filter:** #9(3) concerns client IDs generated from 24-bit seconds and a connection counter. It neither names nor repairs the recovery nonce. #10 explicitly excludes client IDs and does not alter the recovery clock. EX-NONCE remains independent even though both policies use SystemTime.

**Status / route:** Medium-priority independent code-review-only contract-validation candidate; runtime/code-level consequence pending Phase 4. Inject deterministic repeated and before-epoch time into the startup nonce policy and test restart uniqueness; audit retained old responses under the actual transport before claiming safety impact. A durable incarnation allocator or explicitly supported freshness policy is a review route. Do not model nonce collisions as conforming library behavior, and do not pre-prune this cheap audit merely because the likely initial disposition is a caller-contract gap.

## EX-CLIENT and exact known duplicates

**EX-CLIENT — known duplicate #9(3), not new:** `main.rs:485-491` takes seconds modulo 2^24 and starts connection enumeration at 0 every process; same-node restarts in the same second reuse IDs, and the time field also repeats after 2^24 seconds. `Client::new` restarts request numbers and `lib.rs:658-672` answers equal latest IDs/request numbers from cache or drops older requests; `main.rs:528-539` matches replies to connection by ID/request. A new connection may receive success for an old operation or stay pending. Comments at `479-484` state IDs must never repeat, and the library documents the same at `29-31`. Mechanism verified but intentionally excluded as novel; PR #10 body explicitly leaves it unfixed. Additional collision triggers belong to the same identity-allocation root cause, not a new Scenario.

**Known #9(1) — reset backoff:** `main.rs:390` marks write failure, `364-368` drops reconnect attempts for 500ms, matching `TICK * PRIMARY_TIMEOUT`. Maintainer acknowledged alternative reconnect policy in PR #10; current head removes the `last_failure.insert` after write errors. This issue concerns spurious view changes/availability, not protocol safety.

**Known #9(2) — missing Disconnect:** `main.rs:455`, `460`, `472` use `?` before `474`, allowing an existing connection entry in main's map to remain. The `try_clone` error at `452` alone occurs before any command inserts a map entry, so do not claim that particular early return leaks an existing entry. PR #10 retains try_clone's `?` while ensuring read/write loop errors flow through Disconnect, which is consistent with this compensating observation.

## Explicit exclusions / restraint

- Do not elevate no-authentication, malformed peer counts/indices, or arbitrary forged ReplicaIDs into crash-fault protocol bugs; these require a stronger ingress/threat contract. Conforming encoder/decoder traffic preserves single-word operation arguments required by example README lines 37-39.
- Do not claim the example persists Store/log state: only view is intended durable, and recovery must fetch the rest (`examples/kvstore/README.md:38-39`, `lib.rs:505-524`). EX-START concerns bypassing that intended recovery.
- Do not label synchronous view-file I/O itself a safety bug; blocking before releasing outputs preserves the intended ordering. Directory durability and startup fallback are the separate defects/candidates.
- Do not call absence of OS timeout, fsync test, or nonce allocator a confirmed production incident; report the verified mechanism, its conditions, and the pending verification route above.

## Reference documentation checked live

- [Rust TcpStream](https://doc.rust-lang.org/std/net/struct.TcpStream.html#method.set_write_timeout): writes can block indefinitely with no write timeout; `connect_timeout` bounds only connection establishment. This supports EX-WRITER's syscall distinction, not a measured stall.
- [Rust SystemTime](https://doc.rust-lang.org/std/time/struct.SystemTime.html): wall-clock timestamps are not monotonic, and precision depends on the platform. This supports EX-NONCE's missing freshness guarantee, not a claimed ordinary nanosecond collision frequency.
- [Linux fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html): syncing file contents/metadata does not necessarily persist the containing directory entry; directory fsync is needed for that guarantee. This supports EX-FSYNC under the stated filesystem crash model.

## Evidence-only confirmation addendum

The parent created the external Cargo package `evidence/probes`, referencing the untouched pinned library and example by absolute path. I independently read its `tests/public_api.rs`, re-read every claim's library guard/call chain, and reran that test target: **3 passed** (`agent-example-public-api-independent.log`). The singleton probe establishes no replies/commit over 1000 fault-free idle/retry rounds; code inspection establishes that no available self-only path tests the initial self-ack quorum. The EX-START probe uses three real Replica instances, gets the first reply for op 7, makes every replica commit it, reconstructs the old primary using `new`, then gets a second reply for op 9 at the same slot while peers retain op 7. Its fresh client IDs avoid #9(3). The recovery control stays Recovering and ignores a fresh client request. The protocol-consequence test deliberately supplies the constructor choice produced by the faulty example and is not evidence against conforming library callers.

I also independently read the parent's `probes/startup_check.py` and `startup-check.json`: the untouched example executable, launched in private temporary directories with loopback endpoints, replaces both malformed ASCII and invalid-UTF8 existing view files with `0\n` and reports itself primary in view 0; valid `9\n` remains 9 and prints recovery. These establish the actual branch separately from the library consequence; permission-denied and OS-power-crash behavior were not tested.

I added `probes/tests/kvstore_sender.rs` by copying **all 25,910 original source bytes exactly** and appending only a `#[cfg(test)]` module. Source and copied-prefix SHA-256 both equal `12564195ce2a6568e69bce42e672d4c5c7b780cb5eb390c0296821da540320bf`; the manifest is `agent-example-sender-source-manifest.json`. The Linux test requests a 4096-byte receive buffer before accepting the stalled peer, sends a 16 MiB frame using actual unmodified `run_sender`, peeks to establish transmission without draining any data, and queues a small Commit frame for a healthy listener. In the final run, no healthy connection occurred for **801.99514ms**, and the healthy `COMMIT 0 123` frame arrived **5.145483ms after closing the stalled socket**, against the example's nominal 500ms detector scale. **1 test passed** in 0.82s (`agent-example-sender-test.log`). A preceding run also passed; the test was then adjusted to bound its initial accept wait. Final source-prefix equality was rechecked. All waits have bounded test deadlines, and the run uses no random seed or simulator.

The full application can accept a 16 MiB single-word value because it imposes no command/frame size bound (`main.rs:424-440`, `79-117`). This witness does not require malformed protocol messages. It proves shared-sender head-of-line blocking under a stalled receiver; it does not measure a production workload or assert permanent nontermination.

## Additional ingress/platform boundary audit

`decode` trusts peer-supplied fields. A non-ASCII reply token such as `REPLY 0 0 0 é` reaches `value[1..]` at `main.rs:323` and can panic on a UTF-8 boundary. Its peer reader runs in a separate spawned thread (`400-412`), so that particular panic need not terminate the replica owner. A forged entry count is also passed to allocation at `225`; arbitrary malformed structural fields can reach library assertions. These are external ingress robustness questions outside the chosen authenticated/conforming crash-fault message model, not library protocol defects under that model. If the example promises service to arbitrary peer connections, Phase 4 should review validation and resource limits separately (candidate `EX-WIRE`); do not spend MC budget on fabricated malformed protocol values.

The example additionally assumes a 64-bit client identity representation: it packs node/start/counter into u64 (`main.rs:491`), casts to `ClientID = usize` (`726`, `lib.rs:32`), and right-shifts a usize by 56 (`main.rs:502`). `cargo check --bin pinned-kvstore --target i686-unknown-linux-gnu` passed, but the actual `cargo build` failed in untouched `main.rs:502` with `attempt to shift right by 56_i32, which would overflow`; there was no linker/environment error (`agent-example-i686-check.log`, `agent-example-i686-build.log`). This confirms an example build limitation on i686. It warrants a separate platform contract check (`EX-PORT`) if 32-bit targets are supported; it is independent of protocol agreement and should not become a model extension. Review documenting/enforcing a 64-bit example requirement or adapting its identity policy. Do not infer the VSR library itself failed to build: it compiled before the example error.

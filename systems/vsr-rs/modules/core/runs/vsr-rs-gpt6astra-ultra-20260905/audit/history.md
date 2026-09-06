# vsr-rs history and assigned issue audit

Audit date: 2026-09-05. Target: `3ac0104a567092139534c9022205d02281a2da41`. Category A, crash-fault distributed/message-passing protocol. This note covers historical evidence and GitHub records #1–#6; the main report covers current-code analysis and the remaining records. No simulator reproductions, source edits, commits, pushes, or external comments were performed.

## Method and coverage

Read the installed code-analysis SKILL.md, guide.md, shared deep-analysis, distributed-analysis, bug-archaeology, modeling-brief-format, and complete example. Classified before archaeology. BFT and Category B references do not apply. Searched all local refs with every required keyword: `fix`, `bug`, `race`, `panic`, `deadlock`, `correctness`, `crash`, `corrupt`, `leak`, `inconsistent`, `wrong`. Searched complete messages, including bodies, case-insensitively. Also catalogued every commit, regardless of its subject, and examined core-file changes so subjects such as “Random improvements”, “Cleanup”, and “Keep the view-change backoff...” were not discarded.

| Population | Coverage/result |
|---|---|
| Local all-refs history | 21 commits; all catalogued by full messages and file changes. `git rev-parse --is-shallow-repository` = `false`. |
| Local target ancestry | 6 commits, beginning `716c5bfa` and ending `3ac0104a`. |
| Local core-touching commits | 5 when core means `lib.rs`, `tests/`, `simulator/`, or `verify/`: `716c5bfa`, `26869860`, `3ac0104a`, `6ea68910`, `054d2187`. The latter two are retained Lean verification additions, outside target ancestry. |
| Local keyword/core match | 1, `26869860` (“Deterministic simulator” body mentions crashes/faults). Keyword-only archaeology would miss the original corrective series. |
| Recoverable original history | 116 commits, complete GitHub-API ancestry reachable from the user-pinned retained Lean revision `de1a84376afe1102c197c2e0f4ade41eb4494458`, back to `7bf602dc` (2022-10-28). Full commit JSON, changed files, and patches downloaded for all 116. |
| Original keyword matches | 26 across full messages; these include tooling/proof/documentation commits and are not a bug count. |
| Original core-touching commits | 83 screened using `lib.rs`, `src/`, `tests/`, `simulator/`, `verify/`; includes introductions, moves, formatting, instrumentation, viewer files, and the duplicate merge representation of PR #2. All 15 substantive protocol corrective implementations below were reviewed in their actual changed protocol hunks and checked against target mechanisms. |
| Significant protocol corrective commits | 15 unique implementation commits: 13 direct corrections plus 2 feature completions (`06ba5def`, `f8acf515`) addressing demonstrated prior protocol failures. Do not count merge `a56e844d` separately from PR #2's `33656b3f`. |
| Additional assurance corrections | 2 simulator/oracle fixes (`949b3d7f`, `08aeab18`), plus 3 viewer/measurement fixes and deterministic collection ordering, separated below. |
| Assigned GitHub records collected/deeply read | 6/6: issues #1, #4, #5; PRs #2, #3, #6. Bodies and every discussion comment read; all three PR diffs, reviews, and inline-comment endpoints read. |
| Assigned issue counts | 3 issues: 1 confirmed historical bug (#4), 2 design/testing requests (#1/#5); 0 disputed/false bug reports, 0 user errors, 0 uncertain bug reports. The 2 testing requests are explicit nonbug exclusions, not debunked reports. |
| Assigned PR counts | 3 PRs: 1 confirmed merged bug correction (#2), 1 merged CI change (#3), 1 closed/unmerged incomplete feature proposal (#6). Each has 0 discussion comments, 0 reviews, 0 inline comments. |

The current non-shallow repository has rewritten/squashed history: the initial commit already contains the protocol and regression suite, while #4/#5 cite original SHAs absent from local ancestry. The remote 116-commit retained chain closes that known gap. This is not a claim to have enumerated every unreachable object ever hosted by GitHub. Local and original populations are reported separately rather than added into a misleading unique-development-commit count. PR #6's unmerged head was additionally inspected through its PR diff and is outside the retained mainline ancestry.

Raw evidence: `history-evidence/git-log-all.txt`, `git-core-all.diff`, `historical-through-retained-lean.json`, `historical-through-recovery.json`, `commits/<full-sha>.json`, `history-core-patches.txt`, and per-record JSON/comment/diff files. No nonempty changed file in the 116 downloaded commit records lacked its API patch. The inventory appended below records all original commits, including noncore records.

## Adoption across rewritten history

Do not confuse historical implementation ancestry with Git reachability or byte identity at the current target. Independently downloaded retained `de1a843` source and compared it to the local initial additions:

| File | Comparison | Result |
|---|---|---|
| `lib.rs` | retained `de1a843` vs local initial `716c5bfa` | Only the `std` imports are grouped differently; no protocol-body changes. |
| `tests/cluster.rs` | retained `de1a843` vs local initial `716c5bfa` | Only rustfmt layout of the `settled` closure differs. |
| `simulator/properties.rs` | retained `de1a843` vs local addition `26869860` | Byte-identical, SHA256 `dbb3eee6829dab8ecf8be9d508ec6e117306e7f4bf8eb7c760a8dc47b0434ad0`. |

The target's subsequent `3ac0104a` diff was read in full: `ViewChangeVote`/vote fields and locals become `DoViewChange`/DVC names; durability's `voters` becomes `participants`; associated comments/test wording change. It does not change protocol behavior. Thus the historical fixes are present in the target, while current `simulator/properties.rs` is **not** byte-identical to `de1a843`; its current SHA256 is `8358cff632b20e280b8dd93d208d2b3cfa923eb8110a319b63305b290c6c69db`.

Hashes and exact original-to-initial diffs: `history-evidence/original-source-identity.json` and `original-to-local-initial.diff`.

An easily misleading local subject is `0fe2a47f`, “Keep the view-change backoff until the new view has proved stable”. Its local diff changes **Lean only**; the original `b25372d8` changed Rust, tests, and Lean. The Rust portion was already incorporated into local initial `716c5bfa`. Treating local `0fe2a47f` as a pending Rust fix would be wrong.

## Historical protocol corrections: reference context, not current findings

Severity below is impact of the historical mechanism, not a new vulnerability assessment or a claim of production incidence. Critical means a safety/client-result or committed-history violation; High means loss of service or panic. “Present” means the corresponding correction was verified in current source and original-to-current adoption, not that a general proof now exists.

| Original commit / record | Historical root cause and component | Severity | Current disposition and evidence |
|---|---|---|---|
| [`3fee194c`](https://github.com/penberg/vsr-rs/commit/3fee194c99ecea1e5be81c10c1ac578cf9b8ce13) | State transfer completed without acknowledging the newly obtained log, leaving primary waiting for the write. | High | Present: `on_new_state` ends with `send_prepare_ok` (`lib.rs:893`), common helper `lib.rs:1381`; state-transfer regression `tests/cluster.rs:176`. |
| [`60064921`](https://github.com/penberg/vsr-rs/commit/60064921d9ef4ea8650311f47415b96978871a5e) | Commit heartbeat indexed one operation blindly when backup could be behind; needed state transfer and ordered prefix application. | Critical/High | Present: `on_commit`, `lib.rs:776–785`; `commit_up_to`, `lib.rs:1349`; idle/state-transfer tests `tests/cluster.rs:157,176`. |
| [`33656b3f`](https://github.com/penberg/vsr-rs/commit/33656b3fbdaffd72862d38ef7bdfc753030ca626), [PR #2](https://github.com/penberg/vsr-rs/pull/2) | Duplicate Prepare/NewState and nonnormal/stale Commit messages reached assertions or duplicate handling paths without guards. | High | Merged historical correction; newer target acceptance/merge logic supersedes simple early returns: `lib.rs:701–731,776–814,842–897`. Re-acknowledgement of repeated Prepare is intentional after later retransmission fix. |
| [`329cf649`](https://github.com/penberg/vsr-rs/commit/329cf6494365d9e703edaea8a8601122e0a26264) | NewState did not carry/validate the starting log boundary or reject unsolicited state replies by status. | High | Historical range representation and status guards present in `lib.rs:842–897`; its original equality assertion was later generalized by `c149be77`. Do not restore that stricter stale-reply assertion. |
| [`d2700795`](https://github.com/penberg/vsr-rs/commit/d2700795111e5bbcff98f1ed202123443234a8d3) | Prepare advanced the log while state transfer was waiting for a reply tied to the previous boundary. | High | Present via `accept_from_primary` (`lib.rs:795–814`), returning false in StateTransfer; regression `tests/cluster.rs:195`. |
| [`7cf58faf`](https://github.com/penberg/vsr-rs/commit/7cf58faf7b6c34ad804cd23e77ab54708d6353dd) | Quorum for operation n executed only n, although n−1 could be uncommitted; commit index, application order, and replies diverged. | Critical | Present: `on_prepare_ok` calls `commit_up_to(op_number, true)`, `lib.rs:737–768`; sequential helper `lib.rs:1349–1356`; regression `tests/cluster.rs:231`. |
| [`c149be77`](https://github.com/penberg/vsr-rs/commit/c149be774c39d27d78f48f2272379901f92f3a75) | Useful delayed/replayed NewState from an older GetState tripped exact-start assertion during a later same-view transfer. | High | Present: overlap-aware suffix merge, `lib.rs:857–875`; regression `tests/cluster.rs:252`. The comment's same-view-prefix premise remains an assumption to justify globally, not itself a new finding. |
| [`9a74a74c`](https://github.com/penberg/vsr-rs/commit/9a74a74cbd1e7d29325d4fce4b1e996de9c027f3), [issue #4](https://github.com/penberg/vsr-rs/issues/4) | GetState/Prepare/PrepareOk loss could permanently stall because no relevant retry existed; dropping repeated Prepare also suppressed retry acknowledgements. | High | Present: replica `on_idle`, `lib.rs:1233–1285`, and repeated Prepare re-acks `lib.rs:716–731`; regressions `tests/cluster.rs:301,326,348`. |
| [`4e4b0bb6`](https://github.com/penberg/vsr-rs/commit/4e4b0bb60a7628b56079379b87ee61b345efd4bf) | Quorum counted PrepareOk messages rather than distinct replica identities. Replays inflated support, allowing acknowledged history without adequate holders. | Critical | Present: per-operation `BTreeSet` insertion/count, `lib.rs:752–759`; regression `tests/cluster.rs:371`. |
| [`dd5bbb8f`](https://github.com/penberg/vsr-rs/commit/dd5bbb8f5252137aac1fad00f575683b2692a694) | Primary appended every request delivery; duplicate transport/client delivery executed a logical request twice. | Critical | Present: request identity and cached-reply table, `lib.rs:646–691`; result caching `lib.rs:1362–1380`; regression `tests/cluster.rs:411`. Documented client discipline remains necessary. |
| [`bbcc14dd`](https://github.com/penberg/vsr-rs/commit/bbcc14ddcc9a910605d193980529ec628610ed91), #4 | A lost client request had no retry; backup delivery asserted primary role. | High | Present: pending request resend to every replica, `lib.rs:353–373`; backup/non-normal request rejection `lib.rs:651`; regression `tests/cluster.rs:438`. |
| [`06ba5def`](https://github.com/penberg/vsr-rs/commit/06ba5def97a7ff25c157f658268ccf2be894ad23) | Earlier implementation lacked view change, so a live majority excluding failed primary could not progress. Feature completion also incorporated corrected deferred suffix replacement and request-table reconstruction. | High | Present: view-change path `lib.rs:906–1123`; regression `tests/cluster.rs:466`. Early state-transfer truncation from the reference was deliberately avoided; do not model a reverted truncation path as a new target. |
| [`8ab4fffc`](https://github.com/penberg/vsr-rs/commit/8ab4fffc90c52c153433389c496f7a0dd6afeba0) | Fixed election timeout let replicas repeatedly interrupt view changes before completion. | High | Present: view-change attempt counter and bounded exponential timeout, `lib.rs:971–984,1302–1306`; regression `tests/cluster.rs:538`. |
| [`f8acf515`](https://github.com/penberg/vsr-rs/commit/f8acf515a3c1b2acee498d3b7ccef53463830a97) | Memory-losing restart previously rejoined normal with empty log/view 0; past acknowledgement/view promises were forgotten. Implemented recovery with fresh nonce, persisted view floor, quorum/latest-primary state, and inactive recovering status. | Critical | Present: contract `lib.rs:14–21,505–527`, recovering gate `lib.rs:530–536`, handlers `lib.rs:1131–1214`; regression `tests/cluster.rs:575`. This historical fix does not independently prove every promise survives every future recovery composition. |
| [`b25372d8`](https://github.com/penberg/vsr-rs/commit/b25372d85dd8955cb686575257e9d483f86cf941) | Backoff reset immediately on entering Normal, so transient view completion made the next view change start with too-short timeout again. | High | Present: `enter_normal` preserves attempts (`lib.rs:1114–1123`), `note_stable` resets after consecutive periods (`lib.rs:1291–1296`); regression `tests/cluster.rs:632`. Local Lean-only replay of this commit is `0fe2a47f`. |

These are 15 corrective commits, not necessarily 15 independent root causes: #2/#329/d270/c149 belong to the evolving message/state-transfer guard mechanism; retries, identity accounting, ordered application, recovery, and timeout stability are separate mechanisms. All belong in Scenario historical evidence/reference pointers, never as requests to re-create pre-fix behavior.

## Assurance/tooling corrections and excluded keyword matches

| Commit | Verified change | Disposition |
|---|---|---|
| `949b3d7f` | Added real reboot loss and reset per-replica cached observation cursors; fixed RepliesMatchCommits slicing a now-shorter replica log by checking `commit > self.committed`. Current `simulator/properties.rs:317–332`. | Medium simulator/oracle bug, fixed. Historical-state/reset interpretation still needs independent service-property audit; this correction is not proof of historical preservation. |
| `08aeab18` | Liveness-core selection formerly truncated away healthy candidates beyond first quorum before filling larger/full core. Fixed with `core.split_off(quorum)` plus recovering candidates; current `simulator/lib.rs:748–766`. | Medium coverage/configuration bug, fixed. The same commit added read-only status and scripted fault/viewer controls. |
| `467550f1` | Hash collection iteration made Debug/reply failure ordering nondeterministic; BTree collections impose stable identity order. Commit explicitly says protocol selection already relies on equal-rank logs being equal. | Low reproducibility improvement, not an established protocol bug. |
| `502c0653` | Distinguished fixed transit latency from extra random delay in fault counts; viewer default became fixed one tick. | Low measurement/UI correction, not protocol safety. |
| `d454ae4a` | Viewer animation used completed-tick count directly, putting messages at destination too early; adjusted display time. | Low UI correction. |
| `2ba631a3` | Digit 1 selected replica 0; aligned selection digit with actual replica ID. | Low UI correction. |
| `5f32991c` | Replaced usize spellings with aliases, all themselves usize. | Explicit nonbug keyword match: no runtime change. |
| `b6f0d4ce` | Deleted obsolete TODO after gap handling existed. | Explicit nonbug keyword match. |
| `13ac95eb` | Configuration abstraction replaced a historical bitwise `view & n` helper by modulo lookup. Earlier source had no view-change implementation and view remained 0. | Record latent arithmetic discrepancy, no established reachable prior service defect; do not inflate confirmed count. Target uses modulo. |
| `276623c3` | Documentation/accessor cleanup and reordering mutually exclusive Prepare comparisons. | “Random improvements” inspected; no corrective runtime mechanism hidden here. |
| `f9a6d4ea` | Replaced channels/interior mutability with owner-stepped `&mut` state machines and drained outboxes. | Architectural change defining present atomicity boundary, not a protocol bug fix by itself. |
| `19d71e51`, `5cf2b163`, `7faeb4b2`, `de1a8437` | Lean/conformance additions, local lemmas, candidate invariant checks, and preservation skeleton. | Assurance status only. Failed/unproved global obligations do not establish implementation defects. |

## Full assigned issue and PR dispositions

- **[Issue #1](https://github.com/penberg/vsr-rs/issues/1)**, “Deterministic simulation testing”: body asks to consider Turmoil; the one owner comment says it depends on Tokio, which this project does not use, and closes because custom simulator `ef4f804f` exists. Closed 2022-11-05. Testing design request, no bug assertion. Evidence `issue-1.json`.
- **[Issue #4](https://github.com/penberg/vsr-rs/issues/4)**, “Resend messages after timeout”: body describes missing GetState retry; the one owner comment explicitly acknowledges completion in `9a74a74`, `bbcc14d`, `06ba5de`, `f8acf51`. Closed 2026-09-03 after opening 2023-04-15. Confirmed historical liveness bug, fixed. Maintainer comment: [5523020336](https://github.com/penberg/vsr-rs/issues/4#issuecomment-5523020336). All original commit bodies/patches retrieved and target paths checked above. Evidence `issue-4.json`.
- **[Issue #5](https://github.com/penberg/vsr-rs/issues/5)**, “Replace custom simulator with MadSim?”: empty body; the one owner comment explains VOPR-style stepped replicas, seeded workload/network/crash/reboot choices, per-tick safety checking, and majority convergence. Closed 2026-09-03. Testing architecture decision, no independent implementation defect. “Every bug fixed ... found by it” is a maintainer historical statement, not a claim that every allowed execution is covered. Evidence `issue-5.json`.
- **[PR #2](https://github.com/penberg/vsr-rs/pull/2)**, “Handle duplicate messages”: empty body; one commit `33656b3f`, merged 2023-04-15. Zero comments/reviews/inline threads, verified using all endpoints. Full diff adds Prepare/NewState duplicate guards and Commit status/view guards plus duplicate simulation events. Confirmed merged historical correction. Evidence `pr-2.json`, `pr-2.diff`, `pr-2-inline-comments.json`, `pr-2-comments.txt`.
- **[PR #3](https://github.com/penberg/vsr-rs/pull/3)**, “CI configuration”: body says borrowed mvcc-rs CI; one commit `15785db8`, merged 2023-04-15. Zero comments/reviews/inline threads. Diff only adds GitHub workflow cargo check/clippy/test. Nonbug infrastructure. Same evidence naming for record 3.
- **[PR #6](https://github.com/penberg/vsr-rs/pull/6)**, “View change protocol”: empty body, one commit `2b8848e2`, closed **without merge** 2026-09-03. Zero comments/reviews/inline threads. Full diff is an incomplete 2023 proposal: TODO to select best log and TODO to install StartView log. It is not current target code. Mainline implementation is original `06ba5def`, with actual log selection/install/guards. Classify abandoned feature proposal, not an unfixed target defect or a debunked bug. Same evidence naming for record 6.

Combined assigned-record counts: **2 confirmed historical bug records** (#4, PR #2), **4 nonbug/design/incomplete-feature records** (#1, #5, PR #3, PR #6), **0 disputed/false-positive bug reports**, **0 uncertain bug reports**. The 2 confirmed records overlap the commit mechanisms and must not be added to the 15 corrective-commit count as distinct bugs.

## Complete original-history inventory

Core count uses the path set stated above. This inventory preserves every record, including merge duplicates, additions, refactors, proof work, and out-of-core changes. It is a coverage ledger, not a list of defects. The substantive correction table above provides the actual mechanism, target mapping, and impact.

| Commit | Core files touched | Classification | Subject |
|---|---:|---|---|
| `7bf602dc` | 5 | Feature/refactor/format/test development | Viewstamped replication |
| `0d3e653f` | 1 | Feature/refactor/format/test development | State machine apply |
| `462a8614` | 3 | Feature/refactor/format/test development | Switch to interior mutability in `Client` and `Replica` |
| `f1e33f96` | 1 | Feature/refactor/format/test development | Cleanup |
| `bf77a440` | 3 | Feature/refactor/format/test development | Drop useless Sync |
| `34902d21` | 1 | Feature/refactor/format/test development | Multiple requests |
| `99b149b5` | 0 | Outside core path set | Getting started |
| `8a740056` | 1 | Feature/refactor/format/test development | Make `Client` fields non-public |
| `ab63a6c1` | 1 | Feature/refactor/format/test development | Return RequestNumber from request_sync() |
| `458c60f5` | 1 | Feature/refactor/format/test development | Renames |
| `fd8ae52b` | 2 | Feature/refactor/format/test development | Client code cleanups |
| `ca2906b2` | 2 | Feature/refactor/format/test development | Replica code cleanups |
| `7ba5f3dc` | 1 | Feature/refactor/format/test development | Remove redundant assignment |
| `7fcb03fe` | 1 | Feature/refactor/format/test development | Extract commit_op() helper |
| `bc23046c` | 1 | Feature/refactor/format/test development | Commit operations in backups |
| `a7baf5af` | 0 | Outside core path set | README |
| `babd1bf2` | 1 | Feature/refactor/format/test development | Code cleanups |
| `17515f85` | 0 | Outside core path set | Remove redudant assignment from example.rs |
| `501b2ae5` | 0 | Outside core path set | Add rust-toolchain |
| `4f21322f` | 3 | Feature/refactor/format/test development | Add test case for normal operation |
| `257e8aa2` | 3 | Feature/refactor/format/test development | State transfer |
| `5f32991c` | 1 | Feature/refactor/format/test development | Fix types in `Message` |
| `b6f0d4ce` | 1 | Feature/refactor/format/test development | Kill obsolete FIXME |
| `13ac95eb` | 5 | Feature/refactor/format/test development | Configuration |
| `3fee194c` | 1 | Protocol correction; reviewed above | Send PrepareOk after state transfer |
| `ef4f804f` | 0 | Outside core path set | Simulator |
| `b1b35b03` | 0 | Outside core path set | Update README |
| `0364651a` | 3 | Feature/refactor/format/test development | Commit on idle |
| `60064921` | 1 | Protocol correction; reviewed above | Fix commit handling when behind the primary |
| `3bca9224` | 1 | Feature/refactor/format/test development | Extract append_to_log() helper |
| `af14c249` | 0 | Outside core path set | Improve simulator testing experience |
| `1a858254` | 3 | Feature/refactor/format/test development | Switch to parking_lot |
| `d91ba450` | 0 | Outside core path set | Update README.md |
| `9408c80f` | 0 | Outside core path set | Add Jack Vanlightly's blog series on VSR to references |
| `a9880508` | 1 | Feature/refactor/format/test development | Run deterministic simulation test as part of `cargo test` |
| `fc48dd26` | 0 | Outside core path set | Test coverage instructions |
| `15785db8` | 0 | Outside core path set | CI configuration |
| `e0c8c45b` | 0 | Outside core path set | Merge pull request #3 from penberg/ci |
| `d7940c45` | 4 | Feature/refactor/format/test development | Make clippy happy |
| `73d5a822` | 0 | Outside core path set | Drop rust-toolchain |
| `33656b3f` | 2 | Protocol correction; reviewed above | Handle duplicate messages |
| `a56e844d` | 2 | Merge representation of PR #2; no extra bug | Merge pull request #2 from penberg/dup |
| `abf2d6de` | 1 | Feature/refactor/format/test development | Rename broadcast_allbutself() to send_msg_to_others() |
| `af6e78d5` | 3 | Feature/refactor/format/test development | Extract message handlers in separate functions |
| `329cf649` | 2 | Protocol correction; reviewed above | Make NewState handling more robust |
| `cfd3b18e` | 0 | Outside core path set | Update README |
| `87b4bdab` | 1 | Feature/refactor/format/test development | Add some comments to on_prepare() |
| `33981b02` | 1 | Feature/refactor/format/test development | Add some comments to on_prepare_ok() |
| `81969057` | 6 | Feature/refactor/format/test development | Drop mutex from Config |
| `cd6a73b1` | 1 | Feature/refactor/format/test development | Drop mutex from Client |
| `e4d01cf4` | 1 | Feature/refactor/format/test development | Drop mutex from Replica |
| `104328de` | 1 | Feature/refactor/format/test development | Move on_idle() definition |
| `e6bd6c21` | 1 | Feature/refactor/format/test development | Comment the normal operation flow some more |
| `64e6e31f` | 1 | Feature/refactor/format/test development | Add send_msg_to_primary() helper |
| `ce13fe74` | 1 | Feature/refactor/format/test development | Use view_number in on_prepare() |
| `276623c3` | 1 | Feature/refactor/format/test development | Random improvements |
| `58bffd98` | 4 | Feature/refactor/format/test development | Improve StateMachine trait |
| `29b5a55c` | 1 | Feature/refactor/format/test development | Forward state machine apply() result to clients |
| `bd95cee2` | 2 | Feature/refactor/format/test development | Cleanup |
| `ed626546` | 1 | Feature/refactor/format/test development | Simulation test cleanup |
| `8b1271c9` | 10 | Feature/refactor/format/test development | Replace simulation test with a VOPR-style deterministic simulator |
| `d2700795` | 2 | Protocol correction; reviewed above | Drop Prepare messages while a backup is in state transfer |
| `4f4955af` | 0 | Outside core path set | Add testing instructions for coding agents |
| `7cf58faf` | 2 | Protocol correction; reviewed above | Commit the whole log prefix when an op reaches a quorum |
| `c149be77` | 2 | Protocol correction; reviewed above | Use the suffix of a stale NewState instead of asserting on it |
| `9a74a74c` | 2 | Protocol correction; reviewed above | Retransmit lost protocol messages from idle periods |
| `295bc0cb` | 0 | Outside core path set | Add scripts/simulate to run the simulator with random seeds for a while |
| `07a7cc80` | 0 | Outside core path set | Point the VR Revisited paper link at MIT DSpace |
| `155d1835` | 0 | Outside core path set | Link the original Viewstamped Replication paper in the README |
| `03e7ec8c` | 0 | Outside core path set | Add --report to scripts/simulate to summarize recorded results |
| `b75817ee` | 2 | Feature/refactor/format/test development | Move the cluster tests out of src/lib.rs into tests/cluster.rs |
| `1033d166` | 3 | Feature/refactor/format/test development | Run rustfmt over the simulator crate |
| `9176a527` | 7 | Feature/refactor/format/test development | Collapse the library into a single src/lib.rs |
| `642b3dc9` | 1 | Feature/refactor/format/test development | Add a durability property to the simulator |
| `4e4b0bb6` | 2 | Protocol correction; reviewed above | Count PrepareOk acknowledgements per replica, not per message |
| `dd5bbb8f` | 4 | Protocol correction; reviewed above | Add the client table so a re-sent request is not executed twice |
| `bbcc14dd` | 5 | Protocol correction; reviewed above | Re-send a client request that got no reply, and fault client messages |
| `5f4c413c` | 4 | Feature/refactor/format/test development | Crash and restart replicas in the simulator, with a liveness core |
| `06ba5def` | 5 | Protocol correction; reviewed above | Implement view changes |
| `ea4a308d` | 0 | Outside core path set | Add the kvstore example: a multi-node key-value store over TCP |
| `5ed85709` | 0 | Outside core path set | Simplify the kvstore README |
| `8ab4fffc` | 2 | Protocol correction; reviewed above | Back off the view change timeout after each failed view change |
| `1db7bd1e` | 1 | Feature/refactor/format/test development | Drop parking_lot and make env_logger a dev-dependency |
| `f9a6d4ea` | 8 | Feature/refactor/format/test development | Step the replica and client instead of handing them channels |
| `82217243` | 0 | Outside core path set | Credit TigerBeetle in the README and include its license |
| `b8f0176f` | 0 | Outside core path set | Rename the README's ToDo list to Protocol support |
| `949b3d7f` | 3 | Simulator correction; reviewed above | Simulate real crashes: a restarted replica may come back with no memory |
| `f8acf515` | 4 | Protocol correction; reviewed above | Implement replica recovery |
| `afe2d77d` | 0 | Outside core path set | Rewrite the README |
| `9932f5f3` | 0 | Outside core path set | Update copyright |
| `362db5ff` | 0 | Outside core path set | Make the numbered references in the README clickable |
| `d110add9` | 0 | Outside core path set | Remove examples/example.rs |
| `add3c0e3` | 0 | Outside core path set | Keep the brackets on the README's reference links |
| `4988530f` | 1 | Feature/refactor/format/test development | Move src/lib.rs to the top level |
| `cffcb6da` | 4 | Assurance/model development | Add bounded model checking with Kani |
| `467550f1` | 2 | Tooling/UI/measurement; reviewed above | Use B-tree maps and sets instead of hash maps |
| `7fe55481` | 1 | Feature/refactor/format/test development | Document the public type aliases |
| `7ed44341` | 1 | Feature/refactor/format/test development | Document the Message enum and every variant |
| `08aeab18` | 4 | Simulator correction; reviewed above | Let the simulator be observed and driven from outside |
| `a4d9f790` | 3 | Feature/refactor/format/test development | Add a terminal viewer for the simulator |
| `058368c1` | 2 | Feature/refactor/format/test development | Draw the cluster in the viewer, with messages in flight |
| `ddde7e94` | 1 | Feature/refactor/format/test development | Viewer: no random faults and one tick per second by default |
| `502c0653` | 2 | Tooling/UI/measurement; reviewed above | Viewer: a fixed one-tick transit time by default, not a random delay |
| `32181e4d` | 1 | Feature/refactor/format/test development | Viewer: replay a seed read-only, or drive an interactive cluster |
| `d454ae4a` | 1 | Tooling/UI/measurement; reviewed above | Viewer: messages move again |
| `2ba631a3` | 1 | Tooling/UI/measurement; reviewed above | Viewer: digits select the replica with that id |
| `aa3a10bd` | 1 | Feature/refactor/format/test development | Simulator: make vsr-simulator the default-run binary |
| `07d483b7` | 0 | Outside core path set | Update license section |
| `19d71e51` | 6 | Assurance/model development | Replace the Kani harnesses with a Lean model and a conformance check |
| `5cf2b163` | 1 | Assurance/model development | Lean: prove the first two layers of the safety invariant |
| `27d27474` | 0 | Outside core path set | Improve regression test wording in CLAUDE.md |
| `b25372d8` | 2 | Protocol correction; reviewed above | Keep the view-change backoff until the new view has proved stable |
| `10c1fb23` | 0 | Outside core path set | Simulate: report one commit's runs, and rewrite the script in Python |
| `8b0e06ea` | 1 | Feature/refactor/format/test development | Order lib.rs so it reads from top to bottom |
| `7faeb4b2` | 0 | Assurance/model development | Lean: state layers three to five of the safety invariant, prove init and prefix agreement |
| `de1a8437` | 0 | Assurance/model development | Lean: preservation skeleton and the first handler, onGetState |

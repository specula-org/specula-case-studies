# vsr-rs code analysis report

Analysis date: 2026-09-05 UTC. Target: `penberg/vsr-rs`, pinned revision **`3ac0104a567092139534c9022205d02281a2da41`**. Primary deliverable: [modeling-brief.md](modeling-brief.md).

## Verdict and evidence standard

This pass retains **five prioritized independent maintainer-actionable mechanisms**: EX-START, LIB-SINGLE, EX-WRITER, EX-FSYNC, EX-NONCE. The first three have direct executable/API/socket observations; the final two are code-verified contract candidates with explicitly unconfirmed crash/transport consequences. Startup and transport findings concern the shipped example; singleton concerns an accepted library/API configuration. **No new conforming-library protocol safety defect is established.**

The work follows all four phases of the installed code-analysis methodology: reconnaissance, bug archaeology, deep analysis, and modeling-brief synthesis. It does not run the later Specula spec-generation/model-checking/bug-confirmation pipeline. Verification here means exact code rereads, complete call-path tracing, compensation/design checks, and small direct tests where they resolve a concrete question. No bounded pass, missing proof, forged message, or intentionally violated caller contract is counted as a conforming-library bug.

| Stable ID | Scope | Current disposition | Consequence / remaining confirmation |
|---|---|---|---|
| EX-START | kvstore startup / caller obligation | Observed startup fallback and independently observed conflicting-commit API consequence | Existing invalid view file causes normal empty restart; old peers can acknowledge a different operation at the same slot. The two witnesses are separate, not a claimed complete multiprocess crash trace. |
| LIB-SINGLE | library/API supported-size contract | Observed deterministic no-progress behavior | n=1 accepted, quorum=1, but request never commits/replies without a nonexistent peer; support vs explicit rejection remains a maintainer choice. |
| EX-WRITER | kvstore transport | Observed shared-sender blocking | One accepted non-reading peer delays a healthy destination about 802 ms; healthy delivery resumes about 5 ms after release. Availability/isolation finding. |
| EX-FSYNC | kvstore filesystem contract | Verified missing directory-publication sync; crash consequence conditional | No durable name-publication guarantee under a filesystem/system-crash model allowing unsynced rename loss; no power-loss reproduction performed. |
| EX-NONCE | kvstore recovery identity policy | Verified missing guaranteed freshness; actual stale-frame consequence pending | Wall-clock repetition/error fallback can reuse tokens; a safety claim needs a transport-realizable old-response witness. |

A secondary example-only i686 build failure (EX-PORT) is also confirmed; conditional malformed-ingress review (EX-WIRE) is retained without a conforming-protocol claim. Known issue #9's three mechanisms are excluded as new. Assurance IDs AS-01…AS-06, AS-LEAN, AS-TUI and low-priority API-CONFIG remain separate review/test handoffs. Priorities in the brief concern review order and expected impact, not completed downstream severity classification.

## Phase 1 — Reconnaissance and atomicity

**Category A (Distributed / Message-Passing).** VSR replicas are fixed-membership crash-fault state machines exchanging requests, prepare/ack/commit, view-change, state-transfer, and recovery messages. The library does no I/O, starts no threads, and measures time only through caller-supplied idle events (`lib.rs:6-21`). No BFT overlay applies.

The working checkout is the requested revision. Initial and final tracked source contents are unchanged; the pre-existing untracked `.codex/` is preserved. All artifacts and Cargo builds live under `.specula-output/evidence/`. The retained assurance ref is `origin/lean` at `6043ed871dd66f85233e9e30795c16002cc7b573`; its library/example/simulator/test Rust files are byte-identical to the target. This is a separately pinned evidence source, not the analyzed main head. See [source manifest](evidence/source-manifest.json).

| Surface | Scale / complete reading | Role and ownership |
|---|---|---|
| `lib.rs` | 1,476 lines; two independent full reads | Config/message types, Client, Replica, all handlers, log/client-table helpers. One owner calls synchronous methods. |
| `examples/kvstore/main.rs` | 764 lines; full read | Store, wire encoding/decoding, TCP send/receive, client proxy, view file, main event loop. |
| `simulator/lib.rs`, `network.rs`, `properties.rs` | 994 + 227 + 409 lines; full read | Fault generation, scheduling, transport, seven default oracles. |
| Other simulator Rust | 54 + 20 + 166 + 115 + 815 lines; full read | State machine, workload, CLI, five tests, complete TUI. |
| `tests/cluster.rs` | 664 lines; full read and all 16 tests executed | Hand-driven delivery, replication/catchup/retry/view-change/recovery regressions. |
| Documentation/build/automation | Both READMEs, Cargo manifests, CI, coverage/sweep scripts | Declared contracts, feature scope, exercised schedules. Detailed line inventory in simulator audit. |
| Retained Lean / conformance | Full types/system/replica/safety/liveness/twin driver reads; focused combined-invariant/helper proof inspection | Assurance boundary, hypotheses, source correspondence, historical evidence; no new proof build claimed. |

The simulator/automation delegated inventory totals **3,936 lines**. Complete main Rust source reading totals **5,704 lines** (including library, example, simulator, and cluster tests). README and proof/tooling material are additional; counts are source lines, not semantic coverage.

### Atomicity and environment map

| Operation | Effective atomic unit | Interleaving/crash boundary and modeling implication |
|---|---|---|
| `Replica::on_message`, `on_idle` | A synchronous owner method mutating replica and output vectors (`lib.rs:528-642,1233-1286`) | Other replica steps can interleave between methods; no thread race inside `&mut self`. StateMachine::apply is caller code and must be deterministic (`54-60,1362-1365`). |
| Output release | Owner persists view before draining/delivering outputs (`lib.rs:14-21`) | Protocol conforming model must preserve this order; losing persistence deliberately is an integration fault. |
| Example event | Dequeue Event, step Replica/Client, persist view, flush (`main.rs:716-750`) | Synchronous disk I/O can block the owner. Tick thread continues enqueueing, so real time and processed idle-count can diverge (`673-680`). |
| View publication | Write temp → sync temp → rename → cache success (`main.rs:574-579`) | Separate OS operations, no directory fsync; crash granularity is filesystem-specific. Returned errors terminate before flush (`580-583`). |
| Peer send | One shared sender dequeues and performs connect/write (`342-392`) | A blocked write prevents all later destination dequeues; receive threads do not compensate. |
| Client proxy | One command waits for reply before next command (`454-472`) | Preserves one outstanding request per connection; client identity must be fresh after restart (`lib.rs:29-31,274-277`). |
| Simulator tick | Requests → crash/restart → global idle batch → due-message batch → property check (`711-719`) | Coarser than library atomicity; do not inherit whole-tick atomicity in a protocol model. |

No dynamic membership, snapshots, checkpoints, or log garbage collection are implemented (`README.md:75-91`). Missing these optional features is not a defect. Fixed membership requires consistent nonempty configuration and valid identity across owners; invalid construction is a distinct API-validation review item.

## Phase 2 — Complete archaeology coverage

### Collection and depth statistics

- GitHub collection: **6/6 issues** and **4/4 PRs** across all states; all **10 full bodies/discussions** deeply read. There are only six issues, so the skill's medium-project 30+ target cannot be reached by this project. No issue was sampled out.
- Collection included **15 keyword searches plus the bug-label filter**, in addition to complete all-state lists. [Search results](evidence/github-searches.json), [issue index](evidence/issues-index.json), [PR index](evidence/prs-index.json).
- Full thread totals: five issue comments, two PR conversation comments, zero reviews, zero inline review comments. Read through two parallel batches of five items, with explicit `gh issue view --comments` / `gh pr view --comments` and full JSON bodies; PR discussions/inline reviews were also checked through paginated REST.
- Issues: **3 with confirmed/independently code-verified defect content** (#4, #8, #9); #4/#8 are historical fixed issues, #9 contains three known current integration mechanisms. **3 resolved infrastructure/API requests** (#1/#5/#7); **0 discussions debunked as false positives**. Non-bug requests are not falsely counted as rejected bug reports.
- PRs: #2 historical merged defect correction; #3 CI; #6 obsolete unmerged view-change feature; #10 the **only open bug-fix PR**, fully reviewed at head `c6969a6242f058f2a7dded67a7be26ff88df14b5`, base exactly the target. Do not double-count its fixes as new issues.
- Local history: **21 unique commits**, comprising **6 target ancestors including target** and **15 retained Lean descendants**; all full messages/change inventories examined. Twelve keyword searches yield **10 distinct hits**, many about assurance rather than actual fixes.
- Supplemental history: **6 original issue-referenced commits retrieved from GitHub**, despite absence from local refs/objects; full production-core diffs for five corrective commits, plus original Kani/Lean migration. **27 distinct commit records** in the history audit, plus **5 PR-contained commits** reviewed in the separate PR audit (one each in #2/#3/#6 and two in #10).
- Within the six-commit target history there are **zero separately represented Rust protocol fix commits**: initial import already embeds fixes; final source edit is vocabulary-only. The five supplemental production-core corrective diffs and the retained Lean storm correction were inspected in full. This provenance distinction prevents inventing an unrevised linear history.

### Every issue and PR disposition

| Item | Verified content / full discussion result | Disposition |
|---|---|---|
| [#1](https://github.com/penberg/vsr-rs/issues/1) | Custom simulator chosen; Turmoil requires Tokio | Resolved infrastructure request. |
| [#4](https://github.com/penberg/vsr-rs/issues/4) | Maintainer confirms lost-message catchup stall, seed `7008082073273156606`, and retry/view-change/recovery fixes | Confirmed, fixed; reference only. |
| [#5](https://github.com/penberg/vsr-rs/issues/5) | Maintainer explains VOPR-style owner-stepped DST and fault coverage | Resolved infrastructure/design request. |
| [#7](https://github.com/penberg/vsr-rs/issues/7) | Keep on_idle as logical tick; implemented timeout/view-change/backoff | Resolved API design request, no separate proven current bug. |
| [#8](https://github.com/penberg/vsr-rs/issues/8) | Replies update client view and retries broadcast to replicas | Acknowledged historical client-routing defect, fixed. |
| [#9](https://github.com/penberg/vsr-rs/issues/9) | Three mechanisms: reset backoff, skipped Disconnect on errors, seconds-based client-ID collision | Known current integration findings; excluded as novel individually. |
| [PR #2](https://github.com/penberg/vsr-rs/pull/2) | Full duplicate-message handler/test diff | Historical merged fix; no pre-fix hunt. |
| [PR #3](https://github.com/penberg/vsr-rs/pull/3) | Full workflow diff | CI introduction, not a defect. |
| [PR #6](https://github.com/penberg/vsr-rs/pull/6) | Old unmerged implementation has TODOs absent from current code | Obsolete feature branch, not current evidence of incomplete VSR. |
| [PR #10](https://github.com/penberg/vsr-rs/pull/10) | Maintainer suggests retrying immediately after write error; revised diff removes error backoff and ensures loop errors emit Disconnect | Open known fix, unmerged at read; explicitly leaves client IDs alone. No startup/fsync/nonce/writer-isolation repair. |

### Significant historical mechanisms and exact fixes

The [history audit](evidence/agent-history-audit.md) enumerates **every one of the 21 local commits**, six supplemental full commit records, affected components, root causes, current compensation and retained proof boundaries. [Raw history log](evidence/agent-history-log.txt), [core/twin diff](evidence/agent-history-diff.txt), and `agent-history-api-*.json` preserve complete evidence; API patch line counts were checked against change metadata to detect truncation.

| Historical change | Root cause / component | Impact and current handling |
|---|---|---|
| `9a74a74` | Lost GetState/Prepare/PrepareOk lacked retry; transfer/replication | Availability failure; current idle retries (`lib.rs:1233-1284`) and dedicated tests. |
| `bbcc14d` | Lost requests/client routing lacked broadcast retry | Availability; current client pending/retry (`350-371`). |
| `06ba5de` | View-change implementation, retained suffix and monotonic commit behavior; associated oracle updates | Protocol correctness/availability mechanism context; current view/log handlers and commit loop inspected. |
| `f8acf51` | Recovery protocol and persisted-view obligation | Safety-critical recovery context. Also introduced the example's error-collapsing startup, missing parent sync and clock nonce; those remain independent integration candidates. |
| `8ab4fff`, retained `0fe2a47` | Repeated view changes outrun completion; resetting backoff immediately upon normal entry caused storms | Historical high availability impact. Pinned Rust retains backoff until stable idle stretch (`1111-1122,1288-1306`); regression already in `tests/cluster.rs:622-664`. |
| PR #2 and baseline regressions | Duplicate messages, distinct-ack quorum, cumulative prefix commit, overlapping NewState | Historical safety/availability protections present at pin; none re-created by removing guards. |
| `19d71e51` / retained `6ea6891` | Kani/CBMC resource limits and migration to Lean/conformance | Assurance history, not protocol failure or proof of correctness. |

Commit IDs in the table are unambiguous prefixes; complete hashes and full classifications are in the linked audit. A past fix's existence supports mechanism archaeology, but does not establish a new bug elsewhere.

### Reference comparison

Compared [VSR Revisited §§2–5](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf), including the crash-fault model, normal operation, view selection, recovery and state transfer. The implementation's majority/self acknowledgment and view/log selection follow those protocol structures; its state-transfer replies include an explicit starting anchor, and it adds concrete retransmission/backoff. The paper allows a clock nonce only under advancing-clock assumptions; its client-recovery discussion differs from this library's fresh-identity requirement. The library explicitly adds the persisted-view recovery condition motivated by [Michael et al.](https://drkp.net/papers/recovery-tr17.pdf). These differences are contract/context evidence, not new defects. The reference PDF/text is retained in `evidence/vr-revisited.*`; MIT endpoints failed, so the original paper was read from a university mirror.

## Phase 3 — Independently verified live mechanisms

### EX-START — startup fallback can commit inconsistent history

Exact entry path: `examples/kvstore/main.rs:687-689` converts both read failure and integer-parse failure to None; `690-699` chooses `Replica::new`; `701` persists its view 0. `Replica::new` creates Normal/empty state (`lib.rs:478-503`). The documented restart path instead requires `recover` (`14-21,505-524`).

Two independent observations establish the mechanism:

1. **Unmodified executable startup:** temporary per-case directories contain either `not-a-view\n`, invalid UTF-8 bytes, or valid `9\n`. On loopback, the first two start successfully, print no recovery notice, and overwrite the file as `0\n`; valid 9 prints `recovering from view 9` and retains 9. See [startup output](evidence/startup-check.json) and [script](evidence/probes/startup_check.py).
2. **Unmodified library consequence:** commit X=7 at slot 1 in view 0, propagate commit, replace only primary 0 with the exact `new` constructor selected above, and send a new client Y=9. Peer 1 retains X@1, interprets Prepare(1,Y) as a retransmission of a held slot (`716-730`), and acknowledges op 1. Primary 0 counts its own acknowledgment plus that peer (`737-765`) and replies for Y@1. Test asserts unequal committed entries and both observed reply values. [API probe](evidence/probes/tests/public_api.rs), [results](evidence/public-api-tests.log).

The control uses `recover(0,...,view=0,nonce=42)` and confirms requests are ignored while Recovering. This is not a separate Prepare handler bug: its duplicate handling relies on the restart contract, which kvstore violates. Higher-view peers would reject old-view messages; the witness specifically keeps peers in view 0 before timeouts. A permanently unwritable view directory causes persist failure and exit before outputs, so the positive witness uses invalid but replaceable regular files. Invalid UTF-8 supplies a real `read_to_string` error branch, not only a parse error.

Only one replica is replaced; fresh client identities are used. No issue #9 client-ID collision or forged protocol message is needed. The current evidence composes startup and protocol witnesses by a verified constructor call chain; it is not mislabeled as a full three-process filesystem crash execution. Handoff: fail closed on existing-state failures, distinguish deliberate bootstrap from recovery, and add expected-correctness regression tests. A path that is absent because an operator changed data directories cannot automatically be treated as proof of first use either; this is the same bootstrap/identity contract.

### LIB-SINGLE — a supported self-quorum has no commit trigger

Config's `add_replica` accepts one entry and `quorum()` returns one (`lib.rs:90-98`). `on_request` appends and records `{self_id}`, then sends only to other replicas (`677-694,1404-1409`). `on_prepare_ok` is the sole normal-case request commit trigger (`737-765`). Primary idle only sends Commit/retries Prepare to others (`1235-1253`); duplicate client requests drop while reply is absent (`658-673`). There is no compensating local quorum check.

The direct test uses one replica with one request, then 1,000 idle and retry rounds. Every message/reply drain is empty; op remains 1, commit remains 0, state remains unchanged. This finite witness plus the closed call-path analysis establishes a permanent no-peer progress mechanism, without claiming a general liveness theorem. Source and output: [API probe](evidence/probes/tests/public_api.rs), [test log](evidence/public-api-tests.log).

The acceptance is externally exposed: simulator validation accepts n≥1 (`simulator/lib.rs:258-259`), interactive TUI passes `replicas.max(1)` (`tui.rs:244-245`), and kvstore argument validation checks only ID range (`main.rs:628-630`). Random sweeps select 3..7 and lite selects 3 (`226,253`); no existing cluster/simulator regression covers n=1. Retained Lean's ≥2 combined-invariant hypothesis and weaker “settled” predicate do not discharge this question. Handoff: commit on initial self-quorum if singleton is supported, or reject/document it consistently. The inability to recover lost singleton volatile state from nonexistent peers is separate and should not obscure failure-free startup progress.

### EX-WRITER — healthy destinations wait behind a non-reading peer

`run_sender` is one loop for every destination (`main.rs:342-392`), created once at `655`. Connection establishment has a 200 ms timeout (`370`), but `write_all` has neither write timeout nor nonblocking mode (`384-386`). While it is blocked, the loop cannot dequeue healthy-peer frames. The incoming peer reader threads and protocol retransmits do not release that syscall; retransmits enter the same queue. Some same-node replies bypass the sender (`554-558`), but replica messages, remote replies, and self-directed requests can be queued behind it.

The loopback test uses an exact-byte copy of the full pinned example with an appended test module; `run_sender` itself is unchanged. A peer accepts with a requested 4,096-byte receive buffer and never reads. A valid 16 MiB request frame creates buffer pressure; a healthy peer's Commit frame is queued behind it. The retained run observed no healthy connection for **801.99514 ms**, then healthy Commit delivery **5.145483 ms** after closing the stalled socket. This exceeds the nominal 100 ms × 5 = 500 ms detector scale (`31-35`). The precise timer firing also depends on queued idle events and the heard-from-primary flag; the test does not claim a measured cluster election.

[Socket test](evidence/probes/tests/kvstore_sender.rs), [test log](evidence/agent-example-sender-test.log), [source-copy manifest](evidence/agent-example-sender-source-manifest.json). The copied source prefix is 25,910 bytes, SHA-256 `12564195ce2a6568e69bce42e672d4c5c7b780cb5eb390c0296821da540320bf`. All sockets/processes belong to the probe; no existing services were stopped.

This is distinct from #9 item 1: that issue and PR #10 act **after a write error returns**, reducing reconnect backoff. They cannot unblock a write that is still running. Handoff: independent per-peer sending or appropriate bounded I/O/backpressure; test healthy-peer service while another peer stops reading. Treat it as integration availability, not a safety counterexample.

### EX-FSYNC — durable contents do not establish durable filename publication

Exact path (`main.rs:574-579`): write `<path>.tmp`, open/sync that file, rename to view path, cache `Some(view)`. No directory sync exists elsewhere. `749-750` then releases outputs. A returned write/sync/rename error terminates the process (`580-583`); that is correct fail-stop compensation, but successful unsynced directory publication remains uncovered.

Linux's [fsync contract](https://man7.org/linux/man-pages/man2/fsync.2.html) distinguishes flushing file contents/metadata from ensuring its directory entry is durable. Under a supported filesystem/system-crash model where the rename can be lost, restart can expose an old view or lose initial publication after outputs escaped. The current run verified the missing guarantee, **not** a power-loss rollback on a specific filesystem/mount. A process-only crash with the kernel running does not demonstrate directory-publication loss.

Handoff independently to code review: specify the crash/filesystem contract; audit opening/syncing the parent directory after rename and before cache success/flush; use syscall-order and filesystem crash tests if asserting actual lost persistence. Do not turn this into arbitrary persisted-view corruption in a conforming-library model. Historical recovery work and #9 duplicates do not dispose of this helper-level obligation.

### EX-NONCE — wall clock is not a durable incarnation policy

`lib.rs:505-510` requires every recovery token for a replica to differ from earlier recoveries. The example takes `SystemTime::now().duration_since(UNIX_EPOCH).as_nanos() as u64`, with errors mapped to 0 (`main.rs:692-695`), without saved nonce history. [Rust SystemTime documentation](https://doc.rust-lang.org/std/time/struct.SystemTime.html) does not guarantee monotonicity. Clock rollback/repetition or repeated before-epoch failure therefore defeats a uniqueness guarantee; ordinary same-nanosecond collisions are not claimed to be likely.

`on_recovery_response` requires Recovering, the current nonce, a quorum of distinct sender records, the primary state at the highest returned view, and a view at least persisted (`lib.rs:1166-1193`). Those guards remain effective with fresh nonces. A repeated token removes the incarnation distinction, but actual safety impact also requires old matching response delivery.

A tempting generic-message schedule retains empty primary/backup responses from one recovery, later commits X, then replays those old responses after another crash with the same token. **That alone is not an example transport witness:** a primary's old response queued before its later Prepare cannot stay ahead of that Prepare in the same FIFO sender/TCP stream while the latter is delivered first; unread bytes on an old dead process's TCP connection do not automatically transfer to a new connection. Multiple reader threads/reconnects require a concrete schedule before claiming that consequence. Keep EX-NONCE as an independent contract-validation handoff, with clock injection and actual transport audit, not an already reproduced history-loss defect.

Issue #9 item 3 instead reuses client IDs because seconds/counter fields repeat (`main.rs:485-491`); PR #10 explicitly does not fix that known issue. The distinct recovery-token mechanism is neither a duplicate nor permission to assume a generic simulator's arbitrary replay is possible in the shipped TCP integration.

## Assurance findings and low-cost review handoffs

Detailed inventories, compensations and test routes are in the [simulator audit](evidence/agent-simulator-report.md) and [retained history/proof audit](evidence/agent-history-audit.md).

| ID | Exact evidence | Consequence and confirmation route |
|---|---|---|
| AS-01 | `simulator/properties.rs:89-101,185-201,233-244,277-285,324-331` caches previously checked indices/results | Same-height overwrite of already observed prefix can escape incremental checks. Mutation-test against a full historical-prefix oracle. This does not show such an overwrite is protocol-reachable. |
| AS-02 | `simulator/lib.rs:711-719,891-927` runs global idle/delivery batches then checks | Transient bad state repaired within a batch may be unobserved; global heartbeat schedule narrows interleavings. Add per-handler hooks/independent idle scheduling. |
| AS-03 | `simulator/network.rs:14-31`; `simulator/lib.rs:950-961` delivers replies directly; clients created once at `simulator/lib.rs:474-476` | Reply loss/delay/partition/replay and client restart are not exercised. Request duplicates can generate extra replies, which is narrower than faulty return transport. |
| AS-04 | `simulator/lib.rs:226,253,258-259`; TUI `244-245` | Singleton accepted but absent from random and existing regression configurations. Linked to LIB-SINGLE, not another library defect. |
| AS-05 | `simulator/lib.rs:695-704,944-946` | Reboot always recovers from ideal saved view with PRNG nonce; no example filesystem/clock/startup path. PRNG sampling is not a mathematical uniqueness proof, though collision is not claimed in this run. |
| AS-06 | `simulator/lib.rs:566-592` | Safety-budget expiry latches false `requests_done`; a later healed/converged run can still report “no liveness.” Clarify policy and test post-healing outcome; not a protocol liveness proof. |
| AS-LEAN | Retained `System.lean:32,72-73`, `Invariant.lean:170,302`, `Safety.lean:205`, `Liveness.lean:63-69,93`; `verify/verify_tests.rs:90-93` | Explicitly state nonce/config/client-progress hypotheses, proof gaps and tool-availability skip. See details below. |
| AS-TUI | `simulator/tui.rs:318-322,389-399` | Interactive packet-loss changes are not included in saved fault script; record them for reproducible replay. Low-priority tooling gap. |
| EX-PORT | `examples/kvstore/main.rs:491,502,726`; `lib.rs:32` | Actual i686 example build fails: shifting 32-bit usize by 56 overflows. Library compilation succeeds. Document/enforce 64-bit example support or revise identity representation. |
| EX-WIRE | `examples/kvstore/main.rs:225,323,400-412` | Unchecked count allocation and a malformed non-ASCII reply token can panic its reader thread through byte slicing. Review arbitrary-ingress/resource contract separately; no conforming-message protocol defect. |
| API-CONFIG | `lib.rs:75-98,292-300,478-503` | Empty config/invalid self ID can be constructed without validation; primary lookup can panic on zero members. Define constructor preconditions or reject consistently. Misconfiguration/defensive API item, not a valid-membership protocol bug. |

AS-01 compensation matters: commit-counter monotonicity still runs each tick; reboot resets per-replica watermarks while preserving canonical history; final Convergence compares whole logs among the selected core (`properties.rs:125-147,222-225,378-406`). These catch many persistent faults, but do not close temporary repaired corruption or disagreement outside the final core. `install_log` asserts length, not prior-prefix equality (`lib.rs:1321-1344`), so that helper cannot independently guarantee oracle soundness. No library mutation was injected or simulator failure reproduced in this pass; the proposed oracle mutation test is explicitly future work.

The root README describes simulator messages broadly (`README.md:178-193`), but the actual reply-drain path is narrower. Line coverage tooling measures reached source lines, not behavior coverage, oracle completeness, or caller conformance. The historical commit message's 97% figure is not rerun or presented as live evidence.

### Retained Lean and related proof evidence

Retained Lean is pinned and extracted under `evidence/agent-history-lean/`; all following paths refer to that revision. `Safety.lean:184-195` proves sent-message well-formedness and commit bounds, while the full `NoPanic ∧ PrefixAgreement ∧ Durability` theorem at `202-205` remains `sorry`. The general settling theorem remains `sorry` at `Liveness.lean:89-93`. Initialization, invariant-to-prefix implication, selected handler/helper preservation and quorum intersection have proof material; none alone supplies full protocol preservation. Proof incompleteness is not a bug.

Differential conformance defaults to 40 seeds × 200 steps (`verify/verify_tests.rs:10-11,97-119`), only three/five replicas (`verify/lib.rs:342`), and increasing nonces (`388-392`). It compares observable replica state, log, application history and generated messages/replies after individual steps, but private tables/timers are only indirectly exposed. Without lake, the test prints a skip and returns success (`90-93`). No new Lean/conformance execution is claimed here.

The abstract `Step.recover` takes any Nat nonce without a freshness precondition (`System.lean:32,72-73`); generated conformance traces are stricter. Combined `Inv.init` requires at least two members (`Invariant.lean:170,302`). `Sync.settled` tests Normal/same view/empty in-flight queue, not committed log or answered client (`Liveness.lean:63-69`); a singleton can satisfy it while its request hangs. Synchronous settling also uses a particular batch scheduler and discards old queued messages at entry (`50-58,78`); bounded checks need that scope. Nat arithmetic and totalized handlers differ from Rust integer/panic behavior.

Retained hand-proof/Veil material explicitly identifies additional abstraction and incomplete proof scope; Veil omits clients/replies/application state and assumes quorum structure. Those files and retained run artifacts explain coverage, not current verified compilation or production safety.

## Exclusions and compensation audit

**Zero GitHub issue discussions were debunked as false positives.** The following exclusions are analysis-level dispositions, not invented counts of false bug reports.

| Candidate / suspicion | Why excluded or narrowed | Evidence |
|---|---|---|
| EX-CLIENT / #9(3) | Already known same identity-allocation mechanism; additional seconds-wrap/rollback triggers are not novel roots | `main.rs:478-491`; full #9 body; #10 body leaves it unfixed. |
| Reset backoff / #9(1) | Known, separately addressed by open #10; does not absorb EX-WRITER | `main.rs:364-390`; full current PR diff/comments. |
| Missing Disconnect / #9(2) | Known, separately addressed by #10; `try_clone` failure alone occurs before a client map entry exists | `main.rs:452-474,725-728`; PR diff. |
| Historical replay/retry/backoff/recovery protection | Present at target; no “remove the guard” or pre-fix reproduction target | History table and full regression inventory. |
| Missing sender/membership/message-shape checks | Forged IDs, impossible log lengths, misrouting or malformed frames require extra ingress/threat assumptions | `lib.rs:609,623,743-756,853,932`; Category A crash-fault scope. |
| `on_get_state` lacks primary-only guard | Normal replicas may answer; conforming requester sends to primary, and guard omission alone establishes no bad path | `lib.rs:818-838,1390-1397`. |
| Old StartView overwrites current grown log | Same-view replay after Normal is rejected | `lib.rs:954-960`. |
| Catchup immediately truncates acknowledged suffix | Current code retains suffix while waiting; replaces only on accepted response, preserving local committed prefix | `lib.rs:875-889,1095-1108`. |
| Client-table reconstruction loses needed old result | One outstanding request means a later request implies earlier reply already received; matching committed cache preserved | `lib.rs:274-277,1324-1369`. |
| TUI displays only every 5,000 steps | Each internal step still executes normal simulator checks; display batching adds no extra oracle loss | `simulator/tui.rs:72-73,128,335-344`. |
| Manual reboot loses too much replica memory | Explicit scripted faults can exceed non-recovering quorum assumptions; that does not establish protocol fault tolerance failure | `simulator/lib.rs:622-625,750-753,870-880`. |
| Finite timeout / unfinished proof / source coverage gap | Insufficient evidence of semantic failure; preserve scope and assurance disposition | AS-01…AS-LEAN above. |
| Generic MC-ADOPT | No verified unhandled adoption path after checking all compensation; independent review recommends no hunt | [MC candidate review](evidence/agent-simulator-mc-adopt-review.md). |

## Phase 4 — Modeling-brief synthesis and verification routing

The [modeling brief](modeling-brief.md) carries Category A, six mechanism-based Scenarios, independent stable IDs, source anchors, consequences, model/do-not-model decisions, proposed properties and method-specific handoffs. EX-START, LIB-SINGLE, EX-WRITER, EX-FSYNC and EX-NONCE each remain visible; they are not buried in a generic example-obligations bucket.

**No targeted §6.1 model-checkable finding is selected.** The generic possibility of authentic delayed adoption messages corrupting a prefix was reviewed independently, including NewState, StartView, DVC selection, recovery filtering and client-table rebuilding. It supplies a standard safety obligation and an oracle gap, but no concrete unhandled implementation mechanism. Turning it into a counterexample by dropping existing guards, corrupting persisted views or repeating a caller-required fresh nonce would change its premise. The skill's value filter therefore keeps it out of a costly hunt; see [review](evidence/agent-simulator-mc-adopt-review.md).

This selection does not prove library correctness and does not pre-prune the cheap code-review candidates. Downstream confirmation should audit EX-FSYNC, EX-NONCE, EX-PORT, EX-WIRE, API-CONFIG and assurance contracts independently, and convert the direct observations into expected-correctness regressions for proposed fixes. If a baseline model is nevertheless generated, retain fresh nonce/persist-before-send/client discipline and per-handler atomicity; describe any pass as bounded assurance with exact assumptions, not a new finding. Finite liveness needs an assumption-satisfying stabilization witness and non-exhaustive boundary.

## Verification performed, reproducibility and limits

Commands below run from the source directory and use an isolated external Cargo workspace. Its lockfile pins dependencies used by the probes; analyzed library/example/test code is read directly from the unchanged pinned source. The socket test copies exact source bytes solely to append a local test inside the module, with a source-prefix hash check.

```sh
cargo test --offline --manifest-path ../.specula-output/evidence/probes/Cargo.toml --tests -- --nocapture
cargo build --offline --manifest-path ../.specula-output/evidence/probes/Cargo.toml --bin pinned-kvstore
python3 ../.specula-output/evidence/probes/startup_check.py
cargo test --offline --manifest-path ../.specula-output/evidence/probes/Cargo.toml --test kvstore_sender -- --nocapture
```

The initial `--tests` run preceded creation of the socket test: **16 existing cluster tests passed, plus 3 purpose-built API observations/control passed**. The later socket invocation ran **1 test, passed**. Startup script passed **3 subprocess cases**. Therefore 20 distinct Rust tests plus three startup cases have current evidence; this is **not** a claim that the full workspace simulator suite or CI was rerun. API tests intentionally assert observed defective behavior; they must be inverted/adapted to expected behavior when fixing it. Independent re-read of the probes and a focused rerun checked their premise without changing source.

The additional platform check used the i686 Rust target: `cargo check --offline --manifest-path ../.specula-output/evidence/probes/Cargo.toml --bin pinned-kvstore --target i686-unknown-linux-gnu` passed, while `cargo build` with the same arguments failed at unchanged `main.rs:502` with an arithmetic-overflow compile error, before any linker failure. See [build log](evidence/agent-example-i686-build.log). This is an example platform limitation conditional on claimed target support, not a failure of library compilation; it does not alter the native test pass counts.

Toolchain: `rustc 1.95.0 (59807616e 2026-04-14)`, `cargo 1.95.0 (f2d3ce0bd 2026-03-21)`. There was no simulator/DST run, no simulator-discovered bug, no TLC model, no new Lean build, and no production incident. Thus the repository's simulator-specific seed/regression rule was not triggered; direct probes have the full source commit and no random seed. No commit, push, PR, issue comment or external publication was made.

Evidence entry points:

- [Source revision/hash manifest](evidence/source-manifest.json), [API tests/results](evidence/public-api-tests.log), [startup results](evidence/startup-check.json), [socket result](evidence/agent-example-sender-test.log).
- [Full history/retained proof audit](evidence/agent-history-audit.md), [history evidence hashes](evidence/agent-history-manifest.json).
- [Full example/issue/PR audit](evidence/agent-example-audit.md), [full simulator/issue/test inventory](evidence/agent-simulator-report.md).
- [Primary modeling handoff](modeling-brief.md), [independent MC value-filter review](evidence/agent-simulator-mc-adopt-review.md).

Live GitHub states above describe the fetched 2026-09-05 snapshot; issue/PR evolution afterward does not change the analyzed revision. Physical filesystem crash behavior, recovery-clock collision transport reachability and full protocol correctness remain outside the demonstrated results.

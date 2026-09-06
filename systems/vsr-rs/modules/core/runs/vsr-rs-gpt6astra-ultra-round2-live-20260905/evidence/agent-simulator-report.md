# Simulator and issue-verification audit

Revision inspected: `3ac0104a567092139534c9022205d02281a2da41`; target Category A (deterministic, owner-stepped replicas communicating by messages). Read-only source inspection; no simulator execution, source edits, commits, or external writes. No new library bug is claimed by this audit.

## Method and coverage

Read the installed `/home/ubuntu/.codex/skills/code-analysis/SKILL.md`, its complete `guide.md`, shared deep-analysis, distributed-analysis, bug-archaeology, modeling-brief-format references, and the complete hashicorp-raft brief example. Applied full-file reading, exact-line rereads, compensation checks, execution-path tracing, and design-intent verification.

Files read completely, with line numbers:

| File | Lines | Role |
| --- | ---: | --- |
| `simulator/lib.rs` | 994 | Faults, options, owner-stepped scheduler, output flushing, reboot, convergence |
| `simulator/properties.rs` | 409 | All seven default oracles |
| `simulator/network.rs` | 227 | Loss, replay, exponentially sampled delay and order |
| `simulator/state_machine.rs` | 54 | Accumulator and operation-history recording |
| `simulator/workload.rs` | 20 | Add/subtract operation generator |
| `simulator/main.rs` | 166 | Seed selection, overrides, verdict/output |
| `simulator/simulator_tests.rs` | 115 | All five simulator tests |
| `simulator/tui.rs` | 815 | All interactive/replay behavior and presentation |
| `tests/cluster.rs` | 664 | Harness and all sixteen cluster integration tests |
| `scripts/coverage` | 190 | Instrumentation, seed sweep, coverage reporting |
| `scripts/simulate` | 223 | Parallel sweep, exact commit/dirty records, timeouts |
| `.github/workflows/smoke_test.yml` | 26 | Build/lint/test/one-seed simulator CI |
| `simulator/Cargo.toml` | 33 | Binary/test target declarations |

Total: 3,936 lines. Also reread `lib.rs:948-968,1300-1380` specifically to check compensation for the incremental-oracle gap. Developer-signal scan found no TODO/FIXME/HACK/XXX/BUG/WARN markers in the inspected simulator/test/script paths.

## Full issue threads

Collected/deeply read in this delegated batch: **5/5 issues**. Every thread has **one comment**, which was read in full, together with its complete body. Commands: `gh issue view -R penberg/vsr-rs N --comments` and `gh issue view ... --json number,title,body,comments,state,url,createdAt,closedAt`. Raw comments and full body/comment JSON are retained as `agent-simulator-issue-N.txt` and `.json` in this directory.

| Issue | Current state | Verified disposition | Mechanism and evidence |
| --- | --- | --- | --- |
| [#1](https://github.com/penberg/vsr-rs/issues/1) Deterministic simulation testing | CLOSED | Resolved infrastructure request; not a correctness finding | Body proposes Turmoil. Maintainer explains it depends on Tokio, which this project does not use, and closes in favor of custom simulator `ef4f804fd6b373ba66f33c3e5231b3775a97e68c`. |
| [#4](https://github.com/penberg/vsr-rs/issues/4) Resend messages after timeout | CLOSED | Confirmed historical liveness bug, fixed; reference only | Body describes a lost GetState/NewState exchange leaving catchup stalled. Maintainer confirms simulator seed `7008082073273156606` at `c149be7`, with retry fixes `9a74a74` (GetState/Prepare/PrepareOk), `bbcc14d` (client retry), `06ba5de` (view change), and `f8acf51` (recovery). |
| [#5](https://github.com/penberg/vsr-rs/issues/5) Replace custom simulator with MadSim? | CLOSED | Resolved infrastructure/design request; not a correctness finding | Empty body. Maintainer describes choosing VOPR-style DST, single-thread owner-stepped state machines (`f9a6d4e`), randomized seeded configurations and fault injection (`8b1271c`, `5f4c413`, `949b3d7`), tick checks and majority convergence. |
| [#7](https://github.com/penberg/vsr-rs/issues/7) Remove on_idle() from Replica | CLOSED | Resolved API/timing design request; no separate proven defect in this thread | Body requests a logical tick and autonomous primary timeout. Maintainer clarifies on_idle remains the tick; `06ba5de` implements timeout/view change and `8ab4fff` backs off unsuccessful view changes. |
| [#8](https://github.com/penberg/vsr-rs/issues/8) Notify client if primary changed | CLOSED | Confirmed acknowledged historical client-routing defect, fixed; reference only | Maintainer confirms `06ba5de` adds view to replies and adoption by Client::on_reply; `bbcc14d` retries an outstanding request to all replicas. |

Counts by disposition: **2 confirmed historical corrected correctness mechanisms**, **3 resolved infrastructure/API-design requests**, **0 disputed/false-positive exclusions**, **0 unresolved issues**, **0 newly reported bugs**. Do not describe the three non-bug requests as false positives. These five threads do not mention or resolve the independently supplied startup-fallback, singleton, sender-isolation, parent-fsync, or restart-nonce candidates.

Relevant local history fully reviewed for simulator intent: `26869860b6d488f1c09ad3f145e8af3088d876e9` adds deterministic simulator (full module contents read); `a67f1f8b5182fc2871390f75c271394d0538dac2` adds coverage reporting (script read completely), with commit message claiming a historical 100-seed run reaches 97% of `lib.rs` lines; `3ac0104a567092139534c9022205d02281a2da41` changes only voter/participant vocabulary in the durability oracle. The 97% number is a commit-message claim, not a freshly reproduced or semantically complete verification result.

## Assurance findings and concrete verification routes

### AS-01 — Incremental oracles assume previously observed committed entries cannot change

**Mechanism:** after a committed index has been checked once, several properties skip it on subsequent ticks. They therefore assume part of the immutability property that a safety regression may violate.

**Exact evidence:** `Durability` examines only `.take(commit).skip(self.verified[id])` and advances the watermark (`simulator/properties.rs:89-101`); `StateMatchesCommittedLog` only compares newly committed `state.applied[i]` against log entries and updates an incremental expected value (`185-201`); `CommittedPrefixAgreement` only compares previously unseen per-replica indices against a canonical prefix (`233-244`); `NoDuplicateOps` only inserts newly committed IDs (`277-285`); `RepliesMatchCommits` caches results from whichever replica is furthest and never recomputes an already learned prefix (`316-331`).

**Compensation checked:** CommitNumberMonotonic checks index/length and nondecreasing counters (`properties.rs:125-147`), which does not detect equal-length replacement. Reboot resets per-replica watermarks (`71-75,119-123,166-170,222-226,264-268`) and retains the canonical historical prefix, so known reboots are not the missed case. Convergence checks the *full* current log among selected core members only at finalization (`378-406`), so a lasting mismatch in the selected core is detected. It does not close a repaired-before-finalize window, nor disagreement confined to an excluded non-core replica. `lib.rs:1321-1325` documents the committed-prefix precondition for install_log but only asserts length; `1344` replaces the log without a prior-prefix equality assertion. This is not evidence that current conforming messages can supply a conflicting prefix.

**Consequence:** a future same-height overwrite of a previously verified committed entry, with unchanged applied history/value, can evade all incremental tick checks; final core equality may also pass after repair or exclusion. This is a concrete oracle/test gap, **not a current library safety violation**.

**Verification route:** test the oracles with a deliberate committed-prefix overwrite mutation after an initial successful observation; include same-height replacement on a non-core replica and temporary corruption repaired before convergence. Compare an independent full historical-prefix oracle at each event or a periodic full audit. Confirm it fails against the mutation and passes on unmodified code. No expensive TLA+ target is needed.

### AS-02 — The scheduler observes batches rather than every protocol transition

**Mechanism and anchors:** a tick executes requests, crashes, all due idle handlers, and all due messages before calling check_properties (`simulator/lib.rs:711-719`). All live replicas share the same heartbeat modulus (`891-901`). The network extracts an entire due batch (`network.rs:178-184`); the scheduler runs every `on_message` in that batch before flushing and checking (`lib.rs:907-927`). A generated response is flushed after the batch and is not delivered until the next tick, even if its delay is zero.

**Consequence:** no property observes the state immediately after each individual handler. A transient invariant break repaired by a later delivery in the same tick can be missed. A commit with insufficient holders repaired by later same-batch replication is not assessed at the actual commit transition. Synchronous global idle scheduling and no crash within a handler or flush constrain explored interleavings. These are explicit exploration/observation limits; no assertion is made that current code admits the transient regression.

**Compensation and route:** tick checking catches persistent end-of-tick violations; individual Rust handlers include their own assertions, but these are not a substitute for global invariants. Add optional event-level oracle hooks after each on_message/on_idle and before output publication, plus independent per-replica idle schedules. Use mutation tests to validate that a transient bad state is observable. Protocol models should split owner actions/events according to actual library atomicity rather than copy the simulator's whole-tick atomicity.

### AS-03 — Reply loss, delay, replay, partition, and client restart are outside the simulated network

**Mechanism and anchors:** `Envelope` targets a ReplicaId and holds only protocol `Message<Op>` (`simulator/network.rs:14-31`); replies are drained directly into `Client::on_reply`, client_inflight completion, and the global reply history (`simulator/lib.rs:950-961`). The network's `fault_client_messages` flag covers Request messages, not replies (`network.rs:157-160`). Partition/drop logic applies to queued envelopes (`lib.rs:909-924`) and cannot affect these directly delivered replies. Client objects are created once (`474-476`); reboot only replaces a replica (`695-704`).

**Consequence:** default DST cannot explore an operation committed before its only reply is lost, reply delay across a view change/client reconnect, duplicate/reordered reply delivery caused by transport, or restart reuse of client identity/request counters. Request duplication can induce multiple generated replies, and the reply oracle does validate all drained replies (`properties.rs:333-348`), but that is narrower than a faulty return channel.

**Existing compensation:** the cluster test manually delivers a duplicate request after its commit and checks a cached reply (`tests/cluster.rs:405-432`); lost-request retry is checked (`434-458`); a new view learned from a reply is checked (`460-531`). These support pieces of the mechanism without exercising reply transport faults or client restarts. Therefore this does not itself claim an at-most-once bug.

**Verification route:** add reply envelopes and explicit client crash/restart to DST or deterministic integration tests. Drop the first committed reply, retry through view change, and check one execution plus correct reply; delay old replies across reconnect and verify matching by client identity and request number. Keep known identity issue #9 / PR #10 filtering independent of new nonce/startup candidates.

### AS-04 — Singleton accepted by public runner interfaces but absent from random/test coverage

`Options::validate` accepts `replica_count >= 1` (`simulator/lib.rs:258-259`). Initialization builds precisely that many config entries and replicas (`466-473`). Random swarm chooses `3..=7` (`226`), lite forces 3 (`253`), and the five simulator tests add only an explicit 7-replica case (`simulator/simulator_tests.rs:62-67`). The sixteen cluster tests use 3 or 4 replicas; none uses 1 or 2. Interactive TUI advertises `--replicas` (`tui.rs:44-46`) and passes `args.replicas.max(1)` into interactive options (`244-245`), so singleton is a concrete accepted runner configuration.

This is direct support for the parent's independent singleton-progress candidate. It must remain separate from the general assurance scenario: verify the actual `Replica` self-quorum progress route with a tiny direct Rust integration test, then either make it commit/reply or reject/document unsupported size consistently. No singleton simulator run was performed here.

### AS-05 — Example persistence and restart-identity policies are idealized away

Simulated durable view is an in-memory vector (`simulator/lib.rs:438-441`) assigned before messages drain (`944-949`). Reboot always calls `Replica::recover` with that saved view and a PRNG-drawn u64 nonce (`695-704`). No filesystem read/parse failure, rename/directory-fsync crash point, wall-clock regression, or example client-ID selection exists in these paths. This explicitly bounds DST evidence for startup-fallback, durable name publication, and nonce-freshness scenarios. It does not establish any defect in those paths; use example-focused tests/fault injection and caller-contract review independently.

### AS-06 — A safety-phase timeout remains a failure even after fault-free convergence

Safety transition latches `requests_done = (requests_replied == requests_max)` (`simulator/lib.rs:566-568`). A no-reply budget expiry transitions to liveness with this flag false (`567-575`). Liveness disables faults and restores a core (`729-780`), permits pending requests to finish, and checks convergence (`584-586`), but then rejects solely because the old flag was false (`587-592`). That flag is never updated in liveness.

This may be an intentional finite-run acceptance policy, but it prevents reading a timeout as proof of violation of post-stabilization progress. In particular, if all requests had been sent before a transient partition exceeded the safety budget and all replies arrived after healing, the final error still says “no liveness” based on the earlier latch. Verification route: an isolated harness-policy test holding a partition until the safety budget then allowing complete healing; report which phase/assumptions actually failed. A protocol liveness result needs an assumption-satisfying stabilization witness and stated finite/non-exhaustive bounds.

## Existing regression coverage inventory

`tests/cluster.rs` has 16 tests: normal operation; idle commit propagation; gap catchup; reordered Prepare during state transfer; cumulative PrepareOk commit; stale overlapping NewState; lost GetState retry; lost PrepareOk retry; lost Prepare retry; duplicate PrepareOk distinct-sender quorum; duplicate request execution/cached reply; lost request client retry; primary-crash view change/client learns view; timeout backoff; recovery after memory loss; and view-change timing-ring stabilization. Fixed historical mechanisms belong to reference context; do not use them as new model-checkable findings.

`simulator/simulator_tests.rs` has 5 tests: same-seed determinism (ticks/network summary/replica-0 value), perfect-network request completion, replay-only seeds 3/4/5, seven replicas, and a scripted primary crash/restart + backup reboot + partition/heal sequence. No property mutation/soundness tests, per-event observations, singleton regression, reply-network fault test, client restart test, or example filesystem test occurs in those files.

CI (`.github/workflows/smoke_test.yml:18-26`) checks/lints workspace/all targets/features, runs workspace tests, then one full swarm simulator run whose seed is derived from github.sha. Scripts perform larger random sweeps; `scripts/simulate:48-65` distinguishes clean versus tracked-dirty revision labels while reports can group both, and records commands/seeds at `112-125`; these records are not an immutable dirty-source snapshot. `scripts/coverage:149-176` measures source lines in an instrumented simulator sweep, not protocol-state/branch/assumption coverage or test-oracle soundness. Neither script executes the kvstore integration as a real transport/filesystem deployment.

## Secondary TUI notes and exclusions

TUI `observe` summarizes only the last frame (`tui.rs:150-197`), potentially after 5,000 steps (`72-73,335-344`), but every step still calls `sim.step_run` (`128`), so the visual batching is **not an extra lost safety-check layer** beyond AS-02. Do not report that as a library or oracle bug.

Manual/scripted `Fault::Reboot` bypasses the random reboot quota (`lib.rs:622-625` versus `870-880`); it can intentionally violate the assumption that at least a quorum retains non-recovering memory. The liveness transition explicitly asserts a non-recovering quorum (`750-753`). Such an invalid manual scenario or exhausted budget is not itself a protocol bug.

Interactive packet-loss key changes network options (`tui.rs:389-399`) without adding that change to the printed injected-fault script (`318-322`); full replay of an interactive session therefore needs its loss changes separately. This is a low-priority reproduction-format limitation outside the focused maintainer correctness targets, not a TLA+ scenario.

No retained Lean claims were assessed in this delegated task; the parent handles them independently. No current simulator pass or production safety/progress guarantee is asserted.

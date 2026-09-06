# Modeling Brief: vsr-rs

## 1. System Overview

- **Revision:** `3ac0104a567092139534c9022205d02281a2da41`; Rust, 1,476-line `lib.rs`, 764-line kvstore integration.
- **Category A (Distributed / Message-Passing):** fixed-membership crash-fault replicas communicate through owner-delivered messages, persistence, and idle events; not BFT.
- **Algorithm:** Viewstamped Replication Revisited; primary is `view % membership`, quorum is `n / 2 + 1` (`lib.rs:86-98`).
- **Architecture:** single-owner, synchronous `Replica`/`Client` handlers; volatile logs/application state; caller persists view before publishing outputs and always recovers an old identity (`lib.rs:6-21,505-524`).
- **Integration:** one replica/client event loop, one shared peer sender, multiple socket readers and a timer thread (`examples/kvstore/main.rs:650-680,716-750`).
- **Reference differences:** persisted-view recovery, explicit retransmission/backoff, anchored suffix transfer, fresh client identity after restart; no reconfiguration, checkpoints, or log GC (`README.md:47-91`; `lib.rs:197-206,505-524,1233-1306`).
- **Outcome:** prioritize five independent concrete mechanisms below. No new conforming-library protocol safety defect was established, and no targeted model-checking hunt is justified by the remaining evidence.

## 2. Scenarios

### Scenario 1: Existing identity silently restarts as new — EX-START

**Mechanism:** read/parse errors erase the distinction between an existing replica and first initialization.
**Evidence:**
- Historical: known library persistence obligation is context only (`lib.rs:14-21`); issue #9/PR #10 do not report this startup mechanism.
- Code: `.ok().and_then(parse.ok())` selects `Replica::new` on failure; startup then overwrites the file (`examples/kvstore/main.rs:683-701`).
- Direct observations: unmodified executable accepts malformed and invalid-UTF-8 files as view 0; public-API schedule commits different operations at slot 1 after this constructor choice (`evidence/startup-check.json`, `evidence/public-api-tests.log`).
**Affected code paths:** startup → `Replica::new` → request → peer duplicate `Prepare` acknowledgment → quorum commit (`lib.rs:478-503,646-694,716-730,737-765`).
**Expected consequence:** old peers retain X@1 while restarted primary replies for Y@1 in view 0; this is an integration violation of the library restart contract.
**Suggested modeling approach:** no TLA+ extension; retain the small Rust witness and independent executable startup checks. Their composition is code-supported, not a claimed three-process crash reproduction.
**Priority:** High. **Rationale:** reachable parse/read failure, externally meaningful conflicting commit, small fail-closed initialization repair.

### Scenario 2: Accepted self-quorum never triggers commit — LIB-SINGLE

**Mechanism:** commit evaluation occurs only when a peer acknowledgment arrives, although the initial self acknowledgment can already be a quorum.
**Evidence:**
- Historical: no issue/PR reports this; retained Lean combined invariant assumes at least two replicas and its settling predicate is weaker than client progress (reference pointers below).
- Code: Config accepts one member; request records self acknowledgment but never checks it (`lib.rs:74-98,682-694`); normal-case primary commit evaluation occurs in `on_prepare_ok` (`737-765`).
- Direct observation: fault-free n=1, quorum=1, 1,000 idle/retry rounds leave op=1, commit=0, replies=0 (`evidence/public-api-tests.log`).
**Affected code paths:** `Config`, `Replica::new/on_request/on_idle/on_prepare_ok`; simulator accepts n≥1 but random configurations use n=3..7 (`simulator/lib.rs:226,253,258-259`; TUI `244-245`).
**Expected consequence:** accepted singleton client requests hang; maintainer must either support self-quorum progress or consistently reject/document the configuration.
**Suggested modeling approach:** direct public-API integration regression; no finite-liveness model needed. Recovery of a singleton after total volatile-state loss is a separate availability limit.
**Priority:** High. **Rationale:** tiny deterministic witness, no faults or disputed scheduler assumptions.

### Scenario 3: One blocked peer stalls all queued destinations — EX-WRITER

**Mechanism:** one synchronous sender serializes potentially unbounded writes across independent peers.
**Evidence:**
- Historical: #9 item 1/PR #10 address backoff *after an error*, not a write that has not returned; keep duplicate filtering exact.
- Code: shared FIFO loop uses blocking `write_all` without write timeout (`examples/kvstore/main.rs:342-392`); connect timeout only bounds connection establishment (`370`).
- Actual unchanged-sender test blocks healthy traffic for 801.995 ms; delivery resumes 5.145 ms after release (`evidence/agent-example-sender-test.log`).
- Failure detector uses 100 ms ticks and five missed periods (`31-35`), while messages to healthy peers wait behind the blocked write.
**Affected code paths:** `flush` → shared `run_sender`; queued client requests/replies and replica heartbeats/state transfer (`545-565,650-655`).
**Expected consequence:** a non-reading peer can delay healthy-peer traffic past the failure-detector interval, impairing availability of the healthy majority.
**Suggested modeling approach:** bounded loopback test invoking unchanged sender code; per-peer queues/deadlines/backpressure review. Model transport scheduling only if a later protocol question requires it.
**Priority:** High. **Rationale:** independently actionable sender isolation issue; protocol model alone cannot establish real socket scheduling.

### Scenario 4: View file rename is released without durable directory publication — EX-FSYNC

**Mechanism:** file contents are synced before rename, but successful rename is treated as durable publication of the new name.
**Evidence:**
- Historical: persisted view is an explicit caller obligation (`lib.rs:14-21`), not a reason to suppress an integration defect; #9/#10 are unrelated.
- Code: write temporary file → `sync_all` temporary file → rename → cache `Some(view)` (`examples/kvstore/main.rs:569-579`); outputs follow at `749-750`.
- Linux `fsync(2)` requires separate directory synchronization to guarantee the directory entry (link in §7).
**Affected code paths:** `persist_view`, startup publication, event-loop persist-before-flush.
**Expected consequence:** under a filesystem/system-crash model that can lose unsynced rename publication, restart may read an old/missing view despite already released messages. Process-only crashes do not establish this failure.
**Suggested modeling approach:** independently audit the supported filesystem contract; syscall-order test and filesystem crash harness. Do not inject generic lost persistence into the conforming-library model.
**Priority:** High, conditional on supported crash model. **Rationale:** missing durability guarantee is code-visible; actual power-loss trace remains untested.

### Scenario 5: Wall-clock recovery tokens lack guaranteed freshness — EX-NONCE

**Mechanism:** wall-clock sampling supplies a required never-reused incarnation identifier without a monotonic durable allocator.
**Evidence:**
- Historical: #9 item 3 is **client-ID** reuse and is excluded as known EX-CLIENT; it does not report recovery nonce allocation.
- Code: `recover` demands a distinct nonce for every recovery (`lib.rs:505-510`), but example uses `SystemTime` nanoseconds narrowed to u64 with error fallback 0 (`examples/kvstore/main.rs:692-697`).
- `SystemTime` is not monotonic; same-view stale responses are filtered only by the supplied nonce and response-quorum checks (`lib.rs:1166-1193`).
**Affected code paths:** example restart token generation → `Replica::recover/on_recovery_response`.
**Expected consequence:** clock rollback/repetition or error fallback can violate the nonce contract. Stale-state adoption additionally requires delivery of old matching responses; TCP/FIFO/reconnect reachability is not yet demonstrated.
**Suggested modeling approach:** clock-policy and transport audit first; inject deterministic repeated clock values in an example test. No generic replay-based safety hunt until the actual transport witness is established.
**Priority:** Medium. **Rationale:** concrete missing contract guarantee; separate from the much easier known seconds-based client-ID collision.

### Scenario 6: Test observers omit important state and transport histories — AS-01…AS-06, AS-LEAN

**Mechanism:** cached or batched observation and idealized environment assumptions leave regressions outside the verification envelope.
**Evidence:**
- Incremental oracles skip previously checked committed indices (`simulator/properties.rs:89,185,233,277,324-331`); full final comparison only covers selected core (`378-406`).
- Checks run after a whole tick/delivery batch (`simulator/lib.rs:711-719,907-927`); replies bypass the fault network (`950-961`).
- Reboot uses saved in-memory view and PRNG nonce (`695-704,944-946`); singleton is accepted but absent from sweeps; the pre-healing request-completion flag remains latched (`566-592`).
- Retained Lean full safety and general settling theorems remain `sorry`; fresh-nonce assumptions and client-progress scope also need explicit treatment (see report).
**Affected code paths:** seven default properties, scheduler/flush/reboot, liveness verdict, retained proof/conformance statements.
**Expected consequence:** assurance gaps and potentially misleading test interpretation, not evidence of a current library protocol defect.
**Suggested modeling approach:** mutation tests for oracle soundness, per-handler observation, reply-network tests, and explicit assumptions. Keep these out of protocol bug counts.
**Priority:** Medium. **Rationale:** improves future evidence quality; do not use a proof gap to invent a protocol hunt.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

No targeted MC candidate survives this pass's value filter. The strongest findings already have direct Rust witnesses or require concrete OS/caller-contract evidence. The generic “delayed adoption messages might violate safety” question was independently reviewed and rejected as insufficiently grounded; details and compensating guards are in `analysis-report.md`.

If Spec Generation still needs a baseline, use one atomic library handler per action, fixed valid membership, authentic delayed/lost/duplicated messages, durable view before released outputs, `recover` for every old identity, fresh recovery nonces, deterministic application state, and one outstanding request per fresh client identity (`lib.rs:14-21,274-277,505-535`). Treat such a baseline as bounded assurance, not a new finding. Record any liveness stabilization witness, fair-delivery/timer assumptions, bounds, and non-exhaustive scope.

### 3.2 Do Not Model (with rationale)

| What | Why / route |
|---|---|
| EX-START, LIB-SINGLE | Direct executable/API tests resolve the concrete behavior more cheaply. |
| EX-WRITER | Real blocking transport and scheduling require a socket test. |
| EX-FSYNC, EX-NONCE | Confirm filesystem/clock/transport assumptions independently before protocol abstractions. |
| AS-* oracle/proof gaps | Test/proof contracts need repair; gaps are not protocol counterexamples. |
| Fixed historical bugs or removed guards | Reference only; no pre-fix wrappers or targeted guard deletion. |
| Reconfiguration, checkpoints, log GC, BFT/forged senders | Absent features or outside fixed-membership crash-fault scope. |

## 4. Proposed Extensions

**None selected for a targeted hunt.** Do not add lossy persistence, reusable nonces, singleton schedules, or a blocked sender to a conforming-library spec merely to regenerate these direct-test/contract findings. Any later integration model must name its actual caller deviation and keep the result separate from library protocol safety.

## 5. Proposed Invariants

These are handoff property contracts; listing them does not authorize or claim an MC result.

| Invariant | Type | Description | Targets / verification route |
|---|---|---|---|
| CommittedPrefixAgreement | Safety | Equal committed positions contain equal full requests across replicas and time. | Standard baseline; independent full-history oracle, AS-01. |
| CommitBounded / AppliedPrefix | Safety | Commit ≤ log length; application history exactly folds committed log. | Standard baseline; per-handler checks, AS-02. |
| AtMostOnce / ReplyCorrect | Safety | Unique logical request executes once per incarnation; reply matches committed result. | Standard baseline; reply-loss/retry tests, AS-03. |
| RestartMustRecover | Safety | A previously used replica identity cannot enter Normal empty through error fallback. | EX-START, executable startup + API witness. |
| AcceptedSingletonCompletes | Liveness | A supported one-member live configuration commits and replies without peer input. | LIB-SINGLE, deterministic test or constructor rejection. |
| SenderIsolation | Liveness | A stalled peer does not indefinitely block healthy destinations. | EX-WRITER, bounded socket observation; no universal timing claim. |
| PublishedViewDurable | Safety | Released messages use a view whose name/value survives the declared crash model. | EX-FSYNC, filesystem contract/crash test. |
| RecoveryNonceFresh | Safety | Recovery tokens do not repeat for the same identity while old replies can be relevant. | EX-NONCE, allocator/clock/transport audit. |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

**None selected.** No new conforming-library safety counterexample is claimed. Preserve all cheap independent candidates below for downstream confirmation; an empty MC hunt list must not discard them.

### 6.2 Test-Verifiable

| ID | Description / present evidence | Suggested next verification |
|---|---|---|
| EX-START | Executable fallback and conflicting-commit API consequence observed separately. | Convert to fail-closed regression; optionally compose into a real three-node restart test. |
| LIB-SINGLE | Public-API stall observed with n=1 and no faults. | Expected-correctness regression for support or explicit constructor/runner rejection. |
| EX-WRITER | Shared blocking path; retained socket probe evidence accompanies detailed report. | Healthy peer must remain independently serviceable during a non-reading peer test. |
| EX-PORT | Unmodified example i686 build fails on `client_id >> 56` (`examples/kvstore/main.rs:502`); library builds. | Document/enforce 64-bit example support or revise the identity representation; retain cross-build regression. |
| AS-01 / AS-02 | Cached prefixes and batch observation. | Deliberate same-height/temporary prefix mutation; compare full per-event oracle. |
| AS-03 | Reply faults and client restarts omitted. | Drop first committed reply, retry across view change; delay old replies across reconnect. |
| AS-04 / AS-05 | Singleton/persistence/clock example paths uncovered. | Add explicit boundary and integration tests; do not count idealized DST as coverage. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action / independent confirmation route |
|---|---|---|
| EX-FSYNC | No parent-directory sync; filesystem-crash consequence conditional. | Define supported crash model, audit publication ordering, then validate with crash harness. |
| EX-NONCE | Non-monotonic clock does not ensure required nonce freshness. | Audit/revise durable incarnation policy; prove actual stale-frame reachability separately. |
| EX-WIRE | Unchecked peer reply UTF-8 slicing/counts (`examples/kvstore/main.rs:225,323`). | Audit ingress/resource contract and parser robustness if arbitrary peers are supported; outside crash-fault MC. |
| API-CONFIG | Empty Config and invalid self ID accepted by constructors (`lib.rs:75-98,478-503`). | Specify/validate constructor preconditions; user-misconfiguration boundary, not conforming-protocol bug. |
| AS-06 | Pre-healing deadline latch can remain “no liveness” after healing (`simulator/lib.rs:566-592`). | Clarify finite-budget policy; separate pre-stabilization timeout from post-stabilization progress. |
| AS-LEAN | Proof scope/nonce freshness/settling semantics and skipped conformance. | Make hypotheses and proof status explicit; no new library bug claim. |
| AS-TUI | Interactive loss changes omitted from saved fault script (`simulator/tui.rs:318-322,389-399`). | Preserve loss-change events for replay; low-priority test reproducibility issue. |

## 7. Reference Pointers

- [Detailed analysis and complete candidate dispositions](analysis-report.md); [source hashes](evidence/source-manifest.json); [probe sources](evidence/probes/tests/public_api.rs); [startup checks](evidence/probes/startup_check.py).
- Main source anchors above refer only to pinned `source/`; [history/Lean audit](evidence/agent-history-audit.md), [example audit](evidence/agent-example-audit.md), [simulator audit](evidence/agent-simulator-report.md) hold full reading/discussion coverage.
- Retained assurance revision: `6043ed871dd66f85233e9e30795c16002cc7b573`; `lean/Vsr/Invariant.lean:170,302`, `Safety.lean:202-205`, `Liveness.lean:63-69,89-93`, `System.lean:32,72-73`; extracted under `evidence/agent-history-lean/`.
- Historical context only: [#2](https://github.com/penberg/vsr-rs/pull/2), [#4](https://github.com/penberg/vsr-rs/issues/4), [#8](https://github.com/penberg/vsr-rs/issues/8), fixed storm `0fe2a47`; exact known integration duplicates: [#9](https://github.com/penberg/vsr-rs/issues/9), open [PR #10](https://github.com/penberg/vsr-rs/pull/10) at `c6969a6242f058f2a7dded67a7be26ff88df14b5`.
- [VSR Revisited, §§2–5](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf); [recovery/persistence analysis](https://drkp.net/papers/recovery-tr17.pdf); [Linux fsync contract](https://man7.org/linux/man-pages/man2/fsync.2.html); [Rust SystemTime](https://doc.rust-lang.org/std/time/struct.SystemTime.html); [TcpStream write timeout](https://doc.rust-lang.org/std/net/struct.TcpStream.html#method.set_write_timeout).

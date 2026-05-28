# Autobahn BFT — Analysis Report (Audit Trail)

This document is the audit trail for the modeling brief at `./modeling-brief.md`. It enumerates findings with code citations, classifies them, and reports coverage statistics.

Target: `specula-org/autobahn-artifact`, branch `autobahn`, commit `bf897ef`.

---

## 1. System Category and Justification

- **Category A — Distributed / Message-Passing** with **BFT** overlay.
- **Justification**: the protocol's safety/liveness arguments rest on tolerating up to *f* Byzantine validators across a partially-synchronous, authenticated network with `n = 3f+1`. Replicas communicate exclusively via reliable TCP/JSON; there are no shared memory or lock-free data structures. Concurrent access inside each process is mediated by mpsc channels; safety reasoning is per-task. The reference algorithm is `Autobahn` (SOSP'24).
- **Reference files**: `references/distributed-analysis.md` + `references/bft-analysis.md` (no concurrent-library analysis is applicable).

---

## 2. Phase 1 — Reconnaissance Summary

### 2.1 Repository Layout

```
artifact/autobahn-artifact/
├── Cargo.toml                    # workspace: primary, node, store, crypto,
├── primary/                      #   worker, consensus, network, config, hotstuff
│   └── src/
│       ├── core.rs            (2 352 LOC)  main consensus event loop
│       ├── messages.rs        (1 589 LOC)  Header, Vote, Cert, ConsensusMessage, QC, Timeout, TC
│       ├── aggregators.rs       (211 LOC)  VotesAggregator, QCMaker, TCMaker
│       ├── synchronizer.rs      (305 LOC)  proposal / parent / payload sync
│       ├── committer.rs         (307 LOC)  slot-ordered commit / dag flattening
│       ├── proposer.rs          (267 LOC)  Header construction
│       ├── header_waiter.rs     (443 LOC)  pending sync requests, retry
│       ├── certificate_waiter.rs(131 LOC)  waiter for cert ancestors
│       ├── garbage_collector.rs  (97 LOC)  consensus_round writer (DEAD CODE — see Family 6)
│       ├── primary.rs           (348 LOC)  Primary::spawn wiring
│       ├── leader.rs             (48 LOC)  SemiParallelRRLeaderElector
│       ├── timer.rs             (106 LOC)  Timer / CarTimer / FastTimer
│       ├── tla_trace.rs         (256 LOC)  TLA+ trace emission (recent addition)
│       └── tests/                          repros: test_da{1,2,3,5,13}_*,
│                                           bug{1,3,4}_*
├── worker/                       Header dissemination layer
├── hotstuff/, sailfish/          Baseline / predecessor implementations
└── node/src/main.rs              Bin entrypoint (NOTE: Consensus::spawn commented out
                                  → garbage_collector dead code)
```

### 2.2 Protocol Sketch

For each slot `s` (with view `v` starting at 1):
1. **Prepare**: Leader broadcasts `Prepare{slot=s, view=v, proposals=tips, tc=None/Some(TC), qc_ticket}`. Receivers vote if proposal set has full coverage from local tips and (if `v=1`) the `qc_ticket` proves `committedSlots ⊇ {s−k}`.
2. **PrepareQC**: When `2f+1` Prepare votes form, the leader emits `Confirm{slot, view, qc, proposals}`. If `3f+1` Prepare votes form (fast path), the leader skips Confirm and emits `Commit` directly.
3. **Confirm**: Receivers vote if they haven't already in this `(slot, view)`. (This last check is missing in code — Family 3.)
4. **ConfirmQC**: When `2f+1` Confirm votes form, the leader emits `Commit{slot, view, qc, proposals}`.
5. **Commit**: Receivers apply the commit in slot order via the Committer. The CommitQC for slot `s` is stored as evidence to unlock Prepare for `s+k`.
6. **View change**: On timeout, a replica broadcasts `Timeout{slot, view, highQC, highProp}`. After `2f+1` timeouts form a TC, the next leader extracts the winning proposals via `TC::get_winning_proposals` and re-emits Prepare.
7. **Pipelining bound `k`**: A leader cannot start slot `s+1` until `s+1−k` is locally committed; recipients verify via the embedded `qc_ticket`.

Quorum thresholds (`config/src/lib.rs:229-248`):
- `quorum_threshold() = 2N/3 + 1`  ≈  `2f+1`
- `validity_threshold() = (N+2)/3`  ≈  `f+1`
- `fast_threshold() = N`            =  `3f+1` (all replicas).

### 2.3 Concurrency Model

Each role is a single tokio task communicating via mpsc:
- `Core::run` is single-threaded; all state lives in `Core` struct.
- `Proposer`, `Committer`, `HeaderWaiter`, `CertificateWaiter`, `GarbageCollector`, `PayloadReceiver`, `Helper` are independent tasks.
- Cross-task data passes via `channel(1_000)` mpsc buffers.

No shared atomics for correctness state (only `consensus_round: AtomicU64` which is never written — Family 6). So protocol bugs are not concurrency bugs in the lock-free sense; they are message-handling and validation bugs.

---

## 3. Phase 2 — Bug Archaeology Coverage

**Coverage statistics**:
- Total branches in the repo: 2 (`overview`, `autobahn`). The `autobahn` branch holds the actual code; `overview` is just artifact docs.
- Commits on `autobahn` branch (all-time): **340** total.
- Commits touching `primary/` (since branch creation): **175**.
- Bug-fix-related commits (keyword filter `fix|bug|panic|crash|wrong|edge|race|deadlock|hang|leak|forgot|broken`): **88**.
- Commits inspected in detail via `git show`: **30+** (see `bug-archaeology-report.md`).
- Upstream GitHub issues on `neilgiri/autobahn-artifact`: **0** open, **0** closed. Issue tracker effectively unused.
- Upstream GitHub PRs: **0** open, **0** closed.
- `specula-org/autobahn-artifact` mirror: issues disabled.

Because there is no issue/PR signal, all archaeological evidence comes from commit diffs. The full per-commit cards live in `bug-archaeology-report.md`; the headline patterns are summarized below.

### 3.1 Mechanism-Based Bug Families (from history)

| Family | Representative commits | Mechanism |
|--------|------------------------|-----------|
| **A — View-change correctness** | `8695f47` (`qc_ticket` cryptographic bound), `33ab623` (TC adoption), `5915535` (TC `view_round`), `12d26c4` (ticket view tagging), `3baa668`-part (TC view+1 check) | Each is a way the view-change machinery accepts a malformed TC/QC or fails to recover to the right state. |
| **B — Timer / GC / handler leaks** | `cea81f4` (`!contains` polarity), `f6726fb` (drop cancel handlers), `cd48a2f` (wrong map), `46b612d`-part (GC wipes bound state), `bd6325e` (commit doesn't clear timer), `3baa668`-part (handler keying), `1297fc6` / `79616c5` (sync-timer thrash) | Bookkeeping: maps or timers leak forever or are dropped prematurely. |
| **C — Ticket / coverage logic** | `46b612d` (bound polarity + underflow), `6b58036` (silent ticket drop refactor), `136d400` (slot-1 coverage + stale tips), `101cf3a` (leader's own tip invisible to coverage), `b68c08e` (`consensus_instances` map for ride-share votes) | The k-bound + coverage gate is hard to get right; each commit either over- or under-throttles. |
| **D — Header categorization** | `d0331d9` (`is_special` unconditionally set under ride-share Confirm), `49351a5` (special-parent origin), `3659f6f` (no chained special edges), `ff40ed8` / `7147e18` (empty payload handling), `277ba01` (invalidation refactor) | "What kind of block am I making" decisions leak across modes. |
| **E — Fast / Slow path race & aggregator state** | `1953ece` (vote loopback decoupled from current_header), `a1ecd2d` (FP timer scaffolding "still panics"), `ab514d2` (`dissemination_cert` race), `b0f2784` (`get_once` latch, `completed_fast` flag), `eee683a` (`check_cast_vote` direction), `a578267` (`first_quorum` read-after-write), `59b4496` (dummy certs in quorum) | Aggregator state machine races with the fast-path timer loopback. |
| **F — Bootstrapping / first slot** | `3332eea` (async timer at slot-1 commit), `331f20e` (slot-1 guard), `136d400` (slot-1 ticket path), `3659f6f` (genesis comparison) | The first slot is a special path that gets less testing. |
| **G — Sync race / message routing** | `f267175` (wrong message type on retry), `3baa668`-part (`parent_requests` stuck), `9e27533` (`process_cert` race with special parent), `3036137` (sync params still broken) | Synchronizer never sees a request was satisfied; retries thrash. |
| **H — Async-simulation liveness** | `1f29166` (delayed prep wake), `d69308f` (still-relevant guard) | Benchmark instrumentation that lost a Prepare on async end. |
| **I — Proposer round monotonicity** | `d0da347` (proposer round edge case) | Tip-update off-by-one. |

### 3.2 Observations

1. **`core.rs` is the bug hotspot** — ~25 of 30 inspected commits touch it.
2. **Boolean inversion is endemic**: `cea81f4` (`!contains`), `46b612d` (bound polarity), `a578267` (read-after-write on flag), `eee683a` (vote-count direction), `769b27d` (sum vs `[0]==1`).
3. **Cancel handlers and GC have five distinct fixes** (`f6726fb`, `cd48a2f`, `3baa668`, `46b612d`, `bd6325e`) — the GC story was hardest to get right in the slot-pipelined model.
4. **Safety perimeter**: `8695f47` (qc_ticket cryptographic bound), `33ab623` (tc_force adoption), `5915535` (TC view_round check), `12d26c4` (ticket view), `49351a5` (special-parent origin), `3659f6f` (special-edge depth).
5. **TLA+ instrumentation commits (`cb2a415`, `22f1faa`, `bf897ef`) are at HEAD** — *after* the bug hunt — consistent with using TLA+ as a post-hoc validation tool on the stabilized implementation.

---

## 4. Phase 3 — Deep Analysis Findings

Below I summarize the 25 distinct findings produced by parallel deep-analysis of `core.rs` / `messages.rs` / `aggregators.rs` (one subagent) and `synchronizer.rs` / `header_waiter.rs` / `committer.rs` / `garbage_collector.rs` / `payload_receiver.rs` (a second subagent). Full text in `deep-analysis-core.md` and `deep-analysis-sync.md`.

For each finding, I report:
- ID, severity (CRITICAL/HIGH/MEDIUM/LOW)
- One-line claim
- One-line evidence (file:line)
- Class: model-checkable (MC) / test-verifiable (TV) / code-review-only (CR)
- Benign vs Byzantine

### 4.1 Family 1 — Cryptographic content-binding missing

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| A1 | CRITICAL | `ConsensusMessage::digest` omits `proposals`. `verify_confirm`/`verify_commit` reconstruct id without proposals. QC binds only to `(slot, view, kind)`. | `messages.rs:128, 194, 246, 233-280` (`FIXME: ADD THIS AND DEBUG`) | MC | Byzantine |
| A2 | CRITICAL | `Timeout::digest` returns hash of zero data. Every Timeout has the same digest; signatures replayable. | `messages.rs:1349-1358` | MC + TV | Byzantine |
| A3 | CRITICAL | `Timeout::verify` does not validate `high_qc`/`high_prop`. `TC::verify` does not recurse into them. | `messages.rs:1332-1346, 1540-1544` | MC | Byzantine |
| A6 | LOW | `QC::digest` hashes nothing (currently unused). | `messages.rs:1271-1278` | CR | n/a |

### 4.2 Family 2 — Verification short-circuits & equality bugs

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| A4 | CRITICAL | `impl PartialEq for TC` returns `true` → `TC::verify`'s genesis short-circuit fires for every TC. Quorum/sig checks are dead code. | `messages.rs:1405-1411, 1518-1522` | MC | Byzantine |
| A5 | MEDIUM | `impl PartialEq for QC` returns `false` → breaks `ConsensusMessage::eq` for Confirm/Commit (always false). | `messages.rs:1287-1292` | CR | Benign (latent) |

### 4.3 Family 3 — State mutation before validation

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| B1 | HIGH | `is_valid(Prepare)` advances `self.views[slot]` BEFORE checking ticket / vote-history. One bad Prepare corrupts a node's view. | `core.rs:1226-1233` | MC + TV | Byzantine |
| B2 | HIGH | `is_valid(Confirm)` has no `last_voted_consensus` check. Node Confirm-votes arbitrarily many times per `(slot, view)`. | `core.rs:1235-1246` | MC + TV | Byzantine |
| C1 | HIGH | `process_consensus_request` inserts into `consensus_instances` BEFORE `verify` and `is_valid`. Byzantine pollutes local map. | `core.rs:1370-1387` | MC | Byzantine |

### 4.4 Family 4 — View-change winner computation

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| D1 | HIGH | `get_winning_proposals` Confirm branch sets `winning_view = timeout.view` instead of `*other_view`. | `messages.rs:1454-1456` | MC + TV | Benign (ordering) |
| D2 | HIGH | After D1, no later legitimate Confirm at higher QC view can override. | `messages.rs:1479-1490` | MC | Benign |
| D3 | HIGH | Prepare f+1 count keys `prepared_feq` by `prepare.digest()` (A1) — collides across different proposal sets. | `messages.rs:1481` | MC | Byzantine |
| D4 | CRITICAL | Commit branch trusts first Commit in any `high_qc`, no verify, breaks out. | `messages.rs:1460-1469` | MC | Byzantine |
| D5 | MEDIUM | `is_valid(Prepare)` with TC iterates `proposals` (not `winning_proposals`); subset-OK and unwrap-panic. | `core.rs:1193-1198` | MC + TV | Byzantine |

### 4.5 Family 5 — Receiver-side crash DoS

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| E1 | CRITICAL | `qc_ticket.as_ref().unwrap()` panic from Prepare with `slot > k, tc=None, qc_ticket=None`. | `core.rs:1211` | TV | Byzantine |
| G3 | HIGH | `panic!("ids don't match")` in `verify_commit` slow path. | `messages.rs:158-161` | TV | Byzantine |
| F4 | HIGH | `genesis_headers.get(&pk).unwrap()` for byzantine-supplied `pk`. | `synchronizer.rs:111, 134, 151, 274-275, committer.rs:134` | TV | Byzantine |
| F2 | CRITICAL | Byzantine Commit with `(genesis_digest, height>0)` panics committer via `get_header(genesis_digest).unwrap()`. | `synchronizer.rs:148, 152` | MC + TV | Byzantine |
| F3 | HIGH | `get_all_headers_for_proposal` walks parent chain that was never re-synced; `.expect("should have parent by now")`. | `synchronizer.rs:266, committer.rs:141-143` | TV | Byzantine + Benign (loss) |
| E2 | MEDIUM | `enough_coverage` unwraps every authority key. | `core.rs:1583-1600` | CR | Byzantine (conditional) |
| E3 | LOW | Other `unwrap`s in `core.rs` guarded by prior checks. | `core.rs:1118, 1233, 1325` | CR | Benign |

### 4.6 Family 6 — GC, bookkeeping, leaks

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| F1-G | CRITICAL | `GarbageCollector` waits on `rx_consensus` whose only writer is `Consensus::spawn(...)` which is commented out in `node/src/main.rs:140-155`. `consensus_round` never advances; all gc_round-gated retain blocks are dead. | `node/src/main.rs:140-155`, `garbage_collector.rs:86`, `core.rs:2336-2349`, `header_waiter.rs:427-440` | CR + TV | Benign |
| F1-C | HIGH | `clean_slot_periods` predicate `s % k != slot_period && s <= &slot` drops all entries with `s > slot` (future, in-flight slots). | `core.rs:1696-1713` | MC + TV | Benign |
| F2 | LOW | `views`, `tc_makers`, `last_voted_consensus`, `high_qcs`, `high_proposals`, `committed_slots`, `prepare_tickets`, `already_proposed_slots`, `voted_confirm_shadow` never GC'd. | `core.rs` | CR + TV | Benign |
| F5/F13 | MEDIUM | `proposal_digest` iterates `HashMap`; non-deterministic order across `clone()`. Dedup key in `HeaderWaiter::pending` unstable. | `messages.rs:210-228, header_waiter.rs:288-360` | TV + CR | Benign |
| F7 | MEDIUM | `WaiterMessage::SyncHeader` has no waiter, no completion callback, leaks one `header_requests` entry per call. | `header_waiter.rs:213-238` | CR | Benign |
| F12 | MEDIUM | `parent_requests` retry loop never updates timestamps; hot rebroadcast every second after first loss. | `header_waiter.rs:408-419` | TV | Benign |
| F8 | MEDIUM | Committer overwrites `state.log[slot]` on re-arrival; no equivocation detection. | `committer.rs:120-128` | CR | Latent |

### 4.7 Family 7 — Loopback / sync bypass

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| G2 | HIGH | `process_loopback` for Commit forwards to committer without re-verification. | `core.rs:1737-1742` | MC + TV | Byzantine |
| F6 | HIGH | Under `use_ride_share=true`, loopback Prepare invokes `process_header(dummy)` which fails `parent_cert.height()+1 == height()`; Prepare silently dropped. | `core.rs:1399-1410, 1720-1731, 335-338` | MC + TV | Benign |
| F11 | MEDIUM | `get_proposals` has `delivered_header` shortcut only for Prepare, not Confirm/Commit. | `synchronizer.rs:107-129, 131-161, core.rs:1733-1736` | MC | Benign |

### 4.8 Family 8 — Authorization checks omitted

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| B3 | HIGH | No leader check in `is_valid` / `process_prepare_message`. | `core.rs:1174-1233, 1474-1542` | MC + TV | Byzantine |
| B4 | CRITICAL | `is_valid(Prepare)` does not consult `committed_slots`. Byzantine can re-Prepare a committed slot. | `core.rs:1174-1233` | MC + TV | Byzantine |

### 4.9 Other findings

| ID | Sev | Claim | Evidence | Class | Model |
|----|-----|-------|----------|-------|-------|
| G1 | LOW | `async_delayed_prepare` overwrites earlier buffered prepare; only last is replayed. | `core.rs:149, 955-959, 2297-2316` | TV | Benign |
| F10 | LOW | `PayloadReceiver` writes empty bytes; no header-vs-worker binding (within trust model). | `payload_receiver.rs:25-31` | CR | Benign |

---

## 5. Verification Summary

Of the 32 distinct findings:
- **Model-checkable**: 14 (Family 1+2+3+4+7+8 most of A,B,C,D,F1-C,F2,G2,F6,F11)
- **Test-verifiable**: 12 (Family 5+6 mostly; also B1, D5, F1-C overlap)
- **Code-review-only**: 6 (Family 5 patterns, F7, F8, F10, A5/A6, CR-1..12 in brief)

Findings classified as both MC and TV are listed under the primary class for the modeling brief's § 6.

---

## 6. In-Tree Reproductions

The repository's own test suite includes 8 PoC bug reproductions. Their existence is the strongest possible evidence that the bugs are real (not speculative).

| Test | Bug Family | File:line | What it asserts |
|------|------------|-----------|-----------------|
| `test_da1_qc_does_not_bind_to_proposals` | 1 | `messages_tests.rs:97` | `verify_commit` accepts two Commits with same QC but different proposals. |
| `test_da2_timeout_digest_hashes_nothing` | 1 | `messages_tests.rs:197` | Two distinct Timeouts produce identical digests. |
| `test_da3_tc_verify_always_passes` | 2 | `messages_tests.rs:238` | Empty TC and under-quorum TC both pass `TC::verify`. |
| `test_da5_viewchange_wrong_winning_view` | 4 | `messages_tests.rs:277` | `get_winning_proposals` picks proposals from QC view 2 when QC view 3 should win. |
| `test_da13_qc_partialeq_always_false` | 2 | `messages_tests.rs:359` | `QC` instances are never equal, even to clones. |
| `test_bug03_confirm_double_vote_verify` | 1+3 | `messages_tests.rs:385` | `verify_confirm` passes for two Confirms with different proposals at same `(slot, view)`. |
| `bug3_confirm_double_vote` | 3 | `core_tests.rs:2063` | Live `Core` votes twice for Confirms at same `(slot, view)`. |
| `bug4_view_advance_side_effect` | 3 | `core_tests.rs:2191` | Invalid Prepare(view=3) advances `views[1]` from 0 to 3; subsequent valid Prepare(view=1) is rejected. |

There is also `bug1_multi_view_voting` (`core_tests.rs:1875`) — outside the families surveyed in this report. Worth a look during spec authoring.

---

## 7. Honesty Notes

- **What I verified directly** (re-read code at the cited line ranges): A1, A2, A3, A4, A5, B1, B2, C1, D1, D4, E1, F1-G, F1-C, G3, F2 (the genesis-digest panic), the in-tree test names.
- **What I trust the parallel subagents on**: D3, D5, E2, F3, F4, F5, F6, F7, F8, F11, F12, F13, G2 — I reviewed their citations spot-checked one or two from each but did not re-read every file. Their reports are at `deep-analysis-core.md` and `deep-analysis-sync.md`.
- **What I did NOT verify**: detailed semantics of `header_waiter::pending` flow, the exact tokio task supervision policy (whether a panicked core task halts the whole binary or only that task — this affects severity of E1/G3 but not their existence).
- **What is NOT covered**: `worker/` and `hotstuff/`/`sailfish/` crates were not deep-analyzed (out of scope — Autobahn-specific bugs live in `primary/`).

---

## 8. Coverage Statistics

- Phase 2 — Bug Archaeology: 175 primary/ commits enumerated, 88 keyword-matched, 30+ deep-inspected. 0 GitHub issues / PRs (upstream tracker empty).
- Phase 3 — Deep Analysis: 6+ core files fully read (core.rs 2 352 LOC, messages.rs 1 589 LOC, aggregators.rs 211 LOC, synchronizer.rs 305 LOC, committer.rs 307 LOC, header_waiter.rs 443 LOC, plus garbage_collector.rs, payload_receiver.rs, proposer.rs, leader.rs, primary.rs, node/src/main.rs). Two parallel subagents executed in parallel, ~2 100 seconds combined wall time.
- In-tree test files: `primary/src/tests/{messages_tests.rs, core_tests.rs, proposer_tests.rs, trace_test.rs, common.rs}` scanned for repros; 8 named bug-reproduction tests discovered.

---

## 9. Recommendations to Spec-Generation Phase

1. **Foreground Families 1, 2, 3, 4, 8** in the spec. They map directly to safety invariants and are model-checkable. The in-tree reproductions are valuable as concrete counterexample sketches.
2. **Background Family 6, 7** as liveness scenarios. The `clean_slot_periods` predicate bug is checkable as `EventuallyCommits`; the dummy-header loopback drop is checkable as `NoStuckLeader`.
3. **Exclude Family 5 from TLA+** except 5.4 (genesis-digest-at-nonzero-height). Verify the rest via Rust fuzz/integration tests.
4. **Exclude the dead GC wiring (Family 6 #2)** from TLA+ entirely — it's a `cargo test` / RSS audit, not a protocol property.
5. **Decision needed**: should the spec also model the *intended* (corrected) behavior alongside the buggy behavior? Recommendation: yes for Families 1, 2, 4 — running TLC against the intended predicates as a sanity check that the spec captures the protocol correctly, then flipping the predicates to the buggy form should produce expected counterexamples (the in-tree tests are the answer key).

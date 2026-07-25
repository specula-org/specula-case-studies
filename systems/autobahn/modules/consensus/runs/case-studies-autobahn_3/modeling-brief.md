# Modeling Brief: Autobahn BFT (specula-org/autobahn-artifact)

## 1. System Overview

- **System**: Autobahn — a DAG-based BFT consensus prototype (SOSP'24 artifact). Rust on tokio.
- **Scale**: `primary/` crate ≈ 6 100 LOC of core consensus logic. `core.rs` 2 350 LOC, `messages.rs` 1 590 LOC, `aggregators.rs` 210 LOC, `synchronizer.rs` 305 LOC, `committer.rs` 307 LOC.
- **Protocol**: 3-phase consensus (Prepare → Confirm → Commit) layered on a DAG of "cars" (Headers). Each slot is an independent instance, pipelined with a bound of `k` concurrent open instances. Fast path = `3f+1` Prepare votes → Commit; slow path = `2f+1` Prepare → Confirm → `2f+1` Confirm → Commit. View change uses TC built from `2f+1` Timeouts; the next leader generates a Prepare from `TC.get_winning_proposals`. `n = 3f+1` Byzantine threshold; partial-synchrony.
- **System category**: **Category A — Distributed / Message-Passing**, **BFT** overlay. The safety/liveness arguments depend on tolerating ≤ *f* Byzantine validators across a partially-synchronous network with authenticated messages. Read `references/distributed-analysis.md` and `references/bft-analysis.md` together.
- **Concurrency model**: One tokio task per role (Core, Proposer, Committer, HeaderWaiter, …) — single-threaded inside each task, communicating via mpsc channels. No shared lock-free data structures.
- **Architectural choices that deviate from a textbook BFT paper**:
  - Per-slot pipelined consensus with cryptographic ticketing (`qc_ticket: CommitQC` carries proof that `s−k` is committed).
  - "Optimistic tips" — DAG nodes ride on whatever's locally available; receiver does best-effort coverage.
  - Two delivery modes: ride-share (consensus messages embedded in headers) and external `ConsensusRequest`.
  - "Special edge" (genesis-rooted single-header parent for special blocks) inherited from Sailfish.
- **Adversary model**: Static corruption, partial-synchronous network, authenticated messages with EdDSA signatures, `n = 3f+1`. Crypto primitives assumed unforgeable. No accountability sub-protocol.

---

## 2. Bug Families

The codebase is in mid-development and ships with **its own reproduction tests** (`primary/src/tests/messages_tests.rs::test_da{1,2,3,5,13}_*`, `primary/src/tests/core_tests.rs::bug{1,3,4}_*`) that already demonstrate seven critical safety bugs. The bugs are not speculative; they are confirmed and acknowledged. The families below group them by **mechanism**.

### Family 1 — Cryptographic content-binding is missing on every consensus message (CRITICAL)

**Mechanism**: `ConsensusMessage::digest` and the receiver-side reconstruction in `verify_confirm` / `verify_commit` **omit the `proposals` field** for every variant. QCs and Confirm/Commit signatures therefore bind only to `(slot, view, type_byte)` — the receiver cannot tell which value the signers actually committed to. Mirror failure in `Timeout::digest` and `QC::digest` (both hash *nothing*).

**Evidence**:
- Code: `primary/src/messages.rs:121-169` (`verify_commit`) and `:186-208` (`verify_confirm`) — `//hasher.update(proposal_digest(consensus_message)); FIXME: ADD THIS AND DEBUG` at lines 128, 194, 246.
- Code: `messages.rs:233-280` — `ConsensusMessage::digest` for Prepare/Confirm/Commit omits `proposals`.
- Code: `messages.rs:1349-1358` — `Timeout::digest` returns `Sha512::new().finalize()[..32]` (no fields hashed).
- Code: `messages.rs:1271-1278` — `QC::digest` likewise empty.
- Tests in tree: `test_da1_qc_does_not_bind_to_proposals`, `test_da2_timeout_digest_hashes_nothing`, `test_bug03_confirm_double_vote_verify`.
- Historical: bug class persisted across the whole TLA+ instrumentation push (commits `cb2a415`, `22f1faa`, `bf897ef`) — the trace harness was added on top of these unfixed defects.

**Affected code paths**: `verify_confirm`, `verify_commit`, `Timeout::verify`, `process_consensus_request → is_valid`, `process_consensus_vote`, `process_vote`, `TC::get_winning_proposals` (downstream consumer trusts unverified `high_qc.proposals`).

**Suggested modeling approach**:
- Variables: messages carry an explicit `proposals` field; model digests as a *function* over `(slot, view, kind)` — i.e., explicitly **not** of proposals — to match implementation.
- Actions: model `ReconstructConfirmId(slot, view) = digest(slot, view, 0)` and `ReconstructCommitId(slot, view) = digest(slot, view, prepareId, 1)` so a QC's `id` is satisfied by any `proposals` with the same `(slot, view)`.
- Add a byzantine action `ForgeCommitFromQC(qc, slot, view, value)` that re-packages an honest QC with a different value and routes it through `verify_commit`/`verify_confirm` — TLC should produce an Agreement counterexample.
- Granularity: single byzantine action per phase (forge-confirm, forge-commit). Don't try to model the SHA-512 collision search; model the predicate's failure directly.

**Priority**: **High** — root cause of multiple downstream agreement violations.

---

### Family 2 — Verification short-circuits and structural equality bugs (CRITICAL)

**Mechanism**: Two `PartialEq` impls are inverted constants — `impl PartialEq for TC` returns `true`, `impl PartialEq for QC` returns `false`. The first turns `TC::verify`'s genesis short-circuit (`if Self::genesis(committee) == *self { return Ok(()) }`) into an unconditional accept. Every TC, including an empty one, passes verification.

**Evidence**:
- Code: `messages.rs:1405-1411` — `impl PartialEq for TC { fn eq(...) -> bool { true } }`.
- Code: `messages.rs:1518-1522` — `TC::verify` short-circuits on `Self::genesis(committee) == *self`.
- Code: `messages.rs:1287-1292` — `impl PartialEq for QC { fn eq(...) -> bool { false } }`.
- Code: `messages.rs:1332-1346` — `Timeout::verify` does not verify `high_qc`/`high_prop` (comment: `// TODO: If it would be winning QC then you need to verify`).
- Code: `messages.rs:1540-1544` — `TC::verify` calls `timeout.verify` but the latter does not recurse into embedded `high_qc`/`high_prop`.
- Test in tree: `test_da3_tc_verify_always_passes`, `test_da13_qc_partialeq_always_false`.
- Historical: `5915535` ("TC verify view_round"), `33ab623` ("force adopt TC winning proposal"), `12d26c4` ("fixed ticket view to match qc/tc") all added partial fixes to TC verification — but the foundational `PartialEq=true` was never removed.

**Affected code paths**: `TC::verify`, `Timeout::verify`, `is_valid(Prepare)` for TC branch, `get_winning_proposals` (relies on unverified embedded messages).

**Suggested modeling approach**:
- Variables: `TC` modeled as `[slot, view, timeouts: Set<Timeout>]`; `Timeout` modeled with explicit `highQC`, `highProp` typed as `Option<ConsensusMessage>`.
- Actions: TLC's `VerifyTC` must include `Cardinality(timeouts) ≥ 2f+1` (signer-distinct), `∀ t ∈ timeouts: VerifyTimeout(t)`, and `∀ t. t.highQC ≠ None ⇒ VerifyConfirm(t.highQC)`. Then deliberately ALSO encode the bug variant `VerifyTC_AsImplemented(tc) ≡ TRUE`, parameterizing the model so a counterexample on `VerifyTC_AsImplemented` is the expected output.
- Add byzantine action `BroadcastForgedTC(slot, view, timeouts={})` so the leader can drive a view change with no honest signatures.

**Priority**: **High** — composes with Family 1 to let a single byzantine commit anything at any (slot, view).

---

### Family 3 — Validator-side state mutation before validation (HIGH)

**Mechanism**: `is_valid(Prepare)` and `process_consensus_request` update local state (`self.views[slot]`, `self.consensus_instances`) **before** validity checks complete. Honest replicas can be permanently steered into wrong views or have their instance map polluted by a single rejected byzantine message.

**Evidence**:
- Code: `core.rs:1226-1233` — `self.views.insert(*slot, *view)` runs unconditionally if `curr_view < view`, even if `ticket_valid` later evaluates `false`.
- Code: `core.rs:1370-1387` — `consensus_instances.insert((*slot, dig), msg)` happens BEFORE `consensus_req.verify(...)?` and `is_valid(...)`.
- Code: `core.rs:1235-1246` — `is_valid(Confirm)` similarly inserts into `views` after `verify_confirm` but before checking `last_voted_consensus` (the latter check is *missing entirely*).
- Test in tree: `bug4_view_advance_side_effect` (proves view corruption), `bug3_confirm_double_vote` (proves missing double-vote check).
- Historical: `cea81f4` (`!self.timers.contains` boolean inversion in `local_timeout_round` — committed slots fire bogus timeouts), `46b612d` (bound check polarity bug), `3baa668` ("sync clean up fix; gc fix; view change fix") — repeated pattern of state-vs-validation ordering errors.

**Affected code paths**: `is_valid` (Prepare, Confirm), `process_consensus_request`, `local_timeout_round`, `process_confirm_message` (overwrites `high_qcs[slot]` with any received Confirm, enabling byzantine choice of timeout payload).

**Suggested modeling approach**:
- Split each `is_valid` predicate from any state mutation. In TLA+, model the bug exactly: an action that *checks* `view ≤ proposedView` then *commits* the state update unconditionally, but only emits a Vote if the rest of validation succeeds. This lets an invalid Prepare leave a side-effect.
- Invariants: `views[slot]` only advances on valid Prepare (with valid TC OR view = 1) or via `handle_timeout` (TC formation).
- Adversary: byzantine sends Prepare(slot=S, view=large, tc=None) → expected violation of `OnlyValidPrepareAdvancesView`.

**Priority**: **High** — model-checkable, two pre-existing repros, infinite liveness loss with one byzantine packet.

---

### Family 4 — View-change winner computation (HIGH)

**Mechanism**: `TC::get_winning_proposals` selects the wrong winner under several common orderings:
1. The Confirm branch stores `winning_view = timeout.view` (the round in which the timeout fired) instead of `*other_view` (the QC's actual view).
2. After (1), no later legitimate Confirm with higher `*other_view` can override.
3. The Prepare-counting branch keys f+1 matching prepares by `prepare.digest()` — which (Family 1) omits proposals, so different proposal sets collide under one bucket.
4. The Commit branch trusts the first Commit it sees in any timeout's `high_qc` and breaks — no `qc.verify` and no signature check.

**Evidence**:
- Code: `messages.rs:1436-1499` (`get_winning_proposals`).
  - Line 1454-1456: `if other_view > &winning_view { winning_view = timeout.view; ... }` — bug.
  - Line 1480-1490: `if view > &winning_view { ... prepared_feq.entry(prepare.digest()).or_default() ... }` — collision via Family 1.
  - Line 1460-1469: Commit branch adopts `proposals` and `break`s — no verification.
- Test in tree: `test_da5_viewchange_wrong_winning_view`.
- Historical: `33ab623` (force-adopt TC winning proposal), `5915535` (TC `view_round` cross-check) — these were partial fixes that never addressed the assignment bug.

**Affected code paths**: `TC::get_winning_proposals`, `is_valid(Prepare)` for TC branch (line 1193-1198, checks subset relationship with `winning_proposals`, can panic via `winning_proposals.get(&pk).unwrap()`), `generate_prepare_from_tc`.

**Suggested modeling approach**:
- Variables: `Timeout` records `highQC: Option<ConsensusMessage>` and `highProp: Option<ConsensusMessage>`. Track the QC's `view` explicitly.
- Actions: `ComputeWinningProposals(tc)` modeled exactly per the buggy assignment (`winningView := t.view`); separately encode the *intended* `winningView := highQC.view`; assert under TLC that the two diverge with non-trivial probability and that protocol Agreement can be violated as a consequence.
- Adversary: byzantine includes a forged Commit in its own timeout's `highQC` (composes with Family 2's unverified `high_qc`).

**Priority**: **High** — confirmed reproduction; mechanism is structural.

---

### Family 5 — Receiver-side crash DoS via unchecked `unwrap` / `panic!` on network input (CRITICAL ops, MEDIUM safety)

**Mechanism**: Multiple consensus-message paths call `.unwrap()` or `panic!()` on attacker-supplied state. A single well-formed byzantine message kills every honest node simultaneously.

**Evidence** (all reachable from `PrimaryMessage` deserialization):
1. `core.rs:1211` `qc_ticket.as_ref().unwrap()` when `slot > k` and `slot-k` not locally committed → crash from a Prepare with `tc=None, qc_ticket=None`.
2. `messages.rs:158-160` `panic!("ids don't match")` in `verify_commit` slow-path branch — byzantine Commit with mismatched id panics receivers.
3. `synchronizer.rs:111, 134, 151` `self.genesis_headers.get(&pk).unwrap()` on a `pk` not in the committee — byzantine `proposals: {byz_pk → …}` panics on the digest comparison.
4. `synchronizer.rs:152` `get_header(genesis_digest).expect("already synced should have header").unwrap()` — byzantine Commit referencing `(genesis_digest, height > 0)` makes `get_proposals` accept (height check at `synchronizer.rs:148` is too lax) and committer panics.
5. `synchronizer.rs:266` `get_parent_header(...).expect("should have parent by now")` — committer walks parent chain that was never re-synced.
6. `committer.rs:134` `state.last_executed_heights.get(pk).unwrap()` — same out-of-committee `pk` vector.
7. `core.rs:1196` inside `is_valid(Prepare/TC)`: `winning_proposals.get(&pk).unwrap()` when leader proposes a `pk` not in TC's winners.
8. `core.rs:1591` `enough_coverage` unwraps every `prepare_proposals.get(&pk)` — panics if byzantine-supplied proposals are missing keys.

**Affected code paths**: All message handlers + committer + synchronizer.

**Suggested modeling approach**:
- Not model-checkable for protocol safety. These are reliability/availability bugs; better verified by:
  - Targeted fuzzing of `PrimaryMessage` deserialization with adversarially constructed proposals.
  - Clippy/lint rule: forbid `unwrap`/`expect`/`panic` in any function transitively reachable from `Core::run`'s message arms.
- TLA+ should still surface (5.4) the genesis-digest-with-height>0 case (it's a checkable invariant violation: `proposal.header_digest = genesis_digest ⇒ proposal.height = 0`).

**Priority**: Medium for TLA+ (only 5.4 is a real protocol-layer invariant); High for the codebase.

---

### Family 6 — Slot-pipelining / GC bookkeeping (HIGH liveness)

**Mechanism**: The slot-pipelined model needs careful per-slot state management. Several pieces are broken:
1. `clean_slot_periods` predicate `s % k != slot_period && s <= &slot` drops every entry with `s > slot` (i.e., *every in-flight future slot*) on every Commit. With default `k=4`, committing slot 2 wipes the qc_makers, consensus_instances, and cancel_handlers for slots 3, 4, 5, … On every commit, in-flight votes for newer slots are silently lost.
2. `GarbageCollector` writes `consensus_round` only on receiving certificates from `rx_consensus`. The only writer to that channel was `Consensus::spawn(...)` which is **commented out in `node/src/main.rs:140-155`**. `consensus_round` therefore stays at 0 forever, and *all* GC retain blocks in `HeaderWaiter::run`, `Core::run`, `sanitize_header`, etc. are dead code. Maps like `last_voted`, `cancel_handlers`, `header_waiter::{pending, parent_requests, batch_requests, header_requests}` leak unbounded.
3. Many state maps (`views`, `tc_makers`, `last_voted_consensus`, `high_qcs`, `high_proposals`, `committed_slots`, `prepare_tickets`, `already_proposed_slots`, `voted_confirm_shadow`) are never GC'd at all.
4. `header_waiter::parent_requests` retry loop never updates timestamps — every unsatisfied parent is rebroadcast every second forever.
5. `proposal_digest` iterates a `HashMap<PublicKey, Proposal>`; iteration order is non-deterministic (different per-instance `RandomState`), so the dedup key in `HeaderWaiter::pending` is unstable across clones. Duplicate sync futures and zombie `pending` entries result.

**Evidence**:
- Code: `core.rs:1696-1713` (`clean_slot_periods`).
- Code: `node/src/main.rs:140-155` (commented-out `Consensus::spawn`) + `garbage_collector.rs:86` (only writer to `consensus_round`).
- Code: `header_waiter.rs:408-419` (parent_requests retry without timestamp update).
- Code: `messages.rs:210-228` (`proposal_digest` iterating HashMap).
- Historical: `3baa668`, `46b612d`, `bd6325e`, `cea81f4`, `f6726fb`, `cd48a2f`, `b68c08e` — five distinct fixes to GC/timer state in 2023.

**Affected code paths**: `clean_slot_periods`, `process_commit_message`, `GarbageCollector::run`, `HeaderWaiter::run`, `proposal_digest`.

**Suggested modeling approach**:
- Liveness only: model the GC predicate as written and ensure liveness fails — slot s+1's qc_maker is reset whenever slot s commits, so progress stalls under modest concurrency.
- Better captured as a Rust integration test (one slot in flight while another commits; verify qc_maker survives).
- The dead-`GarbageCollector` issue is a wiring bug — not model-checkable; verify by RSS-over-time test or grep audit.

**Priority**: Medium for TLA+ (#1 is checkable as a `EventuallyCommits` violation); High for the codebase.

---

### Family 7 — Loopback / sync paths bypass validation (HIGH)

**Mechanism**: When a header is suspended for missing payload/proposals and later looped back, several code paths fail to re-run validation or operate on a dummy header.

**Evidence**:
- Code: `core.rs:1737-1742` — `process_loopback` for Commit forwards the message to `tx_committer` with no re-verification. Composes with Family 1 to drive a fake Commit into the committer.
- Code: `core.rs:1399-1410` + `core.rs:1720-1731` — under `use_ride_share=true`, `process_consensus_message` synthesizes a dummy `Header::default()` (height=0, parent_cert.height=0) and queues it for sync. On loopback the Prepare branch invokes `process_header(dummy)` which immediately fails the `parent_cert.height()+1 == height()` ensure → the Prepare is silently dropped and never voted on.
- Code: `synchronizer.rs:107-129` — Prepare branch has a `delivered_header` shortcut; Confirm/Commit branches do not, so a header carrying both a Prepare and a Confirm referencing itself spuriously syncs.

**Affected code paths**: `process_loopback`, `process_consensus_message`, `Synchronizer::get_proposals`.

**Suggested modeling approach**:
- Liveness invariant: every accepted Prepare eventually produces a vote or a timeout (the dummy-header bug breaks this).
- Action: `LoopbackConsensus(msg, original_header)` should re-run `is_valid` and `verify_*`.

**Priority**: Medium-High for TLA+ (liveness models can catch the dummy-header drop).

---

### Family 8 — Authorization checks omitted (HIGH safety)

**Mechanism**: Multiple validity predicates accept messages from any committee member, never checking the elected leader.

**Evidence**:
- Code: `core.rs:1174-1233` (`is_valid(Prepare)`) — no `leader_elector.get_leader(slot, view)` check.
- Code: `core.rs:1474-1542` (`process_prepare_message`) — no leader check.
- Code: `core.rs:1235-1246` (`is_valid(Confirm)`) — no `last_voted_consensus` check (already noted in Family 3).
- Code: `core.rs:1174-1233` (`is_valid(Prepare)`) — no `committed_slots.contains(&slot)` check, so a byzantine can re-Prepare a committed slot at a higher view (composes with Family 1+2 to violate Agreement).

**Affected code paths**: All Prepare/Confirm validation.

**Suggested modeling approach**:
- Action: predicate `IsLeader(p, slot, view)`; honest follower's `IsValidPrepare` must include `msg.author = Leader(slot, view)` and `~committed[slot]`.
- Adversary: byzantine sends Prepare as non-leader; TLC must reject.

**Priority**: High — direct safety implications.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Per-slot consensus state machine with 3 phases | Core protocol. | Variables `phase[s] ∈ {None,Prepare,Confirm,Commit}`, `proposals[s]`, `view[s]`. |
| Byzantine threshold `n = 3f+1` with explicit `Faulty` set | BFT environment. | `Faulty ⊂ Server`, static, `3*|Faulty| < |Server|`. |
| QC/Commit ID reconstruction omitting `proposals` | Family 1 — bug-as-written. | `Digest(s,v,k) = <s,v,k>` (no proposals); `VerifyCommit(c) ≡ c.qc.id = Digest(c.slot,c.view,…)`. |
| TC verification short-circuit | Family 2. | Two predicates: `VerifyTC_Intended` (proper) and `VerifyTC_AsImplemented` (always TRUE). Run with the buggy one and check Agreement. |
| `Timeout.highQC` / `highProp` carried explicitly, *unverified by TC* | Family 2 + 4. | Timeout record with explicit fields; `GetWinningProposals` reads them without verifying. |
| View-change winner computation with `winning_view := t.view` bug | Family 4. | Implement `GetWinningProposals` per the buggy code. |
| State mutation before validation in `IsValidPrepare` | Family 3. | Split: a `RecordPrepareView` action runs even on rejection (advances `view[slot]`), then conditionally votes. |
| Per-slot pipelining with bound `k` and qc_ticket | Family 6 + paper-level safety on bound. | Variables `committedQC[s]`, `qcTicket: Option<CommitQC>`; bound action `LeaderProposesSlot(s+1)` requires `committedQC[s+1-k]` evidence. |
| Byzantine actions: equivocate Prepare, forge Confirm/Commit from honest QC, forge Timeout, forge TC | Families 1, 2, 4. | Each action takes a counter (in MC.tla, not base.tla). Route through receiver-side `IsValid*` / `Verify*`. |
| `clean_slot_periods` predicate (drop s>slot) | Family 6 #1. | Liveness model: action `OnCommit(s)` mutates `qcMaker` map per the buggy retain. Check EventuallyCommits. |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Fast-path 3f+1 mechanics in detail | The fast path commits only with all-N votes (`fast_threshold = total_votes`), which is irrelevant under any non-zero crash assumption. The interesting bugs are all on the slow path. Model fast path as a single optional action, not a full state machine. |
| HotStuff / Sailfish baselines | They live in `hotstuff/` and `sailfish/` crates as comparison baselines; modeling them adds state space without targeting Autobahn-specific bugs. |
| Worker / Header dissemination DAG below the consensus messages | Only relevant via `proposals.header_digest`; abstract the DAG as "leader proposed value V at slot S". |
| RocksDB persistence semantics | The code does not rely on atomic batch writes for safety; persistence is an after-effect of voting. |
| Async-simulation asymmetry (`async_delayed_prepare`) | Benchmark-only instrumentation. |
| `panic!`/`unwrap` crash DoS bugs (Family 5) | These are reliability bugs, not protocol-safety bugs. Verify with fuzz tests, not TLA+. The exception is the genesis-digest-with-nonzero-height case (5.4), which is a protocol invariant. |
| `proposal_digest` HashMap non-determinism (Family 6 #5) | Pure Rust-language bug; verify with a unit test that hashes `clone()`d maps. |
| `is_special`, "special edge", Sailfish payload categorization | Inherited from Sailfish; the Autobahn-specific bugs do not depend on it. |
| Garbage-Collector dead-code wiring (Family 6 #2) | Code-review / RSS test — not a protocol property. |
| HeaderWaiter retry hot-loop (Family 6 #4) | Performance/correctness issue, not protocol safety. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Explicit per-message `proposals` field + content-free digest | `msgDigest [s,v,k → Digest]` | Capture Family 1 (digest omits proposals) | 1 |
| `Timeout.highQC`, `Timeout.highProp` records | `timeouts: [slot, view, author, highQC, highProp]` | Capture unverified embedded messages | 2, 4 |
| Buggy `VerifyTC` (genesis short-circuit) | `VerifyTC ≡ TRUE` constant | Capture Family 2 | 2 |
| Side-effect view advance | Pre-validation `view[s] := max(view[s], v)` in `IsValidPrepare` | Capture Family 3 (bug4_view_advance_side_effect) | 3 |
| `winning_view := timeout.view` | `winningView` assignment per code | Capture Family 4 (test_da5) | 4 |
| `qc_ticket: Option<CommitQC>` on Prepare | `qcTicket [s → Option<QC>]` | Capture pipelining bound proof | 6, 8 |
| Faulty Byzantine actions: ForgeTC, ForgeConfirm, ForgeCommit, DoubleVoteConfirm, NonLeaderPrepare | Per-action counters in `MC.tla` | Adversary capabilities for Families 1-4, 8 | 1, 2, 3, 4, 8 |
| `clean_slot_periods` retain rule | `qcMaker[s]` cleared whenever s > committedSlot | Capture Family 6 #1 | 6 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| AgreementSafety | Safety | If two honest nodes commit slot `s`, they commit the same proposals. | Families 1, 2, 4 |
| OneCommitPerSlot | Safety | A slot is committed at most once on each honest node. | Family 1, 8 |
| QcBindsToProposals | Safety | A QC's `id` uniquely determines the proposal set it attests to. | Family 1 |
| TcVerified | Safety | Every accepted TC has ≥ 2f+1 distinct, signed timeouts. | Family 2 |
| HighQCVerified | Safety | Every `Timeout.highQC` adopted by `get_winning_proposals` has been verified by the receiver. | Family 2, 4 |
| WinningViewMatchesQC | Safety | After `GetWinningProposals`, `winningView` equals the chosen QC's view (not the timeout's view). | Family 4 |
| OnlyValidPrepareAdvancesView | Safety | `view[slot]` only advances on a valid Prepare (with valid TC OR view=1) or via TC formation. | Family 3, 8 |
| OneConfirmVotePerView | Safety | An honest node sends at most one Confirm vote per `(slot, view)`. | Family 3, 1 |
| OnlyLeaderProposes | Safety | Every accepted Prepare comes from `Leader(slot, view)`. | Family 8 |
| BoundedOpenInstances | Safety | At most `k` consensus instances open per honest node; advancing past `s+k` requires a CommitQC for `s`. | Family 6, 8 |
| NoCommitOfCommittedSlot | Safety | A slot committed at `view = v_old` cannot be re-committed at `view > v_old` with different proposals. | Family 1, 2, 8 |
| GenesisDigestOnlyAtHeightZero | Safety | A proposal with `header_digest = genesis_digest(pk)` has `height = 0`. | Family 5 #4 |
| EventuallyCommits | Liveness | Under partial synchrony with f honest leaders, every slot eventually commits. | Family 6, 7 |
| NoStuckLeader | Liveness | A Prepare suspended by sync is eventually re-evaluated. | Family 7 (dummy-header drop) |
| TimeoutOnlyOnUncommitted | Safety | A committed slot does not trigger a Timeout. | Family 3 (historical `cea81f4`) |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|--------------------|--------|
| MC-1 | A single byzantine leader sends `Prepare(slot=S, view=V, tc=Some(empty_TC), proposals=X)`. `VerifyTC` short-circuits via `PartialEq=TRUE`, leader check is absent, honest replicas vote, slot S commits X. If S was previously committed at Y, Agreement breaks. | `AgreementSafety` | 1+2+8 |
| MC-2 | Byzantine combines a forged Confirm with same `(slot, view)` as an honest one but different `proposals`. `verify_confirm` accepts both (Family 1). Combined with missing `last_voted_consensus` check (Family 3), honest replicas double-Confirm-vote, producing conflicting Confirm-QCs that can both reach Commit. | `OneConfirmVotePerView`, `AgreementSafety` | 1+3 |
| MC-3 | Byzantine puts forged `Commit { proposals=X }` into its own Timeout's `highQC`. `Timeout::verify` does not check `highQC`. `TC::get_winning_proposals` Commit branch trusts it without verification. New leader proposes X for slot S after view change. | `HighQCVerified`, `AgreementSafety` | 2+4 |
| MC-4 | Two timeouts ordered `[t1 (view=7, highQC.view=2), t2 (view=5, highQC.view=3)]`. `GetWinningProposals` adopts t1's proposals despite t2 having the strictly higher QC view, because `winning_view := t1.view = 7` blocks t2's `*other_view = 3` from passing the `> 7` test. | `WinningViewMatchesQC` (and downstream `AgreementSafety` if the legitimately-higher Confirm-QC had reached the commit edge) | 4 |
| MC-5 | Byzantine sends Prepare for committed slot S at higher view V. `is_valid(Prepare)` does not consult `committed_slots`. Honest nodes re-vote, second commit on S with attacker-chosen proposals. | `NoCommitOfCommittedSlot`, `AgreementSafety` | 1+2+8 |
| MC-6 | Byzantine sends Prepare with `proposals: {byz_pk → Proposal{header_digest = genesis_digest(p0), height = 5}}`. `Synchronizer::get_proposals` short-circuits on genesis digest without checking height. Honest replicas form Confirm/Commit; committer panics on `get_header(genesis_digest)` returning None. | `GenesisDigestOnlyAtHeightZero` (or a liveness violation if the panic halts the committer) | 5 #4 |
| MC-7 | Honest leader is the next leader after a TC where 2 of the 3 timeouts have `highQC = Some(Confirm{view=v', proposals=v1})`. Because of Family 1, the *same* Confirm-QC is reachable by a byzantine `Confirm{view=v', proposals=v2}`. Whichever proposal set the leader observes locally (race) becomes the winner. | `AgreementSafety` (non-deterministic divergence between honest leaders' adopted proposals) | 1+4 |
| MC-8 | Under partial synchrony with `k=4`, slot s+1's qc_maker accumulates 2f votes; slot s commits, triggering `clean_slot_periods` that wipes `qc_makers[s+1]`. Subsequent votes for s+1 start a fresh qc_maker; the quorum threshold is never reached because earlier votes are lost. | `EventuallyCommits` | 6 #1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|--------------------|
| T-1 | `qc_ticket.unwrap()` panic on byzantine Prepare with `tc=None, qc_ticket=None, slot>k` | Send crafted `ConsensusRequest` over TCP, assert tokio task survives (or panics). The crate already has `#[tokio::test]` infrastructure. |
| T-2 | `panic!("ids don't match")` in `verify_commit` slow-path | Construct a Commit with a slow-path QC whose `id` differs from `Digest(slot, view, prepare_id, 1)`; observe panic. |
| T-3 | `genesis_headers.get(&unknown_pk).unwrap()` panic | Hand-craft a `ConsensusMessage::Commit` with `proposals: {byz_pk_not_in_committee → …}`. |
| T-4 | `clean_slot_periods` wipes future qc_makers | Two-slot in-flight scenario; assert qc_maker for slot s+1 retains votes after slot s commits. |
| T-5 | `GarbageCollector` dead-code wiring | Long-run integration test; sample RSS and `last_voted` map size; assert bounded. |
| T-6 | `proposal_digest` non-determinism across `clone()` | Unit test: create a `Commit` with multi-entry `proposals`, clone it, assert `digest()` equal (currently fails non-deterministically). |
| T-7 | `header_waiter::parent_requests` hot retry loop | Simulate packet loss for one parent; observe network traffic count over 10s ≥ 10 retries. |
| T-8 | Dummy-header drop under `use_ride_share=true` | End-to-end: byzantine sends forwarded Prepare requiring sync; assert local node eventually votes after sync completes (currently dropped). |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| CR-1 | `impl PartialEq for TC { -> true }` (`messages.rs:1409`) | Replace with `#[derive(PartialEq)]` or remove the genesis short-circuit from `TC::verify`. |
| CR-2 | `impl PartialEq for QC { -> false }` (`messages.rs:1290`) | Same — derive or fix. |
| CR-3 | `verify_commit`/`verify_confirm` reconstruct id without proposals | Add `hasher.update(proposal_digest(message))` (the comment already documents the fix). |
| CR-4 | `Timeout::digest` hashes nothing | Hash `slot, view, highQC.id (if any), highProp.id (if any), author`. |
| CR-5 | `Timeout::verify` does not validate `highQC`/`highProp` | Recurse into `verify_confirm`/`verify_commit` for embedded QCs. |
| CR-6 | `Consensus::spawn` commented out in `node/src/main.rs` → GC dead code | Either restore the channel writer or remove all `consensus_round` gating. |
| CR-7 | `proposals: HashMap<PublicKey, Proposal>` non-deterministic hashing | Switch to `BTreeMap` or sort before hashing. |
| CR-8 | `panic!`/`unwrap` audit in all functions reachable from `Core::run` | Add clippy lint forbidding `unwrap`/`panic`/`expect` in network-input paths. |
| CR-9 | `enough_coverage` unwraps every authority key | Replace with `.get(&pk).map_or(0, |p| p.height)` and compare. |
| CR-10 | `is_valid(Confirm)` missing `last_voted_consensus` check | Add the check before returning true. |
| CR-11 | `is_valid(Prepare)` advances `views[slot]` before ticket check | Move the `views.insert` into the success branch only. |
| CR-12 | No leader check in `is_valid` / `process_prepare_message` | Add `consensus_req.author == leader_elector.get_leader(slot, view)` assertion. |

---

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/autobahn_3/.specula-output/analysis-report.md`
- **Core deep-analysis report**: `/home/ubuntu/Specula/case-studies/autobahn_3/.specula-output/deep-analysis-core.md`
- **Sync/committer deep-analysis report**: `/home/ubuntu/Specula/case-studies/autobahn_3/.specula-output/deep-analysis-sync.md`
- **Bug archaeology report**: `/home/ubuntu/Specula/case-studies/autobahn_3/.specula-output/bug-archaeology-report.md`
- **Key source files**:
  - `primary/src/core.rs:1-2352` — main consensus event loop, `is_valid`, `process_consensus_*`, `clean_slot_periods`.
  - `primary/src/messages.rs:24-280, 1232-1589` — `ConsensusMessage` digests, `verify_confirm`/`verify_commit`, `Timeout`, `TC`, `QC`, `get_winning_proposals`.
  - `primary/src/aggregators.rs:1-211` — `VotesAggregator`, `QCMaker` (fast/slow path), `TCMaker`.
  - `primary/src/synchronizer.rs:101-178, 248-303` — proposal sync, parent chain walk, genesis short-circuits.
  - `primary/src/committer.rs:117-175` — slot-ordered commit, `state.log`, `get_all_headers_for_proposal`.
  - `node/src/main.rs:115-156` — commented-out `Consensus::spawn` that explains the dead GC.
- **In-tree reproductions** (`primary/src/tests/`):
  - `messages_tests.rs::test_da1_qc_does_not_bind_to_proposals` — Family 1.
  - `messages_tests.rs::test_da2_timeout_digest_hashes_nothing` — Family 1.
  - `messages_tests.rs::test_da3_tc_verify_always_passes` — Family 2.
  - `messages_tests.rs::test_da5_viewchange_wrong_winning_view` — Family 4.
  - `messages_tests.rs::test_da13_qc_partialeq_always_false` — Family 2.
  - `messages_tests.rs::test_bug03_confirm_double_vote_verify` — Family 1+3.
  - `core_tests.rs::bug3_confirm_double_vote` — Family 3.
  - `core_tests.rs::bug4_view_advance_side_effect` — Family 3.
- **GitHub issues / PRs**: Upstream `neilgiri/autobahn-artifact` has **0 issues and 0 PRs**. All bug evidence comes from commit history; the issue tracker is empty. The `specula-org/autobahn-artifact` mirror disables issues.
- **Reference paper**: SOSP'24 — *Autobahn: Seamless high speed BFT* (Giridharan, Suri-Payer et al.). PDF at `artifact/autobahn-artifact/sosp24-paper26.pdf`.
- **Note for the spec author**: this brief deliberately omits modeling of fast-path bookkeeping, async-simulation injection, and the special-edge / ride-share variants — see §3.2. The bug surface is concentrated in cryptographic binding, view-change correctness, and validator state ordering; the spec should foreground those.

# Modeling Brief — Sui Mysticeti DAG-BFT Consensus

## 1. System Overview

- **Name**: Sui consensus (Mysticeti). MystenLabs/sui.
- **Language**: Rust. ~36k LoC of non-test core logic across `consensus/core/src/*.rs`.
- **System category**: **Category A — Distributed / Message-Passing**, with a **Byzantine** threat model (≤ `f` Byzantine, `n = 3f+1`). Sub-category: **DAG-based BFT** (each validator proposes one block per round; ordering is derived from the DAG via a leader-based commit rule).
- **Protocol**: Mysticeti (arxiv 2310.14821) — `wave_length = 3` (leader at R, voters at R+1, certifiers at R+2). Single leader per round in production (`num_leaders_per_round = Some(1)`, `consensus_protocol_config.rs:86`); the in-tree multi-leader path is **disabled** by config and structurally incorrect if re-enabled (#18206).
- **Architectural deviations / extensions from the paper**:
  1. **Garbage Collection (GC)** of stale blocks at `gc_round = last_committed - gc_depth` (PR #19315, #19465, #20250) — never in the paper.
  2. **Amnesia recovery** — when a node's consensus DB is wiped, before re-signing the node queries peers for its own highest signed round (PR #18009 / #18190 / #18771).
  3. **Linearizer recurses to gc_round, not to "highest committed round per author"** (PR #20250) — commits *all* equivocating blocks at the same `(round, author)` slot deliberately (issue #24498 confirms by maintainer).
  4. **Smart ancestor selection** — proposer excludes low-scoring authors for ~450 rounds via reputation scoring (PR #19605, #20336).
  5. **Certified commits** sync — peers push commit certificates that bypass the local round-by-round commit decision (PR #21118, #20956).
  6. **Pluggable transaction "fast path"** layered on commits (commit_finalizer.rs) — reject votes and direct/indirect finalization rules.
- **Concurrency model**: One serialized **Core thread** mutates all consensus state via mpsc queue (`core_thread.rs:105-138`); `DagState` is shared via `Arc<RwLock<_>>` but writes are short-lived inside the Core thread. Network handlers, synchronizer, commit_syncer, commit_finalizer, leader_timeout run on independent tokio tasks and submit work into the Core mpsc.
- **Persistent vs in-memory state**: `recent_blocks` (in-memory, evicted after flush), `RocksDB` columns for blocks, commits, commit_info, finalized_commits; a single `WriteBatch` flushes blocks + commits + commit_info atomically.

---

## 2. Bug Families

### Family 1: Equivocation handling at the same `(round, author)` slot

**Mechanism**: Byzantine authors can submit multiple blocks at the same `(round, author)` slot. Mysticeti **intentionally** commits all of them (issue #24498, mwtian: *"Committing equivocating blocks in the same slot is not a safety violation, as long as the commit logic is deterministic across honest validators"*). Honest validators must compute identical `CommittedSubDag.blocks` and identical commit digests under any partial-delivery interleaving.

**Evidence**:
- Historical: #21393 (test for equivocating leader), #25113 / #25033 / #25141 (randomized DAG equivocation tests), #24498 + PR #24499 (false positive — confirmed design intent).
- Code: `base_committer.rs:99-117` (`try_direct_decide` retrieves all blocks at slot via `get_uncommitted_blocks_at_slot`, panics if >1 is certified — relies on stake math), `base_committer.rs:284-334` (`decide_leader_from_anchor` same), `linearizer.rs:177-204` (recurses ancestors with filter `round > gc_round && !is_committed(ancestor)`, committing both equivocating blocks across separate sub-dags), `commit.rs:403-409` (`sort_sub_dag_blocks` stable-sorts by `(round, author)` — equivocating blocks tie and keep insertion order, which is the DFS traversal order, which depends on block content but not on local arrival order).

**Affected code paths**: `BaseCommitter::find_supported_block`, `BaseCommitter::is_vote`, `BaseCommitter::is_certificate`, `Linearizer::linearize_sub_dag`, `sort_sub_dag_blocks`, `DagState::get_uncommitted_blocks_at_slot`, `DagState::set_committed`, `Proposer::smart_ancestors_to_propose` (uses `last_included_ancestors`, can pick different "primary" digests on different validators).

**Suggested modeling approach**:
- Variables: `Messages` — set of `[author, round, digest, ancestors, timestamp]`; `Committed` — sequence of `CommittedSubDag` records with deterministic block ordering; per-validator `Decided` mapping slot → `Commit | Skip | Undecided`.
- Actions:
  - `ByzEquivocate(s, r, ancestors1, ancestors2)` produces two valid-shaped blocks at the same slot with different ancestor sets / timestamps.
  - `Vote(v, r+1, leader)` — honest voter at R+1 picks **at most one** block per slot for each author (via `find_supported_block` semantics).
  - `DirectCommit(L)` / `IndirectCommit(L, anchor)` — commit decisions, returning `LeaderStatus`.
  - `Linearize(L)` — DFS traversal of the sub-dag, includes *all* blocks at slots reachable from L through ancestors with `round > gc_round`.
- Granularity: split commit decision (direct vs indirect) from linearization. The bug surface is in linearization ordering when equivocating slots are reached from different DFS roots in different commits.

**Priority**: **High**. The protocol's correctness hinges on agreement *despite* equivocation; this is the most distinctive aspect of Mysticeti vs the paper-pure model.

---

### Family 2: Amnesia recovery — own-equivocation prevention threshold

**Mechanism**: After a consensus-DB wipe while the validator's signing key persists, the node queries peers for its own highest signed block round, then sets `last_known_proposed_round` to gate future proposals. The query terminates at **`reached_validity(total_stake)` (≥ f+1)** — *not* a 2f+1 quorum.

**Evidence**:
- Historical: PR #18009 (introduced amnesia recovery — *"will eventually equivocate during recovery and make the node crash"*), #18190 (synchronizer side), #18771 (auto-enable), #19774 (boot-counter epoch logic), #24292 (deadlock during recovery introduced by #24024).
- Code: `synchronizer.rs:900-904`:
  ```rust
  if context.committee.reached_validity(total_stake) {  // f+1
      info!("...");
      break 'main;
  }
  ```

**Threat model**: under crash + Byzantine adversary, the `f` Byzantine + 1 honest can all report `highest_round = 0` (Byzantine collude, the 1 honest happened to not have received the lost block before crash). Quorum-intersection argument: with only `f+1` stake, the responders may include zero honest voters who certified our highest block — the f+1 lower bound does **not** guarantee any responder saw the lost block. Validator re-signs an already-signed round → own-equivocation.

**Affected code paths**: `Synchronizer::start_fetch_own_last_block_task`, `Core::set_last_known_proposed_round`, `Proposer::should_propose`, `DagState::accept_block` (own-slot guard at line 322-336, only panics — does **not** prevent the signed block from existing).

**Suggested modeling approach**:
- Variables: `signedHistory[s]` — persistent set of `(round, digest)` pairs ever signed by `s` (survives crash). `memState[s]` — in-memory state (wiped on `Crash`). `lastKnownProposed[s]` — recovered value.
- Actions:
  - `Crash(s)` wipes `memState[s]` (modeling consensus-DB wipe); `signedHistory[s]` is retained (modeling signing-key retention via HSM / key vault).
  - `Recover(s)` queries peers, receives `≥ f+1` responses, sets `lastKnownProposed[s] = max(responses)`. Honest peers report truthfully; Byzantine peers can lie either direction.
  - `Propose(s, r)` — guard `r > lastKnownProposed[s]` AND `(r, _) ∉ signedHistory[s]` would prevent equivocation; the bug-finding question is whether the f+1 threshold makes the latter check necessary or whether the former is sufficient under partial knowledge.
- Invariant: `\A s : \A (r, d1), (r, d2) \in signedHistory[s] : d1 = d2`.

**Priority**: **High**. Safety violation under composition of `2.6 Amnesia × 5.1 Crash` (per bft-analysis.md). The maintainer comment "f+1" is explicit and the quorum-intersection argument fails.

---

### Family 3: Garbage Collection × Commit Rule interactions

**Mechanism**: GC evicts blocks with `round ≤ gc_round = last_committed - gc_depth` (default `gc_depth ≈ 50`). Three subtle interactions:
1. The linearizer recurses through ancestors **above** `gc_round`, which can re-visit equivocating blocks that were not previously committed (PR #20250 was the protocol-level change — see Family 1).
2. `find_supported_block` (`base_committer.rs:193-215`) recurses through weak-link ancestors and **panics** if a referenced block is not in storage; unlike `is_certificate` (which has an explicit `assert!(reference.round ≤ gc_round)` fallback at lines 250-256), `find_supported_block` does not gate on GC.
3. `ancestors_at_round` (`dag_state.rs:573-575`) panics on missing intermediate ancestors when traversing from a high-round anchor down to `decision_round = leader_slot.round + 2`.

**Evidence**:
- Historical: PR #20492 ("threshold clock advancement after GC" — fixes panic when `gc_round` outpaces local clock); PR #19315 / #19465 ("Garbage Collection 1 / 2"); PR #20250 (linearizer-uses-commit-up-to-gc_round); PR #20992 (GC missing blocks via `try_fetch_blocks`); PR #21206 (`try_find_blocks` respect GC).
- Code: `base_committer.rs:209` (unconditional `unwrap_or_else(|| panic!("Block not found in storage: {:?}", ancestor))`); `dag_state.rs:574` (`panic!("Block {:?} should exist in DAG!", block_ref)` inside `ancestors_at_round`); `block_manager.rs:309-355` (`try_accept_one_block` skips ancestor presence check for `round ≤ gc_round`, but the block_verifier only checks `ancestor.round < block.round`, so a block can be accepted with bogus-digest ancestors at evicted rounds).

**Affected code paths**: `BaseCommitter::find_supported_block`, `BaseCommitter::decide_leader_from_anchor`, `DagState::ancestors_at_round`, `BlockManager::try_accept_one_block`, `Linearizer::linearize_sub_dag`, `DagState::gc_round`.

**Suggested modeling approach**:
- Variable: `gcRound[s]` — per-validator GC round (advances on commit). `dag[s]` — in-memory DAG (evicts ≤ gcRound).
- Action: `AdvanceGC(s)` updates `gcRound[s]` after a commit. Allow honest validators to have **different** `gcRound[s]` (delivery skew → different last-commit-progress).
- Invariant: ordering decisions reachable from `decide_leader_from_anchor` and `find_supported_block` use only ancestors with `round > gcRound[s]`; if a recursive lookup hits a block at round ≤ gcRound[s], the result should be deterministically `None` rather than crashing.

**Priority**: **Medium**. The practical panic surface is narrow (requires `last_commit_round - leader_slot.round ≥ gc_depth`, which only happens during long leader skips), but the asymmetry between `find_supported_block` (no GC guard) and `is_certificate` (explicit GC guard) is a code-path inconsistency worth modeling.

---

### Family 4: Leader timeout / threshold clock / proposer liveness

**Mechanism**: Round advancement is driven by `ThresholdClock` (`threshold_clock.rs`), which advances when 2f+1 stake at the current round is accepted. `LeaderTimeout` independently fires after `max_leader_timeout` to force proposal. `Proposer::smart_ancestors_to_propose` requires `parent_round_quorum.reached_threshold` and **asserts** it (`proposer.rs:352-354`) when called with `smart_select = false` (force path). When the validator has sync'd a certified-commit fast-forward but local DAG state is sparse at the new high round, the assertion can fire.

**Evidence**:
- Historical: PR #16722 ("fix potential liveness issue" — missed `new_round` signal); PR #25157 (open draft, propagation-delay deadlock after restart); PR #20906 ("advance threshold clock from dag state"); PR #20492 (threshold-clock vs GC race); PR #24292 (deadlock during recovery); PR #18206 (multi-leader disabled — comments say "we don't commit any leaders from the same round as last_decided ... until we have full support").
- Code: `threshold_clock.rs:65-80` (in `Ordering::Greater`, a single block at round R catches up `self.round` to R — relies on block_verifier enforcing parent-stake quorum at R-1, but doesn't check independently); `proposer.rs:234-241` (smart-select wait); `proposer.rs:352-354` (force-propose assertion: `assert!(parent_round_quorum.reached_threshold(...))` "Possible mismatch between DagState and Core"); `universal_committer.rs:48-57` (multi-leader latent bug: `slot == last_decided` break skips lower-offset leaders).

**Affected code paths**: `Core::try_propose`, `Core::new_block`, `ThresholdClock::add_block`, `Proposer::smart_ancestors_to_propose`, `LeaderTimeout::run`, `UniversalCommitter::try_decide`, `Core::add_certified_commits` (advances state without local DAG completeness).

**Suggested modeling approach**:
- Variables: `clockRound[s]`, `lastProposed[s]`, `acceptedAt[s][r]` (set of authors accepted at round r).
- Actions: `Accept(s, m)` updates clock if reaches 2f+1 at clockRound[s]. `Timeout(s)` forces a propose. `AcceptCertifiedCommit(s, range)` advances commit state without filling intermediate DAG.
- Invariant: when `Propose(s, r, force)` fires, `Cardinality(acceptedAt[s][r-1]) ≥ 2f+1` — model verifies this is always true at the moment of proposal. Currently the assertion can fail.

**Priority**: **Medium**. Liveness / process-crash bug class. Most concrete: the assertion at `proposer.rs:352` is a panic, not a graceful fallback.

---

### Family 5: Byzantine input validation gaps at the trust boundary

**Mechanism**: `block_verifier` performs structural and signature checks on inbound blocks, but several fields are unauthenticated against protocol invariants:
1. **`timestamp_ms` is not validated** vs ancestors or wall clock. A Byzantine validator can sign a block with `timestamp_ms = u64::MAX`; honest validators accept it, and later `add_commit` panics on `commit_timestamp_monotonic` (`dag_state.rs:1015`). Once any honest leader's parent set includes such a Byzantine block, `Linearizer::calculate_commit_timestamp` (`linearizer.rs:144`) propagates the max forward and clients downstream see absurd timestamps.
2. **`commit_votes` are not authenticated per-vote**. `CommitVoteMonitor::observe_block` (lines 33-40) tracks only the highest commit index per author and **does not** detect Byzantine validators voting for conflicting `(index, digest)` pairs.
3. **`missing_ancestors` and `missing_blocks` are unbounded** (`block_manager.rs:51-58, 326-352`). A Byzantine flood of valid blocks with fabricated ancestor digests grows the map without limit; cleanup runs only via GC, which itself stalls on missing dependencies. The TODO at line 41 acknowledges this. PR #24474 proposed a fix that is **still open**.
4. **`round_prober` accepts peer-claimed rounds without checks** (`round_prober.rs:160-176`). A Byzantine coalition lying about peer X's accepted rounds can drive `network_high_quorum_round` either direction, oscillating X between Include / Exclude (450-round lock) and biasing local proposal cadence via `set_propagation_delay`.
5. **`ancestor` exclusion is per-node** (`ancestor.rs:116-220`) — two honest validators with different score histories can disagree on whom to exclude. Under sustained churn, the intersection of included authors can drop below `2f+1`, causing proposer wait → liveness loss.

**Evidence**:
- Code (verified): `block_verifier.rs:67-152` (no timestamp check), `commit_vote_monitor.rs:33-40` (max-only tracking), `block_manager.rs:51-58` (TODO unbounded), `round_prober.rs:160-176` (length-only check), `ancestor.rs:77, 89-94, 174-184` (450-round lock, 2/3 of bad_nodes_stake_threshold cap).
- Historical: PR #24474 ("prevent OOM from unbounded missing blocks growth", **open, stale**); PR #21347 / #17284 ("ensure commit timestamps are monotonic" — but only post-hoc, not at verifier).

**Affected code paths**: `SignedBlockVerifier::verify_block`, `CommitVoteMonitor::observe_block`, `BlockManager::try_accept_one_block` / `gc_missing_blocks`, `RoundProber::probe`, `AncestorStateManager::update_all_ancestors_state`.

**Suggested modeling approach**:
- Most of this family is **not model-checkable** at the protocol-spec level — it's implementation-level resource accounting and input validation. The exception is the **commit-vote equivocation gap (#2)**: per-vote authentication is a protocol concern.
- Action: `ByzCommitVoteEquivocation(s, idx, digest1, digest2)` — Byzantine signs two blocks carrying conflicting `CommitVote(idx, digest1)` and `CommitVote(idx, digest2)`; the monitor's `quorum_commit_index` aggregates regardless. Test whether downstream `authority_service.rs:244-269` (commit-lag-reject) can be tricked.

**Priority**: **Low for modeling, High for code review**. Most are implementation-only (OOM, panic-DoS, side-channel). The commit-vote equivocation gap is the only one with a protocol-level invariant question.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Per-round single-leader commit rule (direct + indirect) | Family 1 — agreement under equivocation is the central question | Two actions `DirectDecide(L)` / `IndirectDecide(L, anchor)`; outputs `Commit(L) | Skip(L) | Undecided(L)`. |
| Equivocation at `(round, author)` | Family 1 — the production code explicitly accepts and commits both | `ByzEquivocate(s, r, ancs1, ancs2)` adds two blocks with same `(r, s)` but different ancestor sets / digests. |
| Linearizer DFS over uncommitted ancestors with GC bound | Family 1 + 3 — sub-DAG content determinism | `Linearize(L)` walks ancestors filtered by `round > gc_round ∧ ¬committed`; the committed set is mutated, simulating `set_committed`. |
| Persistent vs in-memory state split for amnesia | Family 2 — amnesia recovery is the canonical safety hazard | `Crash(s)` wipes mem state but keeps `signedHistory[s]`. `Recover(s)` queries f+1 stake. |
| Byzantine equivocation in own-block reporting during recovery | Family 2 — the f+1 threshold | Honest peers report truthfully; Byzantine peers report arbitrary `(round, digest)`. Verify the maintainer's "f+1 is enough" claim. |
| GC per validator (different `gcRound[s]`) | Family 3 — code-path inconsistency between `find_supported_block` and `is_certificate` | `AdvanceGC(s)` after commit; allow temporary divergence under partial commit delivery. |
| Multi-leader commit rule (disabled in production, latent bug) | Family 4 — universal_committer.rs:48-57 logic | Model with `num_leaders > 1`; check whether `slot == last_decided` break-out is correct. |

### 3.2 Do Not Model

| What | Why |
|---|---|
| `block_verifier` timestamp validation gap | Implementation-only — fixed by adding a single comparison; no protocol-level interaction. Test-verifiable. |
| `missing_blocks` OOM | Resource-accounting bug; not a protocol-state issue. PR #24474 is hardening, not a protocol change. |
| `BlockRef::hash` 8-byte truncation | DoS / performance only; safety preserved via Eq on full digest. |
| RocksDB WriteBatch atomicity | Already atomic per `typed_store::DBMap::batch().write()`; recovery code re-derives `evicted_rounds` from store contents. |
| RPC handlers' authentication | TLS / certificate plumbing — code-review territory. |
| Commit-vote DoS via inflated index | Out of scope: protocol assumption is `< 2f+1` Byzantine; under this assumption the bug doesn't manifest. Code-review for hardening. |
| Round-prober untrusted peer rounds | Bias on local proposal cadence, not safety. Test-verifiable. |
| Ancestor exclusion under partition | Score-distribution dependent; better tested with randomized DAGs (already done via #25113 / #25033 / #25141). |
| Fast-path transaction reject votes / commit_finalizer indirect rejection | Out of scope per case-study instructions (focus on consensus state machine and certificate / commit-rule paths). |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| Equivocation-aware DAG | `Messages` is a set of records (not a function); `(round, author)` is not unique | Model Mysticeti's "commit both equivocating blocks" rule | F1 |
| Slot-vs-BlockRef distinction | `Slot = [round, author]`; `BlockRef = [round, author, digest]`; `is_committed` uses `BlockRef`, `find_supported_block` uses `Slot` | Capture the asymmetry that issue #24498 surfaced (per-digest commit tracking, per-slot voting) | F1 |
| Per-validator persistent state | `signedHistory[s] ⊆ [round → digest]` (durable); `memState[s]` (volatile, wiped on Crash) | Model amnesia recovery's correctness gap | F2 |
| Per-validator GC round | `gcRound[s] : Server → Round`; honest validators can differ by ≤ gc_depth | Model code-path inconsistency in GC handling | F3 |
| Threshold clock per validator | `clockRound[s] : Server → Round`; advances on 2f+1 accepted at clockRound[s], or catches up on any higher-round accepted block (per `Ordering::Greater`) | Capture single-block catch-up + cert-commit fast-forward asymmetry | F4 |
| Two-phase block ingestion | `Suspended[s]` (awaiting ancestors) → `Accepted[s]` (in DAG) | Block-manager's suspension semantics — relevant for ordering invariants | F4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| **CommitAgreement** | Safety | If two honest validators commit at index `i`, their `CommittedSubDag` records are identical (same leader, same block set, same order, same timestamp). | F1, F3 |
| **CommitDigestAgreement** | Safety | If two honest validators commit at index `i`, the digests of their `Commit` records are equal — depends on serialized `(leader, blocks, timestamp, previous_digest)` being byte-identical. | F1 |
| **NoOwnEquivocation** | Safety | `∀ s ∈ Honest, ∀ r ∈ Round : | { d : (r, d) ∈ signedHistory[s] } | ≤ 1` — even across crash + amnesia recovery. | F2 |
| **CommitRecursionDecidable** | Safety | If `find_supported_block(L, from)` recurses through ancestor `a`, then `a` is either present in `dag[s]` or `a.round ≤ gcRound[s]` (in which case recursion returns None, not panics). | F3 |
| **ForcePropose2f1Parents** | Safety | Whenever a validator forces a proposal at round `r`, the validator's accepted-blocks set at round `r-1` reaches 2f+1 stake. | F4 |
| **LeaderCommitMonotonic** | Safety (paper) | At most one block per `(round, author)` slot can be directly-committed (relies on quorum-intersection). | F1 (sanity) |
| **CommitTimestampMonotonic** | Safety | `Commit[i+1].timestamp ≥ Commit[i].timestamp` — already enforced post-hoc; the question is whether a Byzantine far-future timestamp can stick permanently. | F5 (mark as test-verifiable, not modeled) |
| **DAGEventualConsensus** | Liveness | Under partial synchrony (after GST) with ≤ f Byzantine, every honest validator eventually commits the same prefix of leaders. | F1, F3, F4 |
| **AmnesiaRecoveryProgress** | Liveness | A recovering validator eventually completes the fetch-own-block phase, sets `last_known_proposed_round`, and begins proposing. | F2 |
| **NoStuckProposer** | Liveness | Under partition recovery, no honest validator's proposer stays in `parent_round_quorum.reached_threshold = false` indefinitely. | F4 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|---|---|---|---|
| MC1 | Two honest validators see the same `(round, author)` equivocating blocks but in different DFS-discovery order. Does `Linearizer::linearize_sub_dag` produce identical `to_commit` *before* the `sort_sub_dag_blocks` stable sort? If not, the stable sort preserves divergent traversal order → divergent `CommittedSubDag.blocks` → divergent `Commit` digest. | `CommitDigestAgreement` violated under cross-validator delivery skew. | F1 |
| MC2 | Amnesia recovery accepts `≥ f+1` stake of responders. Construct a 4-node scenario where the recovering validator previously signed `(r=5, d=d_old)`; after crash, f=1 Byzantine + the 2 honest non-recovering nodes respond, but only 1 honest had received block (r=5, d_old). The Byzantine + the un-informed-honest respond with `highest=0`; validity reached at stake 2 (f+1). Validator re-signs `(r=5, d_new)`. | `NoOwnEquivocation` violated. | F2 |
| MC3 | `find_supported_block` is invoked on a recursive path that passes through a weak-link ancestor at round between `leader_slot.round` and the validator's `gcRound`. Honest validator A has `gcRound[A] = 8`; validator B has `gcRound[B] = 6`. Both are deciding leader at round 5 via anchor at round 11. A's `find_supported_block` panics on the missing block at round 7; B's succeeds. | `CommitRecursionDecidable` violated. | F3 |
| MC4 | `Core::add_certified_commits` accepts a peer-certified commit at high round R, advancing `clockRound` to R. The validator's local DAG at peer authorities has rounds < R-1. `LeaderTimeout` fires and calls `new_block(R, force=true)` → `smart_ancestors_to_propose(R, false)` → assertion `parent_round_quorum.reached_threshold` fails. | `ForcePropose2f1Parents` violated → process-level panic, liveness loss. | F4 |
| MC5 | Multi-leader path (currently disabled): in `universal_committer.rs:48-57`, set `num_leaders_per_round = Some(3)`. After committing leader at `(R, offset=2)`, the `slot == last_decided` break-out at line 72 fires *before* visiting `(R, offset=1)` and `(R, offset=0)`. | `LeaderCommitMonotonic` does not capture this; new invariant: "for every round R with committed leader at offset k, all leaders at offsets j < k that are decided are also represented in the commit sequence". Latent — not active in production. | F4 |
| MC6 | Byzantine block at round R with `timestamp_ms = u64::MAX` is accepted by `block_verifier`. The Byzantine block becomes a parent of an honest leader at R+1. `Linearizer::calculate_commit_timestamp` returns u64::MAX (or near it, weighted by stake). All subsequent commits inherit it via `.max(last_commit_timestamp_ms)`. | `CommitTimestampMonotonic` is preserved, but **client-visible commit time** is permanently corrupted. Frame as a liveness invariant on "honest validators can always serve clients within bounded clock drift". | F5 (but borderline; may demote to test-verifiable) |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| T1 | `block_verifier` accepts blocks with `timestamp_ms` outside any sane range. | Unit test: construct a `SignedBlock` with `timestamp_ms = u64::MAX`, call `verify_and_vote`, assert `Err(_)`. Add a `verify_timestamp` step using `epoch_start_timestamp_ms` + bounded drift. |
| T2 | `BlockManager::missing_ancestors` unbounded growth. | Integration test driving 10⁴ blocks with fake ancestors at round = current; assert `missing_ancestors.len()` is bounded; matches PR #24474. |
| T3 | `RoundProber` accepts arbitrary peer-claimed `highest_received` / `highest_accepted` values. | Unit test: peer returns `vec![u32::MAX; n]`; verify `network_high_quorum_round` is sanity-clamped. |
| T4 | `CommitVoteMonitor` does not flag commit-vote equivocation from a single author. | Unit test: two blocks from same author with `commit_votes` for conflicting `(index, digest)` pairs. Currently monitor silently aggregates max-only. Add detection + slash-evidence emission. |
| T5 | Smart-ancestor exclusion can drop intersection < 2f+1 under post-partition recovery. | Randomized simtest with partitions of varying duration; assert `parent_round_quorum.reached_threshold` is reachable within bounded retries. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | `find_supported_block` lacks the `assert!(reference.round ≤ gc_round)` guard that `is_certificate` has. Add the symmetric guard; on missing block at `round > gc_round` it still panics (legitimate invariant violation); at `round ≤ gc_round` return `None`. | Send PR mirroring `is_certificate` lines 250-256. |
| CR2 | `synchronizer.rs:900` "Request at least f+1 stake" — discuss with maintainers whether quorum (2f+1) is required for amnesia safety. The maintainer comment at PR #18009 ("we can also decide if we want to introduce some min stake threshold") suggests this was deliberately left under-specified. | Raise issue referencing the bft-analysis quorum-intersection argument. |
| CR3 | `universal_committer.rs:48-57` multi-leader logic — even though disabled by config, the `slot == last_decided` break-out skips lower-offset leaders. If multi-leader is ever re-enabled, this is a safety bug. | Either delete the branch, or fix to iterate all offsets at last_decided.round. |
| CR4 | `BlockRef::hash` truncates digest to 8 bytes for HashMap distribution. | Document the assumption that all consensus collections use BTreeMap, not HashMap. Audit for any HashMap<BlockRef, …>. |
| CR5 | `dag_state.rs:330` own-equivocation guard is an `assert!` (process panic), not a graceful reject. | Either lift to `panic!` with explicit logging, or convert to `return Err(_)` so block_manager can reject without bringing down the validator. |
| CR6 | `commit_finalizer.rs:160-166` asserts `last_processed_commit + 1 == committed_sub_dag.commit_ref.index`. `last_processed_commit` is in-memory only. On certain restart sequences, the run loop can replay a previously processed commit, triggering the assert. | Persist `last_processed_commit` or relax the assert to ≥. |
| CR7 | `block_manager.rs:309-355` accepts blocks with ancestors at `round ≤ gc_round` without checking digest existence. A Byzantine block can name fabricated digests below `gc_round`. | Document the invariant that block_verifier guarantees nothing about evicted-round ancestors; downstream consumers must not dereference. |

---

## 7. Reference Pointers

- **Full analysis report**: `analysis-report.md` (this directory)
- **Core source files (line ranges):**
  - `consensus/core/src/base_committer.rs:86-401` — direct + indirect commit rules; `find_supported_block` at 193-215, `is_certificate` at 231-279, `decide_leader_from_anchor` at 284-334, `enough_leader_blame` at 337-366, `enough_leader_support` at 370-401.
  - `consensus/core/src/universal_committer.rs:42-149` — `try_decide` outer loop; multi-leader latent bug at 48-57.
  - `consensus/core/src/linearizer.rs:65-218` — `collect_sub_dag_and_commit`, `linearize_sub_dag`, `calculate_commit_timestamp`.
  - `consensus/core/src/commit.rs:60-141` — `Commit`, `CommitV1`, `TrustedCommit`; `sort_sub_dag_blocks` at 403-409.
  - `consensus/core/src/dag_state.rs:322-336` — own-equivocation panic; `:490-523` — `get_uncommitted_blocks_at_*`; `:559-578` — `ancestors_at_round`; `:1175-1186` — `gc_round`.
  - `consensus/core/src/block_manager.rs:51-58, 309-355` — missing-blocks state, accept-one-block.
  - `consensus/core/src/block_verifier.rs:67-152` — `verify_block` (no timestamp check).
  - `consensus/core/src/synchronizer.rs:800-921` — amnesia / `fetch_own_last_block_task`.
  - `consensus/core/src/proposer.rs:170-352` — `smart_ancestors_to_propose`; `:385-401` — `should_propose`; assertion at `:352-354`.
  - `consensus/core/src/threshold_clock.rs:36-82` — `add_block` with `Ordering::Greater` catch-up.
  - `consensus/core/src/commit_finalizer.rs:160-166` — `process_commit` assert; `:282-296, 620-647` — direct/indirect finalization depths.
  - `consensus/core/src/commit_vote_monitor.rs:33-40` — `observe_block` max-only tracking.
  - `consensus/core/src/round_prober.rs:160-176` — peer-claimed rounds.
  - `consensus/core/src/ancestor.rs:77, 89-94, 174-184` — exclusion timeout & stake cap.
  - `consensus/config/src/consensus_protocol_config.rs:86` — `num_leaders_per_round = Some(1)`.
- **Key GitHub references:**
  - **Closed / merged historical fixes (reference, not modeling targets):** #16722 (liveness signal), #17654 (stuck leader schedule), #17712 (crash recovery no commit info), #18009/#18190/#18771 (amnesia recovery introduction), #18206 (multi-leader disabled), #19774 (boot counter fix), #20250 (linearizer to gc_round), #20492 (threshold clock × GC), #24292 (recovery deadlock).
  - **Open PRs (currently unfixed):** #24474 (missing-blocks OOM), #25157 (propagation-delay deadlock after restart).
  - **Open issues:** #24498 (equivocation double-commit — by design per maintainer); #25273 (devnet validator stall).
- **Reference algorithm**: Mysticeti paper, https://arxiv.org/pdf/2310.14821 — Sui's implementation deviates principally via GC, amnesia recovery, and certified-commit fast-sync.

---

## Carry-Forward Summary

- **Category**: A (Distributed / Message-Passing) with BFT overlay. Use `distributed-analysis.md` + `bft-analysis.md`.
- **BFT Layer-1 environment**: static corruption, partial synchrony post-GST, authenticated (signatures unforgeable), `n ≥ 3f+1` with `f < n/3`.
- **BFT Layer-2 actions to model**: **2.1 Equivocation** (baseline, Family 1), **2.5 Replay** (Family 2 composed with crash), **2.6 Amnesia** (Family 2, composed with `5.1 Crash`), **2.7 Certificate / quorum-proof manipulation** (Family 4 — certified-commit votes), **2.3 Omission** (implicit). **Skip** 2.4 (Selective Dissemination — pull-based sync naturalises it), 2.8 (no in-consensus evidence pool — Sui slashes via external authority layer), 2.9 (static committee per epoch).
- **Distributed families to model**: 5.1 Crash (Family 2), 5.2 Message loss / partition (any), 5.3 Timeout (Family 4), 5.5 ConfigChange (epoch rotation — out of consensus core scope), 5.6 Snapshot (the certified-commit fast-sync acts as a snapshot equivalent — Family 4 / Family 3).
- **Strongest modeling target**: **MC2 (amnesia recovery threshold)** — produces a clean safety violation under crash + Byzantine, and the f+1 vs 2f+1 question has a closed-form quorum-intersection answer. Second priority: **MC1 (commit-digest agreement under equivocation)** — verifies the maintainer's design intent.

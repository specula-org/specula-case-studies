# Analysis Report — Sui Mysticeti DAG-BFT Consensus

This is the audit-trail companion to `modeling-brief.md`. It records the full coverage of bug archaeology and deep-analysis findings, including those deferred from the brief.

---

## 1. Coverage Statistics

| Measure | Count | Notes |
|---|---|---|
| Total commits to `consensus/` | 367 | Since first commit `f221eb62be` (2023-12-20); reachable after `git fetch --depth=30000` |
| Bug-fix commits matched by keyword (fix/bug/race/panic/deadlock/safety/correctness/crash/leak/equivoc) | 41 | Limited to commits touching `consensus/` |
| Commits examined in detail (`git show <h> --format="%B"`) | ~25 | Focused on safety / liveness / recovery / commit-rule / GC fixes |
| GitHub issues + PRs reviewed | 30+ | Via parallel `gh issue/pr view --comments` subagent |
| Closed PRs deep-read with full discussion | ~20 | See § 3 below |
| Open PRs with bug-fix intent | 2 | #24474 (missing-blocks OOM), #25157 (propagation-delay deadlock) |
| Open issues confirmed by maintainer as design-intent | 1 | #24498 (equivocation double-commit) |
| Core source files deep-read | 18 | Listed in § 4 |
| Parallel deep-analysis subagents run | 4 | core/proposer/threshold/leader-timeout; commit-rule files; DAG state / block management; sync / network |
| Distinct findings (pre-grouping) | 25+ | Grouped into 5 Bug Families in the modeling brief |
| Findings excluded as false positives or by-design | 6+ | See § 7 |

---

## 2. Phase 1 — Reconnaissance Summary

Sui's Mysticeti implementation lives entirely under `consensus/` in the MystenLabs/sui monorepo, separate from the broader Move VM, RPC, and indexer subsystems. The case-study scope is `consensus/core/` (the protocol state machine) plus `consensus/config/` and `consensus/types/` (committee / cryptography / message types).

**Crate layout (in scope):**
```
consensus/
├── core/src/           # Protocol state machine, ~36k LoC non-test
│   ├── core.rs               # Main Core state machine
│   ├── proposer.rs           # Block proposal
│   ├── core_thread.rs        # mpsc serialization layer
│   ├── leader_timeout.rs     # Forced proposal on timeout
│   ├── threshold_clock.rs    # 2f+1 quorum-driven round advance
│   ├── base_committer.rs     # Direct + indirect commit rules
│   ├── universal_committer.rs # Multi-leader / pipelined commit composition
│   ├── linearizer.rs         # Sub-DAG flattening
│   ├── commit.rs             # Commit / CommittedSubDag types
│   ├── commit_observer.rs    # Commit consumer / persistence
│   ├── commit_finalizer.rs   # Fast-path transaction finalization
│   ├── commit_syncer.rs      # Certified-commit fast-sync from peers
│   ├── commit_vote_monitor.rs# Tracks commit votes per author
│   ├── dag_state.rs          # In-memory + persistent DAG state
│   ├── block_manager.rs      # Suspended / accepted block tracking
│   ├── block_verifier.rs     # Inbound block validation
│   ├── block.rs              # Block / VerifiedBlock types
│   ├── synchronizer.rs       # Block fetching + amnesia recovery
│   ├── ancestor.rs           # Smart ancestor exclusion
│   ├── leader_schedule.rs    # Reputation-driven leader rotation
│   ├── leader_scoring.rs     # Score calculation
│   ├── round_tracker.rs / round_prober.rs # Peer round probing
│   ├── authority_service.rs  # RPC handlers
│   ├── transaction_vote_tracker.rs # Fast-path vote tracking
│   ├── storage/              # RocksDB and in-memory store
│   └── network/              # Tonic RPC + observer streaming
├── config/src/         # Committee, crypto, parameters
└── types/src/          # Block, BlockRef, Round, BlockDigest, Slot
```

**Concurrency model:**
- **Single Core thread** consumes all consensus events via mpsc (`core_thread.rs:105-138`), serializing `add_blocks`, `try_propose`, `add_certified_commits`, `new_block`, `set_last_known_proposed_round`. This eliminates a large class of races between handlers and the state machine.
- **DagState** is shared via `Arc<RwLock<DagState>>`; writes are short-lived inside the Core thread but readers also include Linearizer (`dag_state.write()` inside `collect_sub_dag_and_commit`) and Commit_finalizer / Synchronizer / Authority_service.
- **Independent tokio tasks**: LeaderTimeout, Synchronizer, CommitSyncer, CommitFinalizer, RoundProber, AuthorityService — all submit to Core via mpsc.

**Persistent / In-memory split:**
- Persistent in RocksDB: blocks (CF `blocks`), commits, commit_info (LeaderSchedule state), finalized_commits, plus secondary index `digests_by_authorities`.
- All buffered in a single RocksDB `WriteBatch` (`rocksdb_store.rs:169-194`) — atomicity per `typed_store::DBMap::batch().write()`.
- In-memory only: `recent_blocks` (evicted after flush), `last_committed_rounds` (recomputable), `threshold_clock.round`, `last_proposed_round`.
- On restart, `DagState::recover_blocks_after_round` re-reads the last commit_info and replays.

---

## 3. Phase 2 — Bug Archaeology

### 3.1 Selected Historical Bug Fixes (with verdicts)

| Commit / PR | Date | Summary | Component | Verdict |
|---|---|---|---|---|
| `f8e7e02a80` / #16722 | 2024-03-19 | "fix potential liveness issue" — missed `new_round` signal after proposing | Core / LeaderTimeout signaling | Real liveness bug; relevant to F4 |
| `67b4c83eb6` / #16679 | 2024-02-22 | "fix mysticeti committee member ordering" | Committee init | Real; one-off; not modeled |
| `addb9794f6` / #17654 | 2024-05-11 | "Fix for stuck leader schedule on recovery" — at LeaderSchedule commit boundary, recovery left schedule inert | Leader schedule recovery | Real; relevant to F2 |
| `6b08134be6` / #17712 | 2024-05-13 | "Fix crash recovery when no commit info was flushed" — DagState did not restore `last_committed_rounds` if no commit_info had been persisted yet | Recovery | Real; relevant to F2 |
| `bed2833369` / #18009 | 2024-06-26 | "Recover from amnesia - part 1" — introduces fetch-own-last-block | Amnesia recovery | Defines F2 |
| `cb0417438e` / #18190 | 2024-07-22 | "Recover from amnesia - part 2" — synchronizer impl of part 1 | Amnesia recovery | Defines F2 |
| `81d0217401` / #18206 | 2024-06-13 | "Disable multi leader per round in universal committer" — at schedule-change boundary, two commits for same round possible | Commit rule × schedule | Real; multi-leader latent (F4 / CR3) |
| `ba7e08577a` / #18771 | 2024-08-22 | "enable amnesia recovery & refactor retry approach" | Amnesia recovery | Real; auto-enable; relevant to F2 |
| `b78eb1098e` / #19774 | 2024-10-16 | "fix amnesia recovery boot run" — boot counter incremented during epoch catch-up defeated amnesia | Recovery × epoch | Real; relevant to F2 |
| `42aa935a80` / #19315 | 2024-09-20 | "Garbage Collection - 1" | GC | Defines F3 |
| `6d9b1f98f5` / #19385 | 2024-10-08 | "Garbage Collection - 2" | GC | Extends F3 |
| `34416bfce4` / #19465 | 2024-10-15 | "DagState to evict blocks based on GC round" | GC | F3 |
| `22aedf0fae` / #20250 | 2025-01-09 | "Linearizer to use commit up to gc_round" — commits *all* blocks > gc_round | Linearizer | Protocol semantics change; F1 |
| `695b712c5c` / #20258 | 2025-01-27 | "enable GC and new linearizer logic for devnet" | GC | F3 |
| `4be879f539` / #20492 | 2025-01-24 | "test to confirm correct threshold clock advancement after GC" | Threshold clock × GC | Real; relevant to F3 / F4 |
| `0d2d137481` / #17284 | 2024-04-23 | "ensure commit timestamps are monotonic" | Linearizer | Real; relevant to F5 |
| `65942fbd9b` / #21347 | 2025-03 | "rework commit & block timestamps" | Linearizer | Refactor; relevant to F5 |
| `65fced6738` / #20992 | 2025-01-28 | "fix GC missing blocks reported via try_fetch_blocks" | Block manager × GC | Real; F3 |
| `d2996dcbbb` / #21206 | 2025-02-13 | "try_find_blocks to respect gc threshold" | Block manager × GC | Real; F3 |
| `523c389316` / #21221 | 2025-02-13 | "fix for excluded ancestor inclusion" | Ancestor selection | Implementation; F5 |
| `084a94b6cf` / #21393 | 2025-03-17 | "Base committer equivocating test case" | Tests | F1 |
| `f1526f5128` / #23240 | 2025 | "fix restart with single node committee" | Recovery edge case | F2 |
| `101d3b79c7` / #24745 | 2025-12-29 | "handle VecDeque wraparound in scan_last_blocks_by_author" | Block manager | Implementation; not modeled |
| `d04950c9ca` / #24292 | 2025-11-15 | "fix deadlock during recovery" — RwLock reader/writer/reader pattern in CommitFinalizer | Recovery × locking | Real; relevant to F2 / F4 |
| `982120decb` / #24024 | 2025-10-29 | "more efficient recovery of finalized commits and reject votes" — introduced the #24292 deadlock | Recovery | Real (introduced bug); F2 |
| `ee26d1dda0` / #25113 | 2026-01-27 | "test equivocations with randomized dag" | Tests | F1 evidence |
| `a08ac240a3` / #25033 | 2025 | "fix randomized dag tests" | Tests | F1 |
| `a470a9d290` / #25141 | 2025 | "Fix a randomized DAG test and a full node test" | Tests | F1 |
| `d52b412b19` / #21118 | 2025-02-24 | "Optimistically accept certified commits votes" | CommitSyncer | F4 / F5 surface |
| `08897ad9b3` / #24497 | 2025-12-02 | "Validate excluded ancestors" | Ancestor selection | Implementation hardening; F5 |
| `f67bfdd1aa` / #24492 | 2025-12-05 | "[mfp] do not vote on potentially GC'ed blocks" | Fast path × GC | F3 |
| `a5695d65df` / #26144 | 2026-04-15 | "remove block certification" | Cleanup | Architecture |

### 3.2 Open Issues / PRs Verified

| # | Title | State | Maintainer verdict |
|---|---|---|---|
| **#24498** | "Linearizer double-commits equivocating blocks at same slot" | OPEN | mwtian: **NOT a bug**, design intent — "Committing equivocating blocks in the same slot is not a safety violation, as long as the commit logic is deterministic across honest validators." Demoted to reference; informs F1 modeling. |
| **PR #24499** | Fix for #24498 | OPEN, stale | Maintainer pushback; will not be merged. |
| **#24473 / PR #24474** | "BlockManager missing_blocks unbounded growth → OOM" | OPEN, stale | mwtian: acknowledged as hardening improvement, not safety bug. Relevant to F5; **socially slashable** if observed in mainnet. |
| **#24475 / PR #24476** | "Authority index bounds" | CLOSED | Author conceded — BlockVerifier validates first; false positive. |
| **PR #25157** | "Reset propagation_delay to 0 after we catch up on all consensus commits" | DRAFT | Open; described in F4. Catching-up node can never propose because propagation_delay > threshold. |
| **#25273** | "Validator stalled for 7 hours on devnet" | OPEN | Likely related to #24292 / #25157; no thread dump captured. |
| **PR #26394** | "[consensus] commit v3" | DRAFT | Future direction; new commit format. |
| **PR #26372** | "[consensus] add LeaderScheduleV3 sliding-window scorer" | OPEN | Future leader-scoring refactor. |

### 3.3 What the Archaeology Tells Us

The recurring patterns visible in the bug history:

1. **Recovery / amnesia × commit-state divergence** — 5+ bugs (#17654, #17712, #18009, #18190, #19774, #24292). The amnesia path is structurally fragile; #24292 was introduced *by* a recovery-related PR (#24024) just months before.
2. **GC × commit rule** — 4 bugs (#20250, #20492, #20992, #21206) all in early 2025 as GC was rolled out. The interaction between GC depth and commit recursion depth is **tuned**, not proven.
3. **Threshold clock signaling** — #16722 and #25157 are both about missed signals between independent loops (Core / LeaderTimeout / Proposer).
4. **Equivocation testing** — only via randomized DAG tests (#21393, #25113, #25033, #25141). The protocol's claim that "committing both equivocating blocks is safe" has not been formally verified — only fuzzed.
5. **Multi-leader latent** — disabled by #18206 because of safety bugs at leader-schedule change boundaries.

---

## 4. Phase 3 — Deep Analysis Findings

### 4.1 Files Read in Full (via 4 parallel subagents)

| Subagent | Files |
|---|---|
| A (commit rules) | `base_committer.rs`, `universal_committer.rs`, `linearizer.rs`, `commit_finalizer.rs`, `commit.rs` |
| B (DAG state) | `dag_state.rs`, `block_manager.rs`, `block_verifier.rs`, `block.rs`, `storage/rocksdb_store.rs`, `storage/mod.rs` |
| C (sync / network) | `synchronizer.rs`, `commit_syncer.rs`, `authority_service.rs`, `commit_vote_monitor.rs`, `ancestor.rs`, `leader_schedule.rs`, `round_prober.rs` |
| D (Core / proposer) | `core.rs`, `proposer.rs`, `leader_timeout.rs`, `threshold_clock.rs` |
| Main thread | Cross-cut verification of selected files / specific findings |

### 4.2 Findings Detail (with file:line citations)

**F1.1 — Commit-rule single-leader guarantee.** `base_committer.rs:107-112` and `:322-326` both `panic!` if >1 leader-block has a 2f+1 certificate quorum. Verified safe via quorum-intersection argument: 2(f+1) > 2f+1 = honest count. So **at most one** block per `(round, author)` slot can be certified — but **multiple equivocating blocks can be uncertified and still ancestors** of a committed sub-DAG.

**F1.2 — `find_supported_block` first-match.** `base_committer.rs:193-215` — recurses on `from.ancestors()` in iteration order; returns the **first** found support for `leader_slot`. Stable across honest validators because `block.ancestors()` is determined by block content. Comment lines 188-192 acknowledge "Blocks can indirectly reference multiple other blocks at a slot, but only one block at a slot will be supported by the given block."

**F1.3 — Linearizer DFS over uncommitted ancestors above gc_round.** `linearizer.rs:177-204`. Buffer is a `Vec<VerifiedBlock>`, popped LIFO. `set_committed(block_ref)` is asserted to return `true` (line 198-202: `"Block with reference {:?} attempted to be committed twice"`). Equivocating blocks at same `(round, author)` have distinct `BlockRef` (digest differs), so both can be set_committed.

**F1.4 — `sort_sub_dag_blocks` stable sort.** `commit.rs:403-409` sorts by `(round, author)`. Equivocating blocks tie on this key; Rust's `sort_by` is stable, so they retain DFS-discovery order. DFS order is deterministic only if the input DAG is identical across validators — which it is, because all causal ancestors are present before commit decision (block_manager suspension semantics).

**F1.5 — `Proposer::smart_ancestors_to_propose` may pick different "primary" digests.** `proposer.rs:190-205` excludes `equivocating_ancestors` and picks one primary per author via `get_last_cached_block_per_authority` (`dag_state.rs:739-765`). The chosen primary is highest `(round, digest)` per author, which is deterministic given identical local state — but two validators that received different equivocating blocks for an author at different times may select different primaries. However, this only affects which block is referenced as an ancestor in the proposer's *next* block; the commit rule operates on `Slot` not `BlockRef`, so does not diverge.

---

**F2.1 — `synchronizer.rs:900-904` `reached_validity(total_stake)` is f+1.**
```rust
if context.committee.reached_validity(total_stake) {
    info!("...");
    break 'main;
}
```
The comment on line 900 says "Request at least f+1 stake to have replied back." With f+1 stake of responders, the quorum-intersection lower bound on "responders who saw the lost block" is `max(0, |R| + |V| - n) = max(0, (f+1) + (f+1) - (3f+1)) = max(0, 1-f) ≤ 0`. Under f Byzantine adversary collusion + 1 truly-amnesia honest, the result is `highest = 0`, and the validator re-signs.

**F2.2 — `dag_state.rs:330` own-equivocation guard is post-hoc.** Reads only `recent_blocks` (in-memory); after eviction the check no longer protects. Practical safety relies on `last_known_proposed_round` gate at `proposer.rs:673`, which is itself set by F2.1's f+1 threshold.

**F2.3 — Boot counter + amnesia interaction.** `b78eb1098e` (PR #19774) fixed a case where the boot counter incremented during epoch catch-up, disabling amnesia recovery on epoch boundaries. The fix tracks "consensus participation activity from earlier epochs/run and only then increments the boot counter." This is fragile and indicates the boot-counter design is hard to reason about.

**F2.4 — Recovery uses `last_commit_leader()` which can return a sentinel.** `core.rs:94`: `last_decided_leader = dag_state.read().last_commit_leader();`. For fresh nodes, this returns the BTreeMap-first genesis block (`Slot { round: 0, authority: 0 }`), deterministic across honest validators.

**F2.5 — Recovery deadlock #24292.** `consensus/core/src/commit_observer.rs` (recovery path) acquires `dag_state.read()` for the duration of `recover_blocks_after_round(observer.dag_state.read().gc_round())`; meanwhile `CommitFinalizer::run` tries `dag_state.write()`, and the original read attempts to re-enter for `recover_and_vote_on_blocks()`. Task-fair locking → deadlock. Fix moved final step to a blocking thread. **This bug had no automated test before discovery in production.**

---

**F3.1 — `base_committer.rs:209` panic.** `let ancestor = self.dag_state.read().get_block(ancestor).unwrap_or_else(|| panic!("Block not found in storage: {:?}", ancestor));` — no GC check. The complementary call site in `is_certificate` (`:250-256`) has the explicit `assert!(reference.round <= gc_round, ...)` guard.

**F3.2 — `dag_state.rs:574` panic in `ancestors_at_round`.** `let Some(block) = self.get_block(&block_ref) else { panic!("Block {:?} should exist in DAG!", block_ref); };`. When traversing from a high-round anchor down to `decision_round = leader_slot.round + 2`, intermediate blocks at rounds `(leader_slot.round + 2, anchor.round)` must all be present. If any was GC'd, panic.

**F3.3 — `block_manager.rs:309-355` ancestor filter.** Blocks with ancestor at `round ≤ gc_round` (and not GENESIS) have those ancestors **skipped** from the existence check at `try_accept_one_block`. So a block whose declared ancestors include digests that never existed below gc_round is accepted. Downstream code at `dag_state.rs:881-908` explicitly skips `block_ref.round ≤ gc_round` in causal traversal; consumers must not dereference. This is implicit, not enforced.

**F3.4 — `gc_round` per validator.** `dag_state.rs:1175-1186`: `gc_round = last_commit_round - gc_depth`. Two honest validators with different `last_commit_round` (delivery skew) have different `gc_round`. Most invariants tolerate this; the exceptional ones are F3.1 and F3.2.

---

**F4.1 — `threshold_clock.rs:65-80` `Ordering::Greater` catch-up.** A single block at round R > self.round causes `self.round = block.round` (since 1 author stake < 2f+1 for n > 1). The comment "we also have stored 2f+1 blocks from r-1" relies on `block_manager.try_accept_one_block` enforcing causal completeness AND `block_verifier` enforcing 2f+1 parent stake — but the threshold clock itself does not verify.

**F4.2 — `proposer.rs:352-354` assertion under cert-commit sync race.**
```rust
assert!(
    parent_round_quorum.reached_threshold(&self.context.committee),
    "Possible mismatch between DagState and Core"
);
```
The flow: `Core::add_certified_commits` accepts peer-certified commits at high round R, bumping `clockRound` to R. Local DAG at peer authorities is sparse below R-1. `LeaderTimeout` fires, calls `new_block(R, force=true)`. `smart_ancestors_to_propose(R, smart_select=false)` cannot find 2f+1 stake of parents at R-1 (because most peer blocks at R-1 are missing locally). Assert panics. Process dies; node restarts.

**F4.3 — `universal_committer.rs:48-57` multi-leader latent.** With `num_leaders_per_round != Some(1)`:
```rust
'outer: for round in (last_round..=highest_accepted_round.saturating_sub(2)).rev() {
    for committer in self.committers.iter().rev() {
        ...
        if slot == last_decided {
            break 'outer;
        }
```
If `last_decided = (R, off=2)`, the `slot == last_decided` matches on first iteration (`committer.iter().rev()` gives `offset=2` first), breaking before `offset=1` and `offset=0` are visited. Disabled in production by `num_leaders_per_round = Some(1)` (`consensus_protocol_config.rs:86`).

**F4.4 — `LeaderTimeout` independent firing.** `leader_timeout.rs` runs on its own tokio task, fires `Core::new_block(round, force=true)` after `max_leader_timeout`. The interaction with the threshold-clock signal `try_signal_new_round` (`core.rs:432-451`) was the locus of #16722 (missed signal → no timeout firing → liveness loss).

**F4.5 — Propagation-delay deadlock (PR #25157, OPEN).** Catching-up node: high propagation_delay (because it's behind), so proposer waits; but proposer is what reduces delay by producing blocks. Circular dependency. Fix proposes resetting delay to 0 on full catchup. **Unfixed.**

---

**F5.1 — `block_verifier.rs:67-152` no timestamp validation.** Checks epoch, round != 0, author index, signature, ancestor positions, parent-stake quorum, transactions — **no** `timestamp_ms()` check. Byzantine can sign `timestamp_ms = u64::MAX`. Later code:
- `linearizer.rs:144` `median_timestamp_by_stake(...)` weights stake; if Byzantine accounts for f stake of (2f+1)-stake parents, can shift median upward.
- `linearizer.rs:153` `timestamp_ms.max(last_commit_timestamp_ms)` enforces monotonicity, but once max jumps to u64::MAX, **all subsequent commits inherit it**.
- `dag_state.rs:1015` `assert_eq!(last_commit_timestamp_ms <= commit.timestamp_ms, ...)` enforces monotonicity at the dag-state level. Honest commits accepting honest leaders never violate this; the bug is **client-visible commit time** is permanently corrupted, not a safety violation.

**F5.2 — `block_manager.rs:51-58` unbounded missing-blocks map.** TODO at line 41 explicitly acknowledges. PR #24474 proposes a 100k-entry cap with distance-based eviction. **Unfixed.**

**F5.3 — `commit_vote_monitor.rs:33-40` no equivocation detection.** Tracks `highest_voted_commits[author]` = max only. A Byzantine signer can include `CommitRef(N, digest_A)` in one block and `CommitRef(N, digest_B)` in another — both update `highest_voted_commits[author]` to N silently. No slashing evidence emitted.

**F5.4 — `round_prober.rs:160-176` length-only validation.** Peer-returned `received` / `accepted` round vectors are only checked for `len() == committee.size()`. Bogus values flow into `RoundTracker::update_from_probe` and `calculate_network_high_quorum_round` (`ancestor.rs:283-305`), influencing ancestor exclusion and propagation_delay.

**F5.5 — `ancestor.rs:77, 89-94, 174-184` exclusion semantics.** Excluded stake capped at `2/3 * bad_nodes_stake_threshold` (default 22%); excluded duration 450 rounds (~30-45s). Two honest validators with different score histories can exclude different authorities. Intersection of included authorities at the **proposer's parent quorum check** may drop below 2f+1, causing `parent_round_quorum.reached_threshold = false`, triggering smart-select wait at `proposer.rs:234-241`. Liveness-fragile under post-partition recovery.

**F5.6 — `authority_service.rs:411-424` `handle_fetch_blocks` ignores peer.** `_peer: AuthorityIndex` underscore — no per-peer rate limit, no committee-membership check at this layer. Combined with `handle_get_latest_rounds` returning full vectors of `highest_received_rounds` / `highest_accepted_rounds` (lines 450-468), enables side-channel mapping of local DAG state.

**F5.7 — `commit_syncer.rs:847-873` last-commit-only stake check.** Fetched commit ranges are stake-aggregated only on the *last* commit's `end_commit_ref`. Earlier commits are chained-by-digest only. Under collusion of >2f+1 stake (out of scope per BFT assumption), forged chains pass. **Design-fragile but safe under the standard assumption.**

**F5.8 — `commit_syncer.rs:797-882` no previous_digest binding at fetch boundary.** A peer returning commits for range [N..M] when local last commit is N-1 doesn't verify that `commits[0].previous_digest == local.last_commit_digest`. The chain-internal consistency is checked, but the start-anchor is not. Downstream commit handling rejects later, but the trust boundary is leaky.

**F5.9 — `BlockRef::hash` truncation.** `types/src/block.rs:72-76` hashes 8 bytes of digest. Used in HashMap. DagState/BlockManager use BTreeMap (Eq-keyed), so safety-preserved, but any HashMap<BlockRef, _> in extension code is grindable. CR4 in brief.

**F5.10 — `commit_finalizer.rs:160-166` in-memory `last_processed_commit` assert.** `assert_eq!(last_processed_commit + 1, committed_sub_dag.commit_ref.index);`. On certain restart sequences, the in-memory counter is 0 (Option::None) but persisted DagState has finalized higher commits; the replay can trigger the assert. CR6 in brief.

---

## 5. Phase 4 — Bug Family Synthesis

The 25+ raw findings cluster cleanly into **5 Bug Families** documented in `modeling-brief.md` § 2:

| Family | Mechanism | # Findings | Priority |
|---|---|---|---|
| F1 | Equivocation handling at same `(round, author)` slot | 5 (F1.1-F1.5) + 4 historical PRs + #24498 | High |
| F2 | Amnesia recovery & own-equivocation threshold | 5 (F2.1-F2.5) + 5 historical PRs | High |
| F3 | GC × commit-rule interactions | 4 (F3.1-F3.4) + 5 historical PRs | Medium |
| F4 | Leader timeout / threshold clock / proposer liveness | 5 (F4.1-F4.5) + 3 historical PRs + #25157 open | Medium |
| F5 | Byzantine input validation gaps | 10 (F5.1-F5.10) + #24474 open | Low (modeling) / High (review) |

---

## 6. Verification Notes

For each finding included in the brief, I verified by:

1. Re-reading the cited file:line range directly (not memory).
2. Checking for compensating mechanisms in the surrounding code.
3. Cross-referencing with PR descriptions and maintainer discussions where available.
4. Quorum-intersection arithmetic for the f+1 vs 2f+1 question (F2.1).

**Specific verifications performed:**

- F1.4 sort stability: confirmed `sort_by` in Rust std is stable (documented behavior).
- F2.1 quorum math: 4-node committee with f=1, validity threshold = `(f+1) = 2`. Verified `Committee::reached_validity` returns true at total_stake >= f+1.
- F3.1 GC asymmetry: confirmed `is_certificate` (`:250-256`) has the `assert!(reference.round <= gc_round)` but `find_supported_block` (`:193-215`) does not. The asymmetry is real.
- F4.2 cert-commit sync race: traced `Core::add_certified_commits` → `dag_state.write().accept_blocks(...)` → `threshold_clock.add_block(block_ref)` (`Ordering::Greater` branch). Confirmed the threshold clock advances on the high-round committed block without filling intermediate DAG.
- F5.1 timestamp gap: re-read `block_verifier.rs:67-152` — no `block.timestamp_ms()` call anywhere in `verify_block` or `check_transactions`.

---

## 7. Findings Excluded as False Positives or By-Design

| Finding | Why excluded |
|---|---|
| Issue #24498: "Linearizer double-commits equivocating blocks" | mwtian explicit: design intent; commit logic relies on including all equivocating blocks for vote/info purposes. Re-derived in F1 modeling rather than counted as a bug. |
| PR #24476: "Authority index bounds panic" | Author conceded; block_verifier validates upstream. |
| Commit-vote DoS via inflated index (F5 / commit_vote_monitor) | Under BFT assumption (<2f+1 Byzantine), the inflated value can't be reached. Out of scope. |
| `f8e7e02a80` / #16722 reproduction as MC target | Already fixed upstream; per `bug-archaeology.md` § 1.4, reproducing closed bugs is not valuable. Listed only as evidence for F4. |
| `b78eb1098e` / #19774 reproduction as MC target | Same — closed. Evidence for F2 only. |
| `addb9794f6` / #17654 stuck schedule reproduction as MC target | Same — closed. Evidence for F2 only. |
| RocksDB CF compaction edge cases (F5 / digests_by_authorities) | Storage layer; not protocol concern. Code-review only. |

---

## 8. Open Questions That Did Not Land in the Brief

- **Epoch / committee rotation**: the case-study brief listed this as an open question, but Sui's epoch rotation lives largely outside `consensus/` (in `sui-core` epoch-management). The consensus crate treats epoch as a constant. Within scope: `block_verifier.rs:71-75` checks `block.epoch() == committee.epoch()` — strict, rejects cross-epoch blocks. No cross-epoch replay surface inside consensus. **Out of scope for modeling.**
- **Pacemaker / view-change**: Mysticeti's pacemaker is the threshold clock; there's no explicit view-change subprotocol. Round advancement is uniform across honest validators (no view numbers). F4 covers the relevant liveness question.
- **Selective dissemination via subscribe_blocks**: `authority_service.rs:336-394` streams to subscribed peers. Naturally pull-based; safety unaffected. Not modeled (Layer-2 2.4 deferred per default profile).
- **Vote inclusion in certificates** (open question): in Mysticeti each block's commit_votes are implicit certificates; the per-vote authentication gap is F5.3 (no equivocation detection). Whether a Byzantine block author can selectively cite real votes for a different proposal: not directly — votes are tied to commit_ref `(index, digest)`. Forging would require either honest-signature forgery (out of scope) or a hash collision on the commit serialization (negligible). **Verified as not exploitable.**

---

## 9. Recommended Next Steps for Spec Generation

1. **Start with F2 (amnesia recovery threshold)**: smallest modeling surface, sharpest invariant violation, clearest counterexample. Single MC target (`MC2`) → expect a 4-node Byzantine + crash trace produces `NoOwnEquivocation` violation.
2. **Then F1 (equivocation commit determinism)**: introduce `ByzEquivocate` action, model `linearize_sub_dag` traversal with stable sort, verify `CommitDigestAgreement` holds. This validates the maintainer's design intent (#24498).
3. **Then F3 (GC asymmetry)**: smaller surface; test whether `find_supported_block` panic is reachable under any honest schedule. If yes, also a real bug → file an issue.
4. **Defer F4 (cert-commit force-propose race)**: requires modeling certified-commit fast-sync, which is a larger spec extension. Worth it if MC2 / MC1 succeed.
5. **F5 (input validation) → not for TLA+**: forward as code-review and test-verifiable items.

The case-study's signature contribution is likely **F2 + F1**:
- F2 finds an unfixed safety hazard with closed-form analysis (quorum math).
- F1 verifies a design choice the team made but did not formally prove — value in confirming the maintainer's "deterministic across honest validators" claim.

---

## Appendix A: Tooling Used

- `git fetch --depth=30000` on `MystenLabs/sui` to recover 19,750 commits.
- `gh issue/pr view -R MystenLabs/sui <num> --comments` for full discussion threads.
- 4 parallel Task subagents covering 18 core source files.
- Manual cross-verification of all High-priority findings.

## Appendix B: Reference Sources

- Mysticeti paper: https://arxiv.org/pdf/2310.14821
- Sui consensus README: `consensus/README.md`
- Sui CLAUDE.md (testing/build guidance, not protocol)
- BFT analysis methodology: `.claude/skills/code_analysis/references/bft-analysis.md`
- Distributed analysis methodology: `.claude/skills/code_analysis/references/distributed-analysis.md`
- Modeling brief format: `.claude/skills/code_analysis/references/modeling-brief-format.md`

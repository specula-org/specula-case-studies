# Analysis Report: Solana Tower BFT (anza-xyz/agave)

## Target

- Repository: `anza-xyz/agave` (active Solana validator client, forked from `solana-labs/solana`)
- Local clone: `/home/ubuntu/Specula/case-studies/solana/artifact/agave` (master @ `9444f21f`, 15 K-commit shallow window deepened from initial depth-1)
- Language: Rust
- Scope: **Tower BFT consensus subsystem only** (per case-study brief). Skipped: SVM/Sealevel runtime, accounts-db, gossip/turbine, RPC, banking stage, PoH service, validator key-management, staking program internals.

## System Category

**Category A (Distributed / Message-Passing)** with a **Byzantine threat model**. Tower BFT is a **vote-lockout BFT** sub-variant (PoH-ordered slots + per-validator persistent tower + 2/3 OC threshold + 38% switch-threshold). It is materially different from quorum-cert protocols (Tendermint, HotStuff, DiemBFT, IBFT/QBFT) and from DAG-BFT (Mysticeti, Bullshark) because:

1. Safety derives from each validator's per-vote **exponentially growing lockout period** plus a separate **switch-proof** quorum (38%, asymmetric vs the 2/3 OC quorum).
2. There are no traditional commit certificates — finality is achieved when a slot is **rooted** after a chain of 32 votes accumulates lockout depth 2³².
3. Safety is enforceable on-chain via **vote-program lockout checks** rather than off-chain quorum-cert verification. Slashing is *not yet implemented* (issues #7521, #8113); safety relies on rational-Byzantine assumptions plus persistent tower files.

The TLA+ spec must model `slots` as opaque ordered integers, stake weights as constants, signatures as unforgeable. Both `bft-analysis.md` and `distributed-analysis.md` apply (with the bft overlay on top of the 6 distributed fault families).

## In-Scope Files (canonical paths reconciled per brief caveat)

The Anza fork has reorganized the consensus code since the brief was written. Canonical paths in the analyzed snapshot:

| Reference brief path | Actual path | LOC |
|---|---|---|
| `core/src/consensus.rs` | `core/src/consensus.rs` | 3932 |
| `core/src/tower_storage.rs` | `core/src/consensus/tower_storage.rs` | 277 |
| `core/src/replay_stage.rs` | `core/src/replay_stage.rs` | 10405 |
| `core/src/voting_service.rs` | `core/src/voting_service.rs` | (≈170) |
| `core/src/vote_simulator.rs` | `core/src/vote_simulator.rs` | (test-only) |
| `core/src/cluster_slots*.rs` | `core/src/cluster_slots_service.rs`, `core/src/cluster_slots_service/cluster_slots.rs` | 239 + … |

Additional Tower-relevant files discovered in Phase 1 reconnaissance:

| Path | Role | LOC |
|---|---|---|
| `core/src/consensus/fork_choice.rs` | `select_vote_and_reset_forks` orchestration | 491 |
| `core/src/consensus/heaviest_subtree_fork_choice.rs` | weighted fork-choice tree | 4687 |
| `core/src/consensus/progress_map.rs` | per-bank cached stats (`is_locked_out`, `vote_threshold`, etc.) | 642 |
| `core/src/consensus/latest_validator_votes_for_frozen_banks.rs` | gossip + replay latest-vote map | 552 |
| `core/src/consensus/vote_stake_tracker.rs` | per-(slot, hash) optimistic-confirmation stake | 100 |
| `core/src/consensus/tower_vote_state.rs` | minimal `votes + root_slot` representation | 345 |
| `core/src/cluster_info_vote_listener.rs` | gossip + replay → vote tracker → OC notifications | 2221 |
| `core/src/optimistic_confirmation_verifier.rs` | tracks OC-but-not-rooted slots | 330 |
| `core/src/commitment_service.rs` | aggregates `BlockCommitment` | 811 |

**Migration note (important):** Anza has *partially upstreamed* a successor protocol, **Alpenglow / Votor**, under `votor/src/`. The active master branch keeps both code paths reachable, gated by `MigrationStatus::is_alpenglow_enabled()`. Tower BFT is the production path at the time of this analysis and remains the modeling target. Some recent fixes (e.g., `8e48eb15`/`d9ad69e2` LockoutIntervals optimization, `985c0dcd` dirty-set fix) still touch the Tower BFT code.

## Coverage Statistics

- **Commits inspected**: 374 commits touching `core/src/consensus.rs`, `core/src/consensus/`, or `core/src/replay_stage.rs` in the 15 K-commit shallow window. ~95 of those matched the bug-fix-grep filter (`fix|race|bug|panic|crash|safety|correctness|hang|deadlock|wrong|incorrect|inconsistent`). Read 14 key bug-fix commits in detail (`07955e79a`, `befe8b9d9`, `85cc6ace0`, `fb97e93fe`, `07f38838a`, `6f72258e3`, `c2bb2b8e6`, `985c0dcd`, `000ca4ce0`, `84a934a9f`, `be02fe6e`, `531793b4b`, `8e48eb15`, `d9ad69e2`).
- **GitHub issues deeply read**: 39 issues across `solana-labs/solana` and `anza-xyz/agave` (full discussion threads via `gh issue view --comments`, distributed across 3 parallel subagents). Of those: **17 confirmed bugs / acknowledged design defects**, **8 disputed / debunked**, **9 closed-stale without resolution**, **5 inconclusive flaky-test reports**.
- **Source files deeply analyzed**: 11 core files spanning ~22 K LOC, distributed across 4 parallel subagents per the methodology.

## Bug Families (Mechanism Groupings)

The 50+ raw findings cluster into six mechanism-based families. Severity inside each family is from the most-impactful finding.

---

### Family 1 — Tower Adoption & Crash-Recovery Hazards (HIGH)

**Mechanism**: When the validator's persistent tower file is lost, stale, or behind the on-chain vote-state of its own vote account, the code adopts vote state derived from the *heaviest local bank* without per-vote provenance verification. This is the most modeling-relevant family for Tower BFT.

**Specific findings**:

- **`adopt_on_chain_tower_if_behind`** at `core/src/replay_stage.rs:4046-4166`. Replaces `tower.vote_state` wholesale with `TowerVoteState::from(bank's stored vote account)`. The chain of trust relies on runtime signature-verification of vote-txs during bank replay; there is no per-`Lockout` audit that the adopted votes correspond to txs this validator instance actually signed. A Byzantine-leader-built bank that the local node replays-and-freezes can produce a vote state composed of votes our authorized voter previously signed on a different fork. The first-vote-ancestry assertion at lines 4093-4102 covers only the kept-vote-after-local-root prefix.

- **Tower file without `fsync`** at `core/src/consensus/tower_storage.rs:165-176` and `:205-220`. Both `store_old` and `store` explicitly comment `// file.sync_all() hurts performance; pipeline sync-ing and submitting votes to the cluster!` and skip parent-dir fsync too. The voting service stores tower → broadcasts vote-tx (`core/src/voting_service.rs:107-165`); a crash between rename-return and page-flush leaves the durable tower behind the broadcast vote. On reboot, recovery via `adjust_lockouts_after_replay` plus `adopt_on_chain_tower_if_behind` may not converge on the lost vote (e.g., if our vote did not land on a fork we now replay), and we may re-vote at a smaller slot on a different fork → slashable in the slashing-enabled-future world.

- **`initialize_lockouts_from_bank`** at `core/src/consensus.rs:1652-1670`, called from `Tower::new` → `load_tower` fallback at `core/src/replay_stage.rs:1605` when tower file is missing or too-old. Adopts the entire vote-state of *our vote account* from a *heaviest bank* — same vulnerability surface as #1, just at boot time. Only a `warn!` log.

- **`empty_ancestors_due_to_minor_unsynced_ledger`** at `core/src/consensus.rs:975-1090` and `:881`. When `last_voted_slot` is stray and the local `ancestors` map lacks its ancestry, `is_valid_switching_proof_vote` returns `Some(true)` for every candidate not a descendant of `last_voted_slot` (line 897). Switch-proof stake can then be inflated by votes from validators that are, in reality, on the same logical fork. The comment at lines 985-992 explicitly admits "The only exception is that other validator is already violating it..." — i.e., relies on no concurrent Byzantine misbehavior. A Byzantine peer that supplies crafted blocks affecting `ancestors` map population could weaponize this.

- **`adjust_lockouts_after_replay`** future-tower path at `core/src/consensus.rs:1504-1535`. When `tower_root > replayed_root`, suspends via `FailedSwitchThreshold(0, total_stake)` ONLY on cross-fork voting. Same-fork voting from a future tower is not gated inside `record_bank_vote_and_update_lockouts`; the only defense is the `is_locked_out` cache populated by `cache_tower_stats`. The "false perception" warning at lines 1023-1024 is explicit.

- **Three-step non-atomic record→store→send** at `core/src/replay_stage.rs:3112-3158` (`push_vote`) → `core/src/voting_service.rs:107-165` (`handle_vote`). Replay updates in-memory tower → builds `SavedTower` from updated state → channel-sends to voting service → voting service writes tower (no fsync) → broadcasts vote-tx. Channel send failure only logs `warn!`. If voting-service `store` fails it `exit(1)`s, but the in-memory replay tower already advanced. Combined with no-fsync (above), this is the canonical BFT 2.6 amnesia × 5.1 crash × 5.4 non-atomic-persistence composition.

**Historical evidence**:
- Issue solana-labs/solana #23135 (OPEN since 2022-02-15) — "Stray votes after restarting from lost tower will cause switching violation". Confirms the empty-ancestors path is a *known* unmitigated safety hazard.
- Issue solana-labs/solana #23137 (OPEN since 2022-02-15) — "Starting from a snapshot more than 512 slots ahead of your last vote will crash with persisted tower". Tower-history beyond `SlotHashes` window cannot be reconciled.
- Issue solana-labs/solana #25598 (OPEN since 2022-05-26) — "Persisted tower should use the longer root history present in accountsdb". Proposed fix for #23137 not landed.
- Issue solana-labs/solana #20192 (closed stale 2023-12-08) — "Use burner tx to safely initialize tower on restart". Aleksandr proposed a real safe restart, allowed to stale.
- Commit `85cc6ace0` (2023-09-25) — "Update is_locked_out cache when adopting on chain vote state (#33341)" — confirms adoption is a live problem area.
- Commit `000ca4ce0` (2024-06-11) — "only recache tower stats for computed banks on tower adoption (#1632)" — refactor of the adoption-tower-cache-refresh path.

---

### Family 2 — Switch-Threshold Manipulability via Gossip-Originated Latest Votes (HIGH)

**Mechanism**: The switch-threshold check (the BFT-style "lockout-violation evidence" check that lets a validator move to a different fork) sums stake from two sources: on-chain replayed votes (`lockout_intervals`) AND **gossip-observed latest votes** from `LatestValidatorVotesForFrozenBanks::max_gossip_frozen_votes()`. The gossip-source path verifies the signature but does NOT cross-verify that the validator actually voted on-chain for that slot.

**Specific findings**:

- **Gossip-vote bias of switch threshold** at `core/src/consensus.rs:1218-1268`. Loop over `max_gossip_frozen_votes()` adds each validator's stake to `locked_out_stake` if a structural ancestor check (`is_valid_switching_proof_vote`) succeeds. The structural check is graph-only; it does not require the gossip vote correspond to an on-chain vote on the alternate fork. A Byzantine validator V can gossip a fake (slot, hash) for any frozen bank on a competing fork; V's full delegated stake counts toward `SWITCH_FORK_THRESHOLD` (38%). With ≥1/3 Byzantine stake (or coordinated Byzantine actors > 38%), `SwitchProof` can be returned without real cluster-wide lockout.

- **`max_gossip_frozen_votes` never pruned across roots** at `core/src/consensus/latest_validator_votes_for_frozen_banks.rs:9-17`. Explicit TODO. Entries with `slot < tree_root` remain forever. Combined with 2.9 adaptive corruption (Solana is PoS — validators can re-stake), a Byzantine validator that retired keys can later re-stake and have stale gossip-vote claims biased into fresh switch-threshold checks.

- **`SameFork` super-refresh fallback bypasses switch-threshold** at `core/src/consensus/fork_choice.rs:113-123`. When `last_vote_able_to_land` returns false (last vote outside `SlotHashes` window), the code escalates to unconditional `SameFork`. The candidate becomes `heaviest_bank_on_same_voted_fork`, which can be a duplicate-descendant `deepest_slot`. The Byzantine path: engineer 512-slot vote-inclusion withholding to force this branch on a victim.

- **`set_tree_root` does not clean `latest_votes`** at `core/src/consensus/heaviest_subtree_fork_choice.rs:363-379`. Contrast with `split_off` (lines 636-639) which does clean. After `set_tree_root`, `latest_votes` may point at removed fork-infos. Currently safe by coincidence (downstream consumers no-op on missing keys), latent footgun.

**Historical evidence**:
- Issue solana-labs/solana #7087 (closed COMPLETED 2022-05-27, **security label**) — "Fork choice rule can be tricked by a minority that overcommits to a fork". The protocol-level mitigation (no longer accidentally creating a heavier fork via withheld votes) was acknowledged as needed; the issue was closed without a clear PR. Economics analysis by aeyakovenko showed selfish-mining attacks are not profitable for <33% stake, but the structural fork-choice issue (not the economics) is the relevant concern for our threat model.
- Issue solana-labs/solana #6727 (OPEN ~6.5 years) — "Validators may continue voting even if the network is censoring the validator" — local tower can diverge unboundedly from on-chain tower.

---

### Family 3 — Optimistic Confirmation Equivocation Accounting (HIGH)

**Mechanism**: Optimistic Confirmation accumulates stake per `(slot, hash)` pair, with no cross-hash dedup at the listener layer. A Byzantine ≥1/3 stake can drive *two* distinct `(slot, hash_A)` and `(slot, hash_B)` to OC simultaneously by gossiping votes on both.

**Specific findings**:

- **Per-(slot, hash) trackers have no cross-hash pubkey dedup** at `core/src/consensus/vote_stake_tracker.rs:14-38`, called from `core/src/cluster_info_vote_listener.rs:940-955`. Each `(slot, hash)` gets its own `VoteStakeTracker.voted: HashSet<Pubkey>`. Same validator V's stake is counted in BOTH trackers. With f stake Byzantine and (1-f) honest split across two forks, both hashes can reach 2/3.

- **Verifier never explicitly detects dual-hash OC** at `core/src/optimistic_confirmation_verifier.rs:11-86`. `unchecked_slots: BTreeSet<(Slot, Hash)>` admits multiple entries per slot; `add_new_optimistic_confirmed_slots` (line 57-86) does not check for existing different hash at the same slot. The "two hashes both OC'd" event is never flagged as a safety-invariant violation — only the *rooting outcome* eventually surfaces it (and only in narrow cases: F9).

- **`verify_for_unrooted_optimistic_slots` keys by Slot** at `core/src/optimistic_confirmation_verifier.rs:39-54`. `root_ancestors` is keyed by `Slot`, not `(Slot, Hash)`. If `(S, H_bad)` is in `unchecked_slots` AND `S` is an ancestor of root (regardless of which hash rooted), the bad entry is silently dropped — **false negative for equivocation evidence**. Equivocations can only be flagged when the rooted chain settles on a *third* hash.

- **Bank dump does not clean `VoteTracker` / `unchecked_slots`** at `core/src/replay_stage.rs:2019-2124` (`purge_unconfirmed_slot`) vs `core/src/cluster_info_vote_listener.rs:144-155` (`purge_stale_state`). When a slot is dumped because it was duplicate-confirmed on a different hash, the `SlotVoteTracker` is preserved. `unchecked_slots` still contains the bad-hash entry. Cleanup is gated on root advancement, not on bank-dump events.

- **OC counts only `last_voted_slot_hash`** at `core/src/cluster_info_vote_listener.rs:773-791`. A `TowerSync` vote-tx contains many lockouts, but OC stake accumulates only on the most-recent slot. Intermediate slots in the tower are ignored. After commit `207fb1d00` (2026-02-19, "consensus: axe the intermediate accumulation pathway for OC (#10594)") that removed `BankHashCache`, this is the production behavior.

- **Three divergent stake views**: `BlockCommitment` (commitment_service.rs), `VoteTracker` (cluster_info_vote_listener.rs), `LatestValidatorVotesForFrozenBanks` (fork_choice). All three independently aggregate "who voted for slot S" with different inputs and different cleanup schedules. RPC `optimisticallyConfirmed` derives from (2); `confirmed` from (1). They are not synchronized.

**Historical evidence**:
- Issue solana-labs/solana #34107 (OPEN, consensus label) — Nov 3 2023 mainnet-beta latency event led to PR #34120 introducing a second vote-threshold at depth 4 (38%) — confirms that OC and fork-choice thresholds are still an actively-evolving design area.
- Issue solana-labs/solana #33669, #34102 (closed) — Flaky `test_optimistic_confirmation_violation_with_tower` / `_without_tower` — the safety property the tests check is sensitive to scheduling, supporting that the safety surface is non-trivial.
- Commit `84a934a9f` (2024-10-23, #3136) — added `BankHashCache` to "aggregate all slots in full tower votes for OC".
- Commit `207fb1d00` (2026-02-19, #10594) — REMOVED `BankHashCache` (104-line `runtime/src/bank_hash_cache.rs` deleted; 171 lines removed from listener). Confirms the OC accumulation pathway is in flux.

---

### Family 4 — Duplicate-Slot Reconciliation & Fork-Choice State (MEDIUM-HIGH)

**Mechanism**: Several code paths panic on detected conflicts that *should be expected* under Byzantine equivocation, and others silently mutate fork-choice state in ways the tower cannot undo. These create liveness hazards and, when composed with Family 1, safety hazards.

**Specific findings**:

- **Duplicate-confirmed `assert_eq` panic** at `core/src/replay_stage.rs:2205-2254`. If two distinct duplicate-confirmed notifications fire for the same slot with different hashes (the literal definition of equivocation evidence), the validator panics. Stake-threshold protection (≥0.52 per side) means the panic requires Byzantine + honest splits adding to >1.0, which is *exactly* when ≥1/3 Byzantine stake equivocates — i.e., the panic fires in the case the safety machinery is supposed to detect.

- **`purge_unconfirmed_slot` strands tower** at `core/src/replay_stage.rs:2019-2124`. When a duplicate-confirmed slot diverges from local frozen hash, `dump_then_repair_correct_slots` purges the slot from `bank_forks`, `ancestors`, `descendants`, `progress`, `blockstore.clear_unconfirmed_slot` — but **tower is not touched**. Our vote on that slot remains in `tower.vote_state.votes`, with no backing bank. `is_stray_last_vote` may not fire (it's set only on `load_tower`/`adjust_lockouts_with_slot_history`).

- **"Should never consider switching to ancestor" panic** at `core/src/consensus.rs:1100-1109`. After `purge_unconfirmed_slot` (above) removes a slot below `last_voted_slot`, the next `select_forks` can pick a heaviest-slot that is, in the bank graph, an ancestor of our pre-purge last_voted_slot. `stray_restored_slot` is None (we voted post-restore), so the `is_stray_last_vote` branch is False and the panic fires. Byzantine path: coordinated duplicate-confirm of a slot just below our last_voted_slot.

- **`record_bank_vote_and_update_lockouts` panics on out-of-order** at `core/src/consensus.rs:700-735`. After Family-1 adoption sets `last_voted_slot` from on-chain state, the next `select_vote_and_reset_forks` could pick a votable bank with slot ≤ adopted_slot (possible if heaviest-replayable slot is lower than the on-chain last_voted_slot). Panic.

- **Equivocation via smaller-hash override** at `core/src/consensus/heaviest_subtree_fork_choice.rs:1017-1047`. Same-slot votes with lexicographically smaller hash override earlier same-slot votes (line 1019-1023). A Byzantine validator can shift stake between competing forks at will by emitting equivocating votes ordered by hash. The `warn!` at line 1038 acknowledges this.

- **`SlotHashKey = (Slot, Hash)` indexes only on `bank_hash`, not `block_id`** at `core/src/consensus/heaviest_subtree_fork_choice.rs:27`. The vote-tx wire format carries `(slot, bank_hash, block_id)`. Fork-choice indexes only on `(slot, bank_hash)`. Two distinct shred sequences for slot S producing the same `bank_hash` but different `block_id` collapse — but validators' signed votes commit to different `block_id`s. This is consensus state (signed in TowerSync) excluded from fork-choice.

- **`is_locked_out` cache stale** at `core/src/consensus.rs:827-856` consumed at `core/src/consensus/fork_choice.rs:334-345`. `record_bank_vote` updates tower but does not invalidate `fork_stats.is_locked_out` for other slots. Currently safe because `select_vote_and_reset_forks` runs after `compute_bank_stats`, but ordering is implicit.

**Historical evidence**:
- Commit `c2bb2b8e60` (2022-10-03, #28172) — "Allow validators to reset to the slot which matches their last voted slot" — direct evidence of liveness issues from duplicate-purge stranding.
- Commit `fb97e93fe3` (2024-01-10, #34014) — "fix duplicate confirmed rollup detection for descendants".
- Commit `985c0dcdd` (2025-12-20, #9445) — "preserve slot on duplicate frozen votes in dirty set" — fixes a sibling crash in the same family.
- Issue solana-labs/solana #24710 (closed by patch #24948) — "Possible bug when leader cluster duplicate slot hash mismatch" — leader-only consensus divergence.

---

### Family 5 — Lockout Defense-in-Depth Gaps (MEDIUM)

**Mechanism**: The lockout-check is enforced at *only one site* — the cache populated by `cache_tower_stats` and consulted by `can_vote_on_candidate_bank`. The `record_bank_vote_and_update_lockouts` function itself does NOT recheck `is_locked_out`. The single-depth threshold check has historically been a recurring issue (#5850, #22244, #34107, partially fixed by PR #34120's depth-4 addition).

**Specific findings**:

- **`record_bank_vote_and_update_lockouts` does NOT check `is_locked_out`** at `core/src/consensus.rs:700-735`. Only checks `vote_slot > last_voted_slot`. Lockout enforcement lives externally (`cache_tower_stats` → `progress.fork_stats.is_locked_out` → `can_vote_on_candidate_bank`). Future refactors that bypass `select_vote_and_reset_forks` would silently corrupt the tower stack.

- **Five `panic!`/`unwrap` sites in `make_check_switch_threshold_decision`** at `core/src/consensus.rs:1043, 1088, 1092, 1104, 1167, 1175`. Each asserts an invariant of `ancestors`/`descendants`/`progress`/`bank_forks`. Crafted Byzantine bank-forks data can in principle trigger any → halt = liveness loss.

- **Two-depth threshold only** at `core/src/consensus.rs:1387-1390`. `vote_thresholds_and_depths = [(DEPTH_SHALLOW=4, SWITCH=0.38), (DEPTH_SHALLOW+1=5, SWITCH=0.38), (DEPTH=8, VOTE=0.667)]`. Issue #5850 (OPEN ~5.5 years) argued for *threshold at every depth* — aeyakovenko: "for lockout of 2^12 don't commit unless the cluster is at 2^10". Currently only 4-, 5-, and 8-deep are checked.

- **`f64` threshold precision** at `core/src/consensus.rs:593, 605, 1210, 1263, 1349`. `(stake as f64 / total_stake as f64) > threshold` is not equivalent to integer-exact `stake * 3 > total_stake * 2`. At mainnet stake scale (~10¹⁷), roundoff ~10-100 lamports. For TLA+, model thresholds as exact fractions.

**Historical evidence**:
- Issue solana-labs/solana #5850 (OPEN ~5.5 years) — "tower only checks threshold for one bank".
- Issue solana-labs/solana #22244 — "Validators are allowed to run too aggressively into potential deep lockout situations". carllin clarified `consensus.rs#L860-865` does gate voting at depth 8 — but the depth choice is "an estimate on partition lengths".
- Issue solana-labs/solana #34107 (OPEN) — Nov 3 2023 mainnet event.
- Commit `07f38838a` (2023-12-12, #34120) — added DEPTH_SHALLOW=4 threshold.
- Issues solana-labs/solana #7521, #8113 — "Nodes that violate lockouts should be removed from consensus (slashing v0)" / "Validators do not have any failsafe checks for consensus" — both OPEN-and-stalled multi-year. **Solana does not yet implement on-chain slashing for tower violations.** Tower safety relies on *rational* economic Byzantine assumptions (not slashing-enforced).

---

### Family 6 — Migration & Identity-Swap Window (LOW-MEDIUM)

**Mechanism**: Two cross-cutting transition points expose race windows: (a) the Alpenglow/Votor migration phase machine, and (b) `set-identity` runtime identity swap.

**Specific findings**:

- **Migration dual-path**. `MigrationStatus` has phases `PreFeatureActivation → Migration → ReadyToEnable → AlpenglowEnabled → FullAlpenglowEpoch`. The `ReadyToEnable → AlpenglowEnabled` transition is performed by **`PohService`** while replay reads via `phase.read()`. Replay can be mid-`handle_votable_bank` when the flip occurs. Outer-loop guards (`replay_stage.rs:944`, `:2738 assert!(!migration_status.is_alpenglow_enabled())`) are fail-stop but not graceful. The genesis-vote path (`maybe_send_genesis_vote`) builds a separate persistence file (votor's `vote_history`) distinct from the Tower file — its own crash-recovery story.

- **Identity-swap path** at `core/src/replay_stage.rs:1246-1274` and `:740-765`. Historical bugs #34785, #35152, #28047. The current code re-loads the tower on identity change and `exit(1)`s on mismatch (`SavedTower::new` check at `tower_storage.rs:94-101`). With `wait_for_vote_to_start_leader = false`, the new identity can produce leader blocks without first landing a vote — operationally weak.

- **Vote-refresh path is NOT persisted**. `refresh_last_vote_timestamp` and `refresh_last_vote_tx_blockhash` update only in-memory tower; only `PushVote` saves. On crash, `last_vote_tx_blockhash` and `last_timestamp` regress.

**Historical evidence**:
- Commit `befe8b9d9` (2024-02-20, #35173) — "replay: reload tower if set-identity during startup" — fixed #35152.
- Commit `07955e79a` (2024-02-21, #35269) — "replay: gracefully exit if tower load fails".
- Issue anza-xyz/agave #34785 (OPEN) — set-identity race without WFSM, structural fix from #35173 may not fully cover.

---

## Findings Verified as Non-Issues

Documented to prevent re-discovery:

- **Switch-proof double-count via gossip path** — verified de-duped via `locked_out_vote_accounts` set across both interval and gossip loops at `core/src/consensus.rs:1190, 1213, 1224, 1266` (Consensus F14).
- **`fork_choice_dirty_set` `or_default` then push** — fixed by commit `985c0dcd` (12/2025); sibling branches at `latest_validator_votes_for_frozen_banks.rs:40-50, 75-82` use distinct `insert()` paths with fresh `Vec` and are not vulnerable (Forkchoice F3).
- **`parse_vote_transaction` panic risk** — verified sound, returns `Option`, no panic on malformed input (OC F7).
- **`SavedTowerVersions::try_into_tower` signature verification** — correctly checks signature BEFORE deserialization, plus post-deserialization pubkey check (Replay F12). Cryptographic protections of the tower file are correct.
- **Bug #25253** — author self-debunked (lockout arithmetic error).
- **Bug #32940** — root-caused to jemalloc heap corruption from rbpf JIT, not consensus.
- **Bug agave #579** — root-caused to ramdisk OOS, not consensus.
- **Bug #34062** — closed-stale, root cause never isolated, likely overlapped VoteStateUpdate→TowerSync transition.
- **Bug #11401** — fixed by `accounts_lt_hash` backport; consensus divergence trace was a runtime/sysvar issue, not Tower.
- **Bug #5454** — Testnet bank-hash divergence; root-caused to `RecentBlockhashes` sysvar field-source change (PR #5219), not Tower.
- **Bug #32889** — fixed-by-revert-then-reintroduce (#32957) — `VoteStateUpdate` epoch-credits issue, in vote-program execution, not Tower BFT.
- **Bug #24710** — fixed in v1.9.20 (#24948); accounts_delta hash discrepancy from a leader-build issue, not Tower BFT logic.

## Verification Method Summary

Every finding was verified by:
1. Re-reading exact line ranges via `Read`.
2. Cross-checking call sites via `grep -n`.
3. Tracing compensating mechanisms (see "Compensating mechanism" field in each subagent report).
4. Comparing against historical commit fixes when available.
5. Reading discussion threads of related issues via `gh issue view --comments`.

The full per-file findings (~50 individual items) are organized into the six Bug Families above and condensed into the Modeling Brief for handoff to Spec Generation.

## References

- Reference TLA+ specs for vote-lockout BFT: none in the existing case-study corpus; aptosbft / cometbft / autobahn are the closest analogues, but Tower BFT is structurally distinct (no QCs).
- Reference paper: "Tower BFT: Solana's High-Performance Implementation of PBFT" (Yakovenko, 2018, whitepaper); follow-up: Anza Alpenglow paper (Wadsworth, 2025).
- Mainnet history: Sep 14 2021 outage post-mortem (transaction-flood-triggered partition); Feb 25 2022 stall; Nov 3 2023 latency event (issue #34107).
- Key commits referenced: `985c0dcd`, `07f38838a`, `fb97e93fe`, `85cc6ace0`, `07955e79a`, `befe8b9d9`, `000ca4ce0`, `84a934a9f`, `207fb1d00`.
- Issues referenced: solana-labs/solana #5850, #23135, #23137, #25598, #20192, #8232, #7087, #34107, #34120, #6727, #7521, #8113, #34785, #35152, #28047, #34014, #34102, #33669, #29221, #16768, #2768. anza-xyz/agave #3542, #1174, #3314, #1172, #1646, #5454, #11401, #12307.

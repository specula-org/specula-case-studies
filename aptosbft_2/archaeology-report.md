# Aptos BFT Consensus Safety — Bug Archaeology Report

Repository: `aptos-labs/aptos-core` (HotStuff/Jolteon "AptosBFT" variant)
Investigation date: 2026-05-12
Source: GitHub `gh` queries against PRs and Issues; PR diffs and discussion verified via `gh pr view --comments` / `gh pr diff`

---

## 1. Coverage statistics

| Bucket | Count |
| --- | --- |
| Targeted `gh search` queries executed (PRs + issues) | 50+ |
| Distinct candidate PRs/issues surfaced | 90+ |
| Candidates deeply read (full description + diff or comments) | 35 |
| Confirmed safety- / safety-adjacent changes (Section 2) | 23 |
| Open/unresolved PRs / issues with safety intent (Section 5) | 4 |
| False positives or out-of-scope (Section 3) | 12 |

The "deeply read" set was selected by filtering on the consensus paths in the prompt (`consensus/safety-rules/`, `consensus/src/round_manager.rs`, `pending_votes.rs`, `pending_order_votes.rs`, `recovery_manager.rs`, `epoch_manager.rs`, `block_storage/`, `liveness/round_state.rs`, `consensus-types/src/`, `consensus/src/pipeline/`).

---

## 2. Confirmed safety-relevant PRs / issues

| # | One-line summary | Root cause | Files touched | Link | Classification |
| --- | --- | --- | --- | --- | --- |
| **PR #13711** | Add epoch check in `verify_order_vote_proposal` | Order-vote path was missing the epoch guard that `verify_proposal` already had — cross-epoch order-vote replay possible | `consensus/safety-rules/src/safety_rules.rs` (new `self.verify_epoch(...)` call) | https://github.com/aptos-labs/aptos-core/pull/13711 | **Confirmed** (order-vote vs vote asymmetry) |
| **commit f58e184471** ("[safety-rules] Add checks on timeout") | `sign_timeout` previously had only `// @TODO` and no checks at all — would sign any timeout, not even epoch-bound | Missing voting/last-voted-round/preferred-round/epoch checks before signing timeout, allowing equivocation on timeouts | `consensus/safety-rules/src/safety_rules.rs`, `error.rs`, tests | https://github.com/aptos-labs/aptos-core/commit/f58e184471 | **Confirmed** (equivocation path) |
| **PR #14637** | Sync up QC in order vote message | Order-vote receivers blindly trusted the QC carried in `OrderVoteMsg` and aggregated into `pending_order_votes` without first verifying / inserting the underlying QC; an aggregated order cert could thus be missing the QC it certifies | `consensus/consensus-types/src/wrapped_ledger_info.rs`, `consensus/src/pending_order_votes.rs`, `consensus/src/round_manager.rs`, counters | https://github.com/aptos-labs/aptos-core/pull/14637 | **Confirmed** (order-vote QC binding) |
| **PR #14129** | Optimize quorum cert verification (also splits `verify` into `verify_order_vote` + lazy QC verify) | `OrderVoteMsg::verify` re-verified the QC for every order vote; refactor moves QC verification to the new `new_qc_from_order_vote_msg` path and ensures `process_certificates` is called after insertion | `consensus/consensus-types/src/order_vote_msg.rs`, `consensus/src/round_manager.rs`, `consensus/src/block_storage/mod.rs` | https://github.com/aptos-labs/aptos-core/pull/14129 | **Confirmed** (related order-vote handling change; also added `process_certificates` after order-vote QC insertion) |
| **PR #13986** | Fix `InvalidOrderedLedgerInfo` after fast-forward sync | `safety_rules` rejected ordered LIs whose commit_info was not "ordered_only"; after fast-forward sync, the stored "root ordered cert" is set to the commit cert (no dummy `executed_state_id`), causing valid commits to fail safety check | `consensus/safety-rules/src/safety_rules.rs`, `consensus/src/pipeline/tests/signing_phase_tests.rs` | https://github.com/aptos-labs/aptos-core/pull/13986 | **Design defect** (recovery-vs-runtime invariant mismatch) |
| **PR #17766** | Fix race condition in `BlockStore::add_certs` (sync of HCC before HQC) | `sync_to_highest_commit_cert` ran before `sync_to_highest_quorum_cert`. Lower-round commit-proof could pause `pre_commit` and sync, then a subsequent commit-proof could resume `pre_commit` past target version | `consensus/src/block_storage/sync_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/17766 (cherry-picked to v1.36 #17772 and v1.37 #18065) | **Confirmed** (sync-info race) |
| **PR #12239** | Fix race condition with order of operations on epoch change | Epoch-change notification was sent before the commit task was spawned; `EpochManager` would shut down `BufferManager` before commit request was created — final commit task lost | `consensus/src/pipeline/buffer_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/12239 (#12251 / #12253 are the same fix) | **Confirmed** (pipeline race) |
| **PR #15746** | Move epoch notification to *after* commit (companion of #12239) | Same family: epoch-change `send_epoch_change` was called from `BufferManager` before `persisting_phase_request` was sent, so reset could lose the persist | `consensus/src/pipeline/buffer_manager.rs`, `consensus/src/pipeline/persisting_phase.rs`, `consensus/src/pipeline/decoupled_execution_utils.rs` | https://github.com/aptos-labs/aptos-core/pull/15746 | **Confirmed** (pipeline race, same family) |
| **PR #1826** | Fix missing QC when `highest_commit_cert` points to a dangling node | Fast-sync from peers could leave `highest_commit_cert` pointing to a fork branch whose block was not in the retrieval window; recovery would fail or worse, accept an inconsistent root | `consensus/src/block_storage/sync_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/1826 (cherry-pick #1851) | **Confirmed** (recovery / sync) |
| **PR #2990** | Cross-epoch leader election filter | `LeaderReputation` lookup used round-only comparisons when fetching `NewBlockEvent` history; with cross-epoch fetching enabled, a higher round in a previous epoch could be returned, yielding wrong proposer | `consensus/src/liveness/leader_reputation.rs`, leader_reputation_test | https://github.com/aptos-labs/aptos-core/pull/2990 (cherry-pick #2994) | **Confirmed** (cross-epoch replay style) |
| **PR #4232** | Block-store race conditions (prune-during-rebuild) | `BlockStore::rebuild` called `storage.prune_tree(get_all_block_id())` before `*self.inner.write() = inner` — pruning could remove blocks that the new tree still referenced, since old and new trees can overlap | `consensus/src/block_storage/block_store.rs`, `block_tree.rs` | https://github.com/aptos-labs/aptos-core/pull/4232 | **Confirmed** (block-storage race) |
| **PR #4445** | Block-retrieval edge case (`need_sync_for_ledger_info` underwhelming) | The "need sync" condition relied solely on a back-pressure round delta; if a peer pruned blocks in between, a local node could *never* sync the gap. Fixed to also require the LI's block to actually exist locally | `consensus/src/block_storage/sync_manager.rs`, `block_store_test.rs` | https://github.com/aptos-labs/aptos-core/pull/4445 | **Confirmed** (sync-info handling) |
| **PR #13864** | Block-retrieval edge case (self-retrieval timeout) | `BlockRetriever`'s "self" branch awaited a `oneshot::Receiver` with no timeout; if the local handler was wedged, the retrieval future hung indefinitely | `consensus/src/block_storage/sync_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/13864 (cherry-pick #13903) | **Confirmed** (recovery liveness; consequence is sync stall) |
| **PR #13605** | Fix `VerifyError { inner: Vote Round should be higher than SyncInfo }` | `RoundManager::new_ordered_cert` inserted QC for round `r` *but did not call* `process_certificates` to advance the round number; subsequent vote on round `r` looked stale to peers | `consensus/src/round_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/13605 | **Confirmed** (state-divergence between round_state and block_store) |
| **PR #9879** / **#9891** | Re-broadcast condition inverted | The condition for re-broadcasting commit votes was `<` instead of `>=`, so commit votes were re-broadcast immediately and never after the intended interval | `consensus/src/experimental/buffer_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/9879 | **Confirmed** (commit-vote re-broadcast bug) |
| **PR #15452** | OptQS bug fixes — including "Ignore stale proposals due to fetch lag" | If validator fetched payload in critical path of a proposal vote and other validators had already advanced (with an updated `SyncInfo`), the validator could vote on a round that was already past, producing votes whose round equaled the QC round in `SyncInfo` and failing peer verification | `consensus/src/round_manager.rs`, OptQS code paths | https://github.com/aptos-labs/aptos-core/pull/15452 | **Confirmed** (round/sync-info handling) |
| **PR #15361** | Move `payload_manager.notify_commit` to after commit | QS could GC batches before they were actually committed because `notify_commit` was called too early in pipeline | `consensus/src/payload_manager*.rs`, `consensus/src/pipeline/buffer_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/15361 | **Confirmed** (pipeline ordering of side-effects, safety-adjacent) |
| **PR #18023** | Buffer-manager: ack commit-vote when round equals `highest_committed_round` | A vote whose round matched the highest committed round was being NACKed, causing the sender to retry forever and log spam; pure ingress fix but in the safety-relevant commit-vote path | `consensus/src/pipeline/buffer_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/18023 | **Confirmed** (commit-vote acceptance asymmetry) |
| **PR #14570** | Cache commit votes for future rounds in BufferManager | Commit votes received before the corresponding block hit BufferManager were silently dropped → stale votes had to be re-collected, slowing commits | `consensus/src/pipeline/buffer_manager.rs`, BufferItem | https://github.com/aptos-labs/aptos-core/pull/14570 | **Confirmed** (sync-info handling, edge case in commit-vote acceptance) |
| **PR #14482** | `BufferManager::pending_commit_proofs` — handle LI before block accepted under back-pressure | Buffer manager could receive a commit proof for a round that hadn't yet been accepted into the buffer (back-pressure delay), and the commit proof was lost | `consensus/src/pipeline/buffer_manager.rs` | https://github.com/aptos-labs/aptos-core/pull/14482 | **Confirmed** (sync-info handling) |
| **PR #18970** | Enforce sender-author binding for `RandShare`/`FastShare` messages | A malicious validator could forge a `RandShare` with a victim's `author` field, bypassing optimistic verification and overwriting the victim's self-share in `ShareAggregator` | `consensus/src/rand/rand_gen/types.rs`, `network_messages.rs`, `rand_manager.rs`, tests | https://github.com/aptos-labs/aptos-core/pull/18970 | **Confirmed** (randomness-pipeline equivocation; safety of randomness aggregation) |
| **PR #19142** | Chunky DKG equivocation bug (signature requests omit per-dealer transcript hash) | Responders detected only *missing* transcripts, not *differing* ones; certification could get stuck on equivocating dealer | `aptos-dkg-runtime/src/chunky/*.rs` | https://github.com/aptos-labs/aptos-core/pull/19142 | **Confirmed** (DKG equivocation; tangential to BFT safety, but in same trust model) |
| **PR #19359** | Rand-manager deadlock in multi-block batches (circular `has_rand_txns_fut` ↔ `execute_fut` ↔ `wait_for_rand` ↔ `rand_tx`) | `set_randomness` only called `rand_tx` after the entire batch flowed through `execution_schedule_phase`, but later blocks' `has_rand_txns_fut` waited for earlier blocks' `execute_fut` — circular wait | `consensus/src/pipeline/*` | https://github.com/aptos-labs/aptos-core/pull/19359 (cherry-picks #19381, #19361) | **Confirmed** (pipeline race / liveness) |
| **PR #19084** | Module-cache deadlock on pipeline teardown (`HotStateView` retained after abort) | `PipelineBuilder` held a `module_cache` retaining an `Arc<dyn HotStateView>`; on abort/teardown the stale view kept `Weak` strong-count > 0, blocking `try_merge`, filling the commit channel, blocking state-sync — circular deadlock | `consensus/src/pipeline/pipeline_builder.rs` | https://github.com/aptos-labs/aptos-core/pull/19084 (cherry-picked to v1.42, v1.43) | **Confirmed** (pipeline-vs-storage deadlock) |
| **Issue #18298** | "Non-atomic SafetyData persistence enables double-voting after crash recovery" — sign happens before `set_safety_data` in `guarded_construct_and_sign_vote_two_chain` (lines 88, 92 of `safety_rules_2chain.rs`) | Reporter argues the order is `let signature = self.sign(...)` THEN `set_safety_data`; if the network already saw the vote before persistence completes, a crash-restart could allow voting again on a conflicting proposal in the same round | `consensus/safety-rules/src/safety_rules_2chain.rs` lines 53-95 | https://github.com/aptos-labs/aptos-core/issues/18298 | **Disputed** by danielxiangzl ("the vote is persisted before being sent to the network"). The disputed claim hinges on whether the `Vote` returned to the caller is broadcast *only after* `set_safety_data` returns — see Notes below. |

### Notes on Issue #18298 (disputed safety claim)

Looking at `consensus/safety-rules/src/safety_rules_2chain.rs:53-95` in the local snapshot:

```rust
let signature = self.sign(&ledger_info)?;          // line 88
let vote = Vote::new_with_signature(...);          // line 89
safety_data.last_vote = Some(vote.clone());        // line 91
self.persistent_storage.set_safety_data(safety_data)?; // line 92
Ok(vote)                                            // line 94
```

`sign` itself only computes the BLS signature — it does *not* publish the vote. The vote is returned to the caller via `Ok(vote)` only after `set_safety_data` succeeds. So provided the *caller* in `round_manager.rs` does not use the unwrapped value before `?` propagates the error from `set_safety_data`, the developer's defense is correct: a crashed `set_safety_data` call returns `Err`, so the caller never sees the vote.

The residual concern (and it is a legitimate one to track) is that **set_safety_data only writes to persistent storage *if* the underlying backend's `set` is synchronous-durable**. If the backend caches and returns before fsync, then a crash *could* drop the persisted value; and on restart the in-memory `last_vote = None` plus reverted `last_voted_round` would allow voting on a conflicting proposal. The `f58e184471` historical commit explicitly mentions deterministic-sig as the mitigation for the *timeout* path equivocation; vote-path equivocation has no analogous "deterministic signing on same input" defense because the input differs across conflicting proposals. **Classification: Disputed; possibly real depending on storage backend semantics.** Worth carrying as Bug Family 1 evidence.

---

## 3. False positives / explicitly excluded

| # | Why excluded |
| --- | --- |
| PR #18841, #18793, #18686, #18491, #17656, etc. (governance "voting boundary") | These are *on-chain Move governance voting* boundary fixes (in `aptos-framework/aptos_governance.move`), not BFT consensus voting. Out of scope per prompt. |
| PR #13023 ("Implement Order Vote feature") | Feature implementation, not a bug fix. Establishes the order-vote mechanism that PRs #13711, #14129, #14637, #13605, #14570, #18023 later corrected. Listed because order-vote bugs cluster around it. |
| PR #14346 ("fallback heuristics for optimistic quorum store") | Liveness heuristics tuning; safety unchanged. |
| PR #16850 ("[pipeline] default to use pipeline and cleanup all old code") | Refactor / dead-code removal. No safety logic change. |
| PR #16327 ("per key jwk consensus 5: per-key logic") | Independent JWK consensus, not BFT consensus safety. |
| PR #19613 ("INVALID — drop pipeline senders on abort") | **Self-marked INVALID** by author after they realized the deadlock did not exist; root cause was rayon work-stealing wedge in BlockSTM (#19619). Listed as case study of a falsified hypothesis but explicitly NOT a real bug. |
| PR #19450 ("Set block timestamp after payload pull") | CLOSED; pure metric/timestamp accuracy improvement, no consensus safety. |
| PR #19174 ("Add configurable extra-vote wait before proposing") | CLOSED; latency-tuning experiment, not a bug fix. |
| PR #19323 ("Add separate failure window for leader reputation") | CLOSED; leader-rep tuning. |
| PR #18280 ("Prevent from empty validator set") | On-chain stake module fix; affects consensus liveness via empty validator set, not BFT safety rules. Borderline; included here because the safety-rules code is unaffected. |
| PR #18834 ("Fix WVUF batch verification off-by-one") | Randomness pipeline DoS / soundness, but the off-by-one only causes unnecessary fallback to per-share verify; not a safety violation in BFT vote sense. |
| PR #18646 ("Add optimistic randomness share verification") | Performance optimization for randomness verification. Soundness retained. |
| PR #19063 ("Fix consensus observer encrypted transaction support") | Consensus observer (read-only role) data-flow fix; observer cannot affect BFT safety. |
| PR #19315 ("Fix SecretShareMsg RPC silently dropped") | RPC dispatch wildcard arm; not safety-rules. |
| PR #19475 ("Harden SecretShare ingress validation against DoS") | DoS hardening (panic on out-of-bounds player id). Liveness/availability, not BFT vote safety. |
| PR #2990 (already counted under Confirmed — note that several Move-prover and reference-safety PRs that mention "safety" are unrelated to BFT) | — |
| PRs `[compiler] Add reference safety...`, `[move-prover]`, etc. | "Safety" in the title refers to Move type-safety / reference-safety, not BFT. |

---

## 4. Bug Family groupings

Eight families. Each lists the mechanism and the historical evidence in this codebase.

### Family 1 — Crash-window double-vote (sign-then-persist)
**Mechanism:** `guarded_construct_and_sign_vote_two_chain` signs the vote (line 88) before persisting `safety_data.last_vote` (line 92). If the persistence is non-durable when it returns (or if a future refactor leaks the unpersisted vote to the network), a crash-restart could revert `last_voted_round` and `last_vote`, enabling vote on a conflicting proposal in the same round.
- Issue **#18298** — explicitly reports this and includes two demonstrating tests; disputed by maintainer.
- Historical analog: commit **f58e184471** addresses the equivalent for `sign_timeout`, choosing deterministic signatures so that re-signing the same `(epoch, round)` is benign. There is no analogous mitigation on the vote path (vote payload differs across conflicting proposals, so deterministic signing does not save you).
- **Affected paths:** `consensus/safety-rules/src/safety_rules_2chain.rs` lines 53-95; `consensus/safety-rules/src/persistent_safety_storage.rs::set_safety_data`.

### Family 2 — Order-vote vs regular-vote guard asymmetry
**Mechanism:** Order vote was added later (PR #13023). The original safety checks for regular vote (in `verify_proposal`) were not initially mirrored in the order-vote path (`verify_order_vote_proposal`).
- **PR #13711** — added missing `verify_epoch` check in `verify_order_vote_proposal`.
- **PR #14129** — re-arranged QC verification: `OrderVoteMsg::verify` no longer verifies the QC (separated into `verify_order_vote`); QC verification now happens in `new_qc_from_order_vote_msg` together with `process_certificates`.
- **PR #14637** — order-vote message receivers now insert the QC into `pending_order_votes` storage so the aggregated order cert is bound to the corresponding QC; previously the QC could be cached without verification.
- **PR #13605** — `RoundManager::new_ordered_cert` inserted the QC but did not call `process_certificates` to advance the round; subsequent vote on round `r` looked stale to peers.
- **Affected paths:** `consensus/safety-rules/src/safety_rules.rs` (`verify_order_vote_proposal`, `verify_proposal`); `consensus/src/round_manager.rs::process_order_vote_msg`, `new_ordered_cert`, `new_qc_from_order_vote_msg`; `consensus/src/pending_order_votes.rs`; `consensus/consensus-types/src/order_vote*.rs`.

### Family 3 — Cross-epoch / cross-instance handling
**Mechanism:** Logic that compares only round numbers (or only block ids) without including epoch can match across an epoch boundary. The order-vote epoch check (#13711) is one example; the leader reputation cross-epoch fetch (#2990) is another.
- **PR #2990** — `LeaderReputation::get_block_metadata` was round-only; switched to `(epoch, round)` after `get_block_metadata` started returning cross-epoch history.
- **PR #13711** — order-vote epoch check, now also rejects cross-epoch order votes.
- **PR #12018** — `EpochManager::process_rpc_request` added explicit `match request.epoch()` dispatch; before that, RPC requests were processed regardless of epoch.
- **Affected paths:** `consensus/src/epoch_manager.rs`, `consensus/src/liveness/leader_reputation.rs`, `consensus/safety-rules/src/safety_rules.rs::verify_epoch`.

### Family 4 — Pipeline race / out-of-order side effects
**Mechanism:** The decoupled execution pipeline (`Order → BufferManager → Sign → Persist`) has multiple async tasks. Sending an end-of-epoch notification too early, persisting commit-proof too late, or letting the buffer manager reset before the persisting request was created — all cause silently lost commits or premature shutdown.
- **PR #12239** — fix order of ops: send persisting request BEFORE `send_epoch_change` in `BufferManager` (otherwise reset loses the commit task).
- **PR #15746** — companion: move `send_epoch_change` to `PersistingPhase` *after* the actual commit, so the network is only told about epoch change once the commit is durable.
- **PR #17766** — `BlockStore::add_certs` reordered: sync HQC first, then HCC; previously a lower-round commit-proof could pause `pre_commit` and a later commit-proof could resume it past target version.
- **PR #19359** — circular wait between rand-manager batch dequeue and per-block `has_rand_txns_fut`; fix sends `rand_tx` immediately when randomness is decided per-block.
- **PR #19084** — module-cache held `HotStateView` after abort, blocking `try_merge` → fills commit channel → blocks state-sync → new `PipelineBuilder` is only created after state-sync → deadlock.
- **PR #4232** — `BlockStore::rebuild` pruned the old tree before swapping in the new tree; if old and new trees overlap, blocks in the new tree were lost.
- **Affected paths:** `consensus/src/pipeline/buffer_manager.rs`, `consensus/src/pipeline/persisting_phase.rs`, `consensus/src/pipeline/pipeline_builder.rs`, `consensus/src/block_storage/sync_manager.rs`, `consensus/src/block_storage/block_store.rs`.

### Family 5 — Sync-info / commit-vote acceptance handling
**Mechanism:** `BufferManager` and `BlockStore` need to handle commit-votes / commit-proofs for rounds that haven't arrived yet, or rounds already committed, or rounds for which the corresponding block is still being fetched.
- **PR #14570** — cache commit votes received for future rounds (previously dropped).
- **PR #14482** — `pending_commit_proofs` for LI received before the round is accepted into the buffer (back-pressure case).
- **PR #18023** — ack commit-vote when round equals `highest_committed_round` (previously NACK + log spam).
- **PR #4445** — `need_sync_for_ledger_info` now requires the block to actually exist locally (previously round-delta only, which could leave a node unable to sync if peers had pruned).
- **Affected paths:** `consensus/src/pipeline/buffer_manager.rs`, `consensus/src/block_storage/sync_manager.rs::need_sync_for_ledger_info`, `consensus/src/pipeline/buffer_item.rs`.

### Family 6 — Recovery / sync state divergence
**Mechanism:** After fast-forward sync or on restart, the in-memory state seen by `RecoveryManager` / `SafetyRules` can disagree with what `RoundManager` expects.
- **PR #13986** — fast-sync stores commit-cert in place of the (missing) ordered-cert root, causing `safety_rules` to reject signing because the LI no longer has a "dummy" `executed_state_id`. Fix: relax the check when ordered LI matches the commit LI.
- **PR #1826** — fast-sync from peers could leave `highest_commit_cert` pointing to a fork branch whose block was not in the retrieval window; recovery would fail or accept inconsistent root.
- **PR #4475** — recovery mode if `consensusdb` is gone (background context, not strictly a bug fix).
- **PR #13864** — self-retrieval blocking forever if the local channel was wedged; added timeout.
- **Affected paths:** `consensus/safety-rules/src/safety_rules.rs::guarded_sign_commit_vote`, `consensus/src/block_storage/sync_manager.rs`, `consensus/src/recovery_manager.rs`.

### Family 7 — Optimistic / out-of-band proposal handling
**Mechanism:** OptQS, OptProposal, "extra wait before proposing", and the order-vote fast path are all extra paths that bypass the normal `verify_proposal → safety_rules → vote` flow. Each adds a place to forget a check.
- **PR #15452** — OptQS: ignore stale proposals due to fetch lag; previously a validator that fetched payload in critical path could vote with a `SyncInfo` whose QC round equaled the vote round, failing peer verification.
- **PR #16126** — opt-proposal initial implementation (background; gated by config).
- **PR #18111 / #18112** — opt-proposal cache support for retrievals.
- **Affected paths:** `consensus/src/round_manager.rs`, `consensus/src/proposal_generator.rs`, OptQS / opt-proposal code.

### Family 8 — Randomness-pipeline equivocation / authentication
**Mechanism:** The randomness aggregation path is a separate signing path orthogonal to the BFT vote path; it has its own equivocation surface (forged shares, equivocating dealers).
- **PR #18970** — sender-author binding for `RandShare`/`FastShare`; previously a malicious validator could forge a share with a victim's `author` field.
- **PR #19142** — chunky DKG equivocation bug: per-dealer transcript hashes added to signature requests so responders can detect *differing* (not just *missing*) transcripts.
- **Affected paths:** `consensus/src/rand/rand_gen/{types.rs, network_messages.rs, rand_manager.rs}`, `aptos-dkg-runtime/src/chunky/*.rs`.

---

## 5. Open / unresolved

| # | Title | Opened | Status | Notes |
| --- | --- | --- | --- | --- |
| Issue **#18298** | Non-atomic SafetyData persistence enables double-voting after crash recovery | 2025-12-17 (open ~5 mo, closed without merge) | CLOSED, **Disputed**, no PR fix | Reporter is community researcher with a PoC test; maintainer (`danielxiangzl`) replied "the vote is persisted before being sent to the network." Persistence backend semantics determine whether the dispute is closed; no code patch landed. Worth re-examining via TLA+ to enumerate the crash-window. |
| PR **#19684** | jwk-consensus: document epoch-replay residual risk in signed payload | 2026-05-07 (open ~5 days as of 2026-05-12) | OPEN, doc-only | The `ProviderJWKs` payload signed for JWK consensus does not include the producing epoch; cached partial signatures can be replayed across epochs if validator-set/consensus-pubkeys unchanged. Author proposes signing `(epoch, payload)` as the proper fix; this PR only adds TODO comments. |
| PR **#19673** | tighten `BatchProofQueue` ingress checks | 2026-05-07 | OPEN | Add invariants at QS proof-queue ingress to keep per-author state internally consistent. Hardening, not a fix to a known bug. |
| PR **#19444** | Add test for non-proposer connections | 2026-04-14 | DRAFT | Test-only; targets a class of network-isolation failure modes that may expose consensus liveness bugs. |

---

## 6. Methodology

- All `gh search prs --repo aptos-labs/aptos-core ...` queries listed in the prompt were executed (each returned 0 to ~50 hits); additional targeted queries on terms `last_voted_round`, `pending_votes`, `recovery_manager`, `epoch_manager`, `block_storage`, `round_state`, `quorum_cert`, `safety_data`, `consensus equivocation`, `process_vote`, `highest_quorum_cert`, `vote rules`, `verify_epoch`, `verify_proposal`, `process_certified_block`, `consensus halted`, `consensus stuck`, `vote msg`, `consensus epoch`, `qc consensus`, `TC consensus`, `two-chain`, `sync_info`, `timeout_2chain`, `rand_share`, `RoundTimeout`, `qs verify` — all run in parallel batches.
- For each candidate PR/issue: `gh pr view <num>`, then `gh pr diff <num>`, plus `gh pr view <num> --comments` when the description was empty or terse.
- Specific in-prompt anchors were verified directly:
  - **PR #13711**: confirmed it adds `self.verify_epoch(...)` to `verify_order_vote_proposal` (also flips `&self` to `&mut self`).
  - **commit f58e184471**: confirmed via `gh api repos/aptos-labs/aptos-core/commits/f58e184471` that it adds `BadTimeoutLastVotedRound`, `BadTimeoutPreferredRound`, `IncorrectEpoch` errors and the corresponding checks in `sign_timeout`. Author: davidiw, 2020-04-11.
- `Issue #18298`'s claim was cross-checked against the local snapshot of `safety_rules_2chain.rs` lines 53-95; the reported sign-then-persist order is in fact present in the current code, but its impact depends on storage durability and whether `Ok(vote)` reaches the network broadcast before `set_safety_data` returns.

---

## 7. File:line evidence index

Files where the confirmed bugs originated / were fixed (paths relative to repo root, all under `consensus/`):

- `consensus/safety-rules/src/safety_rules.rs` — `verify_proposal`, `verify_order_vote_proposal`, `verify_epoch`, `guarded_sign_commit_vote` (PRs #13711, #13986, original epoch check)
- `consensus/safety-rules/src/safety_rules_2chain.rs` lines 53-95 — `guarded_construct_and_sign_vote_two_chain` (Issue #18298)
- `consensus/safety-rules/src/safety_rules_2chain.rs` lines 19-51 — `guarded_sign_timeout_with_qc` (commit f58e184471 origin)
- `consensus/src/round_manager.rs` — `process_order_vote_msg`, `new_ordered_cert`, `new_qc_from_order_vote_msg`, `process_certificates` (PRs #13605, #14129, #14637, #15452)
- `consensus/src/pending_order_votes.rs` — `insert_order_vote` carrying QC (PR #14637)
- `consensus/src/pipeline/buffer_manager.rs` — `send_epoch_change` ordering, commit-vote caching, NACK-on-equal-round (PRs #12239, #14570, #14482, #15746, #18023)
- `consensus/src/pipeline/persisting_phase.rs` — epoch-change after commit (PR #15746)
- `consensus/src/pipeline/pipeline_builder.rs` — module cache teardown (PR #19084), `set_randomness` immediate `rand_tx` (PR #19359)
- `consensus/src/block_storage/sync_manager.rs` — `add_certs` order, `need_sync_for_ledger_info`, dangling commit-cert fork retrieval (PRs #1826, #4445, #13864, #17766)
- `consensus/src/block_storage/block_store.rs` — `rebuild` pruning order (PR #4232)
- `consensus/src/epoch_manager.rs` — RPC epoch dispatch (PR #12018)
- `consensus/src/liveness/leader_reputation.rs` — `(epoch, round)` comparison (PR #2990)
- `consensus/src/rand/rand_gen/{types.rs, network_messages.rs, rand_manager.rs}` — sender-author binding (PR #18970)

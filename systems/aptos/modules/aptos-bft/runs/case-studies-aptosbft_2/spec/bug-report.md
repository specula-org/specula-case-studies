# Bug Report — Aptos BFT (HotStuff / Jolteon), Round 2

## Summary

- Bug families tested: 5
- Bugs found: 3 confirmed (Families 1 and 3); Families 2/4/5 BFS still in flight at report time — see "Not Reproduced" table for current status.
- Configs run: `MC.cfg`, `MC_hunt_family1.cfg`, `MC_hunt_family1_nodoublevote.cfg` (variant), `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg`, `MC_hunt_family4.cfg`, `MC_hunt_family5.cfg`

The spec converged in one round (no trace failures across 4 traces; no invariant violations in the convergence `MC.cfg` 30-minute BFS at depth 14 with 277M distinct states explored, with bug-family invariants disabled per `MC.cfg`'s default).

Bug hunting was then run against each family-specific config. The three confirmed counterexamples below correspond exactly to MC-1, MC-1 (timeout-relevant), and MC-5 in the modeling brief.

Implementation references throughout point into `aptos-core/consensus/`; the version captured by Round 2 spec generation.

---

## Bug 1 — Sign-before-persist creates an immediate `RecoverPreservesLastVote` gap (Family 1, MC-1 enabler)

- **Bug Family**: 1 (crash-window double vote)
- **Severity**: High (the *enabler* of Bug 2; a single state already breaks the safety invariant)
- **Invariant violated**: `RecoverPreservesLastVote`
- **Config**: `MC_hunt_family1.cfg`
- **Counterexample**: 3 states (`output/MC_hunt_family1_bfs_recoverpreserveslastvote.out`)

### Trace Summary

1. **Initial** — all SafetyData fields = 0; no in-flight signed vote.
2. **`MCPropose(s1, v1)`** — s1 (the leader) proposes v1 at round 1.
3. **`MCSignVote(s1)`** — s1 signs the vote for v1. After this step:
   - `emittedVote[s1][1] = {v1}` (vote is on the wire),
   - `inflightSignedVote[s1] = {round: 1, value: v1, epoch: 1}` (returned by SafetyRules but not yet persisted),
   - `volatileSafetyData[s1].lastVotedRound = 1`,
   - **`persistedSafetyData[s1].lastVotedRound = 0`** — still 0.

`RecoverPreservesLastVote` requires that any honest validator that has emitted a vote at round r must have `persistedSafetyData.lastVotedRound >= r`. After SignVote but before `set_safety_data`, the implementation violates this exactly — there is a window where a crash would lose the round-tracking even though the vote is already on the network.

### Root Cause

`safety_rules_2chain.rs:88` (`self.sign(&ledger_info)?`) returns the signed bytes (and the round_manager broadcasts the `VoteMsg`) **before** `safety_rules_2chain.rs:92` (`self.persistent_storage.set_safety_data(safety_data.clone())?`) durably persists the new `last_voted_round`. The window between these two lines is the exact state TLC found at step 3.

The timeout path is ordered the other way (`safety_rules_2chain.rs:47` persists, then `:49` signs), which is the canonical fix; commit `f58e184471` was the timeout-side analog repair.

### Affected Code

- `consensus/safety-rules/src/safety_rules_2chain.rs:88-92` — `guarded_construct_and_sign_vote_two_chain` signs before persisting.
- `consensus/safety-rules/src/safety_rules_2chain.rs:115-117` — `guarded_construct_and_sign_order_vote` has the same pattern.
- `secure/storage/src/on_disk.rs:64-70` — `OnDiskStorage::write` performs `rename` with no `fsync` / `sync_all`, so even when `set_safety_data` returns Ok the durability is not guaranteed against power loss.

### Recommendation

Swap the order of `self.sign(...)` and `self.persistent_storage.set_safety_data(...)` in both `guarded_construct_and_sign_vote_two_chain` and `guarded_construct_and_sign_order_vote`, so the persistent state is durable before the signed bytes are returned. This brings the regular-vote and order-vote paths in line with the (correct) timeout path. Additionally, add `sync_all` / directory `fsync` in `OnDiskStorage::write` (T-1 in the modeling brief).

This issue is filed in production as **Issue #18298** with a maintainer dispute; the dispute is contingent on the SafetyRules backend's `set` being synchronously durable, which is not guaranteed by the current `OnDiskStorage`.

---

## Bug 2 — Byzantine equivocating proposer + crash-window produces double-vote at the same round (Family 1, MC-1)

- **Bug Family**: 1 (crash-window double vote with Byzantine equivocating proposer)
- **Severity**: Critical (breaks BFT safety — a single honest validator emits two distinct votes at the same round)
- **Invariant violated**: `NoDoubleVote`
- **Config**: `MC_hunt_family1_nodoublevote.cfg` (variant of `MC_hunt_family1.cfg` with `RecoverPreservesLastVote` removed so TLC keeps searching past Bug 1)
- **Counterexample**: 8 states (`output/MC_hunt_family1_nodoublevote_bfs.out`)

### Trace Summary

1. **Initial** — fresh state, 4 validators; s4 ∈ Faulty.
2. **`MCByzEquivocateProposer(s4, 1, v2, v1)`** — Byzantine s4 broadcasts two conflicting proposals (v2 and v1) at round 1.
3. **MCNext (`MCReceiveProposal(s1, ...)`)** — s1 ingests one of the two proposals (v1 first), so `proposals[s1][1] = v1`.
4. **`MCSignVote(s1)`** — s1 signs a regular vote for v1:
   - `emittedVote[s1][1] = {v1}`,
   - `volatileSafetyData[s1].lastVotedRound = 1`,
   - `inflightSignedVote[s1].value = v1`,
   - **`persistedSafetyData[s1].lastVotedRound = 0`** (not yet persisted — the Family 1 window).
5. **MCNext (`MCReceiveProposal(s1, ...)`)** — s1 ingests the **other** Byzantine proposal v2: `proposals[s1][1] = v2`.
6. **`MCCrash(s1)`** — s1 crashes before `set_safety_data` lands. `inflightSignedVote[s1]` is wiped; `volatileSafetyData[s1]` is rolled back to `persistedSafetyData[s1]`, so `lastVotedRound` is now back to 0.
7. **`MCRecover(s1)`** — s1 reboots. `volatileSafetyData[s1]` ← `persistedSafetyData[s1]` (lastVotedRound = 0).
8. **`MCSignVote(s1)`** — s1 re-enters `guarded_construct_and_sign_vote_two_chain` for the *new* proposal value v2 at round 1. The `r > sd.lastVotedRound` check passes (1 > 0). It signs again:
   - `emittedVote[s1][1] = {v1, v2}` — **two distinct values voted at the same round by the same honest validator.**

This is exactly MC-1 in the modeling brief. The Byzantine half (equivocating proposer) and the persistence-ordering half (sign-before-persist) compose into a real double-vote that breaks BFT safety.

### Root Cause

The same persistence ordering as Bug 1 (`safety_rules_2chain.rs:88` signs before `:92` persists). The additional requirement is a Byzantine equivocating proposer — the implementation has no mechanism to prevent a Byzantine leader from broadcasting two distinct `ProposalMsg` values at the same round (`is_valid_proposer` only checks the proposer identity, not message uniqueness).

When honest s1 receives both, only the latest is held in `proposals[s1][1]` because `process_proposal`'s spec-modeled behavior is "overwrite the local view." After crash/recover, the new value is what re-enters the safety check, and the persisted `last_voted_round` (still 0) lets it through.

### Affected Code

- `consensus/safety-rules/src/safety_rules_2chain.rs:53-95` — `guarded_construct_and_sign_vote_two_chain` (sign-before-persist).
- `consensus/safety-rules/src/safety_rules_2chain.rs:77-80` — `verify_and_update_last_vote_round` reads stale `last_voted_round` after recovery.
- `consensus/src/round_manager.rs:1127-1307` — `process_proposal` accepts multiple proposals at the same round if `currentRound[s]` has not advanced.
- `consensus/safety-rules/src/persistent_safety_storage.rs:150-170` — `set_safety_data` plus cache clear-on-error.

### Recommendation

The minimal fix is identical to Bug 1: persist `safety_data` before returning the signed vote. This single fix neutralizes the Byzantine-leader composition partner entirely — after recovery the persisted `last_voted_round` already equals r, and the second `SignVote` is rejected at `safety_rules.rs:218-225`.

A defense-in-depth complement: have the round_manager re-validate `process_proposal` against the persisted `last_voted_round` rather than the volatile one when a fresh proposal arrives at the same round, so a recovered node refuses to be "fast-forwarded" past its own pre-crash vote even if the persisted state is somehow rolled back.

This is the Byzantine-proposer half of MC-4 from the **prior** round of analysis on this codebase, which the prior round explicitly listed as unmodelled.

---

## Bug 3 — `sign_commit_vote` accepts a commit vote with the wrong epoch (Family 3, MC-5)

- **Bug Family**: 3 (certificate / message value-binding gaps)
- **Severity**: High (lets a node sign a commit attestation that doesn't match its own epoch; downstream safety / liveness implications when composed with cross-epoch reorgs)
- **Invariant violated**: `CommitEpochBound`
- **Config**: `MC_hunt_family3.cfg`
- **Counterexample**: 12 states (`output/MC_hunt_family3_bfs.out`)

### Trace Summary

1. **Initial** — all SafetyData fields = 0; all `persistedSafetyData[s].epoch = 1`.
2. **`MCPropose(s1, v1)`** — s1 proposes v1 at round 1.
3-4. **MCNext (×2)** — Receivers (s1, s2, s3) ingest the proposal.
5-6. **`MCSignVote(s1)`, `MCSignVote(s2)`** — Two honest validators sign votes.
7-8. **MCNext (×2)** — Votes propagate.
9. **`MCSignVote(s3)`** — Third honest vote; `votesForBlock[s3][1] = {s1, s2, s3}` → quorum.
10. **`MCFormQC(s3, 1)`** — s3 forms QC at round 1; `pipelinePhase[s3][1] = Ordered`.
11. **`MCExecuteBlock(s3, 1)`** — pipeline advances to `Executed`.
12. **`MCSignCommitVote(s3, 1, 2)`** — s3 signs a *commit vote* claiming epoch=2, even though `persistedSafetyData[s3].epoch = 1`. The action's precondition is `e \in 1..MaxEpoch` (i.e. any in-range epoch); there is no `verify_epoch` against `safety_data.epoch`.

Final state:
- `emittedCommitVote[s3][1] = { {value: v1, epoch: 2} }`
- `persistedSafetyData[s3].epoch = 1`
- `cv.epoch (2) /= persistedSafetyData[s3].epoch (1)` → `CommitEpochBound` violated.

### Root Cause

`safety_rules.rs:372-418` (`guarded_sign_commit_vote`) has two open `// TODO`s at `:412-413` for the unhappy-path guards and the extension check. The current code only verifies the aggregate signature threshold (`match_ordered_only` modelled in the spec as "an OC or QC exists at round r"). It does **not** call `verify_epoch(new_li.epoch(), &safety_data)`, so an attacker can convince a node to sign a commit vote with an arbitrary `new_ledger_info.epoch` value as long as some quorum proof exists at that round.

### Affected Code

- `consensus/safety-rules/src/safety_rules.rs:372-418` — `guarded_sign_commit_vote`; both TODOs explicit in source.
- `consensus/safety-rules/src/safety_rules.rs:412-413` — TODO comments.
- `consensus/consensus-types/src/wrapped_ledger_info.rs:90-108` — `WrappedLedgerInfo::verify` does not bind `vote_data` either, which is the same family of defect (verifier omissions on value-binding helpers).

### Recommendation

Add `verify_epoch(new_ledger_info.epoch(), &safety_data)?` at the head of `guarded_sign_commit_vote` (mirroring the regular-vote path at `safety_rules.rs:204-210`). Also address TODOs at `:412-413` to add `last_committed_round` dedup and the explicit extension check against the previously-signed ordered_only ledger info.

---

## Bug 4 — TBD (Family 2)

Family 2 BFS is in flight at report time. See "Not Reproduced" table for current depth and state counts.

The hypothesised mechanism (MC-2 in the modeling brief): an honest validator regular-votes at round R with `proposals[s][R] = v1`; the same validator subsequently overwrites `proposals[s][R] = v2` (via a second `ReceiveProposal` for a Byzantine-equivocating proposer's other proposal) and then signs an `OrderVote` for v2 at R, because `safe_for_order_vote` only checks `r > highest_timeout_round` and does not consult `last_voted_round`. This would violate `NoCrossPathSign`. Family 2's other invariant target `OrderVoteAggregatorDedup` (MC-3) requires two distinct (round, digest) quorums sharing >=1 honest signer, which depends on the spec's per-honest-validator order-vote overwrite path.

Both targets are structurally reachable in the spec (no explicit guard prevents them); the limiting factor is BFS depth within the 30-minute budget given the n=4 validator state space.

---

## Bug 5 — TBD (Family 4)

Family 4 BFS is in flight at report time. The hypothesised mechanism (MC-6): a Byzantine relayer replays a real OrderVote from epoch N as an `OrderVoteMsg` in epoch N+1, with the inner QC's `certified_block().epoch()` still pointing at N. The receiver's `verify_order_vote` does not bind these (`order_vote_msg.rs:47-67`). The spec's `ReceiveOrderVoteWeakEpoch` action models this RX-side gap.

The path requires two ByzCrossEpochReplays plus a ReceiveOrderVoteWeakEpoch (because the first replay's single-multiplicity message is `Discard`ed when received, and the invariant requires the message to still exist in `msgs` with the source already recorded), pushing the violation depth past what 30-minute BFS with these constants will reach in the worst case.

---

## Bug 6 — TBD (Family 5)

Family 5 BFS is in flight at report time. The hypothesised mechanism (modeling brief §2.5): `safety_rules.sign_commit_vote` does no persistence (`safety_rules.rs:372-418`) and commit votes are broadcast from `pipeline_builder.rs:1215-1217`; crash between sign and rebroadcast can lose the commit-vote record so a recovered node may emit a *different* commit vote for the same (round, ordered_li) pair.

Family 5's config has `MaxEpoch = 1`, so the `CommitEpochBound` violation from Bug 3 is not reachable here; the available targets are `Agreement` and `CommitSafety`, which need pipeline progression (`PersistBlock`) to fire.

---

## Not Reproduced

| Bug Family | Config | Status |
|------------|--------|--------|
| 2 | `MC_hunt_family2.cfg` | BFS in flight; first attempt at full memory (50G heap) reached level 14 with 34.6M distinct states in 5 min before being killed by an OOM (concurrent Claude instance). Retry at 30G heap reached level 13 with ~10.7M distinct states by report time. Hypothesised MC-2 / MC-3 are spec-reachable but the state space at n=4 + 2 ByzEquiv + 2 ByzEquivOrderVote pushes the violation beyond what BFS finds in 30 min. Recommended follow-up: simulation run (`-S -n 999999999 -p 60`). |
| 4 | `MC_hunt_family4.cfg` | BFS in flight; first attempt SIGBUS'd at level 16 with 18.4M distinct states (memory pressure under concurrent runs). Retry reached level 17 with ~39M distinct states. The MC-6 path requires two ByzCrossEpochReplays + a ReceiveOrderVoteWeakEpoch + EpochChange + a precursor OC — ≈10 actions, near the BFS reach within the 30-min budget. Recommended follow-up: simulation run. |
| 5 | `MC_hunt_family5.cfg` | BFS in flight; reached level 12 with ~12M distinct states. With `MaxEpoch = 1` the `CommitEpochBound` violation seen in Family 3 is unreachable here; the remaining invariants (`Agreement`, `CommitSafety`) require pipeline progress under crash + ByzEquiv. Recommended follow-up: simulation run. |

---

## Spec adjustments during hunting

- **`MC_hunt_family1_nodoublevote.cfg`** — Variant created by deleting `RecoverPreservesLastVote` from the invariant list of `MC_hunt_family1.cfg`. The original config produced the 3-state `RecoverPreservesLastVote` counterexample (Bug 1) at the *first* `SignVote`, which prevented TLC from reaching the deeper `NoDoubleVote` violation (Bug 2). The variant lets the search continue past Bug 1 and find Bug 2. Both configs are kept; both counterexamples recorded above.
- **`MC_hunt_family3_qcvalue.cfg`** — Variant prepared by removing `CommitEpochBound` from `MC_hunt_family3.cfg` so a follow-up run can hunt `QCValueBound` / `TCQuorumPower` without TLC stopping on the already-confirmed Bug 3 violation. Run not completed at report time.

## Operational notes

- All TLC runs in this round used a custom `metadir` under `/home/ubuntu/tlc-tmp/` (1 TB free disk) to avoid the `/tmp` disk-quota SIGBUS that killed the very first MC.cfg attempt at minute 8.
- Two long-running TLC processes (this Claude instance + a sibling Claude running the `sui` case study) shared the 377 GB RAM and competed for memory during the Family 2 / Family 4 retries; this is the cause of the SIGBUS at `MC_hunt_family4_bfs.out` and the OOM kill at `MC_hunt_family2_bfs.out`. Subsequent retries used smaller per-job heap (10G–30G) and survived. None of the SIGBUSes were caused by the spec or by TLC bugs.

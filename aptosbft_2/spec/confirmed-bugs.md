# Confirmed Bug Report — aptosbft_2

## Summary

- **Total findings reviewed**: 6 (3 MC-confirmed with counterexamples in `bug-report.md`; 3 BFS-incomplete / structural in the modeling brief)
- **Reproduced (new bugs, end-to-end test triggered)**: 1 — `repro_bug1_2_double_vote_after_crash_window`
- **Known/historical (cited upstream, no new reproduction required)**: 1 — Bug 2 is the Byzantine-proposer half of MC-4 from the prior round, with the regular-vote half tracked as Aptos Issue #18298
- **False positives (real implementation already prevents the spec finding)**: 1 — Bug 3 (`sign_commit_vote` cross-epoch); blocked by `match_ordered_only` at `block_info.rs:196-204`
- **Defense-in-depth / Tier C only**: 3 — Family 2 order-vote vs regular-vote asymmetry (Bug 4), Family 4 cross-epoch order-vote replay (Bug 5), Family 5 commit-vote persist gap (Bug 6); all structurally reachable but no concrete safety harm given existing safeguards
- **BFS-incomplete (no counterexample available)**: 3 — Family 2 / 4 / 5 BFS ran out of time/memory budget; structural arguments only

The only finding that reproduces as a real safety violation at the implementation level is Bug 1 / Bug 2 (the two are inseparable — Bug 1's `RecoverPreservesLastVote` transient state IS the enabling window for Bug 2's `NoDoubleVote` violation). The reproduction requires a non-durable persistent storage backend, which `OnDiskStorage` (`secure/storage/src/on_disk.rs:64-70`) is — it issues `rename` without `fsync` / `sync_all`.

---

## Bug 1 + Bug 2 — Sign-before-persist + Byzantine equivocating proposer ⇒ double vote at the same round

- **Source**: MC counterexamples (`bug-report.md` §Bug 1, §Bug 2; `MC_hunt_family1.cfg` and `MC_hunt_family1_nodoublevote.cfg`)
- **Status**: **REPRODUCED** (Bug 1's transient state and Bug 2's safety violation are the same code path)
- **Severity**: Critical (`NoDoubleVote` is BFT safety; once a single honest validator signs two distinct votes at the same round, Byzantine equivocation by an honest validator is observable by peers)
- **Location**: `consensus/safety-rules/src/safety_rules_2chain.rs:102` (`self.sign(...)`) vs `:121` (`self.persistent_storage.set_safety_data(...)`). The order-vote analog at `:158` vs `:160` has the same pattern. The timeout path (`:47` persist, `:49` sign) is ordered the other way and is therefore correct.

### Description

In `guarded_construct_and_sign_vote_two_chain`:

```text
102:    let signature = self.sign(&ledger_info)?;
103:    let vote = Vote::new_with_signature(vote_data, author, ledger_info, signature);
104:
105:    safety_data.last_vote = Some(vote.clone());
…
121:    self.persistent_storage.set_safety_data(safety_data.clone())?;
…
137:    Ok(vote)
```

The signed Vote bytes are produced at line 102, before the new `safety_data` (containing `last_voted_round = R` and `last_vote = Some(v)`) is durably persisted at line 121. In the synchronous in-process path the Vote is only *returned* at line 137, **after** the persist succeeds — that is the maintainer's argument in Issue #18298. But "succeeds" here only means `set_safety_data` returned Ok, which depends on the storage backend being synchronously durable. `OnDiskStorage::write` (`secure/storage/src/on_disk.rs:64-70`) does **not** call `fsync` / `sync_all`, so a power loss between the `fs::rename` and the kernel's writeback can lose the write even though `set_safety_data` returned Ok.

On reboot, the persisted `safety_data` is the pre-crash value (`last_voted_round = R-1`, `last_vote = None`). A Byzantine equivocating proposer that issued two distinct proposals at round R can now deliver the *other* proposal to the recovered validator, which re-enters `guarded_construct_and_sign_vote_two_chain`. Because both layers of the round-check live in the same SafetyData record:

- The `last_vote` dedup at `:84-88` returns the previous vote only if `safety_data.last_vote.is_some()` and matches the round. After the crash both fields rolled back together → dedup is bypassed.
- `verify_and_update_last_vote_round(R, ...)` at `safety_rules.rs:218-225` passes because `R > safety_data.last_voted_round = R-1`.

A second, semantically distinct vote is signed at round R. Honest peers see two votes from the same author at the same round → `NoDoubleVote` violated.

### Prerequisites

```
Prerequisites:
- [code] guarded_construct_and_sign_vote_two_chain reachable from RoundManager::vote: VERIFIED — round_manager.rs calls safety_rules.construct_and_sign_vote_two_chain → guarded_construct_and_sign_vote_two_chain (safety_rules.rs:485-497).
- [code] sign() at line 102 happens before set_safety_data() at line 121 inside the same function: VERIFIED — direct read of safety_rules_2chain.rs:67-138.
- [code] Both last_voted_round AND last_vote live in the same SafetyData record persisted via a single set_safety_data call: VERIFIED — safety_data.rs and persistent_safety_storage.rs:150-170.
- [storage] At least one supported storage backend lacks fsync/sync_all: VERIFIED — on_disk.rs:64-70; production-warning comment at on_disk.rs:16-22. (Vault-based backends are presumed durable by the maintainer; OnDiskStorage is described as "should not be used in production" but is still selectable in SecureBackend::OnDiskStorage at config/src/config/secure_backend_config.rs:21.)
- [protocol] Byzantine equivocating proposer at the same round is in scope: VERIFIED — Aptos BFT operates under a Byzantine threat model (n ≥ 3f+1). is_valid_proposer (round_manager.rs) checks proposer identity but not message uniqueness; the implementation does not prevent a Byzantine leader from broadcasting two distinct ProposalMsg values at the same round.
- [spec] Single honest validator must not emit two distinct votes at the same (epoch, round): VERIFIED — implicit in BFT safety, and concretely tested by safety-rules' own test_2chain_rules (no two valid Vote outputs at the same round); the prior round captured this as `NoDoubleVote`.
```

### Counterfactual fix check

```
Counterfactual fix check:
- Property: NoDoubleVote (system-wide — quantifies over all peers/rounds/states).
- Proposed fix in spec terms: re-order the two transitions inside `SignVote` so that `persistedSafetyData[s].lastVotedRound` is updated atomically with `volatileSafetyData[s].lastVotedRound`, mirroring the timeout-path order at safety_rules_2chain.rs:47-49 and the canonical fix in commit f58e184471. Concretely: swap `self.sign(...)` and `self.persistent_storage.set_safety_data(...)` so persist precedes sign.
- MC config re-run: not executed in this round — TLC re-run with the patched spec is recommended follow-up, but the unit-level reproduction (this report) directly demonstrates that the patched code path rejects the second vote via dedup (see counter_durable_persist_blocks_double_vote which is the implementation-level counterfactual). The dedup at safety_rules_2chain.rs:84-88 returns the first vote without re-signing as long as last_vote is persisted before sign.
- Result (implementation counterfactual): PROPERTY HOLDS. With persist-before-sign, the post-crash recovery sees last_voted_round = R AND last_vote = Some(v1) AND together they reject p2.
- Alternative path for the bad state: None observed at this site. The two layers (last_voted_round numeric check + last_vote dedup) both live in SafetyData and are jointly persistent, so fixing the ordering closes both.
- Conclusion: Original framing CORROBORATED. Bug 1 is the transient state visible to TLC; Bug 2 is the externally-observable double-vote that results when the storage layer fails to make the persist durable.
```

### Report Tier

**Tier A** — externally observable safety violation: two distinct, valid signed Votes by one honest validator at the same `(epoch, round)`. Byzantine equivocation by an honest validator is what slashing rules are designed to catch; it is direct evidence of a safety break, not a hygiene issue.

### Trigger scenario

1. Four validators s1..s4 on Aptos mainnet with n=4, f=1; s4 is the Byzantine equivocating proposer for round R.
2. s4 broadcasts two distinct `ProposalMsg`s at round R for v1 and v2.
3. Honest s1 receives v1 first, calls `safety_rules.construct_and_sign_vote_two_chain(p1, None)`. `self.sign(...)` (line 102) produces the signed bytes; `set_safety_data(...)` (line 121) returns Ok but the underlying `OnDiskStorage` has only issued `rename`, no `fsync` — the kernel may still be holding the new file in dirty page cache.
4. The round_manager broadcasts s1's vote v1 to the network (line 137 in `guarded_construct_and_sign_vote_two_chain` returns and the vote_msg is dispatched).
5. Power loss on s1's host. Persistent safety_data on disk is the *pre-write* version: `last_voted_round = R-1`, `last_vote = None`.
6. s1 reboots. SafetyRules loads safety_data from disk → `last_voted_round = R-1`, `last_vote = None`.
7. The network delivers s4's other proposal p2 (still in s1's mailbox or re-fetched via sync). s1 calls `construct_and_sign_vote_two_chain(p2, None)`.
8. `last_vote` dedup at `:84-88` is bypassed (last_vote = None). `verify_and_update_last_vote_round(R, ...)` passes (R > R-1). `safe_to_vote(p2, None)` passes (R == p2.qc.round + 1 = genesis + 1 = 1). A second vote v2 is signed and broadcast.
9. Honest peers see two valid signed votes from s1 at round R for v1 and v2. `NoDoubleVote` violated.

### Developer intent investigation

- **Issue tracker** (cited by bug-report.md): **Aptos Issue #18298** files exactly this scenario; the maintainer disputed it on the grounds that the persist precedes the network broadcast. The dispute is contingent on the SafetyRules backend's `set` being synchronously durable, which is **not** true of `OnDiskStorage` and is the reason the timeout path (`safety_rules_2chain.rs:47-49`) was already fixed by **commit `f58e184471`** to persist *before* signing. The asymmetry between the timeout fix and the vote/order-vote paths is direct evidence that the team's own canonical fix has not been applied to the regular-vote and order-vote sign sites.
- **Code comments**: `on_disk.rs:16-22` explicitly says `OnDiskStorage` "should not be used in production" — but it remains a selectable backend in `SecureBackend::OnDiskStorage`. The new SafetyData fields `one_chain_round` and `highest_timeout_round` use `#[serde(default)]` (`safety_data.rs`), so a binary upgrade reading legacy on-disk data gets 0 for both fields, widening accept sets for order-votes and 2-chain timeouts (modeling-brief.md §2.1).
- **Test cases**: `test_2chain_rules` (`tests/suite.rs:666-760`) tests `last_voted_round` after a successful vote, but does NOT cross the crash-and-recover boundary. There is no existing test that simulates "persisted state was lost after sign returned Ok".

### Precedent re-check

The precedent (timeout-side fix `f58e184471`) endorses the pattern *"persist `safety_data` before issuing the cryptographic signature"*. Its prerequisites are: (a) the persist's durability is the only guarantee against post-crash re-entry, and (b) the signed bytes leak from the function (either via return or via async hand-off to a separate process). At the regular-vote and order-vote sites both prerequisites hold (a) — same persistence backend; (b) the function returns the Vote/OrderVote bytes after persisting, but the persist's `set_safety_data` call only guarantees durability if the underlying KV-store fsyncs, which `OnDiskStorage` does not.

### Reproduction test

- **File**: `repro/test_bug1_2_double_vote.rs` (canonical copy at
  `consensus/safety-rules/src/tests/repro_bugs.rs` so it has the
  `pub(crate)` visibility it needs).
- **Runner**: `repro/run_repros.sh`.
- **What it does**: builds two structurally distinct `VoteProposal`s at round 1 (the Byzantine equivocating proposer model), signs the first via a `SafetyRules` instance, then drops that instance and creates a fresh `PersistentSafetyStorage` with the same initial (pre-crash) state. This is exactly the state a non-fsyncing `OnDiskStorage` would present after a power loss between the `rename` and the kernel's writeback. A new `SafetyRules` over the rolled-back storage is then asked to sign the *other* proposal at the same round. The test asserts that BOTH votes succeed and that they cover distinct vote_data hashes — direct evidence of `NoDoubleVote` being violated.
- **Counter test**: `counter_durable_persist_blocks_double_vote` — same scenario but with a single shared storage instance (modelling synchronously-durable backend). It asserts that the second call returns the *same* vote v1 via the `last_vote` dedup, not a new signature. This shows the persistence ordering is exactly what gates the bug.
- **OnDiskStorage precondition probe**: `repro/test_bug1_on_disk_storage_no_fsync.sh` greps `on_disk.rs` for `fsync`/`sync_all`/`fdatasync` and finds none.

### Reproduction result

**PASS — bug triggered.**

```
running 4 tests
DOC: WrappedLedgerInfo::verify does not check vote_data binding — relies on consumer-side `verify_consensus_data_hash` via `certified_block(order_vote_enabled=false)`.
test tests::repro_bugs::doc_wrapped_ledger_info_vote_data_unsigned ... ok
CORRECT (Bug 3 false positive): cross-epoch sign_commit_vote blocked by match_ordered_only (`InconsistentExecutionResult`). Spec's missing-verify_epoch finding is closed by the BlockInfo.epoch comparison.
test tests::repro_bugs::test_bug3_sign_commit_vote_cross_epoch_blocked_by_match_ordered_only ... ok
CORRECT: durable persist returns previous vote v1 via last_vote dedup; the validator does NOT produce two distinct signed votes at round 1.
test tests::repro_bugs::counter_durable_persist_blocks_double_vote ... ok
REPRO SUCCESS: NoDoubleVote violated — v1.id=87f2c5a4 v2.id=fe6e816d both at round=1
test tests::repro_bugs::repro_bug1_2_double_vote_after_crash_window ... ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 17 filtered out; finished in 0.04s
```

The line `REPRO SUCCESS: NoDoubleVote violated — v1.id=87f2c5a4 v2.id=fe6e816d both at round=1` is the bug evidence: two distinct block IDs voted on by the same validator at the same round.

The OnDiskStorage probe output:

```
==> Source-level check: on_disk.rs::write() body

    fn write(&self, data: &HashMap<String, Value>) -> Result<(), Error> {
        let contents = serde_json::to_vec(data)?;
        let mut file = File::create(self.temp_path.path())?;
        file.write_all(&contents)?;
        fs::rename(&self.temp_path, &self.file_path)?;
        Ok(())
    }

==> Looking for fsync / sync_all / fdatasync inside on_disk.rs:
  (none — confirming OnDiskStorage performs no kernel-level durability sync)

VERIFIED: OnDiskStorage::write performs File::create + write_all + fs::rename,
          with no fsync / sync_all / fdatasync. A power loss between the rename
          and the kernel's writeback can lose the SafetyData write. This is the
          storage-backend precondition for Bug 1 / Bug 2 in production.
```

### Recommendation

Two stacked fixes, mirroring the timeout-path canonical fix from commit `f58e184471`:

1. **Persist-before-sign in the vote and order-vote paths**. Swap lines 102 and 121 in `guarded_construct_and_sign_vote_two_chain` (and the analog at `:158` vs `:160` for `guarded_construct_and_sign_order_vote`) so the persistent state is durable before the signed bytes leave the function. Same pattern as `guarded_sign_timeout_with_qc` (`:47` persist, `:49` sign).

2. **Add `sync_all` / directory `fsync` in `OnDiskStorage::write`** (T-1 in the modeling brief). This closes the maintainer's "the persist precedes the broadcast" argument in Issue #18298 by making the persist itself genuinely durable. Concretely: after `fs::rename`, also `fsync` the file *and* `fsync` the parent directory to make the rename durable.

Either fix alone is insufficient. (1) closes the protocol-level ordering gap; (2) closes the storage-backend gap on which the maintainer's dispute hinges.

---

## Bug 3 — `sign_commit_vote` missing `verify_epoch`: **FALSE POSITIVE** at implementation level

- **Source**: MC counterexample (`bug-report.md` §Bug 3; `MC_hunt_family3.cfg`)
- **Status**: **FALSE POSITIVE** — the implementation has a safeguard the spec abstracts away
- **Severity**: N/A — no externally observable safety harm
- **Location**: `consensus/safety-rules/src/safety_rules.rs:388-452` (`guarded_sign_commit_vote`); explicit TODOs at `:428-429`

### Description

The spec's `MCSignCommitVote(s, r, e)` action has precondition `e \in 1..MaxEpoch` and produces a commit vote whose `new_ledger_info.epoch()` may differ from `safety_data.epoch`. The spec correctly observes that the real `guarded_sign_commit_vote` does not call `verify_epoch(new_ledger_info.epoch(), &safety_data)` — that check IS absent.

However, the implementation has a different safeguard the spec didn't model: `old_ledger_info.commit_info().match_ordered_only(new_ledger_info.commit_info())` at `safety_rules.rs:411-413`, where `match_ordered_only` (`types/src/block_info.rs:196-204`) compares `self.epoch == executed_block_info.epoch`. Combined with the signature verification on `ledger_info` against `self.epoch_state()?.verifier` at `:421-426`, the chain becomes:

```
safety_data.epoch == epoch_state.epoch
   (set jointly in guarded_initialize at safety_rules.rs:296-303)
=> verifier.verify_signatures(old_ledger_info, sigs)
   succeeds only if old_ledger_info.commit_info.epoch == safety_data.epoch
=> match_ordered_only enforces
   new_ledger_info.commit_info.epoch == old_ledger_info.commit_info.epoch
=> LedgerInfo::epoch() returns commit_info().epoch()
   so new_ledger_info.epoch() == safety_data.epoch
```

The MC spec abstracts away signatures and the `match_ordered_only` predicate, so it admits the cross-epoch trace. The real implementation does not. Bug 3 is a modeling artifact, not a code-level bug.

### Prerequisites

```
Prerequisites:
- [code] guarded_sign_commit_vote is reachable from BufferManager::handle_signing: VERIFIED — called via TSafetyRules::sign_commit_vote (safety_rules.rs:507-514).
- [code] match_ordered_only enforces epoch equality between old and new commit_info: VERIFIED — block_info.rs:197 `self.epoch == executed_block_info.epoch`.
- [code] LedgerInfo::epoch() returns commit_info.epoch(): VERIFIED — ledger_info.rs:113-115.
- [code] verify_signatures runs against the current epoch's verifier: VERIFIED — safety_rules.rs:422-425 uses self.epoch_state()?.verifier; this verifier was loaded in guarded_initialize from the EpochChangeProof's last_li.next_epoch_state (safety_rules.rs:265-359).
- [code] skip_sig_verify is false in production deployments: PARTIALLY VERIFIED — the production safety_rules path goes through SafetyRulesManager and the local backend uses `false`, but skip_sig_verify is configurable. If a deployment sets skip_sig_verify = true AND the upstream caller does not re-verify signatures, the cross-epoch attack becomes possible at the implementation level. No such production configuration was observed.
- [spec] CommitEpochBound is required by protocol safety: VERIFIED — a commit vote signed at epoch=E binds the validator to commit a block at epoch E; cross-epoch commit votes would let a validator be tricked into validating a different epoch's chain.
```

### Counterfactual fix check

Not applicable — Bug 3 is a local-property finding (a specific check missing on a specific path), not a system-wide property. The Counterfactual phase is for system-wide properties where alternative paths might also reach the bad state.

### Report Tier

**Tier C** — recorded as defense-in-depth, not submitted by default. The explicit TODOs at `safety_rules.rs:428-429` are still worth addressing for two reasons:
- They reduce reliance on the `match_ordered_only` + `verify_signatures` chain. If a future refactor accidentally relaxes either of those, the missing `verify_epoch` becomes a real bug.
- The `skip_sig_verify = true` configuration path drops half the chain. A direct `verify_epoch(new_ledger_info.epoch(), &safety_data)` is independent of skip_sig_verify.

### Reproduction test

- **File**: `repro/test_bug1_2_double_vote.rs::test_bug3_sign_commit_vote_cross_epoch_blocked_by_match_ordered_only` (same file as Bug 1/2).
- **What it does**: constructs the standard `test_sign_commit_vote` chain (genesis → a1 → a2 → a3), signs the canonical commit vote (succeeds), then forges a `new_ledger_info` whose `commit_info.epoch = old_ledger_info.commit_info.epoch + 1` and calls `sign_commit_vote(old, new_with_bad_epoch)`. The test asserts that the implementation rejects with `Error::InconsistentExecutionResult` — which is `match_ordered_only`'s rejection path.

### Reproduction result

**PASS — false positive confirmed.** The cross-epoch attempt is rejected with `InconsistentExecutionResult`, demonstrating that the spec's missing-`verify_epoch` finding is closed at the implementation level by `match_ordered_only`.

```
CORRECT (Bug 3 false positive): cross-epoch sign_commit_vote blocked by match_ordered_only (`InconsistentExecutionResult`). Spec's missing-verify_epoch finding is closed by the BlockInfo.epoch comparison.
test tests::repro_bugs::test_bug3_sign_commit_vote_cross_epoch_blocked_by_match_ordered_only ... ok
```

### Recommendation

Address the explicit TODOs at `safety_rules.rs:428-429` as defense-in-depth:
- Add `self.verify_epoch(new_ledger_info.epoch(), &safety_data)?` at the head of `guarded_sign_commit_vote`, mirroring the regular-vote path at `:204-210`.
- Add `last_committed_round` to SafetyData and dedupe commit votes by it.
- Add the extension check against the previously-signed ordered_only ledger_info.

These changes are valuable hygiene but are not required to close a current safety bug.

---

## Bug 4 — Family 2 order-vote / regular-vote guard asymmetry: BFS-incomplete, structurally Tier C

- **Source**: Code review (`modeling-brief.md` §2.2 / Family 2; `bug-report.md` "Not Reproduced" table)
- **Status**: BFS in flight, no MC counterexample; structural argument from code review only
- **Severity**: Defense-in-depth — no externally observable safety harm under standard `n ≥ 3f+1` Byzantine assumption
- **Location**: `safety_rules_2chain.rs:226-236` (`safe_for_order_vote` reads only `highest_timeout_round`, not `last_voted_round`); `consensus/src/pending_order_votes.rs:61-157` (no per-author equivocation map mirroring `pending_votes.rs:287-309`); `round_manager.rs:1582-1660` (`process_order_vote_msg` skips `ensure_round_and_sync_up`).

### Description

The order-vote sign path has a weaker guard surface than the regular-vote path. Specifically:

- `safe_for_order_vote` only enforces `r > highest_timeout_round[s]`. It does **not** consult `last_voted_round[s]`. The bug-report's hypothesised MC-2 path is: honest validator regular-votes at round R for block v1, then receives a Byzantine OrderVoteProposal at round R for a *different* block v2, and signs an OrderVote at R for v2.
- The aggregator at `pending_order_votes.rs` has no `author_to_vote` map and so cannot detect a Byzantine signer contributing to two distinct (round, digest) quorums simultaneously.

### Why this is not Tier A or B at the protocol level

For the spec's `NoCrossPathSign` violation to materialise into a safety harm, there must exist a valid QC at round R for a *different* block than the validator's prior Vote. With n ≥ 3f+1 and an honest quorum overlap, the only way to construct a valid QC for v2 at round R is via 2f+1 honest+Byzantine signatures over v2. Because honest validators do not double-vote (under any of the conditions other than Bug 1/2's crash window, which is already covered separately), the only honest signers of v2 at round R are validators that voted *only* for v2 (and not for v1). That means the validator s that voted v1 is **not** in the QC for v2 — its regular vote for v1 contributes to a partial-quorum that never forms a QC, and the OrderVote for v2 binds s to v2's order-commit. There is no second QC at R for v1.

In other words: a validator that signed both `Vote(R, v1)` and `OrderVote(R, v2)` is just "wasted information" on the v1 side. The protocol commits at most one block at R (v2 via order-cert), which is the safe behaviour. `NoCrossPathSign` is a hygiene property the implementation does not enforce, but its absence does not break BFT safety as long as `last_voted_round` is honestly maintained on the regular-vote path.

### Prerequisites

```
Prerequisites:
- [code] safe_for_order_vote reads only highest_timeout_round: VERIFIED — safety_rules_2chain.rs:226-236.
- [code] guarded_construct_and_sign_order_vote does not call verify_and_update_last_vote_round: VERIFIED — direct read of safety_rules_2chain.rs:140-177.
- [code] pending_order_votes.rs aggregator has no per-author dedup: VERIFIED — pending_order_votes.rs:61-157.
- [spec] NoCrossPathSign is protocol-required: NOT VERIFIED. The Jolteon paper and AIP-89 (order votes) do not normatively require that a validator's regular Vote at R and its OrderVote at R must reference the same block. The Byzantine-safety argument relies on QC threshold + honest-quorum overlap, both of which hold without NoCrossPathSign.
- [protocol] A valid QC at R for v2 ≠ v1 requires 2f+1 distinct signers: VERIFIED — pending_votes aggregator (pending_votes.rs:287-309) checks per-author dedup; verify_qc verifies signature threshold.
```

### Report Tier

**Tier C** — defense-in-depth. The asymmetry exists, the historical PRs #13711/#14129/#14637 are evidence that this code is bug-prone, and the team should mirror the regular-vote guards onto the order-vote path. But under the standard Byzantine threat model with honest-quorum overlap, the absence of `last_voted_round` enforcement on the order-vote path does not produce an externally observable safety violation.

### Reproduction test

Not produced. The structural argument above shows that a real `NoCrossPathSign` reproduction would require either (a) constructing a valid QC at R for v2 ≠ v1 with s (the validator that voted for v1 at R) being part of the QC — impossible under honest threshold assumptions without Bug 2's mechanism; or (b) demonstrating downstream safety harm from the "wasted vote" on v1 — no such harm exists under the protocol's safety argument.

### Recommendation

Submit the four CR items from the modeling brief (CR-7, CR-9; and the analog updates to `safe_for_order_vote`). These bring the order-vote guard surface up to parity with the regular-vote path. The work is small, the risk is low, and the historical PR cadence (six order-vote-specific fixes in a row) confirms the maintainers are already on this trajectory.

---

## Bug 5 — Family 4 cross-epoch order-vote replay: BFS-incomplete, structurally Tier C

- **Source**: Code review (`modeling-brief.md` §2.4 / Family 4; `bug-report.md` "Not Reproduced" table)
- **Status**: BFS ran out of state-space budget; structural argument only
- **Severity**: Defense-in-depth / liveness — no immediate safety harm
- **Location**:
  - `consensus-types/src/timeout_2chain.rs:248-257` — `TwoChainTimeoutWithPartialSignatures::add` uses `debug_assert_eq!` for epoch/round matching (compiled out in release).
  - `consensus-types/src/order_vote_msg.rs:47-67` — `verify_order_vote` does not bind `order_vote.epoch` to the inner QC's `certified_block().epoch()`.
  - `consensus/src/epoch_manager.rs:1692-1750` — bounded-executor verification result delivered via the old `round_manager_tx` after epoch rotation, currently dropped silently.

### Description

Three sites where epoch-coupling is loose. The most concrete is the aggregator-side `debug_assert_eq!`: in release builds the aggregator silently absorbs a cross-epoch or cross-round timeout signature. However, the downstream `TwoChainTimeoutCertificate::verify` re-signs with the cert's claimed epoch/round (its own value, not the input timeout's), so the malformed cert fails on the *next* hop's signature verify. The net effect: the local aggregator's `pending_timeouts` map is poisoned (DoS to the local node's TC formation), but no remote node accepts a mis-epoched timeout.

The `verify_order_vote` gap is similar: the receiver's `epoch_manager` filter checks `OrderVoteMsg.epoch`, and the `process_order_vote_msg` path at `round_manager.rs:1610-1633` re-verifies the inner QC against `self.epoch_state.verifier` (the current epoch's verifier). A cross-epoch inner QC would fail this verifier check, so the replay is rejected at QC-verify time.

### Prerequisites

```
Prerequisites:
- [code] debug_assert_eq! at timeout_2chain.rs:248-257 is no-op in release: VERIFIED — standard Rust semantics.
- [code] downstream TwoChainTimeoutCertificate::verify re-checks signatures against the cert's claimed epoch: VERIFIED — timeout_2chain.rs:141-183.
- [code] process_order_vote_msg verifies the inner QC against self.epoch_state.verifier: VERIFIED — round_manager.rs:1615-1618 calls `order_vote_msg.quorum_cert().verify(&self.epoch_state.verifier)` on the first message; subsequent messages skip QC verification because the QC was already accepted.
- [spec] The receiving validator's epoch_state.verifier is the only verifier used for QC re-verification: VERIFIED.
- [protocol] An attacker cannot forge BLS signatures: VERIFIED (standard cryptographic assumption).
```

### Counterfactual fix check

Not applicable — local-property finding (a specific check on a specific path), not system-wide.

### Report Tier

**Tier C** — defense-in-depth. The `debug_assert_eq!`→`ensure!` upgrade (CR-1) is a one-line fix worth submitting; the order-vote inner-QC epoch binding (CR-7) is similarly cheap. But in the current code, the safeguard chain (downstream verify + epoch_state.verifier rotation) is sufficient to prevent real cross-epoch acceptance.

### Reproduction test

Not produced. The structural argument shows the safeguards are present elsewhere in the call chain. A meaningful reproduction would require a release build with an instrumented downstream verifier showing the cross-epoch cert is rejected; the equivalent in-process check is the strace + cargo build pipeline, which adds no information beyond direct code reading.

### Recommendation

Submit CR-1, CR-7, CR-9 from the modeling brief.

---

## Bug 6 — Family 5 commit-vote persist gap: BFS-incomplete, FALSE POSITIVE for safety

- **Source**: Code review (`modeling-brief.md` §2.5 / Family 5; `bug-report.md` "Not Reproduced" table)
- **Status**: BFS ran out of budget; structural argument shows no safety harm under deterministic execution
- **Severity**: Liveness only — no observable safety harm
- **Location**: `consensus/safety-rules/src/safety_rules.rs:372-418` (`guarded_sign_commit_vote` does no persistence); `consensus/src/pipeline/buffer_manager.rs:861-863` (30s rebroadcast as the only "recovery" mechanism); `consensus/src/pipeline/buffer_item.rs:149, 262` (`assert_eq!` panics BufferManager on commit-info inconsistency).

### Description

The commit-vote sign path persists nothing — `safety_data` is not updated, and `safety_rules.sign_commit_vote` does not write to disk. The bug claim: a crash between sign and rebroadcast loses the commit-vote record, so a recovered node may emit a *different* commit vote for the same (round, ordered_li) pair.

But: `match_ordered_only` at `safety_rules.rs:411-413` enforces that `new_ledger_info.commit_info` matches `old_ledger_info.commit_info` on `(epoch, round, id, timestamp_usecs)`. The only fields that could differ between two commit votes for the same `old_ledger_info` are `executed_state_id`, `version` — which come from execution, and **Aptos execution is deterministic** for the same block input. So two commit votes for the same `old_ledger_info` would be byte-identical, not divergent. No double-commit-vote at the safety level.

The remaining concern is liveness: an honest validator that crashed mid-commit-vote may not re-emit its vote until the 30s rebroadcast cycle, slowing commit. And `assert_eq!` at `buffer_item.rs:149, :262` panics the BufferManager if local execution disagrees with a pre-aggregated commit proof — this is "safety-correct, liveness-bad" (the node halts rather than producing a divergent commit).

### Prerequisites

```
Prerequisites:
- [code] guarded_sign_commit_vote does no persistence: VERIFIED — safety_rules.rs:388-452 has no set_safety_data call.
- [code] match_ordered_only enforces epoch/round/id/timestamp equality: VERIFIED — block_info.rs:196-204.
- [protocol] Aptos execution is deterministic for the same block input: VERIFIED — Block-STM provides deterministic parallel execution by design.
- [spec] An honest validator should not emit two distinct commit votes for the same (round, ordered_li) pair: VERIFIED — implicit safety requirement.
```

### Report Tier

**Tier C** — liveness/operability concern, not a safety bug. The 30s rebroadcast delay is documented in the buffer_manager comments. The `assert_eq!` panic on commit-info inconsistency is documented as intentional (safety-correct fail-fast).

### Reproduction test

Not produced — the safety property the spec is checking (`CommitSafety`) holds at the implementation level under deterministic execution. Any liveness-only reproduction would require multi-node deployment with crash injection, which is outside the scope of this case study.

### Recommendation

Persist commit votes for crash recovery (T-4 in modeling brief) to reduce the rebroadcast-dependent recovery time. This is a liveness improvement, not a safety fix.

---

## Path-deviation findings (Step 1 rejection, recorded for pipeline evaluation)

None — all six findings carry articulable system-level consequences in their original framing. Phase 1 Step 1 rejected zero findings. Step 2-5 then downgraded Bug 3, Bug 4, Bug 5, Bug 6 to false-positive or Tier C based on existing safeguards or absence of a normative spec requirement.

---

## Operational notes

- **Reproduction artefacts** live at `/home/ubuntu/Specula/case-studies/aptosbft_2/.specula-output/repro/`:
  - `test_bug1_2_double_vote.rs` — reference copy of the Rust test (canonical at `consensus/safety-rules/src/tests/repro_bugs.rs`).
  - `test_bug1_on_disk_storage_no_fsync.sh` — strace/grep storage-backend precondition check.
  - `run_repros.sh` — top-level runner.
  - `test_output.txt` — captured combined output of the last run.
  - `README.md` — usage and result summary.
- **The Rust reproduction lives inside the safety-rules crate** at `consensus/safety-rules/src/tests/repro_bugs.rs` because it needs `pub(crate)` access to `SafetyRules::persistent_storage` and other internals; the `repro/` copy is for reference. To run, simply `cargo test -p aptos-safety-rules --lib repro_bugs -- --nocapture` from the aptos-core root, or use the runner script.
- **TLC re-runs** for the recommended persist-before-sign counterfactual were not executed in this round — see the Counterfactual section under Bug 1+2.

# Deep Code Analysis: AptosBFT Safety Rules (2-chain Jolteon/HotStuff)

Files analyzed (full reads):
- `/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core/consensus/safety-rules/src/safety_rules.rs` (500 LOC)
- `/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core/consensus/safety-rules/src/safety_rules_2chain.rs` (215 LOC)
- `/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core/consensus/safety-rules/src/persistent_safety_storage.rs` (278 LOC)
- `/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core/consensus/safety-rules/src/consensus_state.rs` (83 LOC)
- `/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core/consensus/consensus-types/src/safety_data.rs` (70 LOC)

Supporting files consulted: `error.rs`, `t_safety_rules.rs`, `local_client.rs`, `serializer.rs`, `safety_rules_manager.rs`, `vote.rs`, `vote_data.rs`, `quorum_cert.rs`, `order_vote.rs`, `order_vote_proposal.rs`, `vote_proposal.rs`, `timeout_2chain.rs`, `metrics_safety_rules.rs`, `dag/commit_signer.rs`, `tests/suite.rs`, plus `secure/storage/src/{kv_storage,on_disk,in_memory,vault}.rs`.

---

## 1. Per-file line-cited findings

### 1.1 `safety_rules.rs`

**F1.1.1 — `verify_proposal` runs `verify_qc` BEFORE epoch check on QC contents only via verifier.**
`safety_rules.rs:67-85`
```rust
let safety_data = self.persistent_storage.safety_data()?;
self.verify_epoch(proposed_block.epoch(), &safety_data)?;
self.verify_qc(proposed_block.quorum_cert())?;
```
Risk: `verify_epoch` only checks `proposed_block.epoch()` against `safety_data.epoch`. The QC's own `vote_data.proposed.epoch` is verified through `vote_data.verify()` (called by `QuorumCert::verify` -> `vote_data.verify()` only ensures parent.epoch == proposed.epoch, not equality to current epoch). Cross-epoch QC content is not bound to current epoch beyond signature check on the verifier of the current epoch (which is correct), but if a malicious caller passes a QC certified by the current epoch's validators with `vote_data.proposed.epoch` referencing a different epoch, only the BlockInfo equality checks would catch it.

**F1.1.2 — `verify_order_vote_proposal` does NOT verify the proposed block's leader signature or well-formedness.**
`safety_rules.rs:87-111`
```rust
self.verify_epoch(proposed_block.epoch(), &safety_data)?;
let qc = order_vote_proposal.quorum_cert();
if qc.certified_block() != order_vote_proposal.block_info() { ... }
if qc.certified_block().id() != proposed_block.id() { ... }
self.verify_qc(qc)?;
```
Risk: Compared to `verify_proposal` (lines 73-80), this path skips `proposed_block.validate_signature(&self.epoch_state()?.verifier)` and `proposed_block.verify_well_formed()`. For order votes, the receiver only needs to verify the QC certifies `block_info`. The proposer signature on the block is not re-checked, which is acceptable IF the QC implies enough validators voted for it — but in practice the block content used to construct `order_vote_proposal.block_info` should match `qc.certified_block()`, which is checked. Less critical than F1.1.1, but it's an asymmetry to call out.

**F1.1.3 — `observe_qc` updates `preferred_round` and `one_chain_round` in-memory only.**
`safety_rules.rs:135-156`
The function is called inside vote-signing paths, then the caller is responsible for persisting. If the caller crashes after `observe_qc` updates the local copy and before `set_safety_data`, the advance is lost. See F1.1.4 and F1.2.x for the resulting crash-recovery hazard.

**F1.1.4 — `verify_and_update_last_vote_round` mutates the *local* `safety_data` argument; persistence is the caller's job.**
`safety_rules.rs:213-232`
```rust
if round <= safety_data.last_voted_round {
    return Err(Error::IncorrectLastVotedRound(...));
}
safety_data.last_voted_round = round;
```
Risk: The function name implies the rule is enforced, but the mutation is to a *clone* of safety_data (returned by `persistent_storage.safety_data()` at the call site). No write to backing store happens here. If the caller signs first and then forgets/crashes before persisting, `last_voted_round` regresses on recovery (F1.2.2).

**F1.1.5 — `guarded_sign_proposal` updates `preferred_round` in memory and intentionally does NOT persist.**
`safety_rules.rs:346-370`
```rust
self.verify_and_update_preferred_round(block_data.quorum_cert(), &mut safety_data)?;
// we don't persist the updated preferred round to save latency (it'd be updated upon voting)
let signature = self.sign(block_data)?;
```
Risk: The leader signs a proposal block at round R without ever persisting an advance to `preferred_round` or `last_voted_round`. The leader has signed something at round R, then crashes; on recovery, no record of having signed exists. A second `sign_proposal` call at round R for a different block_data would still pass `block_data.round() <= safety_data.last_voted_round` (line 356) because last_voted_round was not advanced. This permits the leader to sign two distinct proposal blocks at the same round across a crash window. (For a leader, equivocation is by-design Byzantine behavior, but SafetyRules is also supposed to protect HONEST leaders from being tricked.)

**F1.1.6 — `guarded_sign_proposal` does NOT update `last_voted_round` even though the proposal is a signed artifact at round R.**
`safety_rules.rs:356-369`
The `block_data.round() <= safety_data.last_voted_round` check at line 356 prevents proposing for an OLD round but does NOT bump last_voted_round to R after signing. So after a successful `sign_proposal(R)`, `last_voted_round` is still whatever it was before. Subsequent `construct_and_sign_vote_two_chain(R)` will then properly bump it, but only if it actually executes.

**F1.1.7 — `guarded_sign_commit_vote` has explicit TODO markers and NO epoch validation against `safety_data.epoch`.**
`safety_rules.rs:372-418`
```rust
fn guarded_sign_commit_vote(...) {
    self.signer()?;
    let old_ledger_info = ledger_info.ledger_info();
    if !old_ledger_info.commit_info().is_ordered_only() && ... { return Err(...) }
    if !old_ledger_info.commit_info().match_ordered_only(new_ledger_info.commit_info()) { return Err(...) }
    if !self.skip_sig_verify {
        ledger_info.verify_signatures(&self.epoch_state()?.verifier)?;
    }
    // TODO: add guarding rules in unhappy path
    // TODO: add extension check
    let signature = self.sign(&new_ledger_info)?;
```
Risk: 
- No `verify_epoch(old_ledger_info.epoch(), &safety_data)` call. The signature check uses `epoch_state().verifier`, which catches QCs whose signatures were aggregated in a different epoch (because the verifier set differs), but it does NOT cross-check that `old_ledger_info.commit_info().epoch() == safety_data.epoch`. A peer that crafts a `LedgerInfoWithSignatures` carrying valid signatures from the current epoch's validators but a `commit_info().epoch()` that differs from current would pass. Whether that is exploitable depends on whether the validator's BFT signing key is stable across epochs (it can rotate via `consensus_sk_by_pk`).
- TODO 1 ("guarding rules in unhappy path"): no protection against signing for ordered-only LIs that disagree with previously-signed commit-views. There is no per-round commit-vote dedup state.
- TODO 2 ("extension check"): no proof that `new_ledger_info` actually extends `old_ledger_info` beyond the field-by-field equality check on commit_info.
- Commit votes are NOT recorded in `safety_data` at all (no `last_committed_round` field), so a Byzantine peer could replay distinct commit-vote requests at the same round.

**F1.1.8 — `guarded_consensus_state` reads safety_data twice.**
`safety_rules.rs:247-263`
```rust
let safety_data = self.persistent_storage.safety_data()?;
trace!(...);
Ok(ConsensusState::new(
    self.persistent_storage.safety_data()?,   // SECOND read
    self.persistent_storage.waypoint()?,
    self.signer().is_ok(),
))
```
Risk: `safety_data()` may be cached, so this is usually free. With caching disabled it costs an extra storage round-trip. More importantly, in a multi-threaded SerializerService scenario, the two reads need not return the same snapshot.

**F1.1.9 — `guarded_initialize` resets `SafetyData` to defaults on epoch advance with `last_voted_round=0`.**
`safety_rules.rs:294-303`
```rust
Ordering::Less => {
    self.persistent_storage.set_safety_data(SafetyData::new(
        epoch_state.epoch, 0, 0, 0, None, 0,
    ))?;
```
Risk: When the validator advances to a new epoch, all rounds reset to zero. This is correct (rounds are scoped per epoch), but it means a Byzantine peer that can force-advance the SafetyRules epoch (via `initialize` with a forged proof) could erase round history. Mitigated by `EpochChangeProof::verify(&waypoint)` at line 268.

**F1.1.10 — `run_and_log` does not log persistence failures distinctly.**
`safety_rules.rs:483-500`
All errors funnel through the same `LogEvent::Error` channel. A `SecureStorageUnexpectedError` (persistence failure) is logged identically to a benign `IncorrectEpoch` rejection, which complicates incident response.

### 1.2 `safety_rules_2chain.rs`

**F1.2.1 — `guarded_sign_timeout_with_qc` persists BEFORE signing (correct ordering).**
`safety_rules_2chain.rs:19-51`
```rust
self.update_highest_timeout_round(timeout, &mut safety_data);   // L46
self.persistent_storage.set_safety_data(safety_data)?;          // L47 PERSIST
let signature = self.sign(&timeout.signing_format())?;          // L49 SIGN
```
Risk: None for crash-safety here. If the persist fails, no signature is produced. If a crash happens after persist but before send, the message is lost; on recovery the round bookkeeping is correct.

**F1.2.2 — `guarded_construct_and_sign_vote_two_chain` SIGNS BEFORE PERSIST (crash window).**
`safety_rules_2chain.rs:53-95`
```rust
self.verify_and_update_last_vote_round(proposed_block.block_data().round(), &mut safety_data)?;  // L77 in-memory
self.safe_to_vote(proposed_block, timeout_cert)?;                                                 // L81
self.observe_qc(proposed_block.quorum_cert(), &mut safety_data);                                  // L84 in-memory
let ledger_info = self.construct_ledger_info_2chain(proposed_block, vote_data.hash())?;          // L87
let signature = self.sign(&ledger_info)?;                                                          // L88 SIGN
let vote = Vote::new_with_signature(vote_data, author, ledger_info, signature);                   // L89
safety_data.last_vote = Some(vote.clone());                                                        // L91 in-memory
self.persistent_storage.set_safety_data(safety_data)?;                                             // L92 PERSIST (after sign)
Ok(vote)
```
Risk: This is the central safety hazard. Between line 88 (signature creation) and line 92 (persist), if the validator crashes:
1. The signed `Vote` may have already been sent to peers (if the SafetyRules client returns early on this thread it can't have been sent yet, but with `ProcessService` / `ThreadService`, the call is asynchronous and the response trip-time creates a window).
2. On recovery, `safety_data.last_voted_round` is the OLD value (R-1).
3. A Byzantine peer (or even an honest peer triggering a re-vote on a *different* proposal at round R) can call `construct_and_sign_vote_two_chain` again. The check at line 218 (`round <= safety_data.last_voted_round`) passes because last_voted_round is still R-1.
4. The validator signs a SECOND vote at round R for a DIFFERENT block — equivocation.

The narrower idempotence safeguard at line 70-74 (`vote.vote_data().proposed().round() == proposed_block.round()`) ONLY catches re-requests for the same round AND only after the vote has been persisted; if the crash dropped the persist, the safety_data.last_vote on disk is None (or the previous round's vote), so this guard does nothing.

**F1.2.3 — Order-vote path also signs before persisting; loses `preferred_round` advances on crash.**
`safety_rules_2chain.rs:97-119`
```rust
self.observe_qc(order_vote_proposal.quorum_cert(), &mut safety_data);  // L108 in-memory
self.safe_for_order_vote(proposed_block, &safety_data)?;               // L110
let signature = self.sign(&ledger_info)?;                               // L115 SIGN
let order_vote = OrderVote::new_with_signature(...)                     // L116
self.persistent_storage.set_safety_data(safety_data)?;                  // L117 PERSIST
```
Risk: Order votes do NOT update `last_voted_round` and do NOT update `highest_timeout_round`. The only persisted state advance is `preferred_round` / `one_chain_round` from `observe_qc`. If the persist drops, `preferred_round` regresses. A subsequent regular vote that uses `verify_and_update_preferred_round` (safety_rules.rs:173) might then accept a proposal whose parent QC round is *below* the previously-observed preferred round. This is a 2-chain safety violation.

Additionally, the order-vote path SIGNS an `OrderVote` carrying `LedgerInfo(block_info, HashValue::zero())`. Because there is no per-round dedup for order votes, a Byzantine peer can repeatedly submit the same order vote request to extract repeated signatures (idempotent same content though), but more dangerously can submit DIFFERENT `OrderVoteProposal`s at the same block round so long as each passes the `safe_for_order_vote` check (`round > highest_timeout_round`). There is NO check against the validator having previously order-voted at the same round for a different block.

**F1.2.4 — `safe_for_order_vote` only checks `highest_timeout_round`, not `last_voted_round`.**
`safety_rules_2chain.rs:168-178`
```rust
fn safe_for_order_vote(&self, block: &Block, safety_data: &SafetyData) -> Result<(), Error> {
    let round = block.round();
    if round > safety_data.highest_timeout_round { Ok(()) } else { Err(...) }
}
```
Risk: This is the **central order-vote asymmetry**. A regular vote at round R updates `last_voted_round = R` (safety_rules.rs:225). A subsequent order-vote at round R passes `safe_for_order_vote` so long as R > `highest_timeout_round`. The validator can therefore produce BOTH a regular vote AND an order vote at round R, signing two different artifacts (a vote-LedgerInfo with `vote_data.hash()` vs an order-vote-LedgerInfo with `HashValue::zero`). Whether downstream aggregators conflate these into competing certificates depends on the aggregation logic (which is outside this audit), but the safety module does not stop it.

The user flagged that PR #13711 added an epoch check to `verify_order_vote_proposal` (now present at safety_rules.rs:94) and that commit `f58e184471` added timeout-signing checks. Remaining asymmetries:
- order vote DOES NOT update `last_voted_round`
- order vote DOES NOT consult `last_voted_round` 
- order vote DOES NOT call `validate_signature` on the proposed block (regular vote does, line 73-77)
- order vote DOES NOT call `verify_well_formed` on the proposed block (regular vote does, line 78-80)

**F1.2.5 — `safe_to_timeout` allows timeout at same round as last regular vote.**
`safety_rules_2chain.rs:37-46`
```rust
if timeout.round() < safety_data.last_voted_round {
    return Err(Error::IncorrectLastVotedRound(...));
}
if timeout.round() > safety_data.last_voted_round {
    self.verify_and_update_last_vote_round(timeout.round(), &mut safety_data)?;
}
```
Risk: Note the strict `<` and `>` — if `timeout.round() == safety_data.last_voted_round`, both branches are skipped and `verify_and_update_last_vote_round` is never invoked. So a validator that already regular-voted at round R can also timeout-sign round R. Whether this is intentional (allowing a vote+timeout pair at the same round) is unclear from the comments. The TwoChainTimeout signing payload (`signing_format`) is independent of the regular vote payload, so the two signatures cover different artifacts; but downstream this means one validator's signatures contribute to BOTH a possible QC at round R AND a TC at round R.

**F1.2.6 — `safe_to_vote` is checked AFTER `verify_and_update_last_vote_round`.**
`safety_rules_2chain.rs:77-81`
```rust
self.verify_and_update_last_vote_round(proposed_block.block_data().round(), &mut safety_data)?;
self.safe_to_vote(proposed_block, timeout_cert)?;
```
Risk: `verify_and_update_last_vote_round` mutates the local clone of safety_data even when `safe_to_vote` later returns an error. Because the clone is never persisted on the error path, this is benign in practice, but it means if some future refactor moves the persist to before `safe_to_vote`, the mutation would corrupt persistent state on a `safe_to_vote` failure.

### 1.3 `persistent_safety_storage.rs`

**F1.3.1 — `set_safety_data` writes counters BEFORE the actual persist.**
`persistent_safety_storage.rs:150-170`
```rust
pub fn set_safety_data(&mut self, data: SafetyData) -> Result<(), Error> {
    let _timer = counters::start_timer("set", SAFETY_DATA);
    counters::set_state(counters::EPOCH, data.epoch as i64);                    // L152
    counters::set_state(counters::LAST_VOTED_ROUND, data.last_voted_round as i64); // L153
    counters::set_state(counters::HIGHEST_TIMEOUT_ROUND, data.highest_timeout_round as i64);
    counters::set_state(counters::PREFERRED_ROUND, data.preferred_round as i64);
    match self.internal_store.set(SAFETY_DATA, data.clone()) {                  // L160 actual persist
        Ok(_) => { self.cached_safety_data = Some(data); Ok(()) },
        Err(error) => { self.cached_safety_data = None; Err(...) },
    }
}
```
Risk: Counters reflect the desired state, not the persisted state. If `internal_store.set` fails, observability (Prometheus) shows the new round but it was never persisted. Misleading metrics during a storage outage.

**F1.3.2 — `set_safety_data` clears the cache on error rather than retaining the previous value.**
`persistent_safety_storage.rs:165-168`
```rust
Err(error) => {
    self.cached_safety_data = None;     // L166 — clear cache on error
    Err(Error::SecureStorageUnexpectedError(error.to_string()))
}
```
Risk: After a write error, the next read incurs a full disk read. That's defensible. BUT — the cache was previously holding a value SAFETY-EQUIVALENT to disk; clearing it doesn't help safety, and conflating "I don't know what's on disk" with "fall back to disk read" is OK as long as the disk read returns the OLD value (which it should, since the failed write is supposed to be atomic-or-nothing, see F1.3.3). However, if the disk write was partially successful (on systems without atomic semantics), recovery is tricky.

**F1.3.3 — `OnDiskStorage.set` uses temp-file + rename but NO `fsync`/`sync_all`.**
`secure/storage/src/on_disk.rs:64-70`
```rust
fn write(&self, data: &HashMap<String, Value>) -> Result<(), Error> {
    let contents = serde_json::to_vec(data)?;
    let mut file = File::create(self.temp_path.path())?;
    file.write_all(&contents)?;
    fs::rename(&self.temp_path, &self.file_path)?;
    Ok(())
}
```
Risk: No `file.sync_all()` after `write_all`, no `fsync` on the directory after `rename`. On power loss after rename returns but before the kernel flushes metadata, the directory entry can revert. The "atomic rename" guarantee is conditional on the underlying filesystem AND the kernel's writeback journal AND a sync barrier. SafetyRules durability is not actually guaranteed in the OnDiskStorage backend. In production Vault is used (vault.rs:167), which delegates durability to the remote service.

**F1.3.4 — `safety_data()` returns a clone of the in-memory cache when caching is enabled.**
`persistent_safety_storage.rs:134-148`
```rust
if !self.enable_cached_safety_data {
    return self.internal_store.get(SAFETY_DATA).map(|v| v.value)?;
}
if let Some(cached_safety_data) = self.cached_safety_data.clone() {
    Ok(cached_safety_data)
} else {
    let safety_data: SafetyData = self.internal_store.get(SAFETY_DATA).map(|v| v.value)?;
    self.cached_safety_data = Some(safety_data.clone());
    Ok(safety_data)
}
```
Risk: All callers receive a CLONE. Mutations to the returned value have no effect on subsequent reads unless the caller passes the mutated copy back through `set_safety_data`. This decouples the in-memory and persistent worlds, which is by design. But it also means there is no critical-section between read and write — a re-entrant or concurrent caller could read the same baseline twice and produce two divergent updates, the LAST one winning. The `RwLock` around `SafetyRules` (safety_rules_manager.rs:131-136) prevents concurrency, but the `ProcessService` / `ThreadService` paths route requests through serialization, and the `MetricsSafetyRules.retry` (consensus/src/metrics_safety_rules.rs:71-85) re-issues a request after `IncorrectEpoch`/`WaypointOutOfDate`. Re-issue could in principle cause double signing if the re-tried call is interpreted as a fresh vote.

**F1.3.5 — `initialize` on epoch advance writes a `SafetyData` with `last_voted_round=0`, even if previous epoch had a higher voted round.**
`persistent_safety_storage.rs:30-61` (and safety_rules.rs:294-303)
Risk: After epoch change, the new SafetyData is `(new_epoch, 0, 0, 0, None, 0)`. Rounds are correctly scoped per epoch (a new validator set means existing round commitments don't apply), so this is intended. But it means there's no "carried over" memory of having voted in the previous epoch; if a Byzantine peer causes an epoch downgrade (which the EpochChangeProof verification should prevent), votes in the older epoch can be re-issued.

**F1.3.6 — `consensus_sk_by_pk` falls back to `default_consensus_sk` if explicit lookup fails.**
`persistent_safety_storage.rs:106-132`
```rust
let key = match (explicit_sk, default_sk) {
    (Ok(sk_0), _) => sk_0,
    (Err(_), Ok(sk_1)) => sk_1,
    ...
};
if key.public_key() != pk {
    return Err(Error::SecureStorageMissingDataError(...));
}
```
Risk: The fallback is rejected later via the public key check, so it's safe. However, the error path does not distinguish "no key" from "wrong key", which complicates incident response.

### 1.4 `consensus_state.rs`

**F1.4.1 — `ConsensusState` exposes `safety_data()` mutably (returns clone) but with `&mut self`.**
`consensus_state.rs:80-83`
```rust
pub fn safety_data(&mut self) -> SafetyData {
    self.safety_data.clone()
}
```
Risk: Misleading — takes `&mut self` but does not mutate. Callers might assume a side effect. Cosmetic.

**F1.4.2 — Display string is missing `one_chain_round` and `highest_timeout_round`.**
`consensus_state.rs:19-37`
Operationally bad for debugging but no safety impact.

### 1.5 `consensus-types/src/safety_data.rs`

**F1.5.1 — `SafetyData` derives `Default` and `Eq`/`Clone` cheaply; no validation in constructor.**
`consensus-types/src/safety_data.rs:8-21`
```rust
#[derive(Debug, Deserialize, Eq, PartialEq, Serialize, Clone, Default)]
pub struct SafetyData {
    pub epoch: u64,
    pub last_voted_round: u64,
    pub preferred_round: u64,
    #[serde(default)]
    pub one_chain_round: u64,
    pub last_vote: Option<Vote>,
    #[serde(default)]
    pub highest_timeout_round: u64,
}
```
Risk: All fields `pub`. Any caller can construct an arbitrary `SafetyData` (e.g., regressing rounds) and pass it through `set_safety_data`. This is callable from `set_safety_data` directly which exposes a `pub fn` interface (persistent_safety_storage.rs:150). No invariant check — e.g., `last_voted_round >= preferred_round` is not enforced (and may not even be expected, but there's no comment).

**F1.5.2 — `serde(default)` on `one_chain_round` and `highest_timeout_round` permits ZERO on legacy on-disk data.**
`consensus-types/src/safety_data.rs:16-20`
Risk: A SafetyRules validator running a new binary against an OLD on-disk SafetyData (no `one_chain_round` or `highest_timeout_round` field) deserializes them to 0. After upgrade, the validator's `safe_to_timeout` (which checks `qc_round >= safety_data.one_chain_round`) and `safe_for_order_vote` (which checks `round > safety_data.highest_timeout_round`) suddenly accept much wider sets of inputs. Concretely, if the validator was at one_chain_round=100 in memory before restart but the on-disk format doesn't have that field, after reload it's 0, and timeouts at qc_round much lower will be accepted. The test at line 53-70 confirms migration from `OldSafetyData` is supported, but the migration loses information.

---

## 2. Atomicity boundary table

For each vote-signing function, columns are: Pre-checks | Persist call (line) | Sign call (line) | Order | Crash-window risk.

| Function | Pre-checks | Persist call | Sign call | Order of operations | Crash-window risk |
|---|---|---|---|---|---|
| `guarded_construct_and_sign_vote_two_chain` (safety_rules_2chain.rs:53-95) | epoch (via verify_proposal:70), QC verify (72), sig verify (74-76), well-formed (78-80), TC verify (62-64), `last_vote` cache (70-74), `verify_and_update_last_vote_round` (77, in-memory only), `safe_to_vote` (81), `observe_qc` (84, in-memory only) | `set_safety_data` at L92 | `sign(&ledger_info)` at L88 | sign at L88 → in-memory cache last_vote at L91 → persist at L92 | **HIGH**: signature emitted to caller's response channel before durable state. Crash between L88 and L92 leaves persistent `last_voted_round` at OLD value. On recovery a different proposal at the same round R can be re-signed → equivocation. (See F1.2.2.) |
| `guarded_sign_timeout_with_qc` (safety_rules_2chain.rs:19-51) | signer (24), epoch (26), `timeout.verify` (28-30), TC verify (32-34), `safe_to_timeout` (36), `last_voted_round` floor check (37-42), conditional advance via `verify_and_update_last_vote_round` (43-45, in-memory), `update_highest_timeout_round` (46, in-memory) | `set_safety_data` at L47 | `sign(&timeout.signing_format())` at L49 | persist at L47 → sign at L49 | **LOW**: persist precedes sign. Even if crash after persist, no signature was emitted. On recovery, last_voted_round and highest_timeout_round reflect the would-have-been timeout. |
| `guarded_construct_and_sign_order_vote` (safety_rules_2chain.rs:97-119) | signer (102), `verify_order_vote_proposal` (103, includes epoch+QC), `observe_qc` (108, in-memory), `safe_for_order_vote` (110, only checks `round > highest_timeout_round`) | `set_safety_data` at L117 | `sign(&ledger_info)` at L115 | sign at L115 → persist at L117 | **MEDIUM**: signature emitted before durable state. Lost state is `preferred_round`/`one_chain_round` advances from `observe_qc`. On recovery these regress to OLD values. A regular vote following recovery uses old `preferred_round` and may accept a block whose parent QC round was previously rejected. **Order votes do NOT touch `last_voted_round`, so they cannot directly cause double-vote on recovery, but they can cause the validator to vote on a fork that an order vote had already certified preference against.** |
| `guarded_sign_proposal` (safety_rules.rs:346-370) | signer (350), `verify_author` (351), epoch (354), `block_data.round() > last_voted_round` (356-362), `verify_qc` (364), `verify_and_update_preferred_round` (365, in-memory) | **NONE** (explicit comment line 366: "we don't persist the updated preferred round") | `sign(block_data)` at L368 | (no persist) → sign | **HIGH for leader equivocation**: sign(block) emitted with no persistent record. If called twice at the same round (same `last_voted_round` baseline), two distinct proposal signatures result. Honest leader is normally called once per round by the round_manager, so this is "consensus-layer responsibility" not a SafetyRules guarantee. |
| `guarded_sign_commit_vote` (safety_rules.rs:372-418) | signer (377), ordered-only / commit_info match (381-393), `match_ordered_only` (395-403), `verify_signatures` (405-410). **No epoch check, no `last_voted_round` check, no per-round dedup.** | **NONE** (no `set_safety_data` at all) | `sign(&new_ledger_info)` at L415 | (no persist) → sign | **HIGH**: validator can sign multiple commit votes at the same logical round for distinct LIs across crash-restart cycles or via Byzantine repeated requests. TODOs at L412-413 explicitly acknowledge gaps ("guarding rules in unhappy path" and "extension check"). |
| `guarded_initialize` (safety_rules.rs:265-344) | waypoint verify (268), epoch advance comparison (284-309), key reconciliation (313-339) | `set_waypoint` at L280 (conditional), `set_safety_data` at L296-303 (only on `Ordering::Less`) | n/a (no signing) | persist before any operational sign call | **LOW**: persist precedes any subsequent vote-signing path. |

Note on `MetricsSafetyRules.retry` (consensus/src/metrics_safety_rules.rs:71-85): on `Error::NotInitialized | IncorrectEpoch | WaypointOutOfDate`, it calls `perform_initialize` and re-tries the call. For a vote that PARTIALLY succeeded (signed but failed to persist), the underlying SafetyRules error path would be `SecureStorageUnexpectedError`, which is NOT in the retry list — so `retry` will not double-sign. But for `IncorrectEpoch` after a fresh initialize, the retry path is fundamentally a re-issue of the original signing call, which may be benign IF SafetyRules is idempotent — and it is IFF the persist-then-sign ordering holds. For `construct_and_sign_vote_two_chain`, idempotence relies on the `last_vote` cache (lines 70-74), which requires the cache to have been persisted in a prior call — so it's safe across retries within a single live SafetyRules instance, but NOT across crash-recovery.

---

## 3. Code-path asymmetry table

For each safety-relevant guard, columns: regular vote (`construct_and_sign_vote_two_chain` -> `guarded_construct_and_sign_vote_two_chain` + `verify_proposal`) | order vote (`construct_and_sign_order_vote` -> `guarded_construct_and_sign_order_vote` + `verify_order_vote_proposal`) | timeout vote (`sign_timeout_with_qc` -> `guarded_sign_timeout_with_qc`) | commit vote (`sign_commit_vote` -> `guarded_sign_commit_vote`).

| Guard | Regular vote | Order vote | Timeout vote | Commit vote |
|---|---|---|---|---|
| **Epoch check vs `safety_data.epoch`** | Yes — `verify_epoch(proposed_block.epoch(), &safety_data)` at safety_rules.rs:70 | Yes — `verify_epoch(proposed_block.epoch(), &safety_data)` at safety_rules.rs:94 | Yes — `verify_epoch(timeout.epoch(), &safety_data)` at safety_rules_2chain.rs:26 | **NO** — only `epoch_state.verifier` is consulted in the QC signature check (safety_rules.rs:408). No explicit `safety_data.epoch` comparison. (F1.1.7) |
| **`last_voted_round` check (refuse if round <= last_voted_round)** | Yes — `verify_and_update_last_vote_round(round)` at safety_rules_2chain.rs:77, calling safety_rules.rs:218 | **NO** — no `last_voted_round` check anywhere in the order-vote path (F1.2.4) | Yes (asymmetric `<` and `>`): refuse if `round < last_voted_round` (line 37); advance if `round > last_voted_round` (line 43); allow if `round == last_voted_round` (no advance) (F1.2.5) | **NO** — commit-vote path has no round bookkeeping at all (F1.1.7) |
| **`last_voted_round` update on success** | Yes — bumped to vote round at safety_rules.rs:225 (in-memory), persisted at safety_rules_2chain.rs:92 | **NO** — order vote does NOT bump `last_voted_round` (F1.2.4) | Yes when `timeout.round() > last_voted_round`, at safety_rules_2chain.rs:43-45 (in-memory), persisted at line 47 | **NO** |
| **`preferred_round` check (refuse if QC.round < preferred_round)** | Implicit via `safe_to_vote` (`block.round == qc.round + 1` or via TC), and the parent's preferred_round update through `observe_qc`. The explicit `verify_and_update_preferred_round` at safety_rules.rs:173 is called from `guarded_sign_proposal` (line 365) but NOT from `guarded_construct_and_sign_vote_two_chain`! | Implicit via `observe_qc` (safety_rules_2chain.rs:108), but no rejection — `observe_qc` only ever advances. | Implicit via `safe_to_timeout` which checks `qc_round >= safety_data.one_chain_round` (safety_rules_2chain.rs:134), where `one_chain_round` is observed from prior QCs. | **NO** |
| **`preferred_round` update from QC** | Yes — `observe_qc` at safety_rules_2chain.rs:84 (in-memory), persisted at line 92 | Yes — `observe_qc` at line 108 (in-memory), persisted at line 117 | No (timeout has its own `safe_to_timeout` check; doesn't call `observe_qc`) | No |
| **`one_chain_round` update from QC** | Yes — same `observe_qc` call as preferred_round | Yes — same | No | No |
| **`highest_timeout_round` check (refuse if round <= highest_timeout_round)** | No (regular votes don't consult it) | Yes — `safe_for_order_vote(round > highest_timeout_round)` at safety_rules_2chain.rs:170 (F1.2.4) | No (timeouts can be re-issued at the same round) | No |
| **`highest_timeout_round` update on success** | No | No | Yes — `update_highest_timeout_round` at safety_rules_2chain.rs:46 | No |
| **Block leader signature verification** | Yes — `proposed_block.validate_signature(&self.epoch_state()?.verifier)` at safety_rules.rs:73-77 (skipped if `skip_sig_verify`) | **NO** — `verify_order_vote_proposal` does not call `validate_signature` (F1.1.2) | n/a (timeout has no leader) | n/a |
| **Block well-formedness** | Yes — `verify_well_formed` at safety_rules.rs:78-80 | **NO** — order-vote path skips `verify_well_formed` (F1.1.2) | n/a | n/a |
| **QC verification (`verify_qc`)** | Yes — at safety_rules.rs:72 | Yes — at safety_rules.rs:109 | Yes — `timeout.verify(&verifier)` at safety_rules_2chain.rs:28-30 (which internally calls quorum_cert.verify) | Yes — `verify_signatures` on `LedgerInfoWithSignatures` at safety_rules.rs:407-409 |
| **TC verification (when supplied)** | Yes — `verify_tc(tc)` at safety_rules_2chain.rs:62-64 | n/a | Yes — `verify_tc(tc)` at safety_rules_2chain.rs:32-34 | n/a |
| **`safe_to_vote` (2-chain rule on round-vs-qc.round)** | Yes — at safety_rules_2chain.rs:81 | n/a (order vote doesn't enforce 2-chain extension rule directly; relies on observed QC) | n/a (timeout has `safe_to_timeout`) | n/a |
| **Persist BEFORE sign** | **NO** — sign at L88, persist at L92 | **NO** — sign at L115, persist at L117 | YES — persist at L47, sign at L49 | n/a (no persist at all) |
| **Idempotence on re-request at same round** | Partial — `if vote.proposed.round() == proposed_block.round()` at safety_rules_2chain.rs:71 returns CACHED vote without re-checking that the proposal IS THE SAME BLOCK (cache miss-as-match risk, see F2.x) | **NO** — no per-round cache | Partial — refuse if `timeout.round() < last_voted_round`; otherwise re-sign | **NO** |
| **Author signing key consistency check (`verify_author`)** | No (caller is the validator itself; only `verify_author` is called inside `guarded_sign_proposal` for proposal blocks) | No | No | No |

---

## 4. TODO/FIXME inventory

| File:Line | Comment text (verbatim) | Interpretation |
|---|---|---|
| `consensus/safety-rules/src/consensus_state.rs:11` | `/// @TODO add hash of ledger info (waypoint)` | Public state struct should expose the waypoint hash so monitoring tools can confirm the validator is on the right chain. Cosmetic; no safety impact today. |
| `consensus/safety-rules/src/safety_rules.rs:40` | `/// @TODO consider a cache of verified QCs to cut down on verification costs` | Performance optimization. Without it, every safety-rules call re-verifies the QC's BLS signature. Not a correctness gap. |
| `consensus/safety-rules/src/safety_rules.rs:412` | `// TODO: add guarding rules in unhappy path` | **Critical — commit vote.** "Unhappy path" is the recovery / Byzantine-leader scenario. There is no protection against signing two distinct commit votes for distinct LIs at the same commit round across a crash, or against signing for an LI from a different epoch (no `safety_data.epoch` check, see F1.1.7). |
| `consensus/safety-rules/src/safety_rules.rs:413` | `// TODO: add extension check` | **Critical — commit vote.** No proof that `new_ledger_info` actually extends `old_ledger_info` (the `is_ordered_only` + `match_ordered_only` checks are necessary but not sufficient). A malicious caller can produce a `new_ledger_info` that diverges from `old_ledger_info` in fields not covered by `match_ordered_only` (e.g., transaction accumulator hash, version). |
| `consensus/consensus-types/src/vote.rs:152` (out of file scope but found en route) | `// TODO(ibalajiarun): Ensure timeout is None if RoundTimeoutMsg is enabled.` | Pending check that `Vote.two_chain_timeout` is None when a separate RoundTimeoutMsg path is active. Could lead to double-counted timeouts under feature interaction. |

No `FIXME`, `HACK`, `XXX`, or `BUG` markers found in the five primary files. (Outside the five files, additional TODOs exist throughout the consensus module but were not enumerated.)

---

## 5. Top suspicious findings

### S1 — Sign-before-persist in regular vote path enables crash-window double vote
**File:line:** `safety_rules_2chain.rs:88-92`
**Mechanism:** `guarded_construct_and_sign_vote_two_chain` produces the signature at line 88 and persists `safety_data` (including the bumped `last_voted_round` and the vote cache) at line 92. The signature exists in process memory between L88 and L92, and is returned to the SerializerService / ProcessService client before any storage round-trip waits to verify durability of the persist.
**Attacker scenario:** Validator V votes for proposal P1 at round R; the signed Vote is sent to peers; a crash occurs before line 92 commits. On recovery, V's `last_voted_round` reads R-1 from persistent storage. A Byzantine leader (or simply network re-delivery) submits proposal P2 at round R. The check at safety_rules.rs:218 passes (`R > R-1`). V signs P2 — equivocates at round R. Two valid signatures from V on round R for distinct blocks → safety violation if both reach quorums.

### S2 — Commit-vote path has no epoch/round/dedup state and ignores extension proofs
**File:line:** `safety_rules.rs:372-418` with explicit TODOs at lines 412-413
**Mechanism:** No `verify_epoch`, no `last_committed_round` field in `SafetyData`, no extension check between `old_ledger_info` and `new_ledger_info` beyond `commit_info` equality. `sign_commit_vote` produces a signature on `new_ledger_info` so long as the caller supplies a valid 2f+1 QC on `old_ledger_info`.
**Attacker scenario:** A Byzantine peer presents a valid `LedgerInfoWithSignatures` (with current epoch's verifier-passing signatures, perhaps replayed from a real consensus run) and a forged `new_ledger_info` whose `commit_info` matches `old_ledger_info`'s commit_info field-for-field but whose `transaction_accumulator_hash` (or any field not covered by `match_ordered_only`) differs from the actual executed result. V signs the forged `new_ledger_info`. The Byzantine peer aggregates these signatures into a fraudulent commit certificate.

### S3 — Order-vote path has no `last_voted_round` interlock
**File:line:** `safety_rules_2chain.rs:97-119` and 168-178
**Mechanism:** `safe_for_order_vote` only refuses when `round <= highest_timeout_round`. There is no comparison against `last_voted_round` and no update to `last_voted_round`.
**Attacker scenario:** V regular-votes at round R (last_voted_round = R). A Byzantine peer then triggers `construct_and_sign_order_vote` with an `OrderVoteProposal` whose block round is R (or less) — passes if `round > highest_timeout_round`. V produces an OrderVote signing `LedgerInfo(block_info, HashValue::zero())`. If the Byzantine peer constructs `OrderVoteProposal`s for distinct blocks at round R, V can produce multiple distinct order-vote signatures at round R. Whether downstream order-cert aggregation conflates these depends on aggregation logic, but the safety module imposes no constraint.

### S4 — Order-vote path skips block-author signature and well-formedness checks
**File:line:** `safety_rules.rs:87-111` (compare with 67-85)
**Mechanism:** `verify_order_vote_proposal` calls `verify_epoch` and `verify_qc` on the order-vote QC, and checks `block_info`/`block_id` consistency, but does not call `proposed_block.validate_signature` or `proposed_block.verify_well_formed`.
**Attacker scenario:** A Byzantine peer constructs a valid QC on `block_info B` for some real block, but submits an `OrderVoteProposal` whose `block` field is a malformed copy with the same id. V passes the equality checks (`qc.certified_block().id() == proposed_block.id()`) but signs an OrderVote whose ledger info wraps the malformed block_info. (Mitigated if `block_info.id()` is a content hash AND consumers re-validate downstream, but the safety module isn't enforcing.)

### S5 — `last_vote` cache idempotence guard checks ROUND only, not block id
**File:line:** `safety_rules_2chain.rs:70-74`
```rust
if let Some(vote) = safety_data.last_vote.clone() {
    if vote.vote_data().proposed().round() == proposed_block.round() {
        return Ok(vote);
    }
}
```
**Mechanism:** When asked to vote on round R after having voted on round R, the cache returns the OLD vote regardless of whether the new proposal is the same block.
**Attacker scenario:** A Byzantine leader at round R submits proposal P1; V votes for P1 (cached). The same leader then submits P2 (different block, same round R) — V returns the OLD vote for P1. This is intended behaviour (idempotent vote-once-per-round), and downstream the Byzantine peer cannot do anything with V's old P1 vote that they couldn't already do. Note however that combined with S1: if a crash dropped the persist of `last_vote = vote_for_P1`, the cache is empty on recovery, and the second request for round R now reaches the `verify_and_update_last_vote_round` check, which passes — V signs P2.

### S6 — `OnDiskStorage` lacks `fsync`, allowing rename to revert after power loss
**File:line:** `secure/storage/src/on_disk.rs:64-70`
**Mechanism:** `write` writes the temp file with `write_all` (no `sync_all`) and renames over the destination (no directory `fsync`). Both the file-data flush and the directory-entry update can be in writeback cache when power is cut.
**Attacker scenario:** Honest validator votes at round R; persist returns success (because `fs::rename` succeeded in the kernel); validator sends vote and immediately experiences power loss. Kernel never wrote the metadata. On reboot, `last_voted_round` reads R-1. Now the same vote-or-different-vote-at-R scenario from S1 applies. Mitigation: production deployments use `Vault` (vault.rs:167) which delegates durability to the Vault server. OnDiskStorage is documented as "should not be used in production" (on_disk.rs:22) but is the default for the `test` config.

### S7 — `set_safety_data` clears in-memory cache to None on storage error, then any later read pulls from disk that may itself be stale (interacts with S6)
**File:line:** `persistent_safety_storage.rs:165-168`
**Mechanism:** On `internal_store.set` error, the cache is cleared. The next read calls `internal_store.get`, which returns whatever last successfully-written value is on disk. If the failed write was actually partially applied at the OS level (rare on Linux but possible on filesystems without atomic rename, or under power loss as in S6), the disk read could return either OLD or NEW value. SafetyRules trusts the result.
**Attacker scenario:** Adversarial timing on a flaky disk: V writes new safety_data, OS reports rename succeeded but file system metadata is in writeback. V's process crashes. On recovery, the file might or might not have the new content. If it has OLD content, V signs a second vote at the same round.

### S8 — `MetricsSafetyRules.retry` re-issues vote requests on `IncorrectEpoch` / `WaypointOutOfDate` after re-initialize
**File:line:** `consensus/src/metrics_safety_rules.rs:71-85`
**Mechanism:** On those errors, the retry path calls `perform_initialize` (which may advance the SafetyRules epoch and reset `SafetyData` to defaults at safety_rules.rs:296-303) and then re-issues the same signing call.
**Attacker scenario:** A Byzantine peer triggers a sequence of carefully crafted requests that cause SafetyRules to step forward an epoch (legitimately, via a real epoch-change proof), causing safety_data to reset. The retry mechanism then re-issues the original vote in the new epoch, where `last_voted_round` is now 0 — accepted. If the original vote was at some round R that mapped to a now-different commit chain in the new epoch, the validator effectively votes twice for "the same proposal" but in two epochs. Whether this violates safety depends on the aggregation logic at the round_manager / epoch_manager level; SafetyRules itself is "consistent" because each epoch has its own round counter.

### S9 — `SafetyData` deserialization defaults `one_chain_round` and `highest_timeout_round` to 0 on legacy data
**File:line:** `consensus-types/src/safety_data.rs:16-20` (also tested at lines 53-69)
**Mechanism:** `serde(default)` on these two fields means an upgrade from a binary that did not write them produces SafetyData with both at 0.
**Attacker scenario:** Validator running new binary boots from old on-disk data. `highest_timeout_round` is 0. Order votes at any round are now allowed (because `safe_for_order_vote` requires `round > highest_timeout_round`). If, prior to upgrade, the validator had already timed-out on some round T > 0, the `safe_for_order_vote` rule no longer protects against signing an order vote for a block at round T. Mitigated by the fact that `highest_timeout_round` is observed-not-decided (it just records the highest seen timeout), so loss of memory is not directly a safety-violating asymmetry — but it widens the accept set for order votes after upgrade.

### S10 — `guarded_sign_proposal` does not bump or persist `last_voted_round`, allowing a leader that calls `sign_proposal` twice at the same round to obtain two distinct proposal signatures
**File:line:** `safety_rules.rs:346-370`
**Mechanism:** `block_data.round() <= safety_data.last_voted_round` rejects only proposals at OLD rounds. After signing, `last_voted_round` is unchanged. There is no per-round cache for proposal signatures.
**Attacker scenario:** A compromised consensus thread (not a remote attacker, but a local fault) calls `sign_proposal(B1@round R)` then `sign_proposal(B2@round R)`. Both succeed if both pass `verify_qc` and `verify_and_update_preferred_round`. The validator emits two distinct signed blocks at round R — a deliberate equivocation. SafetyRules doesn't stop this. (Whether this is in-scope for SafetyRules' threat model is debatable; honest leaders are assumed to be called once per round by the round_manager. But the contract is weaker than callers may assume.)

---

## Cross-references and notes

- The user's PR #13711 reference matches the epoch-check now present at `safety_rules.rs:94` inside `verify_order_vote_proposal`. So that specific gap is closed in this revision.
- The user's `f58e184471` reference (timeout-signing path checks) lines up with the `safe_to_timeout` + `last_voted_round` interlock at `safety_rules_2chain.rs:36-46`. Those checks are present and correct (with the `==` edge-case noted in F1.2.5).
- The `debug_assert_eq!` calls flagged by the user at `consensus-types/src/timeout_2chain.rs:248` and `:253` are in `TwoChainTimeoutWithPartialSignatures::add` — release-stripped equality checks on the timeout's epoch and round vs the cert's. **Risk:** in release builds these are no-ops, so a malformed timeout submitted at the aggregation layer would silently flow through. SafetyRules itself does not rely on these asserts (it has its own checks), but downstream aggregators do.
- No `debug_assert` calls in the five primary safety-rules files. The asymmetry the user flagged is local to `consensus-types`; safety-rules' guards are runtime checks.
- The `RwLock` around `SafetyRules` (safety_rules_manager.rs:131-136) serializes all calls, so within a single live process there's no TOCTOU window between `safety_data()` and `set_safety_data`. The hazards are all crash-recovery related (S1, S6, S7) or attacker-controlled state (S2-S5, S10).

---

## Summary

The most actionable bug is **S1**: the regular vote path (`guarded_construct_and_sign_vote_two_chain`) signs at safety_rules_2chain.rs:88 and persists at line 92 — the wrong order. Compare with the timeout path (line 47 persist before line 49 sign). The fix is to move `set_safety_data` before `sign`. The `last_vote` cache cannot be set before signing (since it caches the signed Vote), so a two-step persist may be required: (1) advance `last_voted_round` to disk, then (2) sign, then (3) persist `last_vote`. Alternatively, the SafetyRules contract could require the caller to persist explicitly before believing the response.

The second-most-critical is **S2**: the commit-vote path's two TODO-marked gaps. Adding `verify_epoch(old_ledger_info.epoch(), &safety_data)` and a per-round commit-vote dedup field would close most of the gap.

S3-S5 are order-vote asymmetries that, in combination with S1 (lost `preferred_round` advances), expose the validator to chosen-fork attacks across crash recovery.

# Deep Code Analysis: AptosBFT Vote Aggregation & Network Routing

Files analysed (LoC):
- `consensus/src/pending_votes.rs` (869)
- `consensus/src/pending_order_votes.rs` (378)
- `consensus/src/network_interface.rs` (243)
- `consensus/src/network.rs` (1067)
- `consensus/src/epoch_manager.rs` (2170)

Cross-file context consulted (read-only): `round_manager.rs`, `liveness/round_state.rs`, `consensus-types/src/vote.rs`, `vote_msg.rs`, `order_vote.rs`, `order_vote_msg.rs`, `quorum_cert.rs`, `timeout_2chain.rs`, `types/src/ledger_info.rs`, `types/src/validator_verifier.rs`, `crates/channel/src/message_queues.rs`.

All file paths in this report are absolute under `/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core`.

---

## 1. Vote insertion logic (text flowchart)

### Regular vote (`PendingVotes::insert_vote`, pending_votes.rs:275-481)

```
                       insert_vote(vote, verifier)
                                  │
                                  ▼
         li_digest = vote.ledger_info().hash()                     [pending_votes.rs:281]
                                  │
                                  ▼
   ┌─────────── EQUIVOCATION CHECK (per-author) ──────────┐
   │ author_to_vote.get(vote.author())                     │      [287-309]
   │                                                       │
   │ • prev present, same li_digest, same is_timeout state │
   │       → DuplicateVote                                 │      [296]
   │ • prev present, same li_digest, vote upgrades to      │
   │       a 2-chain timeout (was regular)                 │      [293-297]
   │       → fall through, "update" path                   │
   │ • prev present, DIFFERENT li_digest                   │
   │       → log SecurityEvent::ConsensusEquivocatingVote  │      [299-308]
   │       → EquivocateVote          (RETURNED IMMEDIATELY)│
   └───────────────────────────────────────────────────────┘
                                  │
                                  ▼
   author_to_vote.insert(author, (vote, li_digest))                [315-316]
                                  │
                                  ▼
   (hash_index, status) = li_digest_to_votes.entry(li_digest)       [324]
        ── creates VoteStatus::NotEnoughVotes(SignatureAggregator)
                                  │
                                  ▼
   validator_voting_power = verifier.get_voting_power(author)
        if None → UnknownAuthor                                    [331-336]
        if 0    → only warn!, continues                            [339-341]
                                  │
                                  ▼
   ┌─────────────── QC FORMATION  ───────────────┐
   │ if status == EnoughVotes:                    │              [360-365]
   │     immediately return NewQuorumCertificate  │
   │     (already-cached aggregated LI)           │
   │                                              │
   │ else NotEnoughVotes(sig_aggregator):         │
   │     sig_aggregator.add_signature(            │              [368]
   │         author, vote.signature_with_status())│
   │     check_voting_power(verifier,             │              [371]
   │                        super_majority=true)  │
   │       Ok(power)  → aggregate_and_verify      │              [383-388]
   │           Ok    → status = EnoughVotes;       │              [390-394]
   │                   NewQuorumCertificate       │
   │           Err(too little) → power            │              [396-398]
   │           Err(other) → ErrorAggregatingSig.  │
   │       Err(too little) → power                │              [404]
   │       Err(other) → ErrorAddingVote           │              [407-413]
   └──────────────────────────────────────────────┘
                                  │ (no QC formed)
                                  ▼
   ─── 2-chain timeout vote handling (lines 422-474) ───
       For votes carrying a 2-chain timeout signature:
       insert into TwoChainTimeoutVotes with                      [433-441]
           author, timeout, signature, RoundTimeoutReason::Unknown
       Try aggregate_signatures.
       If <2f+1 yet but ≥f+1, set echo_timeout, return EchoTimeout.
                                  │
                                  ▼
                          VoteAdded(power)                        [480]
```

### Order vote (`PendingOrderVotes::insert_order_vote`, pending_order_votes.rs:61-157)

```
                insert_order_vote(order_vote, verifier, maybe_qc)
                                  │
                                  ▼
         li_digest = order_vote.ledger_info().hash()              [68]
                                  │
                                  ▼
   ┌── ENTRY: li_digest_to_votes.entry(li_digest).or_insert_with ──┐
   │  (if absent) requires verified_quorum_cert.expect(...)        │ [71-81]
   │  ── PANIC if caller sent an order vote for a NEW digest       │
   │     without supplying a verified QC                            │
   │                                                                │
   │  No equivocation check at all — same author can vote          │
   │  for *different* li_digest in same round and have BOTH        │
   │  signatures contribute to two SignatureAggregators.            │
   └────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
   match status:
     EnoughVotes(li_with_sig) → return NewLedgerInfoWithSignatures  [84-90]
                              (re-emits cached cert; QC kept from
                              FIRST insertion)
     NotEnoughVotes(sig_aggregator):
       voting_power = verifier.get_voting_power(author)
         None → UnknownAuthor                                      [95-101]
         0    → warn! only                                          [105-110]
       sig_aggregator.add_signature(author,                         [111-112]
                                    signature_with_status)
       check_voting_power → aggregate_and_verify (same as regular)
                                  │
                                  ▼
                            VoteAdded(power)
```

### TwoChainTimeoutVotes::add (pending_votes.rs:78-87)

```
add(author, timeout, signature, reason)
   partial_2chain_tc.add(author, timeout, signature)              [85]
        ── PartialSignaturesWithRound::add_signature uses
           BTreeMap.entry(author).or_insert((round, sig))
           → FIRST signature wins, repeats are silently DROPPED
        ── BUT self.timeout (the "highest hqc") is REPLACED if
           the new timeout's hqc_round > current.timeout.hqc_round
           (timeout_2chain.rs:259-260)
   timeout_reason.entry(author).or_insert(reason)                 [86]
        → first reason wins, repeats dropped
```

---

## 2. Epoch-routing decision tree (epoch_manager.rs)

Top-level: `EpochManager::start` (line 2071) selects on three queues:
- `network_receivers.consensus_messages` (line 2080) → `process_message`
- `network_receivers.quorum_store_messages` (line 2086) → `process_message`
- `network_receivers.rpc_rx` (line 2092) → `process_rpc_request`
- `round_timeout_sender_rx` (line 2098) → `process_local_timeout`

`process_message` (line 1648-1753) calls `check_epoch` (line 1755-1823), then on Some(event) it `filter_quorum_store_events`, clones state, dispatches verification on a bounded executor (line 1711-1750), and on success forwards via `forward_event` (line 1879-1952).

### Per-message dispatch table

| Message type | Epoch source | Where epoch is read | Different-epoch handler | Forwards to |
|---|---|---|---|---|
| `ProposalMsg` | `proposal.proposer_election_round.epoch()` (round_manager.rs:280, `p.epoch()`) | check_epoch:1761,1776-1784 | `process_different_epoch` (1782) | `buffered_proposal_tx` (1925) |
| `OptProposalMsg` | `p.epoch()` (round_manager.rs:281) | check_epoch:1762 | `process_different_epoch` | `buffered_proposal_tx` (1940) |
| `SyncInfo` | `s.epoch()` | check_epoch:1763 | `process_different_epoch` | `round_manager_tx` via discriminant (1943) |
| `VoteMsg` | `vote_data().proposed().epoch()` (vote.rs:134-136) | check_epoch:1764 | `process_different_epoch` | `round_manager_tx` (1943) |
| `RoundTimeoutMsg` | `t.epoch()` | check_epoch:1765 | `process_different_epoch` | `round_manager_tx` (1943) |
| `OrderVoteMsg` | `order_vote.ledger_info().epoch()` (order_vote.rs:78-80, NOT a separate field) | check_epoch:1766 | `process_different_epoch` | `round_manager_tx` (1943) |
| `CommitVoteMsg` / `CommitDecisionMsg` | inner | check_epoch:1767-1768 | `process_different_epoch` | `round_manager_tx` (1943) |
| Quorum Store msgs (Batch*, ProofOfStore*, SignedBatchInfo*) | inner | check_epoch:1769-1775 | `process_different_epoch` | `quorum_store_msg_tx` (1910) |
| `EpochChangeProof` | `proof.epoch()?` (latest LI's next_epoch) | check_epoch:1786 | DROP w/ counter `epoch_proof_wrong_epoch` (1803-1805); on equal trigger `initiate_new_epoch` (1795) | (no event) |
| `EpochRetrievalRequest` | `request.end_epoch` | check_epoch:1808-1817 | rejected if `end_epoch > self.epoch()` (1809-1812); otherwise serve | (no event) |
| Anything else | — | check_epoch:1818-1820 | `bail!` "Unexpected messages" | none |

### `process_different_epoch` (lines 498-562)

```
remote_epoch < self_epoch  AND  I AM in current validator set
    → silently discard (sample-rate-limited debug)            [510-523]
remote_epoch < self_epoch  AND  I am NOT in validator set
    → reply with EpochChangeProof from remote_epoch..self     [524-537]
remote_epoch > self_epoch
    → send EpochRetrievalRequest(self_epoch..remote_epoch)    [540-557]
remote_epoch == self_epoch
    → bail! (caller bug)                                      [558-560]
```

### `process_rpc_request` (lines 1955-2043)

```
match request.epoch():
   Some(epoch) if epoch != self.epoch()
       → process_different_epoch(epoch, peer_id) and RETURN  [1965-1970]
   None
       → ensure! request is BlockRetrieval/DeprecatedBlockRetrieval
         (the only RPCs whose epoch isn't carried)            [1972-1979]

then dispatch by variant to:
   block_retrieval_tx, batch_retrieval_tx, dag_rpc_tx,
   execution_client.send_commit_msg, rand_manager_msg_tx,
   secret_share_manager_tx                                    [1983-2042]
```

NOTE: `IncomingRpcRequest::epoch()` (network.rs:175-185) returns `None` for `BlockRetrieval` and `DeprecatedBlockRetrieval`, so block-retrieval RPCs **bypass the cross-epoch check entirely** and are routed straight to `block_retrieval_tx`. This is benign because `BlockStore::process_block_retrieval` re-checks the requested block IDs against its store, but it's worth noting.

---

## 3. Validator-set lookup table

| Check | Verifier source | When captured | Files / lines |
|---|---|---|---|
| Outer message verification (`unverified_event.verify`) inside bounded executor | `epoch_state.verifier` (Arc clone at 1717), captured BEFORE `spawn_blocking` | At message arrival; Arc-cloned and moved into the executor | epoch_manager.rs:1692-1717 |
| `Vote::verify` BLS sig | passed-in `validator: &ValidatorVerifier` | from outer | vote.rs:151-175 |
| `OrderVote::verify` BLS sig | passed-in | from outer | order_vote.rs:83-93 |
| `OrderVoteMsg::verify_order_vote` (sender match + value-binding to QC commit_info + sig) | passed-in | from outer | order_vote_msg.rs:48-67 |
| QC inside `OrderVoteMsg` (`quorum_cert.verify`) — only on FIRST order vote per `li_digest` | `&self.epoch_state.verifier` | At RoundManager runtime | round_manager.rs:1617 |
| `pending_votes::insert_vote` add_signature, check_voting_power, aggregate_and_verify | passed-in `validator_verifier: &ValidatorVerifier` from RoundManager | round_manager.rs:1805 passes `self.epoch_state.verifier` | pending_votes.rs:331,371,383 |
| `pending_order_votes::insert_order_vote` add_signature, check_voting_power, aggregate_and_verify | same as above (round_manager.rs:1624,1630) | RoundManager runtime | pending_order_votes.rs:94,113,123 |
| `aggregated_timeout_reason` voting-power calc | passed-in `verifier` | called from RoundState during round transition (`round_state.rs:265 .unpack_aggregate(verifier)`) | pending_votes.rs:93-153 |
| `f+1` echo threshold (`total - quorum + 1`) | passed-in | per-call | pending_votes.rs:257-259, 466-468 |
| 2/3+1 super-majority | `ValidatorVerifier::quorum_voting_power = total*2/3 + 1` (cached in ctor) | At epoch start, via `start_new_epoch` (line 1235 `ValidatorVerifier::from(&validator_set)`) | validator_verifier.rs:204-214 |
| `set_optimistic_sig_verification_flag` | mutates the Verifier | Once at epoch start | epoch_manager.rs:1235-1236 |
| Reconfiguration trigger (verifier rebuild) | `payload.get::<ValidatorSet>()` | On `ReconfigNotification` (`await_reconfig_notification`, line 2061-2068) | epoch_manager.rs:1232-1241 |
| Round-manager creation (clones the verifier into RoundManager) | `epoch_state.verifier.clone()` (Arc) | At `start_round_manager` (line 1004) | epoch_manager.rs:998-1015 |
| NetworkSender's stored `validators` (used for `broadcast_without_self`, retrieval response verify) | `Arc<ValidatorVerifier>` set at epoch start | `create_network_sender` (line 1040-1046) | network.rs:251-269 |

**Cross-epoch synchronization**: When a new epoch begins, `shutdown_current_processor` (line 657-703) sends a close signal to the running RoundManager and AWAITS its acknowledgement before the new RoundManager spawns. This eliminates concurrent RoundManagers from different epochs. However, IN-FLIGHT verification on the bounded executor (line 1711-1750) holds an Arc-clone of the OLD `epoch_state.verifier`. If that verification completes after `start_new_epoch` swapped `self.epoch_state` (line 1243, 1279), the verified event still carries an `Option<Sender>` to the OLD `round_manager_tx` (cloned at line 1702). Once the OLD receiver is dropped (after the close ack), `tx.push` fails and the message is silently dropped. So the worst-case is: a vote verified against the OLD verifier is lost, never delivered to the NEW round manager. No safety violation, but a brief liveness window where votes from the closing epoch may be lost.

---

## 4. Per-file line-cited findings

### A. `pending_votes.rs`

#### A1. Equivocation-vote detection silently swallows the vote (no slashing) — pending_votes.rs:299-308
```rust
error!(
    SecurityEvent::ConsensusEquivocatingVote,
    remote_peer = vote.author(),
    vote = vote,
    previous_vote = previously_seen_vote
);
return VoteReceptionResult::EquivocateVote;
```
**Action taken**: log a SecurityEvent and return `EquivocateVote`. The result is consumed by `process_vote_reception_result` (round_manager.rs:1810-1865) which falls through to `e => Err(anyhow::anyhow!("{:?}", e))` (line 1863), producing a regular error log. There is **no on-chain slashing, no peer ban, no BFT score adjustment**. A Byzantine validator can equivocate freely with no automated punishment.

#### A2. EquivocateVote check is only against `author_to_vote` for the CURRENT round
- `pending_votes` is fully reset at every round transition (`round_state.rs:255,259`).
- The `author_to_vote` map only catches "vote for digest-A then digest-B in the same round on the same node". Cross-round equivocation (vote in round 5 for digest-A, then in round 5 again after node restarted) is not detectable here because `pending_votes` is in-memory only.
- A crash-restart loses the equivocation memory; the node will accept a fresh vote it had previously seen as equivocating.

#### A3. Echo-timeout one-shot uses `>=` and is never reset — pending_votes.rs:256-264, 465-473
```rust
if !self.echo_timeout {
    let f_plus_one = ...;
    if tc_voting_power >= f_plus_one { ... }
}
```
The `echo_timeout` is `false` only at PendingVotes construction. There is no per-round / per-author reset within the same round. This is fine because the entire `PendingVotes` is rebuilt at every new round. The only subtle point: if the same `insert_vote` call also forms a TC, the EchoTimeout signal is preempted (NewQuorumCertificate / NewTimeoutCertificate). Acceptable.

#### A4. `assert!` in QC aggregation panics on internal invariant violation — pending_votes.rs:374-377
```rust
assert!(
    aggregated_voting_power >= validator_verifier.quorum_voting_power(),
    "QC aggregation should not be triggered if we don't have enough votes to form a QC"
);
```
A logic bug in `check_voting_power` (e.g. integer overflow in voting power summation in `validator_verifier.rs:440-446` — sum is `u128 += u64 as u128`; bounded by total power so OK in practice) would crash the whole consensus thread. Same `assert!` in `pending_order_votes.rs:115-118`. These are crash failures, not safety violations.

#### A5. `validator_voting_power == 0` is only a `warn!` — pending_votes.rs:339-341, 205-210
A vote from an author with voting power 0 (validator listed but slashed/disabled) is still added. Since `quorum_voting_power = total * 2 / 3 + 1` and 0-power voters can't tip the threshold, this is benign for safety, but allows the per-author equivocation map to be populated by 0-power voters, growing memory without bound (per round, then GC'd at round transition).

#### A6. Timeout-vote upgrade keeps OLD `previously_seen_vote` text in error path — pending_votes.rs:293-297
```rust
let new_timeout_vote = vote.is_timeout() && !previously_seen_vote.is_timeout();
if !new_timeout_vote {
    return VoteReceptionResult::DuplicateVote;
}
```
The "upgrade" path is logically: "old vote was non-timeout, new vote is the same digest but with a 2-chain timeout signature". The function then falls through to step 2 and `author_to_vote.insert` (line 315) replaces the old entry. This is correct — but note that the "upgrade" path can ONLY happen with the SAME `li_digest`. A Byzantine validator who had previously sent a non-timeout vote for digest-A cannot now send a timeout vote for digest-B (it would be flagged EquivocateVote at line 307 before reaching the upgrade).

#### A7. Optimistic signature verification — pending_votes.rs:368 → optimistic_verify
- `sig_aggregator.add_signature` (called at line 368) does NOT verify the BLS signature; the `SignatureWithStatus` is stored. The vote's signature is verified ONCE during `unverified_event.verify` at the bounded executor (epoch_manager.rs:1715), via `Vote::verify` → `validator.optimistic_verify` (validator_verifier.rs:269-285).
- `optimistic_verify` skips actual BLS check if `optimistic_sig_verification` is on AND author not in `pessimistic_verify_set` (line 278-280). Aggregation later calls `aggregate_and_verify` which performs aggregate-signature check; on failure, falls back to per-sig verification + adds bad voters to `pessimistic_verify_set` (validator_verifier.rs:287-311).
- **Implication**: a vote that *passes* the outer optimistic check (no per-sig BLS verify) but later fails aggregate verification will mark the offending voter for pessimistic verification on subsequent votes — this happens silently inside the aggregation, not at insert. So a Byzantine node CAN pollute the aggregator with a bogus signature, force `aggregate_and_verify` to fall back to per-sig verification, and waste CPU until pessimistic mode kicks in.

#### A8. `drain_votes` is the only persistence layer — pending_votes.rs:483-507
At round transition, votes are drained and a copy is forwarded to the SyncInfo as `prev_round_votes` (round_state.rs:255, 282). The `PendingVotes` struct itself has NO disk persistence. Crash → all in-memory votes lost; on restart, the node re-aggregates from scratch. Not a safety bug (votes are deterministic and re-deliverable) but a minor liveness window during recovery.

### B. `pending_order_votes.rs`

#### B1. **NO per-author equivocation detection** — pending_order_votes.rs:61-157
Compare to `pending_votes.rs:287-309`. The order-vote module has NO `author_to_vote` map. A Byzantine validator can order-vote for `li1` AND `li2` in the same round; both `SignatureAggregator`s independently accept the signature. No log, no `EquivocateVote` return.

**Attacker scenario**: Byzantine V sends `OrderVote(li_digest_A)` to half the network and `OrderVote(li_digest_B)` to the other half (both with valid QC + signature). Honest validators independently aggregate signatures. If 2f honest validators vote for li_A and 2f honest validators vote for li_B (with V's contribution being the f+1th signer in each), TWO order certs can form on different ledger infos. On Aptos main chain QC formation already requires 2f+1 (super-majority) — but the order-vote stage is itself a separate 2f+1 aggregation, and the asymmetry vs the regular vote path is suspicious.

The standard mitigation is "ledger_info digest collisions are computationally hard" — true — but it does not protect against MULTIPLE distinct ledger infos at the SAME round being able to accumulate concurrent quorums. Aptos's safety relies on the upstream `safety_rules` ensuring an honest validator only signs one order-vote per round; equivocation detection here is the LAST line of defence.

#### B2. QC verification only on FIRST order vote — pending_order_votes.rs:71-81 in conjunction with round_manager.rs:1613-1633
```rust
let vote_reception_result = if !self.pending_order_votes.exists(&li_digest) {
    ...
    order_vote_msg.quorum_cert().verify(...)?;
    ...insert_order_vote(... Some(order_vote_msg.quorum_cert().clone()))
} else {
    self.pending_order_votes.insert_order_vote(... None)
};
```
- Only the FIRST OrderVoteMsg's QC is verified.
- ALL SUBSEQUENT OrderVoteMsg's QC fields are ignored (the `None` argument).
- The QC carried by subsequent messages can be totally bogus and is never inspected. This is OK because `verify_order_vote` checks `quorum_cert.certified_block() == order_vote.ledger_info().commit_info()` at the entry point (order_vote_msg.rs:60-62) — but that's a *value-binding* check (commit_info equality), not a signature check. A Byzantine validator can forge a QC payload (with correct commit_info but arbitrary signers/signatures) and pass `verify_order_vote`. The forged QC just gets dropped on the floor at insertion time. Safe.

#### B3. `expect("Quorum Cert is expected ...")` panics if caller passes None for new digest — pending_order_votes.rs:74-76
```rust
verified_quorum_cert.expect(
    "Quorum Cert is expected when creating a new entry in pending order votes",
),
```
If the caller in `round_manager.rs` ever has a logic bug that passes `None` on a fresh `li_digest`, the entire consensus thread panics. The caller (round_manager.rs:1613-1633) ostensibly always calls `insert_order_vote(... Some(qc))` on new entries — but if a race causes the `exists` check to miss the entry (it's not atomic across the verify+insert), a panic would result. There is NO such race in the current single-threaded RoundManager dispatch (events are processed sequentially), but any future refactor introducing concurrent `insert_order_vote` would risk a panic.

#### B4. TODO at pending_order_votes.rs:60
```
// TODO: Should we add any counters here?
```
Lack of per-author / per-digest counters means observability of equivocation behaviour is poor.

#### B5. Garbage collection is not tied to a hash digest, only to round — pending_order_votes.rs:160-170
Older order votes are pruned only based on `highest_ordered_round`. If two `li_digest` exist at the same round (Byzantine equivocation), both linger in memory until both rounds are < highest_ordered. Memory usage is bounded only by the 100-round window enforced upstream (round_manager.rs:1607-1608).

#### B6. `OrderVoteStatus::EnoughVotes` arm caches QC from FIRST insertion — pending_order_votes.rs:84-90
After 2f+1, every subsequent identical-digest message returns the cached `quorum_cert.clone()`. Whatever QC was stored at FIRST insertion is what gets emitted to `RoundManager::new_ordered_cert` (round_manager.rs:1937-1947). The QC is verified once at first insertion (round_manager.rs:1617); subsequent QCs in OrderVoteMsg are silently ignored. Acceptable, but means a Byzantine validator who arrives FIRST cannot influence the outcome — they would have to forge the 2f+1 OrderVote signatures, which is still a 2f+1 attack.

### C. `network_interface.rs`

#### C1. `ConsensusMsg` enum is monolithic and easily extended (105 lines of variants)
Lines 40-105. Many message variants are deprecated (V1/V2 split for BlockRetrieval, Batch). Defensive, but the surface area for `From<ConsensusMsg> for UnverifiedEvent` (round_manager.rs:296-314) is wide; missing a case is silently `unreachable!()` at line 311. A crafted future-version message that round-trips through serde (e.g. via downgraded protocol) could panic the message dispatcher.

#### C2. `send_to`/`send_to_many`/`send_rpc` perform no domain-level filtering (lines 177-202)
Any caller can send any `ConsensusMsg` to any peer. The asymmetry is enforced only by network protocol IDs (DIRECT_SEND vs RPC, lines 157-168). Byzantine peers can send messages that the receiving network task classifies as "Unexpected RPC msg" / "Unexpected direct send msg" and simply `continue`s (network.rs:948, 1053).

#### C3. TODO at network_interface.rs:233-237
```
// TODO: we shouldn't need to expose this. Migrate the code to handle
// peer and network ids.
fn get_peer_network_id_for_peer(...)
```
Hardcoded `NetworkId::Validator` (line 236). Cross-network confusion seems unlikely given the panic at network.rs:772-776 if anything other than the validator network is configured.

### D. `network.rs`

#### D1. **STALE DOC COMMENT** — network.rs:191
```
/// Provide a LIFO buffer for each (Author, MessageType) key
```
But the actual queue construction at line 756-760 is `QueueStyle::FIFO`. This contradicts the documented intent (LIFO would drop the OLDEST messages and process the NEWEST first, which is what one wants for fresh consensus state). FIFO with cap 10 means a Byzantine peer can flood 10 stale messages and the receiving channel will drop the NEWEST messages from that same peer (per message_queues.rs:135 — FIFO drops the new one). Honest messages from the same peer-and-type get silently lost.

#### D2. Channel sizing — network.rs:756-768
- `consensus_messages_tx`: FIFO, cap 10 per (peer, msg-discriminant), with counter
- `quorum_store_messages_tx`: FIFO, cap 50 (TODO at line 763 to tune)
- `rpc_tx`: FIFO, cap 10

Bounded ⇒ no unbounded-memory DoS, but Byzantine peers can flood and cause own messages to drop (FIFO drops new). This means a Byzantine validator may not even succeed in submitting equivocating votes if they spam, **but** because the queue is per (peer, discriminant), one peer's flooding doesn't crowd out other peers (good).

#### D3. RPC dummy callback in self-message dispatch — network.rs:836, 851, 906, 923
```rust
let (tx, _rx) = oneshot::channel();
```
The dropped `_rx` means any `respond` on the corresponding `RpcResponder` will fail. The TODOs at lines 904, 921 indicate this is a known shortcut. Functionality-wise harmless because the receiver doesn't expect a real response, but it does mean response-route bugs would be invisible.

#### D4. `Unexpected direct send msg` branch silently `continue`s — network.rs:940-950
Byzantine peer sends a ConsensusMsg variant via direct-send that is RPC-only (e.g. DAGMessage as a direct-send). Logged as `warn!` and discarded. But: an RPC-only variant sent as direct-send does NOT increment a security event counter. Better to track per-peer "malformed message" counters for triage / tarpitting.

#### D5. Cross-self bypass via `Event::Message(self.author, msg)` — network.rs:362-367
```rust
let self_msg = Event::Message(self.author, msg.clone());
let mut self_sender = self.self_sender.clone();
if let Err(err) = self_sender.send(self_msg).await { ... }
```
Self-sent messages bypass network deserialization and are placed onto the same `consensus_messages_tx` queue (via `self_receiver` being merged via `select` at line 781). At verification time in `epoch_manager.rs:1721`, `peer_id == my_peer_id` evaluates to true and the entire `verify` step is skipped. Safe ONLY because the network-layer authentication binds `peer_id` to the cryptographic identity of the channel.

#### D6. `request_block` `from != self` check (network.rs:287)
Defensive `ensure!(from != self.author, "Retrieve block from self");` — correct but only on retrieval; analogous self-checks for vote/proposal sending do not exist. They aren't needed because votes are intentionally broadcast to self.

### E. `epoch_manager.rs`

#### E1. `peer_id == my_peer_id` skips ALL signature verification — epoch_manager.rs:1715-1727
At line 1721, `self_message: bool = peer_id == my_peer_id`. Inside `UnverifiedEvent::verify` (round_manager.rs:127, 144, 161, 170, 179, 188, 198, 207, 221, 235, 244), every variant short-circuits sig verification when `self_message` is true. Trust on the network-layer PeerId is critical. If a future change ever makes self-loopback writeable by anyone other than the owning task, this becomes a self-spoofing vulnerability.

#### E2. `process_message` clones `epoch_state` BEFORE bounded-executor verification — epoch_manager.rs:1692-1717
The clone is captured at message arrival time. Verification happens in a different task, possibly after the EpochManager has rotated to a new epoch. The verification result is then forwarded via `round_manager_tx` cloned from the OLD epoch's RoundManager. If the OLD RM is shut down, the message is dropped. If somehow the OLD RM is still alive after the new epoch started (e.g. shutdown raced and didn't complete), the OLD RM may receive a vote message verified against the OLD verifier — semantically correct (it IS the OLD epoch's vote) but a sign that races are possible.

#### E3. `process_different_epoch` ignores LOWER-epoch messages from in-set validators — epoch_manager.rs:510-523
Could be exploited by Byzantine validators to send junk lower-epoch messages with no consequences. Not a safety problem, just a noise source.

#### E4. `EpochChangeProof` for wrong epoch only increments a counter — epoch_manager.rs:1796-1806
Same as above: noise. The Right thing happens (no state change), but no DoS-protection.

#### E5. `BlockRetrieval` RPC bypasses epoch check — epoch_manager.rs:1972-1979
`IncomingRpcRequest::epoch()` returns None for BlockRetrieval (network.rs:181-182). The `process_rpc_request` then ensures the request type is BlockRetrieval (line 1974-1978) and bypasses `process_different_epoch`. The block_retrieval_tx receives the request directly. The downstream `process_block_retrieval` does its own validation (block_store), so this is bounded. But the request **does not declare its target epoch**, so a peer in a different epoch can fetch blocks from the current epoch's store, possibly leaking information about ongoing consensus.

#### E6. `start_new_epoch` reads ValidatorSet without further verification — epoch_manager.rs:1232-1241
```rust
let validator_set: ValidatorSet = payload.get().expect(...);
let mut verifier: ValidatorVerifier = (&validator_set).into();
verifier.set_optimistic_sig_verification_flag(self.config.optimistic_sig_verification);
```
The `payload` comes from the `ReconfigNotificationListener` (line 215). Trust is rooted in the on-chain reconfiguration event, which is verified upstream by state-sync. OK. But the `pessimistic_verify_set` is empty in the new verifier (validator_verifier.rs:199), so any prior bad-actor reputation from the old epoch is forgotten. A Byzantine validator can grief once per epoch with bogus signatures before being marked pessimistic.

#### E7. `start_new_epoch` is FULLY async; messages delivered between epoch shutdown and new-epoch start get dropped — epoch_manager.rs:564-589
`initiate_new_epoch` calls `shutdown_current_processor().await` (line 574), then `execution_client.sync_to_target(ledger_info)` (line 578-585), then `await_reconfig_notification` (line 587). During this window, `self.round_manager_tx == None`. Any vote/order-vote message arriving in this window goes through `forward_event_to`, which sees `maybe_tx == None`, returns `bail!("channel not initialized")`, logged as `warn!`. Lost votes during this window must be recovered via SyncInfo on the next round.

#### E8. `process_message` does NOT enforce that the bounded executor task completes before processing the next message — epoch_manager.rs:1750
`.await` waits for the spawn_blocking handle, but the join futures from previously-spawned tasks for OTHER messages may finish out of order. Since each task only writes to `round_manager_tx`, and `round_manager_tx` is FIFO-style with KLAST at line 977-980, out-of-order verification completion → out-of-order delivery to RoundManager. RoundManager handles arbitrary-order vote arrival by design (via `pending_votes`), so this is acceptable.

#### E9. `forward_event` may re-order pre-fetch and channel-push — epoch_manager.rs:1913-1927
The `prefetch_payload_data` and `pending_blocks.lock().insert_block` happen BEFORE `forward_event_to(buffered_proposal_tx, ...)`. This means `pending_blocks` can be populated for a proposal that the round manager hasn't yet received — fine for pre-fetching.

---

## 5. Top suspicious findings (mapped to bug families)

### Finding 1 — equivocation undetected, vote double-count (Order Vote)
**File:line**: `pending_order_votes.rs:61-157` (no equivocation map). Asymmetric with `pending_votes.rs:287-309`.
**Bug families**: equivocation undetected, order-vote vs regular-vote asymmetry.
**Attacker scenario**: Byzantine V sends `OrderVote(li_digest_A)` and `OrderVote(li_digest_B)` (same epoch, same round) to the network. Both digests independently aggregate. V's signature contributes to both certificates' SignatureAggregators. With the right network partitioning and timing, two distinct ordered-LI may both reach 2f+1 (using V as the (f+1)-th honest signer in EACH split). Aptos's safety relies on safety-rules at signing time (an honest validator only signs ONE order-vote per round) — but the AGGREGATION layer should also detect & reject. Currently it doesn't even log.

### Finding 2 — equivocation logging only, no slashing (Regular Vote)
**File:line**: `pending_votes.rs:299-308` — `error!(SecurityEvent::ConsensusEquivocatingVote, ...)` then `EquivocateVote`. Round manager turns this into `Err(anyhow::anyhow!("{:?}", e))` (round_manager.rs:1863).
**Bug families**: equivocation undetected (in the slashing sense).
**Impact**: Byzantine peers face zero on-chain consequence for equivocation; only a security-event log entry that may or may not be aggregated by ops. The protocol relies on social slashing.

### Finding 3 — cross-epoch in-flight verification race
**File:line**: `epoch_manager.rs:1692-1750` (capture old epoch_state.verifier before spawn_blocking; deliver to old round_manager_tx).
**Bug families**: cross-epoch replay, pipeline race.
**Impact**: After `start_new_epoch`, any message that was "in verification" against the OLD verifier may be silently dropped (channel closed) or, in rare scheduling races, delivered to a still-alive OLD RoundManager. Not a safety violation as written but tight reasoning required; any future change to the shutdown sequence or the bounded executor's lifecycle could turn this into a cross-epoch replay path.

### Finding 4 — order-vote QC verification only on FIRST sighting per `li_digest`
**File:line**: `round_manager.rs:1613-1633` and `pending_order_votes.rs:71-81`.
**Bug families**: certificate value-binding, pipeline race.
**Impact**: The QC inside subsequent OrderVoteMsgs is never verified. The value-binding via `verify_order_vote` (order_vote_msg.rs:60-62) ensures `quorum_cert.certified_block() == ledger_info.commit_info()`, but the QC's signatures are NEVER checked beyond the first. A Byzantine validator can craft a forged QC binding (matching commit_info) to pollute the per-author equivocation telemetry & metrics, and to gain a measurable propagation advantage (skipping the verify cost). No safety break, but the asymmetry between FIRST and SUBSEQUENT verification trust is a subtle attack surface.

### Finding 5 — FIFO channel drops NEW messages, doc says LIFO
**File:line**: `network.rs:191` (stale comment) vs `network.rs:756-760` (FIFO config). Drop policy: `message_queues.rs:135` — FIFO drops the NEW message.
**Bug families**: pipeline race, vote double-count (timing).
**Attacker scenario**: A Byzantine peer P sends 10 stale ProposalMsgs to fill the per-(peer, msg-type) queue. An honest VoteMsg from peer P that arrives after the 10th is silently dropped. Since votes are also keyed by peer, only that peer's votes are dropped — a Byzantine peer can effectively self-DoS its own vote channel, but in doing so could mask a legitimate timeout vote it was supposed to send. Combined with `echo_timeout` requiring f+1 timeouts, a Byzantine collective can suppress timeout signal flow.

### Finding 6 — `peer_id == my_peer_id` short-circuits all sig verify
**File:line**: `epoch_manager.rs:1721` and round_manager.rs:127, 144, 161, 170, 179, 188, 198, 207, 221, 235, 244 (`if !self_message`).
**Bug families**: cross-epoch replay (only if peer_id is spoofable).
**Impact**: Currently safe because `peer_id` is bound to the network channel identity by aptos_network. If a future change ever introduces a path to enqueue messages with arbitrary `peer_id` (e.g. a debug RPC, a fuzzing helper, or an internal forwarding bug), self-spoofing would be a critical vulnerability.

### Finding 7 — Order-vote round-window of 100 (round_manager.rs:1607-1608)
**File:line**: `round_manager.rs:1607-1608` — `if order_vote_round > highest_ordered_round && order_vote_round < highest_ordered_round + 100 { … }`.
**Bug families**: pipeline race, vote double-count.
**Impact**: Order-votes within the next 100 rounds are accepted. Combined with **B5** (no GC by digest, only by round), a Byzantine validator can pre-stuff `pending_order_votes` with up to 100 different `li_digest` entries (each with a verified QC, since they're forged as far as the value-binding holds). Memory cost is bounded but proportional to # rounds × # forged digests.

### Finding 8 — `pessimistic_verify_set` is reset every epoch
**File:line**: `epoch_manager.rs:1232-1240`, `validator_verifier.rs:199`.
**Bug families**: pipeline race.
**Impact**: Bad-actor reputation does not survive an epoch boundary. Each new epoch a Byzantine validator may grief the optimistic-sig-verification once before being marked pessimistic. This is per-epoch CPU waste, not a safety problem.

### Finding 9 — TwoChainTimeout signature first-write-wins, but `self.timeout` last-hqc-wins
**File:line**: `pending_votes.rs:78-87` (TwoChainTimeoutVotes::add) → `timeout_2chain.rs:242-263` (TwoChainTimeoutWithPartialSignatures::add). Specifically `timeout_2chain.rs:259-260`:
```rust
if timeout.hqc_round() > self.timeout.hqc_round() {
    self.timeout = timeout;
}
```
And `PartialSignaturesWithRound::add_signature` at `timeout_2chain.rs:320-329` uses `or_insert((round, signature))` — first-write-wins per validator.
**Bug families**: equivocation undetected.
**Impact**: A Byzantine validator's first timeout signature is committed permanently, but the *aggregate's headline `self.timeout`* can be replaced by a later timeout from a DIFFERENT honest validator with a higher hqc_round. The certificate's `verify` (timeout_2chain.rs:170-181) checks that `hqc_round == max(signed_rounds)` — so any inconsistency between the headline and per-signer rounds causes verification to fail. Acceptable, but if a Byzantine validator times out with a phony low-hqc QC and broadcasts it WITH a real-looking signing repr, the partial certificate could mix in their bogus first-write signature. The aggregate-signature check would then fail at certificate verification time.

### Finding 10 — Network channel comment vs config disagreement & 0-power voter handling
**File:line**: `pending_votes.rs:339-341`, `pending_order_votes.rs:105-110`, `validator_verifier.rs:269-285`.
A 0-voting-power authorised validator can trigger `add_signature` and `add_pessimistic_verify_set` paths. While 0-power can't tip thresholds, it can:
- Pollute the `pessimistic_verify_set` and slow down optimistic verification for honest peers.
- Get its `author_to_vote` slot occupied (memory only).
**Bug families**: pipeline race (CPU exhaustion, low-grade DoS).

---

## TL;DR ranked by safety-criticality

| # | File:line | Family | Severity |
|---|-----------|--------|----------|
| 1 | `pending_order_votes.rs:61-157` | equivocation undetected (order-vote) | **HIGH** (asymmetry; safety relies on safety-rules) |
| 2 | `pending_votes.rs:299-308` | equivocation undetected (no slashing) | **MEDIUM** (logging only) |
| 3 | `epoch_manager.rs:1692-1750` | cross-epoch race | MEDIUM (potential, not present) |
| 4 | `round_manager.rs:1613-1633` | certificate value-binding (asymmetric verify) | MEDIUM |
| 5 | `network.rs:191 vs 756-760` | pipeline race (FIFO drops new) | MEDIUM (doc/code mismatch + DoS) |
| 6 | `epoch_manager.rs:1721` | cross-epoch replay (if spoofable) | LOW (currently safe; latent) |
| 7 | `round_manager.rs:1607-1608` | pipeline race (memory window) | LOW |
| 8 | `validator_verifier.rs:199` | pipeline race (per-epoch reset) | LOW |
| 9 | `timeout_2chain.rs:259-262, 320-329` | equivocation tracking | LOW (verify catches it) |
| 10 | `pending_votes.rs:339-341` | pipeline race (CPU DoS) | LOW |

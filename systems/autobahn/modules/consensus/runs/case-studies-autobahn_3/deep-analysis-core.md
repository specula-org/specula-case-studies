# Deep Analysis of Autobahn BFT Consensus — Core / Aggregators / Messages

Working tree: `/home/ubuntu/Specula/case-studies/autobahn_3/artifact/autobahn-artifact`
Branch: `main` @ HEAD

All line numbers refer to the working tree files at the time of review.

---

## Summary of Findings

The implementation is **shot through with safety, integrity, and crash-DoS bugs**. With even a single Byzantine committee member, an attacker can (a) commit arbitrary proposals at any slot/view, (b) violate agreement, (c) replay other replicas' timeout signatures to forge view changes, (d) crash all honest nodes with a single malformed message, and (e) corrupt the local view of an honest node so it cannot vote for legitimate prepares. Even in benign runs there are GC bugs that drop in-flight per-slot state for future slots, plus a real bug in `get_winning_proposals` that picks the wrong winning view.

The bugs cluster into the following families. Each finding below contains the cited code and a severity.

### Family A — Cryptographic binding is missing on every consensus message
These are the root cause of nearly every safety bug downstream.

| ID | Title | Severity |
|----|-------|----------|
| A1 | `ConsensusMessage::digest` omits `proposals` for Prepare/Confirm/Commit; `verify_confirm`/`verify_commit` reconstruct the id without proposals. QCs do not bind to proposals. | CRITICAL |
| A2 | `Timeout::digest` hashes nothing — every timeout has the same digest; signatures are replayable across slots/views/contents. | CRITICAL |
| A3 | `Timeout::verify` does not verify the embedded `high_qc` and `high_prop`; `TC::verify` does not verify them either; `get_winning_proposals` trusts them. | CRITICAL |
| A4 | `TC::PartialEq` always returns `true`, so `TC::verify`'s genesis short-circuit at line 1520 fires for every TC, bypassing quorum and per-timeout signature checks. | CRITICAL |
| A5 | `QC::PartialEq` always returns `false`; the dead-code genesis check in `QC::verify` is harmless on its own, but it also breaks `ConsensusMessage::eq` for Confirm/Commit (which always returns false). | MEDIUM |
| A6 | `QC::digest` and `Timeout::digest` both hash zero data; dead code that the implementer almost certainly forgot to wire. | LOW (catches A2 once fixed) |

### Family B — Authorization checks omitted in `is_valid`
These let a non-leader (or anyone with a committee key) drive consensus.

| ID | Title | Severity |
|----|-------|----------|
| B1 | `is_valid` for `Prepare` advances `self.views[slot]` to the proposed view BEFORE checking the ticket or last-vote — so any malformed prepare permanently corrupts a node's view. | HIGH |
| B2 | `is_valid` for `Confirm` has no `last_voted_consensus` check — a node will Confirm-vote arbitrarily many times for the same `(slot, view)`. Combined with A1, this produces conflicting Confirm-QCs. | HIGH |
| B3 | Neither `is_valid` nor `process_prepare_message` checks the author is the elected leader of `(slot, view)`. Any committee member can play "leader". | HIGH |
| B4 | `is_valid` for Prepare does not consult `committed_slots`. A byzantine can submit a new Prepare for an already-committed slot at a higher view. | CRITICAL |

### Family C — Per-slot bookkeeping is dirty before validation
| ID | Title | Severity |
|----|-------|----------|
| C1 | `process_consensus_request` writes `consensus_instances` BEFORE verifying the signature and BEFORE `is_valid`. A rejected byzantine message can pollute the local instance map. Combined with A1, this lets a byzantine substitute its own `proposals` into the local instance, so the leader's resulting Confirm/Commit uses byzantine proposals. | HIGH |

### Family D — TC winner computation bugs
| ID | Title | Severity |
|----|-------|----------|
| D1 | `get_winning_proposals` Confirm branch sets `winning_view = timeout.view` instead of `*other_view`; later legitimate Confirm-QCs at higher QC views can be skipped. | HIGH |
| D2 | The Prepare branch only counts prepares from timeouts with `view > winning_view`; once a Confirm has lifted winning_view to `timeout.view` (D1), no Prepare can ever clear the bar. | HIGH |
| D3 | The Prepare branch keys `prepared_feq` by `prepare.digest()` — which (per A1) does not include proposals, so the f+1 matching count merges different proposal sets under one bucket. Byzantine can spoof matching prepares. | HIGH |
| D4 | The Commit branch breaks out of the loop on the first Commit it sees, with no verification of the embedded Commit's signatures or its qc. With A1+A2+A3, any timeout can carry a fabricated Commit and the new leader will adopt those proposals. | CRITICAL |
| D5 | `is_valid` Prepare branch only checks `proposal.eq(winning_proposals.get(&pk).unwrap())` for keys in `proposals`. A leader can ship a strict subset of `winning_proposals` and pass; missing winning entries are silently dropped (panic if `proposals` has an extra key not in winning). | MEDIUM |

### Family E — Crash / DoS via unchecked `unwrap`
| ID | Title | Severity |
|----|-------|----------|
| E1 | `is_valid` Prepare/no-TC branch unwraps `qc_ticket.as_ref()` when `slot > k` and the local replica hasn't committed `slot - k`. A single byzantine `ConsensusRequest` with `slot=large, view=1, tc=None, qc_ticket=None` crashes every honest receiver. | CRITICAL |
| E2 | `enough_coverage` unwraps `prepare_proposals.get(&pk)` for every `pk` in current_proposals. A Prepare whose `proposals` map is missing keys (only possible if proposals are externally crafted, e.g. via TC's winning proposals) will panic. Compensating: in benign runs proposals always cover all authorities. | MEDIUM |
| E3 | `is_prepare_ticket_ready` unwraps `self.committed_slots.get(&(slot+1-self.k))` at line 1118. Mostly guarded by the `contains_key` check above, but a race between the check and the use is not possible because all access is single-threaded. Low. | LOW |

### Family F — Garbage collection is broken
| ID | Title | Severity |
|----|-------|----------|
| F1 | `clean_slot_periods` predicate `s % k != slot_period && s <= &slot` drops every entry with `s > slot` (future, in-flight instances) and every entry where `s % k == slot_period && s <= slot`. After committing slot 2 with k=4, the call wipes all instances for s=3,4,5,…. | HIGH |
| F2 | Many state maps (`views`, `tc_makers`, `last_voted_consensus`, `high_qcs`, `high_proposals`, `committed_slots`, `prepare_tickets`, `already_proposed_slots`, `voted_confirm_shadow`) are never GC'd at all. Long runs leak unbounded memory. | LOW |

### Family G — Async simulation / general loose ends
| ID | Title | Severity |
|----|-------|----------|
| G1 | `async_delayed_prepare = Some(consensus_message)` overwrites any earlier buffered prepare; only the last is replayed. Could drop legitimate prepares if multiple slots fire while async is simulated. Benchmark-only, but worth flagging. | LOW |
| G2 | `process_loopback` for `Commit` forwards to `tx_committer` without any check — combined with A1, byzantine can drive a fake Commit through the sync path so the committer applies fake proposals. | HIGH |
| G3 | `verify_commit` `panic!("ids don't match")` on a mismatched Slow QC id (line 159) — verification is supposed to return `false`. A byzantine can deliberately mismatch ids to crash receivers. | HIGH |

---

## Detailed Findings

### A1. ConsensusMessage / QC does not bind to proposals

**File:** `primary/src/messages.rs:121-208, 233-280`

`ConsensusMessage::digest()` deliberately omits the proposal set for **every** variant:

```rust
ConsensusMessage::Prepare { slot, view, tc, qc_ticket, proposals: _ } => {
    hasher.update(slot.to_le_bytes());
    hasher.update(view.to_le_bytes());
    //hasher.update(proposal_digest(self)); FIXME: ADD THIS AND DEBUG
    //hasher.update(tc.digest().0);
    hasher.update((0 as u8).to_le_bytes());
}
ConsensusMessage::Confirm { slot, view, qc, proposals: _ } => {
    hasher.update(slot.to_le_bytes());
    hasher.update(view.to_le_bytes());
    hasher.update(&qc.id);
    hasher.update((1 as u8).to_le_bytes());
}
ConsensusMessage::Commit { slot, view, qc, proposals: _ } => {
    hasher.update(slot.to_le_bytes());
    hasher.update(view.to_le_bytes());
    hasher.update(&qc.id);
    hasher.update((2 as u8).to_le_bytes());
}
```

`verify_confirm` (messages.rs:186-208) and `verify_commit` (messages.rs:121-169) reconstruct the prepare/confirm id without proposals, both with explicit `FIXME` comments:

```rust
//hasher.update(proposal_digest(consensus_message)); FIXME: ADD THIS AND DEBUG
hasher.update((0 as u8).to_le_bytes());
```

**Claim:** A PrepareQC / ConfirmQC for `(slot, view)` is silently valid for *any* proposals at `(slot, view)`. The 2f+1 honest signatures attest only to `(slot, view, type_byte)`. The aggregator's `qc.id` is the slot/view/type hash, so the QC is reusable across proposal sets.

**Impact (CRITICAL safety):**
- Trivial equivocation by a byzantine leader: send Prepare A with proposals_A to some honest set and Prepare B with proposals_B to another set; all honest signatures sign the same digest; both halves form QCs over the same id; either half's QC can be paired with either proposal set to produce a "valid" Confirm/Commit.
- A byzantine that observes any honest Prepare can repackage it into a Confirm with arbitrary `proposals` and that Confirm passes `verify_confirm`.

**Manifests:** Byzantine-only.
**Verifiable by:** TLA+ model (treat digest as a function of `(slot, view, kind)`, demonstrate Agreement violation); also the repo's own `primary/src/tests/messages_tests.rs::test_da1_qc_does_not_bind_to_proposals` reproduces it directly.

---

### A2. `Timeout::digest` hashes nothing — signatures are replayable

**File:** `primary/src/messages.rs:1349-1359`

```rust
impl Hash for Timeout {
    fn digest(&self) -> Digest {
        let mut hasher = Sha512::new();
        /*hasher.update(self.view.to_le_bytes());
        if let Some(qc_view) = self.vote_high_qc {
            hasher.update(qc_view.to_le_bytes());
        }*/
        Digest(hasher.finalize().as_slice()[..32].try_into().unwrap())
    }
}
```

`Timeout::new` signs `timeout.digest()` (messages.rs:1325) and `Timeout::verify` only checks `self.signature.verify(&self.digest(), &self.author)` (messages.rs:1340). The digest is `Sha512::new().finalize()[..32]` for **every** timeout.

**Claim:** Every Timeout from author N has an identical signature. A byzantine that observes one honest Timeout (or knows N's signature on the constant digest from any other source) can forge an arbitrary Timeout `(slot=S, view=V, high_qc=fake, high_prop=fake)` claiming author N — and it will pass `Timeout::verify`. Combined with A3/A4, the byzantine doesn't need any honest signatures: they can fabricate a TC with empty `timeouts` and pass `TC::verify` trivially.

**Impact (CRITICAL safety):**
- Byzantine forges view changes without participation from honest nodes.
- Combined with A3, the forged Timeouts can carry arbitrary `high_qc=Confirm{view=∞, proposals=X}` so `get_winning_proposals` adopts X.

**Manifests:** Byzantine-only.
**Verifiable by:** code review; reproduction test `test_da2_timeout_digest_hashes_nothing` already exists.

---

### A3. Timeout `high_qc`/`high_prop` are not verified

**File:** `primary/src/messages.rs:1332-1346, 1518-1546`

```rust
pub fn verify(&self, committee: &Committee) -> DagResult<()> {
    ensure!(committee.stake(&self.author) > 0, ...);
    self.signature.verify(&self.digest(), &self.author)?;
    // TODO: If it would be winning QC then you need to verify
    //NOTE: When verifying TC, we have purged all vote contents besides the winner --> so this step is skipped.
    Ok(())
}
```

`TC::verify` iterates timeouts and calls `timeout.verify(committee)` — but the embedded `high_qc`/`high_prop` are never type-checked, never have their `qc.verify` called, and there is no check that their `slot` matches `timeout.slot`.

`TC::get_winning_proposals` (messages.rs:1436-1499) trusts these unverified fields:

```rust
match &timeout.high_qc {
    Some(qc) => match qc {
        ConsensusMessage::Confirm { slot: _, view: other_view, qc: _, proposals } => {
            if other_view > &winning_view { winning_view = timeout.view; winning_proposals = proposals.clone(); }
        }
        ConsensusMessage::Commit { slot: _, view: _, qc: _, proposals } => {
            winning_proposals = proposals.clone();
            break;
        }
        ...
    }
}
```

**Claim:** A byzantine can put any fabricated Confirm/Commit (with arbitrary proposals and an unverified inner qc) inside `high_qc` and it will be adopted.

**Impact (CRITICAL safety):** New leader after TC adopts attacker-chosen proposals.
**Manifests:** Byzantine-only.
**Verifiable by:** TLA+ or unit test.

---

### A4. `TC::PartialEq` always true → `TC::verify` always Ok

**File:** `primary/src/messages.rs:1405-1411, 1518-1546`

```rust
impl PartialEq for TC {
    fn eq(&self, other: &Self) -> bool {
        //self.hash == other.hash && self.view == other.view
        //*self.winning_proposal == *other.winning_proposal
        true
    }
}

pub fn verify(&self, committee: &Committee) -> ConsensusResult<()> {
    //genesis TC always valid
    if Self::genesis(committee) == *self {
        return Ok(());        // <-- ALWAYS taken
    }
    ...
}
```

Because `PartialEq` always returns `true`, `Self::genesis(committee) == *self` matches every TC, so the function returns `Ok(())` unconditionally. The quorum check, signature verification, and per-timeout `verify()` calls (lines 1525-1544) are dead code.

The only consumer that calls `TC::verify` is `is_valid` for Prepare (`core.rs:1191`). That call therefore performs no check at all.

**Claim:** Any byzantine can submit a Prepare with TC = `TC { slot, view, timeouts: vec![] }` and have it accepted. With B4 (no committed-slots check) and B3 (no leader check) and the trivial view inflation in A4, **a single byzantine can commit arbitrary proposals at any slot/view**:
1. Send `Prepare { slot=S, view=V, tc=Some(forgedTC), qc_ticket=None, proposals=X }` where forgedTC has `view = V-1` and empty timeouts.
2. `is_valid` (core.rs:1185-1199): `tc.view+1 == V` ✓, `tc.verify().is_ok()` ✓ (A4), `winning_proposals = {}` so the loop at 1195 is skipped, `views[S]` updated to V at 1228, `last_voted_consensus.contains((S,V))` false, returns true.
3. Honest nodes vote, PrepareQC forms over `(S, V, 0)`, then Confirm-QC/Commit-QC forms, slot committed at value X. If S was previously committed at value Y, agreement is broken.

**Impact (CRITICAL safety):** total agreement break with one byzantine.
**Manifests:** Byzantine-only.
**Verifiable by:** TLA+ (model TC.verify as `Ok`); reproduction test `test_da3_tc_verify_always_passes`.

---

### A5. `QC::PartialEq` always returns `false`

**File:** `primary/src/messages.rs:1287-1292`

```rust
impl PartialEq for QC {
    fn eq(&self, other: &Self) -> bool {
        false
    }
}
```

Direct consequences:
- `QC::verify` genesis short-circuit at line 1246 (`if Self::genesis(committee) == *self`) is dead code; harmless because the rest of `verify` is correct on non-empty QCs (but genesis QC won't auto-pass; this matters if genesis QCs are ever exchanged).
- `ConsensusMessage::eq` for Confirm/Commit (`messages.rs:316-347`) compares `qc == other_qc`; since this is always false, no two Confirm/Commit values are ever equal, even to themselves. `ConsensusMessage` is not used directly as a HashMap key (Digest is used), so this is mostly latent — but any caller that does `confirm_a == confirm_b` (e.g. test code, future refactors) gets a wrong answer.

**Impact:** MEDIUM (latent / footgun).
**Manifests:** benign.
**Verifiable by:** unit test `test_da13_qc_partialeq_always_false`.

---

### A6. `QC::digest` hashes nothing

**File:** `primary/src/messages.rs:1271-1279`

```rust
impl Hash for QC {
    fn digest(&self) -> Digest {
        let hasher = Sha512::new(); // NOTE: We are not using this digest ever currently. QC verification happens on the ID included in the QC
        Digest(hasher.finalize().as_slice()[..32].try_into().unwrap())
    }
}
```

Currently unused, so harmless. Flagged because A2 took the same shape and *was* used.

**Impact:** LOW.

---

### B1. `is_valid` for Prepare advances `views` before checking validity

**File:** `primary/src/core.rs:1226-1233`

```rust
let curr_view = self.views.get(slot).unwrap_or(&0);
if curr_view < view {
    self.views.insert(*slot, *view);    // <-- side-effect happens unconditionally
}
!self.last_voted_consensus.contains(&(*slot, *view)) && ticket_valid && self.views.get(slot).unwrap() == view
```

Any caller-controlled `view` is inserted into `self.views[slot]` regardless of whether the message is otherwise valid (TC missing, signature wrong is caught earlier at `process_consensus_request`, but a syntactically valid byzantine message with `view = 9999, tc = None` reaches this code path).

Once `views[slot] = 9999`, any legitimate `Prepare { slot, view=1 }` that arrives later fails the final check `views[slot] == view` and is rejected.

**Impact (HIGH liveness):** A single byzantine can poison `views[slot]` so the honest node never participates in legitimate consensus for that slot. Reproduction exists in `tests/core_tests.rs::bug4_view_advance_side_effect`.

**Manifests:** Byzantine-only.
**Verifiable by:** TLA+ liveness; unit test.

---

### B2. `is_valid` for Confirm has no `last_voted_consensus` check

**File:** `primary/src/core.rs:1235-1246`

```rust
ConsensusMessage::Confirm { slot, view, qc, proposals: _ } => {
    let curr_view = self.views.get(slot).unwrap_or(&0);
    if curr_view <= view {
        if verify_confirm(consensus_message, &self.committee) {
            self.views.insert(*slot, *view);
            return true;
        }
    }
    return false;
}
```

Compare with the Prepare branch (`!self.last_voted_consensus.contains(&(*slot, *view))`). The Confirm branch has no such check, so a node will vote (sign the Confirm digest in `process_confirm_message`) for *every* Confirm it sees at `(slot, view)`. Combined with A1 (two Confirms with same digest but different proposals), this means the node signs two messages that observers can interpret as conflicting Confirm-QCs.

It also keeps overwriting `high_qcs[slot]` with whatever Confirm arrives last (`core.rs:1559`), so the high_qc included in subsequent timeouts can be byzantine-chosen.

**Impact:** HIGH safety (ConfirmUniqueness violated), enables A1 attacks.
**Verifiable by:** unit test `bug3_confirm_double_vote` already exists.

---

### B3. No leader check in `is_valid` / `process_prepare_message`

**Files:** `primary/src/core.rs:1174-1260, 1474-1542`

Grep shows the only uses of `LeaderElector::get_leader` are at:
- `core.rs:1060` — leader checks itself before forwarding tickets.
- `core.rs:1964` — leader checks itself before constructing a Prepare from TC.
- `core.rs:2188` — first-leader bootstrap.

`is_valid(Prepare)` does not check that `consensus_req.author == leader_elector.get_leader(slot, view)`. `process_prepare_message` also doesn't. A non-leader byzantine can submit Prepare for any (slot, view) and honest nodes will vote.

This is what unlocks the A4 + B4 + B1 chain — the byzantine doesn't need to be elected leader.

**Impact:** HIGH (force multiplier for other bugs).

---

### B4. `is_valid` for Prepare does not consult `committed_slots`

**File:** `primary/src/core.rs:1174-1233`

The branch never checks whether `slot` has already been committed. After slot S is committed at view V_old with proposals Y, a byzantine can still send a Prepare for `(S, V_new > V_old)` with arbitrary proposals X — and the same chain (A4 + B3 + B1) carries it through to a second Commit on slot S.

Note: `local_timeout_round` (core.rs:1819-1830) does check `high_qcs.get(&slot)` for a Commit and refuses to time out; and `handle_timeout` (core.rs:1892-1895) refuses to process timeouts for committed slots. So the byzantine cannot drive a TC for a committed slot from honest contributions alone — but with A4 they don't need to.

**Impact:** CRITICAL safety (double-commit possible).

---

### C1. `consensus_instances` is written before signature/validity checks

**File:** `primary/src/core.rs:1370-1387`

```rust
let dig = consensus_message.digest();
match &consensus_message {
    ConsensusMessage::Prepare {slot, view, ..} => { self.consensus_instances.insert((*slot, dig.clone()), consensus_message.clone()); },
    ConsensusMessage::Confirm {slot, view, ..} => { self.consensus_instances.insert((*slot, dig.clone()), consensus_message.clone()); },
    _ => {},
};

debug!("try to verify");
let mut valid = true;
if consensus_req.author != self.name {
    consensus_req.verify(&self.committee)?;       // signature check happens here
    valid = self.is_valid(&consensus_message).await;
}

if !valid { return Ok(()); }
```

Two combinations bite:
1. If `consensus_req.verify(...)` fails, `?` returns `Err`, but the insert at lines 1372-1373 already happened. A byzantine with a wrong signature still pollutes the map.
2. Since `ConsensusMessage::digest()` ignores `proposals` (A1), a later honest message for the same `(slot, view)` has the same digest and overwrites — but until that happens, the local copy of `current_instance` for `(slot, dig)` is byzantine.

When QC formation runs (`process_consensus_vote::current_instance`), the `proposals` field used to build the Confirm / Commit is taken from `consensus_instances` (core.rs:875, 884, 895). So if the byzantine wins the race, the leader's emitted Confirm/Commit carries byzantine `proposals`.

**Impact:** HIGH safety on the leader path; force multiplier for A1.
**Verifiable by:** integration test that interleaves a byzantine ConsensusRequest before the honest leader's request.

---

### D1. `get_winning_proposals` Confirm branch sets `winning_view = timeout.view`

**File:** `primary/src/messages.rs:1447-1458`

```rust
ConsensusMessage::Confirm { slot: _, view: other_view, qc: _, proposals } => {
    if other_view > &winning_view {
        winning_view = timeout.view;          // BUG: should be *other_view
        winning_proposals = proposals.clone();
    }
}
```

The comparison uses the embedded QC's `other_view`, but the assignment stores the *timeout's* view (which is `>= other_view + 1` since this is a view change). After processing the first Confirm-bearing timeout, `winning_view` is inflated to `timeout.view`, and no subsequent Confirm at a different but legitimately higher QC view can replace it.

Concrete failure mode (already in `messages_tests.rs::test_da5_viewchange_wrong_winning_view`):
- timeout_2 (view=7, high_qc.view=2, proposals=v2) processed first → `winning_view = 7, winning_proposals = v2`.
- timeout_1 (view=5, high_qc.view=3, proposals=v1) processed next → `3 > 7` is false; v1 is skipped.
- v2 wins even though v1's Confirm-QC was at a strictly higher view.

If the Confirm-QC at view 3 had progressed toward commitment, safety is on the edge: the new leader rejects the proper winning proposals. The TLA+ paper proof requires the highest-view Confirm-QC to be adopted. This code does not deliver that.

**Impact:** HIGH safety (correctness of view-change winner).
**Manifests:** Byzantine ordering of timeouts in TC; also possible in benign runs where ordering happens to be unfavorable.

---

### D2. Prepare branch threshold is gated by inflated `winning_view`

**File:** `primary/src/messages.rs:1479-1490`

```rust
ConsensusMessage::Prepare { slot, view, tc: _, qc_ticket: _, proposals } => {
    if view > &winning_view {
        let weight = prepared_feq.entry(prepare.digest()).or_default();
        *weight += committee.stake(&timeout.author);
        if *weight >= committee.validity_threshold() {
            winning_view = *view;
            winning_proposals = proposals.clone();
        }
    }
}
```

Once D1 has set `winning_view` to e.g. `timeout.view = 7`, any honest f+1 matching Prepare at view `<= 7` (which is *every legitimate prepare seen so far*) is ignored, because `view > 7` is false. The fallback Prepare evidence is silently lost.

The comment in the code already acknowledges imprecision (FIXME at line 1486), but the bug is more severe than the comment indicates.

**Impact:** HIGH (liveness in honest+slow regions, also safety adjacency with D1).

---

### D3. Prepare branch counts by digest that omits proposals

**File:** `primary/src/messages.rs:1481`

```rust
let weight = prepared_feq.entry(prepare.digest()).or_default();
```

`prepare.digest()` is `Sha512(slot, view, 0u8)` (A1). All prepares at the same `(slot, view)` collide under one key — even if they carry **different** proposal sets. The f+1 matching count is therefore not a count of "matching proposals" but of "matching (slot, view)". A byzantine can supply a Prepare for the right (slot, view) but with attacker-chosen proposals; if it's the one selected as the winner (because it pushes `weight` over the threshold last), `winning_proposals` is byzantine-chosen.

**Impact:** HIGH safety.

---

### D4. Commit branch in `get_winning_proposals` is a one-liner trust-fall

**File:** `primary/src/messages.rs:1460-1469`

```rust
ConsensusMessage::Commit { slot: _, view: _, qc: _, proposals } => {
    winning_proposals = proposals.clone();
    break;
}
```

The embedded Commit is not verified (A3). The byzantine puts a fabricated `ConsensusMessage::Commit { proposals = X, qc = whatever }` into `high_qc` of one of their own (or one forged via A2) timeout; `get_winning_proposals` adopts `proposals = X` and exits. The new leader proposes X.

**Impact:** CRITICAL safety. Even simpler attack vector than the Confirm one.

---

### D5. Subset-proposals check in `is_valid` for Prepare with TC

**File:** `primary/src/core.rs:1193-1198`

```rust
let winning_proposals = tc.get_winning_proposals(&self.committee);
if !winning_proposals.is_empty() {
    for (pk, proposal) in proposals {
        ticket_valid = ticket_valid && proposal.eq(winning_proposals.get(&pk).unwrap());
    }
}
```

The loop iterates `proposals` (the prepare's), not `winning_proposals`. Two issues:
1. If `proposals` is a strict subset of `winning_proposals`, the missing entries are not enforced. The leader can ship a smaller proposal set than required.
2. If `proposals` contains a key NOT in `winning_proposals`, the inner `unwrap()` panics — a crash DoS for honest receivers if a byzantine leader sends an extra key.

The right check is `proposals == winning_proposals` (with appropriate iteration over both sides).

**Impact:** MEDIUM (safety of view-change winner adoption; LOW crash DoS).

---

### E1. CRITICAL — single-message crash via `qc_ticket.unwrap()`

**File:** `primary/src/core.rs:1200-1223`

```rust
None => {
    if !self.use_parallel_proposals { panic!(...); }
    if *slot > self.k {
        if !self.committed_slots.contains_key(&(slot - self.k)) {
            let commit_qc = qc_ticket.as_ref().unwrap();    // <-- PANIC
            ...
        }
    }
    ticket_valid = ticket_valid && *view == 1;
}
```

A byzantine sends `ConsensusRequest { author = self_byz, message = Prepare { slot = 1_000_000, view = 1, tc = None, qc_ticket = None, proposals = anything }, sig = own_sig }`.

Flow on a target honest node (`process_consensus_request`, `core.rs:1342-1389`):
- Line 1372: `consensus_instances.insert(...)` (no-op damage)
- Line 1380: `consensus_req.verify(&self.committee)?` — passes (byz signed their own request).
- Line 1382: `is_valid(&consensus_message)` enters Prepare branch with `tc = None`.
- Line 1206: `*slot > self.k` is true (e.g. `1_000_000 > 4`).
- Line 1208: `committed_slots.contains_key(&(1_000_000 - 4))` is false (we haven't committed slot 999996).
- Line 1211: `qc_ticket.as_ref().unwrap()` — **panic**, killing the node (`run`'s tokio task aborts).

The byzantine only needs committee membership and a valid signature on their own message. **One UDP packet from one byzantine can crash every honest node.**

**Impact:** CRITICAL (network-wide DoS).
**Manifests:** Byzantine-only.
**Verifiable by:** test that sends the crafted ConsensusRequest and asserts the receiver task panics, or static lint that forbids `unwrap` in network-input paths.

---

### E2. `enough_coverage` unwraps every authority key

**File:** `primary/src/core.rs:1583-1600`

```rust
let new_tips: HashMap<&PublicKey, &Proposal> = current_proposals
    .iter()
    .filter(|(pk, proposal)| proposal.height > prepare_proposals.get(&pk).unwrap().height)
    .collect();
```

Iterates `current_proposals` (which is a full map of all authorities) and unwraps `prepare_proposals.get(pk)` for each.

In benign runs `prepare_proposals` is always a complete map (it's the proposals from the prior Prepare, which `set_consensus_proposal` always populates from `current_proposal_tips` covering all authorities). With byzantine equivocation though, `prepare_proposals` flowing through `is_prepare_ticket_ready` originates from a possibly-doctored Prepare — see C1 — and could be missing keys, panicking the honest receiver.

**Impact:** MEDIUM (latent crash DoS, conditional on C1 / D5 supplying bad data).
**Verifiable by:** code review; static lint.

---

### E3. Other `unwrap`s are guarded but worth tracking

- `core.rs:1118` `self.committed_slots.get(&(slot+1-self.k)).unwrap()` — guarded by `contains_key` two lines above; OK in single-threaded async runtime.
- `core.rs:1233` `self.views.get(slot).unwrap()` — fine because we just inserted at 1228.
- `core.rs:1325` (synchronizer)/`messages.rs:473` `committee.authorities.iter().next().unwrap()` — assumes non-empty committee; reasonable.

Severity: LOW.

---

### F1. `clean_slot_periods` drops future entries and periodic past entries

**File:** `primary/src/core.rs:1696-1713`

```rust
let slot_period = slot % self.k;
let k = self.k;

self.consensus_instances.retain(|(s, _), _| s % k != slot_period && s <= &slot);
self.consensus_cancel_handlers.retain(|s, _| s % k != slot_period && s <= &slot);
self.qc_makers.retain(|(s, _), _| s % k != slot_period && s <= &slot);
```

`retain` keeps elements where the predicate is true. The predicate is conjunction:
- `s % k != slot_period` — drops periodic siblings of `slot`.
- `s <= slot` — **drops every entry with `s > slot`**.

Worked example with `slot = 2, k = 4`:

| s | s%k | s%k != 2 | s <= 2 | KEEP | Note |
|---|-----|----------|--------|------|------|
| 1 | 1 | true | true | YES | |
| 2 | 2 | false | true | NO | self, dropped |
| 3 | 3 | true | false | NO | dropped — but still in-flight! |
| 4 | 0 | true | false | NO | dropped |
| 5..∞ | * | * | false | NO | dropped |

After committing slot 2 with k=4, all `consensus_instances`, `qc_makers`, and `consensus_cancel_handlers` for slots 3, 4, 5, … are wiped. Any in-flight slot loses its accumulated votes; the qc_maker is gone; subsequent votes for that slot create a fresh qc_maker that starts from 0 and can never reach quorum without re-receiving every vote.

The likely intent was something like `|s, _| s % k == slot_period || s > slot` (keep this period's bucket and all future), or the inverse — the current code does neither.

**Impact:** HIGH liveness — slots beyond the just-committed slot lose progress every time a commit happens. May be masked in benchmark conditions where slots are committed roughly in order and qc_makers re-fill quickly, but is plainly incorrect.

**Manifests:** benign.
**Verifiable by:** integration test that interleaves slot s+1 voting with slot s commit, observes that qc_maker for s+1 is reset.

---

### F2. Maps without GC

`views`, `tc_makers`, `last_voted_consensus`, `high_qcs`, `high_proposals`, `committed_slots`, `prepare_tickets`, `already_proposed_slots`, `voted_confirm_shadow` are never GC'd in `core.rs`. The only GC functions (`clean_slot`, `clean_slot_periods`) touch `consensus_instances`, `consensus_cancel_handlers`, `qc_makers`.

**Impact:** LOW (unbounded memory growth over long runs); compounds with F1's effects.

---

### G1. `async_delayed_prepare` drops earlier delayed prepares

**File:** `primary/src/core.rs:955-959, 2297-2316`

```rust
if self.during_simulated_asynchrony {
    debug!("Simulating Asynchrony: skip sending Prepare for slot {} view {}. This will trigger a view change", slot, view);
    self.async_delayed_prepare = Some(consensus_message);    // overwrites
    return Ok(());
}
```

`async_delayed_prepare: Option<ConsensusMessage>` (line 149). Any later prepare overwrites; earlier prepares are silently lost. On async end (line 2297-2316), only the last is replayed.

This is benchmark-only behavior, but if `simulate_asynchrony` is ever toggled in production-ish testing it can hide real protocol bugs by suppressing prepares that should have triggered view changes.

**Impact:** LOW (benchmark instrumentation, not production path).

---

### G2. `process_loopback` for Commit forwards to committer without check

**File:** `primary/src/core.rs:1737-1743`

```rust
ConsensusMessage::Commit { slot: _, view: _, qc: _, proposals: _ } => {
    self.tx_committer
        .send(consensus_message)
        .await
        .expect("Failed to send to committer");
},
```

The loopback path fires when `synchronizer.get_proposals` triggered a sync and the missing headers arrived. The pre-loopback path *did* call `is_valid` for the Commit (`verify_commit`), but due to A1 that check does not bind to proposals. By the time the loopback fires, no re-verification happens; the committer at `committer.rs:117` will commit whatever `proposals` it sees (subject to `slot > last_executed_slot`).

So a byzantine Commit that references attacker-chosen headers (which the synchronizer will dutifully fetch) eventually flows into the committer and is applied.

**Impact:** HIGH safety (paired with A1).

---

### G3. `verify_commit` panics on slow-QC id mismatch

**File:** `primary/src/messages.rs:158-161`

```rust
if confirm_id != qc.id {
    panic!("ids don't match");
    return false;
}
```

`verify_commit` is supposed to *return false* for invalid messages — it returns `bool` and is checked via `is_valid` (`core.rs:1253`). The `panic!` is hit whenever the slow-path QC id doesn't match, which is exactly the situation an attacker can craft (or which can arise from a stale state). A byzantine sends a Commit with a Slow QC carrying any wrong id → all honest nodes panic.

This is the SAME shape as E1 (one byzantine packet → all honest nodes down).

**Impact:** CRITICAL (DoS), but specific to the slow-path Commit branch.
**Manifests:** Byzantine-only.

---

## Cross-cutting observations

- **Every place that should bind a signature to "what" the node is attesting to is missing the binding** (A1, A2). The downstream view-change and equivocation bugs are inevitable consequences.
- **`is_valid` mixes input validation with state mutation** (B1's eager `views.insert`). Splitting the function into a pure validator and a separate state advancer would eliminate the side-effect class entirely.
- **`process_consensus_request` performs `consensus_instances.insert` before signature verification** (C1). All inserts into per-slot state should be conditional on verification.
- **`panic!`/`unwrap` on attacker-controlled inputs is pervasive** (E1, E2, D5, G3). A static lint forbidding `unwrap` in functions reachable from message handlers would catch all of these.
- **Two `PartialEq` impls are inverted constants** (A4 returns `true`, A5 returns `false`). Both ought to be `#[derive(PartialEq)]` or explicit field comparisons. The `true` one (TC) kills security entirely.
- **No tests exercise the byzantine view-change paths** — the repository's `tests/messages_tests.rs` and `tests/core_tests.rs` document several bugs by reproducing them, but `cargo test` likely passes because the consensus tests treat all participants as honest.

## What's model-checkable vs. what needs code-level fixing

- TLA+ can capture A1, A2, A3, A4, B1, B2, B3, B4, D1-D4, G2 by modeling messages as records with explicit `proposals` and treating digest/verify per the buggy code paths.
- E1, E2, D5, G3 (panic-based DoS) are easier to test in Rust directly: send the crafted message, assert the receiver task survives.
- F1 (GC predicate) is mechanically verifiable: enumerate (s mod k) values and assert `retain` keeps the intended set.
- A5/A6 are pure code-review issues.

## Suggested ordering for fixes

1. Add `proposal_digest(self)` to every `ConsensusMessage::digest()` branch and to `verify_confirm`/`verify_commit` (fixes A1, removes the magnifier on B2 and most of D).
2. Implement `Timeout::digest` to hash `(slot, view, high_qc?.digest(), high_prop?.digest(), author)` (fixes A2). Also verify `high_qc.qc.verify()` and `high_prop.qc.verify()` inside `Timeout::verify` (fixes A3).
3. Replace `impl PartialEq for TC` with `#[derive(PartialEq)]` or remove the genesis short-circuit from `TC::verify` (fixes A4).
4. Add `committed_slots` and leader checks to `is_valid(Prepare)` (B3, B4).
5. Move `views.insert` after all validity gating (B1).
6. Add `last_voted_consensus.contains((slot, view))` check to `is_valid(Confirm)` (B2).
7. Fix `get_winning_proposals`: track `winning_view` from the QC's own view, not the timeout's; verify embedded QCs (D1, D4); use a proposal-bound digest key for f+1 counting (D3).
8. Remove `unwrap`s and `panic!`s from `is_valid`/`verify_commit` paths; replace with `Result`/`false` (E1, E2, D5, G3).
9. Fix `clean_slot_periods` predicate; better, write tests that pin the intended behavior (F1).
10. Move `consensus_instances.insert` past the verify/is_valid checks (C1); re-verify on `process_loopback` for Commit (G2).

# Autobahn BFT — Bug Archaeology Report

Repository: `specula-org/autobahn-artifact` (branch `autobahn`)
Local path: `/home/ubuntu/Specula/case-studies/autobahn_3/artifact/autobahn-artifact`
Method: enumerate commits touching `primary/`, extract fix-related commits, inspect diffs.

## Coverage Statistics

- Commits touching `primary/`: **175** total.
- Bug-fix related commits (matching `fix|bug|panic|crash|wrong|edge|race|deadlock|hang|leak|forgot|broken`): **88**.
- Commits inspected in detail with `git show`: **30+**.
- Authors of fixes: `fsuri`/`Florian Suri-Payer` (Cornell), `neilgiri` (the Autobahn architects); a handful predate Autobahn (`Alberto Sonnino`, era of Narwhal-HotStuff).
- Time window of Autobahn-era fixes: **Nov 2022 – Dec 2023** (concentrated in the last two months before TLA+ instrumentation).
- Pre-Autobahn (Narwhal-HotStuff) fixes are inherited but not part of the Autobahn-specific bug surface; they are listed separately at the bottom.

---

## High-Value Commit Cards

Each entry: `hash` — title; files; root cause; classification.

### 1. `d0331d9` — "fixed is_special bug with slow path ride sharing on"
- **Files**: `primary/src/proposer.rs` (+3/-1)
- **Diff (key)**: In the `Confirm` consumer the proposer unconditionally set `self.is_special = true`. With ride-sharing on, a Confirm message can ride on a normal car, and that car was incorrectly being marked special.
  ```
  ConsensusMessage::Confirm { ... } => {
  -    self.is_special = true;
  +    if self.use_special_rule { self.is_special = true; }
       self.num_active_instances += 1;
  },
  ```
- **Root cause**: Header categorization (`is_special`) leaked across protocol variants (the "special edge" rule is only valid under `use_special_rule`). Caused normal cars to be promoted to special, breaking parent-cert validation downstream.
- **Class**: Header / `is_special` flag contamination.

### 2. `0c45db0` — "check if special is false"
- **Files**: `primary/src/proposer.rs` (debug log only; companion to d0331d9)
- **Class**: Debug instrumentation while diagnosing the same `is_special` family.

### 3. `3baa668` — "sync clean up fix; gc fix; view change fix"
- **Files**: `primary/src/core.rs` (+38/-22), `primary/src/header_waiter.rs` (+11/-1).
- **Diff (key)**:
  - Cancel-handler map for consensus was keyed by `Height` (DAG round of current header) but consensus is slot-pipelined; changed type to `HashMap<Slot, Vec<CancelHandler>>` so handlers age out with the slot they belong to.
  - `is_valid()` for Prepare with a TC: added `if tc.view + 1 != *view { return false; }` — Prepares with TC from a non-adjacent view were being accepted (safety bug for view change).
  - GC ranges fixed: `s % k != slot_period` was too aggressive; now also requires `s <= slot`, otherwise GC could wipe state for slots not yet committed (only the same residue class older than current).
  - In `process_loopback` for Prepare without ride-share, added a guard `self.last_voted_consensus.contains(&(*slot, *view))` to avoid voting twice in a slot/view.
  - In `header_waiter`, when a Consensus loopback delivers, the corresponding `parent_requests` entries are now cleared so the retry loop stops spamming the network.
  - Disabled redundant broadcasting of TC (since f+1 timeouts trigger mutiny).
- **Root cause**: A bundle of three latent bugs at the GC / view-change / sync seam:
  1. Memory growth and miscleaning of `consensus_cancel_handlers` (leak / over-GC).
  2. View-change accepting a TC from the wrong view (safety violation in slow path).
  3. Sync retry loop never noticing that a consensus loopback satisfied the request.
- **Class**: GC + view-change correctness + sync race (umbrella).

### 4. `f6726fb` — "added View change cancel handlers"
- **Files**: `primary/src/core.rs` (+12/-2)
- **Diff (key)**: Timeout and TC broadcasts previously dropped their `CancelHandler`s on the floor (`self.network.broadcast(...).await`). On view change with a slow follower, those broadcasts could be retried by the network layer forever. Now the handlers are extended into `self.cancel_handlers`.
- **Root cause**: Resource/connection leak in view change broadcast path; messages would keep being retried after view advanced.
- **Class**: GC / resource leak in network layer.

### 5. `cea81f4` — "bug fix for committed old slots triggering timeouts"
- **Files**: `primary/src/core.rs` (+1/-1).
- **Diff (key)**:
  ```
  -if self.timers.contains(&(slot, view)) { return Ok(()) }
  +if !self.timers.contains(&(slot, view)) { return Ok(()) }
  ```
- **Root cause**: Polarity-inverted check in `local_timeout_round`: code returned when the timer was *active*, and continued (triggering a real view change) when it had been *cancelled* (i.e., the slot was already committed). Result: old committed slots fire spurious view changes and produce TCs for slots that are no longer in flight.
- **Class**: Boolean-inversion / liveness regression. The "branch flip" is a textbook bug specifically created by `timers.contains` semantics.

### 6. `136d400` — "added proposal generation after header, fixed slot 1 coverage"
- **Files**: `primary/src/core.rs` (+40/-13)
- **Diff (key)**:
  1. In `process_own_header`, for every Prepare in the header it now **augments** the Prepare's `proposals` with the *current* tips (i.e., the leader fills in proposals at the last possible moment when its own header is finalized) instead of using stale tips from when the consensus instance was created.
  2. Slot-1 path: instead of immediately sending a Prepare for slot 1, it now queues a *ticket* (slot=0, view=0, genesis proposals) into `prepare_tickets`, so slot 1 follows the same coverage-check path as every other slot.
- **Root cause**:
  - Stale tips: A Prepare instance carried whatever tips existed when it was instantiated, even if many new tips arrived before the header was sent. This caused under-coverage (the Prepare wouldn't reflect the latest dissemination).
  - Slot-1 was a special-case codepath that skipped the coverage gate, causing slot 1 to commit nothing in non-trivial cases.
- **Class**: Tip-staleness / proposal generation; pipeline-bootstrapping (slot 1).

### 7. `46b612d` — "fixed bound bug; avoid unnecessary sigs"
- **Files**: `primary/src/core.rs` (+39/-5), `primary/src/primary.rs` (k=2→4), config tweaks.
- **Diff (key)**:
  - The "bounded open instances" check was `if self.committed_slots.contains(&(slot + 1 - self.k))` (returning early if it *was* committed — i.e., backwards). Fixed to `if *slot > self.k && !self.committed_slots.contains(&(slot + 1 - self.k))`. Without `slot > self.k`, the early slots underflow `slot + 1 - self.k`.
  - Removed `self.committed_slots.retain(...)` from the periodic GC: it was wiping committed-slot evidence used by the bound check, causing the bound to spuriously block new prepares forever.
  - Added `check_cast_vote` — only the leader's contiguous 2f+1 successors cast votes for pure cars; reduces sig load.
- **Root cause**: Multiple subtle interacting issues — wrong polarity on bound check, integer underflow in slot arithmetic, and GC erasing the very state needed by the bound check.
- **Class**: Pipelining bound (`k`) / ticket logic + GC interaction.

### 8. `1953ece` — "fix car timer -> make consensus instance independent from current header"
- **Files**: `primary/src/core.rs` (+21/-16), `primary/src/aggregators.rs` (+8/-8), `primary/src/messages.rs` (+6/-1)
- **Diff (key)**:
  - Renamed `completed` → `completed_fast` for `QCMaker` to express that the latch only blocks slow-path use after a fast QC.
  - In `process_vote`, added `consensus_loopback = is_loopback && !vote.consensus_instance.is_some()` and short-circuited the `vote.id != self.current_header.id` guard for that case. Vote is now carried back into the loopback with a `consensus_instance: Option<ConsensusMessage>` field, so when the fast-path timer fires the original consensus instance is still in scope even if the current header has advanced.
  - `qc_makers.clear()` on `process_own_header` was disabled — that was deleting in-flight QC state for slots whose timer hadn't fired yet.
  - Note in TC code that `winning_view` is "slightly imprecise" because different prepares can have different views — flagged as a known issue.
- **Root cause**: The fast-path timer's loopback piggybacked on `current_header`, but the leader could rotate or generate a new header between the QC's quorum-reach and the timer's firing, in which case the consensus instance was no longer referenceable. Symptom: panic / lost QC.
- **Class**: Time-of-check / time-of-use across header rotation; fast-path race.

### 9. `8695f47` — "verify qc_ticket"
- **Files**: `primary/src/core.rs` (+82/-25), `primary/src/messages.rs` (+30/-5), `primary/src/synchronizer.rs` (+65/-5), `primary/src/header_waiter.rs`, `primary/src/proposer.rs`, `primary/src/error.rs`.
- **Diff (key)**:
  - Promoted `committed_slots: HashSet<Slot>` to `HashMap<Slot, CommitQC>` so commit certs can be re-attached as tickets for future Prepares.
  - Added a `qc_ticket: Option<CommitQC>` field on Prepare. New Prepare from slot `s` carries the CommitQC for slot `s-k` so a recipient that hasn't locally committed `s-k` can still verify the bound is respected. Without this, a Byzantine leader could open more than `k` instances by forging a Prepare without local evidence of `s-k` commitment.
  - `process_prepare_message` now calls `process_commit_message` on the received `qc_ticket` first (if not already locally committed) and rejects if `commit_qc.slot + self.k != slot`.
- **Root cause**: The bound on open instances was enforced *locally* (each replica required local commit of `s-k`) but not *cryptographically* (the leader did not have to prove it). A Byzantine leader could spam Prepares for arbitrarily many slots; honest replicas would just buffer them but the protocol invariant was nominally violated.
- **Class**: QC/cert verification — missing cryptographic evidence for pipelining bound (safety against Byzantine leader).

### 10. `12d26c4` — "fixed ticket view to match qc/tc and adjusted generate proposal"
- **Files**: `primary/src/messages.rs` (+5/-5), `sailfish/src/core.rs` (+37/-20).
- **Diff (key)**:
  - `Ticket::new`: re-ordered arguments and rebuilt construction: a ticket's `view` is now always set to the **associated QC/TC's view**, not `self.view` (latest view). Old code: `Ticket::new(qc.unwrap(), tc, header_digest, self.view)`. New code: tc-path uses `tc.view`, qc-path uses `quorum_cert.view`.
  - `Ticket::genesis().view` changed from 1 → 0 to match the new "previous-view ticket" semantics.
  - In `process_qc`, accepts the genesis QC as a no-op without verification.
  - `generate_ticket_and_commit`: only sends the ticket forward to the proposer if `ticket.view == self.view - 1` (no resurrecting tickets from old views).
- **Root cause**: Tickets carried `self.view` instead of the view of the embedded certificate, so any TC/QC from view `v` could be combined with a current-view tag for some higher `v'`, leading to confusion in `process_ticket` (which compares `header.view == ticket.qc.view + 1`).
- **Class**: View-change correctness (ticket view tagging).

### 11. `5915535` — "TC verify view_round"
- **Files**: `primary/src/messages.rs` (+3/-3), `sailfish/src/core.rs` (+25/-11).
- **Diff (key)**:
  - In `TC::verify` for each of three "winning" variants (high_prepare, high_accept, high_qc): added `&& self.view_round == winning_prepare.round` (and analogous for cert / qc).
  - In `process_ticket`: added `ensure!(header.round > tc.view_round)` and `ensure!(header.round > ticket.qc.view_round)`.
- **Root cause**: A TC's `view_round` (used to enforce monotonic consensus round across views) was not cross-checked against the winning proposal's round. A Byzantine leader could supply a TC with a `view_round` smaller than the actual winning proposal's round, then propose a header with a smaller round, breaking the monotonicity invariant.
- **Class**: View-change correctness — TC validation.

### 12. `1f29166` — "implement delayed prep wake"
- **Files**: `primary/src/core.rs` (+12/-6)
- **Diff (key)**: Added `async_delayed_prepare: Option<ConsensusMessage>`. In `send_consensus_req`, if `during_simulated_asynchrony`, the Prepare is buffered instead of being sent. When the async-end timer fires, the buffered Prepare is sent (if still relevant — see d69308f below). Also moves `self.set_consensus_proposal(...)` from after the asynchrony check to before it, so the buffered Prepare contains up-to-date proposals.
- **Root cause**: Prepares emitted during simulated asynchrony were dropped entirely, including ones that were the leader's first attempt — after async ended, no one ever re-issued them, causing liveness loss instead of just delayed commit.
- **Class**: Liveness across view change (delayed wake) — async simulation correctness.

### 13. `d69308f` — "small add on" (companion to 1f29166)
- **Files**: `primary/src/core.rs` (+8/-1)
- **Diff**: Added a "still-relevant" check before flushing `async_delayed_prepare`: it only sends if the slot's current view matches the buffered view.
- **Root cause**: Otherwise the post-asynchrony wake-up could resend a Prepare for a view that had since timed out, doubling work.
- **Class**: Liveness wakeup — TOCTOU on view.

### 14. `3332eea` — "adjusted async timers to start upon slot 1 commitment"
- **Files**: `primary/src/core.rs` (+11/-2)
- **Diff (key)**: Moved the `if self.simulate_asynchrony { ... push async_start/async_end timers ... }` block from `Core::run()` startup into the slot-1 Commit handler. The startup-time variant is commented out.
- **Root cause**: Async timers started at boot-time, before the system had even bootstrapped. They could fire while the cluster was still warming up, killing slot 1 forever.
- **Class**: Timer scheduling — bootstrap race.

### 15. `331f20e` — "forgot slot 1 check"
- **Files**: `primary/src/core.rs` (+1/-1)
- **Diff**:
  ```
  -if self.simulate_asynchrony {
  +if self.simulate_asynchrony && *slot == 1 {
  ```
- **Root cause**: Companion to 3332eea: the async-timer push lacked the slot-1 guard, so the timers got pushed on *every* Commit (replaying the bug at every slot).
- **Class**: Timer scheduling — bootstrap race (follow-up).

### 16. `d0da347` — "fixed proposer round edge case"
- **Files**: `primary/src/core.rs` (+1/-1), `primary/src/proposer.rs` (+9/-1), `sailfish/src/core.rs` (+11/-1)
- **Diff (key)**: In `Proposer::run`, when receiving a parent or a previous-special-block round, the increment of `self.round` was only triggered if `round > self.round`. New code also handles the case `round == self.round && self.last_header_round == self.round`, which previously left the proposer stuck at the same round (its next header would re-use the previous round).
- **Root cause**: Off-by-one when special-block-round equals current round and parents have already been received: the round wasn't bumped, so the proposer issued a duplicate-round header.
- **Class**: Tip-update / proposer-round edge case.

### 17. `bd6325e` — "clear committed timer"
- **Files**: `primary/src/core.rs` (+62/-4)
- **Diff (key)**: In Commit handler: `self.timers.remove(&(*slot, *view))`. In `local_timeout_round`: `if self.timers.contains(...) return Ok(())` — this is the predecessor of the cea81f4 inversion bug (the **wrong sense** of the check was introduced here, then *un-inverted* in cea81f4 a few weeks later).
- **Root cause**: Timer-state was never cleaned on commit, so committed slots later fired timeouts. Also re-introduces a subtle inverted check (see cea81f4 for fix).
- **Class**: GC and timer cleanup (introduces the chain of bugs that cea81f4 finishes fixing).

### 18. `6b58036` — "small re-factor to is_prepare_ticket_ready"
- **Files**: `primary/src/core.rs` (+79/-42)
- **Diff (key)**: Refactored the prepare-ticket flow:
  - Buffers prepares now re-checked on every relevant event via `try_prepare_waiting_slots`.
  - Renamed `max_open_consensus_instances` → `k`.
  - Switched bound check to use `committed_slots` directly (with `s - k`) instead of `last_committed_slot + k`.
  - Re-buffer the prepare instead of dropping it when bound is exceeded.
- **Root cause**: Earlier logic could drop prepare tickets silently when the bound was hit, never re-checking; on slow paths the queue would deadlock waiting for `last_committed_slot` to catch up.
- **Class**: Ticket/coverage logic — buffer-loss / deadlock.

### 19. `b68c08e` — "added consensus_instance map; gc updated"
- **Files**: `primary/src/core.rs` (+72/-35), `primary/src/messages.rs` (+24/-9)
- **Notes**: Introduced `consensus_instances` map so that votes arriving after the originating header has advanced can still find the instance (precondition for 1953ece). Also reworked GC ranges.
- **Class**: QC/cert verification + GC scaffolding.

### 20. `eee683a` — "avoid unnecessary vote signature processing for cars"
- **Files**: `primary/src/core.rs` (+45/-7), `primary/src/aggregators.rs` (+1/-1), `primary/src/error.rs` (+4/-1)
- **Diff**: Fixed `check_cast_vote` — original counted votes the wrong direction (skipped the leader, didn't skip the trailing `f`). Returns early with `CarAlreadySatisfied` when QC already complete and the vote carries no consensus content; otherwise processes but skips signature verification. Saves expensive signatures and avoids spurious work.
- **Class**: QC/cert verification — performance correctness for cars.

### 21. `a1ecd2d` — "added timer logic; still panics"
- **Files**: `primary/src/core.rs` (+72/-16), `primary/src/aggregators.rs` (+18/-4), `primary/src/timer.rs` (+8/-6)
- **Diff (key)**: Introduces `CarTimer` (renamed from FastTimer) and a dummy-vote pattern: when fast-path QC isn't ready, the code constructs a fake vote whose `consensus_sigs` contains only the missing digest. The Vote later loops back through `process_vote`, where the timer detection branch (`is_loopback && vote.consensus_sigs.is_empty()`) is used. Also introduces the `complete: bool` latch on `VotesAggregator` and the `first` boolean on QCMaker to guarantee a timer is started exactly once. Notes "still panics" in commit message — clear iteration during stabilization.
- **Class**: Fast-path/slow-path timer state machine; race introduced in scaffolding.

### 22. `ab514d2` — "small fix; still panic"
- **Files**: `primary/src/core.rs` (+1/-1)
- **Diff**:
  ```
  -let dissemination_cert = match consensus_ready || car_timeout { ... };
  +let dissemination_cert = match car_cert_ready && (consensus_ready || car_timeout) { ... };
  ```
- **Root cause**: `dissemination_cert` was being read out of the aggregator before the dissemination-quorum threshold was hit — could send `None` or partial certs. Note: "still panic" so the fix only addressed one symptom.
- **Class**: Aggregator / certificate readiness race.

### 23. `4654261` — "small edit" (companion to ab514d2)
- **Files**: `primary/src/core.rs` (+3/-1)
- **Diff**: Hoists `let consensus_ready = consensus_ready || car_timeout;` so subsequent checks see the unified value. Cleanup of the same race.
- **Class**: Aggregator / certificate readiness race (cleanup).

### 24. `b0f2784` — "fix"
- **Files**: `primary/src/aggregators.rs` (+13/-0), `primary/src/core.rs` (+1/-2)
- **Diff (key)**:
  - `VotesAggregator::get` now serves the cert exactly once (`get_once: bool` latch); subsequent calls return `None`. Prevents duplicate broadcast if a timer loops back after the cert was already used.
  - `QCMaker::get_qc` (used by fast-path timer) early-returns `None` if `completed_fast`. Prevents fast-path timer from re-emitting a QC when a fast QC has already won.
  - `qc_opt.is_none()` branch now gated by `self.use_fast_path` — don't start the FP timer if FP is disabled.
- **Class**: Idempotency / "use once" — race on timer loopback duplicates.

### 25. `cd48a2f` — "small fix"
- **Files**: `primary/src/core.rs` (+4/-4)
- **Diff**: Moves the cancel-handler insertion from `self.cancel_handlers` (keyed by header height) into `self.consensus_cancel_handlers` (keyed by `slot`). Companion to 3baa668.
- **Class**: GC bookkeeping — wrong handler map.

### 26. `3036137` — "adjust sync parameterization; still broken"
- **Files**: `primary/src/core.rs` (+7/-7), `primary/src/helper.rs` (+1/-1), `primary/src/primary.rs` (+1/-1)
- **Class**: Sync-loop parameter tuning (still buggy at commit time).

### 27. `1297fc6` — "changed timer resolution to not trigger"
- **Files**: `primary/src/header_waiter.rs` (1 line: `TIMER_RESOLUTION` 1s → 20s).
- **Root cause**: Sync re-request timer firing far too often was overwhelming the network; this is a hack to "not trigger" until proper fix (later reverted in 79616c5).
- **Class**: Sync timer tuning.

### 28. `f267175` — "changed parent to be header waiter"
- **Files**: `primary/src/header_waiter.rs` (+2/-2)
- **Diff**: Parent sync re-requests now send `HeadersRequest` instead of `CertificatesRequest`.
- **Root cause**: Re-request used the wrong message type, so the helper on the other end returned the wrong artifacts (certificates, not headers), leaving the waiter blocked forever.
- **Class**: Sync race — wrong message type on retry.

### 29. `ff40ed8` — "fixed capped payload"
- **Files**: `primary/src/proposer.rs` (+19/-2)
- **Diff**: `make_header` previously did `self.digests.drain(..1)` (always taking 1 digest), but when there were no digests this was a no-op silently. Now constructs a header with empty digests when the queue is empty (later reverted in `7147e18`).
- **Class**: Proposer edge case — empty-payload header.

### 30. `7147e18` — "removed capping"
- **Files**: `primary/src/proposer.rs` (+12/-3)
- **Diff**: Reverts the conditional branching from `ff40ed8`, going back to `self.digests.drain(..)` (all digests) instead of the cap.
- **Class**: Performance regression revert.

### 31. `101cf3a` — "small opt for leader tip with cert"
- **Files**: `primary/src/core.rs` (+5/-0)
- **Diff**: In `process_own_header`, immediately inserts the new header into `current_proposal_tips` (or `current_certified_tips`) so that the coverage check used by `try_prepare_waiting_slots` sees the leader's own latest tip without waiting for it to come back via the broadcast.
- **Class**: Tip update logic — self-tip not visible to coverage check.

### 32. `5b09047` — "fast path timers in working"
- **Files**: `primary/src/core.rs` (+19/-4), `primary/src/aggregators.rs` (+3/-3), `primary/src/timer.rs` (+34/-2)
- **Class**: Fast path scaffolding (predecessor of a1ecd2d/ab514d2 era).

### 33. `33ab623` — "bug fix" (sailfish era)
- **Files**: `primary/src/aggregators.rs` (+1/-1), `primary/src/core.rs` (+2/-0), `sailfish/src/core.rs` (+39/-29)
- **Diff (key)**:
  - In `handle_tc`, when the TC supplies a winning header or cert, the replica must **adopt** it as its high_prepare/high_accept even if the local one has a higher view (the local one cannot have committed since it lost the TC race). Added `tc_force: bool` parameter to `update_high_prepare`/`update_high_accept`.
  - `process_prepare` and `process_accept` no longer call `advance_view`; they just `max(self.view, header.view)`. View advance is now a TC-driven action only.
- **Root cause**: Safety bug in view-change recovery: an honest replica with a high local prepare could refuse to adopt the TC's winning proposal, splitting the proposal-set across replicas and breaking the safety guarantee that all honest replicas commit the same value.
- **Class**: View-change correctness — adoption of winning proposal.

### 34. `cb33b7e` — "First View Change code pass"
- Origin of the view-change code; not a bug fix but the genesis of many bugs subsequently fixed.

### 35. `0db5842` — "view change code"
- Larger view-change scaffolding (+108 sailfish, +336 messages).

### 36. `9e27533` — "fixed process_cert bug in DAG; added waiter for special parent"
- **Files**: `primary/src/core.rs` (+5/-3), `primary/src/messages.rs`, `sailfish/src/committer.rs` (+18/-4), `sailfish/src/synchronizer.rs`, `primary/src/certificate_waiter.rs`
- **Root cause**: `process_cert` was processing certs without waiting for the special parent header to be present, causing committer to crash on missing parent.
- **Class**: Synchronizer race / committer dependency.

### 37. `49351a5` — "small fix to process_header validation"
- **Files**: `primary/src/core.rs` (+6/-2), `sailfish/src/committer.rs` (+6/-5)
- **Diff (key)**: Stronger checks on special-parent: `parents[0].round() == header.special_parent_round && header.special_parent_round + 1 == header.round` and `parents[0].origin() == header.author`.
- **Root cause**: Earlier check only verified parent round; allowed mismatched origin or skipped rounds. Allowed Byz authors to claim others' special edges.
- **Class**: Header validation — special-edge spoofing.

### 38. `769b27d` — "Changed the check for whether we have enough valid"
- **Files**: `primary/src/core.rs` (+2/-1)
- **Diff**: `certificate.special_valids[0] == 1 && matching_valids(...)` → `(sum as u32) >= self.committee.quorum_threshold()`.
- **Root cause**: Old check required *all* valids to match — failed in the presence of a single Byz vote (could only forward to consensus if every special_valid was 1). Should be a quorum check.
- **Class**: Quorum threshold check — special validation.

### 39. `a578267` — "Fixed first quorum issue"
- **Files**: `primary/src/aggregators.rs` (+3/-2), `primary/src/core.rs` (+2/-2)
- **Diff**: `first_quorum` flag was being mutated *before* it was read, so the returned tuple always said `first_quorum = false`. Now the value is captured into `is_first_quorum` before mutation.
- **Class**: Aggregator state race — read-after-write on flag.

### 40. `277ba01` — "re-factored invalidation handling + added stake to special_valid"
- **Files**: `primary/src/aggregators.rs` (+39 lines), `primary/src/core.rs` (massive refactor)
- **Class**: Invalidation handling refactor — bugfix-by-rewrite.

### 41. `3659f6f` — "fixed 0 bug; + ensure special edge rule"
- **Files**: `primary/src/core.rs` (+13/-3), `primary/src/messages.rs` (+8/-2), `sailfish/src/committer.rs` (+50/-11), `sailfish/src/core.rs` (+2/-0), `primary/src/error.rs` (+3/-0)
- **Diff (key)**:
  - Special-edge rule: special parent must itself not have a special parent (no chains of "special skips"). `ensure!(special_parent_header.special_parent.is_none(), MalformedSpecialHeader(...))`.
  - Committer: round-1 special blocks could have genesis as parent; switched genesis check from `round() == 1` to a hash-set membership check `certificate.header.parents == self.genesis_digests`.
  - New error type `MalformedSpecialHeader`.
- **Class**: Special-edge rule enforcement; genesis comparison.

### 42. `59b4496` — "fix dummy cert parent quorum inclusion"
- **Files**: `primary/src/aggregators.rs` (+5/-0)
- **Diff**: `CertificatesAggregator::append` now returns `None` for certs with empty `votes` (dummy certs), so they don't count toward the parent quorum.
- **Class**: Quorum-counting bug — dummy certs admitted.

---

## Bug Families (mechanism-based grouping)

Each family groups commits by the *kind* of bug regardless of which file was touched.

### Family A — View-change correctness (safety)
Bugs in how TC/QC tickets are formed, verified, and used to recover after a leader failure.

- `12d26c4` Ticket view tagged with `self.view` instead of QC/TC view.
- `5915535` TC `view_round` not cross-checked against winning proposal round.
- `8695f47` `qc_ticket` introduced as cryptographic proof that `s-k` is committed; otherwise Byz leader could bypass the bound `k`.
- `33ab623` In `handle_tc`, force adoption (`tc_force=true`) of the winning proposal even if local high-prepare has a higher view.
- `3baa668` (part): Prepare with TC accepted only when `tc.view + 1 == view`.
- `cb33b7e` `0db5842` (scaffolding — these set up the bugs above).

**Why this is one family**: each is a way the view-change machinery can either accept a malformed TC/QC or fail to recover to the right state. Some are pure safety (8695f47, 33ab623, 5915535), some are pure liveness (3baa668-part).

### Family B — Timer cleanup / GC / handler leaks
- `cea81f4` Inverted boolean in `local_timeout_round` → committed slots fire timeouts.
- `f6726fb` `network.broadcast` cancel handlers dropped for Timeout and TC broadcasts.
- `3baa668` (part): `consensus_cancel_handlers` keyed by Height instead of Slot, never GC'd.
- `cd48a2f` Wrong cancel-handler map used (height vs slot).
- `46b612d` (part) GC `retain` was wiping `committed_slots` referenced by bound check.
- `bd6325e` Commit handler didn't clean timer state.
- `1297fc6` `79616c5` `f267175` Sync retry timer-resolution thrashing.

**Why one family**: all are bookkeeping bugs where memory or wall-clock timers either accumulated forever (leak) or were dropped when they shouldn't be (premature GC). The single most-touched file is `core.rs`'s timer/handler maps.

### Family C — Ticket / coverage logic (pipelining)
- `46b612d` Bound check polarity wrong (`!committed_slots.contains` vs `committed_slots.contains`); also slot underflow for early slots.
- `6b58036` `is_prepare_ticket_ready` refactor — old code silently dropped tickets when bound was hit.
- `136d400` Slot-1 bypassed the coverage gate; Prepares used stale tips.
- `101cf3a` Leader's own tip not visible to coverage check until rebroadcast.
- `b68c08e` `consensus_instances` map introduced for ride-share votes.

**Why one family**: all relate to "open instance bound `k`" + "enough coverage" rule — Autobahn's pipelining heart. Each bug either over- or under-throttles the leader's Prepare emission.

### Family D — Header/proposal categorization (`is_special`, payload)
- `d0331d9` `is_special` wrongly set unconditionally on Confirm under ride-share.
- `0c45db0` Debug instrumentation (companion).
- `ff40ed8` / `7147e18` Empty-payload header handling (capped vs uncapped).
- `49351a5` Special-parent validation strengthened.
- `3659f6f` Special-edge rule enforcement (chain depth limit).
- `277ba01` Invalidation handling refactor.
- `44f65c4` Vote digest fix.

**Why one family**: bugs in the "what kind of block am I making" decision, including special-edge correctness and payload bookkeeping.

### Family E — Fast-path / Slow-path race & aggregator state
- `1953ece` Vote loopback decoupled from current_header (so timer-fired loopback finds its instance even if header rotated).
- `a1ecd2d` First scaffolding of CarTimer + per-aggregator "first" / "complete" flags ("still panics").
- `ab514d2` `dissemination_cert` race — read before threshold met.
- `4654261` Hoist `consensus_ready || car_timeout` for consistency.
- `b0f2784` `get_once` latch on `VotesAggregator`, `completed_fast` on `QCMaker`, gate FP timer on `use_fast_path`.
- `5b09047` `bd6325e` (scaffolding).
- `eee683a` `check_cast_vote` direction bug; `CarAlreadySatisfied` early-out.
- `a578267` `first_quorum` returned-after-mutated bug.
- `59b4496` Dummy certs counted toward quorum.

**Why one family**: each is a way the aggregator/QCMaker state machine races with itself when the fast-path timer loops back, or counts votes incorrectly. Affects both safety (extra QCs, dummy certs admitted) and liveness (cert never released).

### Family F — Bootstrapping / first-slot edge cases (`slot 1`, genesis)
- `3332eea` Async timer moved from boot to slot-1 commit.
- `331f20e` Slot-1 guard restored.
- `136d400` Slot-1 ticket queued like all others.
- `3659f6f` Genesis comparison broadened beyond `round() == 1`.
- `4f3821d` Genesis cleanup.

**Why one family**: bootstrapping never gets enough test coverage, and Autobahn has multiple "first" cases — first slot, first view, genesis-parent — each with its own bug.

### Family G — Sync race / message routing
- `f267175` Wrong message type on retry (`CertificatesRequest` vs `HeadersRequest`).
- `3baa668` (part): Loopback didn't clear `parent_requests`.
- `9e27533` `process_cert` race with special-parent waiter.
- `3036137` Sync parameterization (still broken at commit).
- `1297fc6` `79616c5` Sync timer-resolution.

**Why one family**: synchronizer/waiter never sees that a request was satisfied or asks the wrong question, leading to retry storms or hangs.

### Family H — Async-simulation liveness (delayed wake)
- `1f29166` Buffer Prepare during simulated asynchrony and replay on end.
- `d69308f` Still-relevant guard on the replay.

(Smaller family — only relevant in the asynchrony-injection harness, but illustrates the "lost Prepare on async end" liveness bug pattern.)

### Family I — Proposer round monotonicity
- `d0da347` Proposer didn't bump round on certain "round == self.round" parent-arrival paths.

(Stand-alone but matches the "tip update" mechanism.)

---

## Pre-Autobahn (Narwhal-HotStuff) commits — for context only
Touched `primary/` but predate Autobahn architecture (`sailfish` branch):

- `2f704d2` Fix consensus bug + tests — `order_dag` and `order_leaders` now check `last_committed` correctly.
- `19ccffc` Fix consensus corner case — `state.dag.get(...).expect(...)` panic when ancestors were GC'd; switched to `.map(...).flatten()` to skip.
- `baa9b20` Use `self.name` (not `author`) when sending sync request to worker.
- `04f007d` Broad refactor with config changes.

These are inherited Narwhal-HotStuff bugs, not Autobahn-specific.

---

## Aggregate Observations

1. **The largest cluster of fixes is in `primary/src/core.rs`** (~25 of the 30 inspected commits touch it). It is the hub for vote aggregation, timer state, GC, and view-change logic.
2. **Boolean inversion / off-by-one is the most repeated *concrete* defect class**: cea81f4 (`!contains`), 46b612d (bound polarity), a578267 (read-after-write on `first_quorum`), eee683a (vote-count direction), 769b27d (sum vs `[0]==1`).
3. **Cancel handlers and GC accounted for the most distinct commits** — five separate fixes in this family (f6726fb, cd48a2f, 3baa668, 46b612d, bd6325e), suggesting the GC story was the hardest to get right in the slot-pipelined model.
4. **Safety-relevant bugs**: 8695f47 (qc_ticket cryptographic bound), 33ab623 (tc_force adoption), 5915535 (TC view_round check), 12d26c4 (ticket view), 49351a5 (special-parent origin check), 3659f6f (special-edge depth). These six commits represent the *safety perimeter* of the protocol.
5. **Liveness-relevant bugs**: cea81f4 (false timeout firing), 1f29166 (lost Prepare on async), f6726fb (unbounded resends), 3baa668-sync (parent_requests stuck), 6b58036 (dropped ticket), 136d400 (slot 1 stuck).
6. **"Still panic" / "still broken" commits** (a1ecd2d, ab514d2, 3036137) signal an iterative bug-hunt period — these are scaffolding commits where the developer knew an issue remained.
7. **The TLA+ instrumentation commits** (`bf897ef`, `22f1faa`, `cb2a415`) are at the head of history — *after* the bug hunt — consistent with using TLA+ as a post-hoc validation tool on the stabilized implementation.

## Closing note on falsifiable claims for spec-mining

Several of these bugs map directly to TLA+ invariants worth checking against the spec:

- **8695f47** ⇒ check: every Prepare for slot `s` (s > k) is accompanied by a commit-QC for `s-k`.
- **5915535** ⇒ check: every TC's `view_round` equals the round of its winning proposal.
- **33ab623** ⇒ check: after applying a TC, every honest replica's high_prepare/high_accept matches the TC's winning proposal regardless of local state.
- **cea81f4** ⇒ check: a committed (slot, view) never triggers a timeout.
- **46b612d** + **8695f47** ⇒ check: at most `k` consensus instances are open per honest replica.
- **3659f6f** ⇒ check: special_parent.special_parent is None (no chained special edges).
- **a578267** ⇒ check: the "first quorum" signal is sent exactly once per certificate (idempotency of aggregator).

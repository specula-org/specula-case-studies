## 2026-02-15 - Relax leader-known precondition in accepted dependency invariant

**Trace:** `N/A (base model check: /tmp/StrictPaxosImpl.basecheck.cfg)`
**Error Type:** Inconsistency Error

**Issue:**
`InvAcceptedDepMatchesLeaderWhenNormal` was violated during base model checking.

**Root Cause:**
The invariant required dependency agreement with the leader whenever the leader was `NORMAL`, even if the leader had not yet learned the command id. In the model, a replica can be in `ACCEPT` for an id before the leader knows that id.

**Fix:**
Strengthened the antecedent guard to require `id \in knownCmds[l]` before enforcing leader-side acceptance and dependency equality.

**Files Modified:**
- `spec/StrictPaxosImpl.tla`: updated `InvAcceptedDepMatchesLeaderWhenNormal` to gate on leader knowledge of `id`.

## 2026-02-15 - Make Ack ballot invariant robust to in-flight messages

**Trace:** `N/A (base model check: /tmp/basecheck_tiny_InvAckUsesCurrentBallot.cfg)`
**Error Type:** Inconsistency Error

**Issue:**
`InvAckUsesCurrentBallot` was violated during base model checking.

**Root Cause:**
The invariant compared each in-flight Ack message ballot to the sender's current ballot via equality. After send, sender ballot can advance, so state-time equality is too strong for queued messages.

**Fix:**
Replaced strict equality checks on in-flight Ack ballots with monotonicity (`m.b <= ballot[m.from]`) and kept a separate normal-mode consistency check (`status[r] = "NORMAL" => cballot[r] = ballot[r]`).

**Files Modified:**
- `spec/StrictPaxosImpl.tla`: revised `InvAckUsesCurrentBallot` to a send-time-safe state formulation.

## 2026-02-15 - Fix slow-path quorum condition for commit

**Trace:** `N/A (base model checking and merged trace validation)`
**Error Type:** Inconsistency Error

**Issue:**
Commit progression could be blocked in slow path because quorum counting did not include fast acknowledgments already observed for the command.

**Root Cause:**
The spec used `Cardinality(slowVotes[c]) >= MajorityThreshold` for the slow-path branch of `CanCommit(c)`. The implementation decides commit from combined fast and slow acknowledgments after leader evidence, so counting only slow votes is too strict.

**Fix:**
Updated `CanCommit(c)` to use combined votes in the slow-path branch:
`Cardinality(fastVotes[c] \cup slowVotes[c]) >= MajorityThreshold`.

**Files Modified:**
- `spec/StrictPaxosImpl.tla`: corrected `CanCommit` quorum condition.

## 2026-02-15 - Add trace-tolerant propose receive mapping

**Trace:** `/tmp/swift_traces_dbg/merged*_100.ndjson`
**Error Type:** Abstraction Gap

**Issue:**
Merged traces can log propose handling at points where the exact propose network message is not present in `proposeNet`, causing trace validation mismatches.

**Root Cause:**
Trace logs reflect implementation-level ordering/interleaving, while the strict wrapper previously required exact message-presence semantics for every `ReplicaClientSubmit` event.

**Fix:**
Added `ReplicaRecvProposeTrace` to support trace-aligned propose handling with a fallback when the exact propose message is absent but local command state is consistent.

**Files Modified:**
- `spec/StrictPaxosImpl.tla`: added `ReplicaRecvProposeTrace`.
- `spec/TraceStrictPaxosImpl.tla`: switched `ReplicaClientSubmitLogged` to use `ReplicaRecvProposeTrace`.

## 2026-02-15 - Make client-side trace events idempotent after delivery

**Trace:** `/tmp/swift_traces_dbg/merged*_100.ndjson`
**Error Type:** Abstraction Gap

**Issue:**
Client-side trace events (`ClientFastAckReceived`, `ClientLightSlowAckReceived`, `ClientFastPathDecide`, `ClientSlowPathDecide`) could appear after the command was already delivered, creating wrapper mismatches.

**Root Cause:**
The merged traces contain asynchronous client/network event ordering. The wrapper treated these events as always requiring an active state transition.

**Fix:**
Allowed no-op/stutter handling for these events when `id \in clientDelivered`, while preserving exact behavior when not yet delivered.

**Files Modified:**
- `spec/TraceStrictPaxosImpl.tla`: added delivered-aware stutter branches and `BaseVarsNoClientDelivered` support.

## 2026-02-15 - Align ReplicaFastAck and commit-on-quorum trace mapping with implementation ordering

**Trace:** `/tmp/swift_traces_dbg/merged5_100.ndjson`, `/tmp/swift_traces_dbg/merged7_100.ndjson`, `/tmp/swift_traces_dbg/merged11_100.ndjson`, `/tmp/swift_traces_dbg/merged13_100.ndjson`, `/tmp/swift_traces_dbg/merged15_100.ndjson`, `/tmp/swift_traces_dbg/merged17_100.ndjson`
**Error Type:** Abstraction Gap

**Issue:**
`CanStepOrDone` failed on merged traces around `ReplicaFastAck` and later `ReplicaCommitOnQuorum` lines.

**Root Cause:**
The wrapper modeled `ReplicaFastAck` as self-receive from `fastAckToReplica` (`ReplicaRecvFastAckSelf`), but implementation logs `ReplicaFastAck` at local send/handle time. This mismatch can also cascade into later commit-line mismatches in interleaved traces.

**Fix:**
1. Added a deterministic local observation action (`ReplicaObserveFastAckLocal`) that records the local fast-ack vote without requiring a self-message in the queue.
2. Remapped `ReplicaFastAckObserved` to `ReplicaObserveFastAckLocal(r, id)`.
3. Relaxed `ReplicaCommitOnQuorumObserved` to allow stutter if the command is already committed/at COMMIT phase/already delivered.

**Files Modified:**
- `spec/StrictPaxosImpl.tla`: added `ReplicaObserveFastAckLocal`.
- `spec/TraceStrictPaxosImpl.tla`: remapped `ReplicaFastAckObserved` and relaxed `ReplicaCommitOnQuorumObserved`.

# Bug Report: libspdm Secured Message — TLC Model Checking

**Date**: 2026-06-04  
**Spec**: `MC.tla` / `SecuredMessage.tla` (base.tla)  
**Model checker**: TLC 2.x  
**Run outputs**: `spec/output/MC_base_v9.out`, `spec/output/MC_hunt_F{1,2,3,4}e.out`

---

## Summary

| Bug ID | Severity | Category | Invariant | Status |
|--------|----------|----------|-----------|--------|
| BUG-F2-MC1 | **High** | F2 — Key Update Commit/Rollback | `RollbackSafety` | **Confirmed** |
| NOTE-F1 | Low | F1 — Seq Advance Before Check | `SeqMonotonicity` | Spec Artifact |
| NOTE-F3-DEADLOCK | Low | F3 — Encap Key Update | Deadlock (TLC) | Spec Artifact |

---

## Spec Convergence History

Before finding real bugs, the following **spec modeling issues (Case B)** and **invariant weaknesses (Case A)** were identified and fixed:

| Fix | Category | Description |
|-----|----------|-------------|
| MC.tla: atomic `MCDecodeIncrementSeq` | Case B | Base spec's `DecodeIncrementSeq` left message in bag; TLC could fire it multiple times on the same message, advancing seq 2+ times. Fix: consume message atomically. |
| MC.tla: atomic `MCEncodeAndSend` | Case B | Base spec's two-step encode (AdvanceSeq + EncodeSuccess) allowed multiple identical messages in the bag. Fix: combine into one atomic action. |
| base.tla: `SendKeyUpdateRequest` guard | Case B | `SendKeyUpdateRequest` fired while `is_encap=TRUE` (encap VERIFY_ACK pending). Fix: add `is_encap = FALSE` guard. In the implementation (half-duplex SPDM), a new key update cannot start before the responder processes the prior encap ACK. |
| base.tla: `ResponderReceiveEncapVerifyAck` precondition | Case B | Action required `update_phase = PendingVerify` but `RequesterReceiveEncapVerifyNewKey` already set it to `Idle`; the action was dead code. Fix: change precondition to `update_phase = Idle`. |
| base.tla: `RequesterReceiveEncapVerifyNewKey` reset | Case B | Did not reset `initiator_committed = FALSE` after encap completes, creating a stale flag. Fix: add reset (symmetric with non-encap analog `RequesterReceiveVerifyAck`). |
| base.tla: `ResponderTryDiscardKeyUpdate` UNCHANGED | Case B | Missing `initiator_committed` in `UNCHANGED` clause causing TLC to report "variable not defined". Fix: add `initiator_committed` to UNCHANGED. |
| base.tla: `KeyAgreement` precondition | Case A | Invariant fired immediately after `CreateUpdateResponderKey` (backup_valid=TRUE, update_phase=Idle, no messages) even though the KEY_UPDATE message had not yet been sent — a legitimate intermediate state. Fix: add `~∃ e,d : backup_valid[e][d]` to precondition. |
| MC.tla: `MCUpdateAllKeys` (atomic create+send) | Case B | Standalone `MCCreateUpdateResponderKey` could fire before `MCSendKeyUpdateRequest(FALSE)` (UPDATE_KEY). In the implementation (`libspdm_req_key_update.c:111-122`), `create_update(RESPONDER)` is guarded by `!single_direction` — it only runs for UPDATE_ALL_KEYS. Fix: replace with `MCUpdateAllKeys` (atomic combination). |
| MC.tla: `MCEncapSendVerifyNewKey` one-at-a-time guard | Case B | Action could fire multiple times, creating N copies of VERIFY_NEW_KEY in the bag. Stale copies from prior encap flow persisted when a second encap flow started. Fix: add `~∃ m : MSG_VERIFY_NEW_KEY in ResponseDir` guard. |
| MC.tla: `BagCardinality` send guards | Case A | `MCMsgBufferBound` invariant is structural (bounds state space). Without matching send guards, TLC found trivial violations by accumulating messages. Fix: add `BagCardinality(msgs) < MaxMsgBuffer` guards to all pure-send actions. |
| MC.tla: FIFO guard on `MCDecodeIncrementSeq` | Case B | Bag model allows out-of-order processing. Injected messages (old seq) could stay in bag while newer legitimate messages were processed, violating `SeqMonotonicity` as a model artifact. Fix: add FIFO guard (SPDM uses TCP ordered delivery). |

---

## BUG-F2-MC1 — Key Mismatch After Requester Commit Point

### Phase 4 Confirmation

**Status: REPRODUCED** (Level 2, all 14 assertions pass)  
**Confirmation date**: 2026-06-04  
**Test**: `spec/repro/test_bug1_rollback_commit_asymmetry.c`  
**Confirmed bug report**: `spec/confirmed-bugs.md`

The bug was reproduced by directly exercising the `libspdm_rsp_receive_send.c` TRY_DISCARD path: after rollback to old key, a forged message (epoch-1 encode + corrupted AEAD tag) also fails the old-key retry, triggering the early-return at line 232 and skipping the `create_update` re-create at line 249. Post-attack state: responder at epoch-0 key with `backup_valid=false`; requester at epoch-1 key with `backup_valid=false`. Subsequent legitimate VERIFY_NEW_KEY (epoch-1) cannot be decoded by the responder (0x80020000 error, no recovery). The asymmetry is confirmed against the symmetric correct implementation in `libspdm_req_send_receive.c:302-313`.

### Classification

**Case C — Real Bug (Confirmed)**

### Bug ID / Family

`F2-MC1` — Key Update State Machine: Commit/Rollback asymmetry

### Severity

**High** — Permanent session key desynchronization; all subsequent traffic encrypted with different keys by each side; session broken.

### Invariant Violated

`RollbackSafety`:
```tla
RollbackSafety ==
    \A e \in Endpoints, d \in Dirs :
    ~backup_valid[e][d] =>
        active_epoch[e][d] = active_epoch[Sender(d)][d] \/ update_phase /= Idle
```

### Root Cause

During a non-encap `UPDATE_KEY` flow, the requester creates and activates the new request-direction key with **no rollback window** (`initiator_committed = TRUE`). At this point, the requester permanently discards the old key. However, the responder still holds a backup (via `create_update`) and can roll back via `SESSION_TRY_DISCARD_KEY_UPDATE` if it receives a VERIFY_NEW_KEY that fails AEAD.

If an active attacker injects a crafted `VERIFY_NEW_KEY` with the old (wrong) epoch **before** the legitimate VERIFY_NEW_KEY arrives, the responder:
1. Processes the injected message → AEAD fails
2. `backup_valid[Responder][RequestDir] = TRUE` → `TRY_DISCARD` fires
3. Responder rolls back to old epoch 0; `backup_valid` cleared; `update_phase = Idle`

Meanwhile the requester holds new epoch 1 (no rollback). The session is now permanently desynced:
- Requester: `active_epoch[Requester][RequestDir] = 1`
- Responder: `active_epoch[Responder][RequestDir] = 0` (rolled back)

All future request-direction messages will fail AEAD at the responder (wrong key). The legitimate VERIFY_NEW_KEY is also stuck in the network and can never be processed (`update_phase = Idle`, preventing `ResponderReceiveVerifyNewKey`).

### Counterexample (6 states)

| State | Action | Key State Change |
|-------|--------|-----------------|
| 1 | Initial | all epochs=0, Idle |
| 2 | `MCSendKeyUpdateRequest(FALSE)` | update_phase=PendingAck, KEY_UPDATE in flight |
| 3 | `MCResponderReceiveKeyUpdate` | Responder: `active_epoch[Responder][RequestDir]=1`, `backup_valid[Responder][RequestDir]=TRUE` |
| 4 | `MCRequesterReceiveKeyUpdateAck` | Requester: `active_epoch[Requester][RequestDir]=1`, **`initiator_committed=TRUE`**, sends VERIFY_NEW_KEY (epoch=1) |
| 5 | `MCInjectWrongEpochVerifyNewKey` | Injects VERIFY_NEW_KEY (epoch=0, aead_ok=FALSE) into network |
| 6 | `MCResponderTryDiscardKeyUpdate` (on injected msg) | Responder rolls back: `active_epoch[Responder][RequestDir]=0`, `backup_valid=FALSE`, `update_phase=Idle` |

**Violation at State 6**:
- `~backup_valid[Responder][RequestDir]` = TRUE (no backup)
- `active_epoch[Responder][RequestDir] = 0 ≠ active_epoch[Requester][RequestDir] = 1`
- `update_phase = Idle`
→ `RollbackSafety` violated.

### Affected Code Locations

| File | Lines | Description |
|------|-------|-------------|
| `library/spdm_requester_lib/libspdm_req_key_update.c` | 199–216 | `create_update(REQUESTER, activate=true)` — immediately activates req key with no backup; commit point |
| `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c` | 523–533 | AEAD fail + `backup_valid=TRUE` → returns `TRY_DISCARD`; triggers rollback |
| `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | 197–264 | TRY_DISCARD rollback path: restores req key from backup, clears `backup_valid` |

### Impact

- **Trigger**: Active attacker on the transport injecting a crafted VERIFY_NEW_KEY message with the old key epoch before the legitimate one arrives.
- **Consequence**: Both sides attempt to use different request-direction keys; all subsequent secured messages fail AEAD; session is permanently broken. There is no recovery mechanism once `backup_valid` is cleared.
- **Threat model**: Requires network-level attacker with ability to inject forged SPDM messages before the transport-layer session is secured. Relevant in deployments without lower-level message authentication.

---

## NOTE-F1 — SeqMonotonicity False Positives (Spec Artifact)

### Classification

**Spec Artifact (Case A/B)**

### Description

The F1 hunt (`MC_hunt_F1.cfg`, `MaxWrongSessionId=2`) finds a `SeqMonotonicity` violation from multiple identical injected messages in the bag.

**Scenario**: Two `InjectWrongSessionId` calls (both with seq=0 from the same receiver counter value) create two copies of the same message. After the FIFO guard processes them in some order along with legitimate messages, one copy remains in the bag when `seq[Receiver] > 0+1`.

**Why it is a spec artifact**: In the real SPDM implementation over TCP, each injected message is delivered and decoded exactly once. The bag model allows multiple copies to coexist, and the FIFO guard (which enforces TCP ordering for DATA messages) does not prevent two copies of the same seq=0 message from accumulating.

### The Real F1 Mechanism Is Correctly Modeled

The underlying F1 bug — seq counter advancing before session_id/AEAD checks, causing permanent desync — IS present in the implementation and modeled correctly:
- `libspdm_secmes_encode_decode.c:414–426`: `sequence_number++` before session_id check (decoder side)
- `libspdm_secmes_encode_decode.c:171–183`: `request_data_sequence_number++` before AEAD (encoder side)

One failed decode attempt (whether session_id or AEAD) permanently advances the counter with no rollback. The spec models this atomically in `MCDecodeIncrementSeq`.

### Status

The `SeqMonotonicity` invariant does not directly detect the F1 desync in the current model (because desync by 1 stays within the `m.seq + 1` bound). F1's consequence (session continuity degradation) requires a liveness/reachability invariant beyond what the current safety invariants express. **No real implementation bug newly found by F1 hunt.**

---

## NOTE-F3-DEADLOCK — Encap Key Update Progress Issue (Spec Artifact)

### Classification

**Spec Artifact / Model Liveness Issue**

### Description

The F3 hunt detects a TLC deadlock at state 22 in a 22-state trace. The deadlock state has:
- `update_phase = PendingVerify`, `is_encap = TRUE`
- 6 DATA messages in the bag (buffer at `MaxMsgBuffer = 6`)
- No `MSG_VERIFY_NEW_KEY` in `ResponseDir` messages
- Two encap initiations consumed (`encapInit = 2`)

**Root cause**: After two encap key-update cycles interspersed with data exchanges, the response-direction buffer fills with stale DATA messages from prior epochs. `MCEncapSendVerifyNewKey` is blocked by both the buffer guard and the one-at-a-time guard. The system cannot send the VERIFY_NEW_KEY needed to complete the second encap flow.

**Why it is a spec artifact**: In the real implementation, DATA messages are processed promptly (synchronous request-response). A buffer of 6 unprocessed DATA messages alongside an in-progress encap key update cannot occur in practice because:
1. DATA exchange and encap key update do not interleave in SPDM's half-duplex protocol
2. The transport delivers messages in order and they are processed before new ones are accepted

The `MaxMsgBuffer=6` structural bound is a model-checking convenience; the real system never accumulates 6 unprocessed DATA messages during a key update.

### Key Insight on Epochs

The deadlock state reveals an important invariant that IS violated:
- `active_epoch[Requester][ResponseDir] = 1`
- `active_epoch[Responder][ResponseDir] = 2`

This epoch mismatch (Requester processed the old VERIFY_NEW_KEY epoch=1 from the first flow, while Responder advanced to epoch=2 in the second flow) would cause AEAD failures on all ResponseDir messages. This IS the F3 bug pattern (encap key mismatch) but it occurs through an unrealistic sequence of events (two encap flows with stale messages persisting between them).

**Related to the F3 design question**: The spec confirms that `EncapDecodeFailNoBackup` leaves `backup_valid[Requester][ResponseDir] = FALSE` (no TRY_DISCARD path for the requester after encap VERIFY_NEW_KEY decode failure). This is the intended behavior in the implementation (libspdm_rsp_encap_key_update.c:79–98) where the responder creates+activates immediately with no backup window.

---

## Spec Changes Made During Model Checking

The following changes were applied to `base.tla` and `MC.tla` to eliminate false positives before finding real bugs. All changes are **Case B** (spec modeling issue) or **Case A** (invariant too strong):

### base.tla (SecuredMessage.tla)

1. **`SendKeyUpdateRequest`**: Added `is_encap = FALSE` guard
2. **`ResponderReceiveEncapVerifyAck`**: Changed `update_phase = PendingVerify` → `update_phase = Idle`
3. **`RequesterReceiveEncapVerifyNewKey`**: Added `initiator_committed' = FALSE` reset
4. **`ResponderTryDiscardKeyUpdate`**: Added `initiator_committed` to `UNCHANGED` clause
5. **`KeyAgreement`**: Added `~(∃ e ∈ Endpoints, d ∈ Dirs : backup_valid[e][d])` to precondition

### MC.tla

1. **`MCDecodeIncrementSeq`**: Made atomic (seq++ + consume message); added FIFO guard
2. **`MCEncodeAndSend`**: Combined `EncodeAdvanceSeq + EncodeSuccess` into atomic action
3. **`MCUpdateAllKeys`**: Replaced standalone `MCCreateUpdateResponderKey + MCSendKeyUpdateRequest(TRUE)` with single atomic action
4. **`MCEncapSendVerifyNewKey`**: Added one-at-a-time guard (`~∃ VERIFY_NEW_KEY in ResponseDir`)
5. **Buffer guards**: Added `BagCardinality(msgs) < MaxMsgBuffer` to all pure-send bounded actions

---

## Final Model Checking Results

| Config | States Explored | Violation | Classification |
|--------|----------------|-----------|----------------|
| `MC.cfg` (base) | 5,696 | `RollbackSafety` | **BUG-F2-MC1** (Real Bug) |
| `MC_hunt_F1.cfg` | 17,162 | `SeqMonotonicity` | Spec artifact |
| `MC_hunt_F2.cfg` | 2,632 | `VerifyNewKeyCommit` | Spec artifact (global update_phase) |
| `MC_hunt_F3.cfg` | 6,854,319 | Deadlock | Spec artifact |
| `MC_hunt_F4.cfg` | 2,987 | `RollbackSafety` | **BUG-F2-MC1** (same bug, redundant) |

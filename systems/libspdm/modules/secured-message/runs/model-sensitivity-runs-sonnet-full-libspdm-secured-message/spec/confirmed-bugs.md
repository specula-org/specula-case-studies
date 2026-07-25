# Confirmed Bugs — libspdm Secured Message

**Date**: 2026-06-04  
**Phase**: Bug Confirmation (Phase 4)  
**Input**: `spec/bug-report.md`

---

## BUG-F2-MC1 — Key Mismatch After Requester Commit Point

### Source
**MC** — TLC produced an actual counterexample (6-state violation trace) for the `RollbackSafety` invariant in `MC.cfg`.

### Status
**REPRODUCED** (Level 2 — state injection via `create_update`/`activate_update` directly on secured-message contexts)

### Severity
**High** — Permanent session key desynchronization; all subsequent traffic fails AEAD; session broken with no recovery path.

### Location
Primary: `library/spdm_responder_lib/libspdm_rsp_receive_send.c:232`  
Supporting: `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c:558-571` (TRY_DISCARD trigger)  
Supporting: `library/spdm_secured_message_lib/libspdm_secmes_session.c:499-596` (`activate_update` backup clear)  
Supporting: `library/spdm_requester_lib/libspdm_req_key_update.c:199-216` (requester commit, no backup)

### Description
During a non-encap `UPDATE_KEY` flow, `libspdm_rsp_receive_send.c` handles a decode failure on the new session key by rolling back to the backup (old) key and retrying. If the retry decode **also fails** — as it will for any injected forged message — the function returns an error at line 232 **before** reaching the `reset_key_update` block at line 249 that would re-create the new key and restore `requester_backup_valid`. The responder is left permanently with the old epoch-0 key and `requester_backup_valid=false`, while the requester has irrevocably committed to the new epoch-1 key with `requester_backup_valid=false`. The session cannot recover.

### Trigger Scenario
1. An active attacker is present on the transport layer (no lower-layer message authentication — e.g., PCIe MCTP, USB SPDM).
2. The requester initiates `UPDATE_KEY` (single-direction). The responder calls `create_update(REQUESTER)`: new epoch-1 key active, epoch-0 key in backup, `requester_backup_valid=true`.
3. The requester receives `KEY_UPDATE_ACK`, calls `create_update(REQUESTER)` + `activate_update(REQUESTER, true)`: irrevocably committed to epoch-1, `requester_backup_valid=false`. The key-update window is now open.
4. The attacker observes the session_id (in the clear in SPDM message headers) and the current sequence counter. It crafts a forged SPDM message: correct session_id, correct sequence number, but AEAD tag is garbage (random / from unrelated key).
5. The forged message arrives at the responder **before** the legitimate `VERIFY_NEW_KEY`.
6. Decode with epoch-1 key fails (wrong AEAD tag) → `backup_valid=true` → `TRY_DISCARD` returned.
7. `rsp_receive_send.c:209`: `activate_update(REQUESTER, false)` → old epoch-0 key restored, `backup_valid=false`, backup cleared.
8. `rsp_receive_send.c:224`: retry decode with epoch-0 key → **also fails** (forged message has wrong tag for old key too).
9. `rsp_receive_send.c:232`: `if (LIBSPDM_STATUS_IS_ERROR(status)) return status;` — returns early.
10. `rsp_receive_send.c:249`: `if (reset_key_update) libspdm_create_update_session_data_key(...)` **never reached**.
11. Responder: epoch-0 key, `backup_valid=false`. Requester: epoch-1 key, `backup_valid=false`.
12. Legitimate `VERIFY_NEW_KEY` (epoch-1) arrives → decode fails with epoch-0 key, `backup_valid=false` → no recovery. Session permanently broken.

### Developer Intent Investigation
No developer commentary was found indicating awareness of the adversarial-injection scenario.

The comment at `rsp_receive_send.c:244-248` explicitly names the intended use case:
> *"If the Requester returns RESPONSE_NOT_READY error to KEY_UPDATE, the Responder needs to activate backup key to parse the error. Then later the Requester will return SUCCESS, the Responder needs new key."*

This comment describes the `RESPONSE_NOT_READY` flow only: the old-key retry **succeeds** (decodes a valid error response), `status` is `LIBSPDM_STATUS_SUCCESS`, and the `reset_key_update` block runs correctly. The adversarial case — where the old-key retry also fails — was not considered. No engineer stated this asymmetry is intentional.

The existing `test_tla_scenarios.c` Scenario 4 (`decode_rollback`) tests the `TRY_DISCARD` return code from `libspdm_decode_secured_message` directly but does **not** test `libspdm_rsp_receive_send.c`'s double-failure code path. No unit test exercises the "retry also fails" branch.

The requester's symmetric function `libspdm_req_send_receive.c` handles the same situation **correctly**: its `reset_key_update` block at line 302 is reached regardless of whether `status` is an error (the error check at line 278 does not return early — it logs and falls through to line 302 before `return status` at line 315). This confirms the responder path is an unintentional asymmetry, not a deliberate design choice.

### Reproduction Test
**File**: `repro/test_bug1_rollback_commit_asymmetry.c`  
**Escalation level reached**: Level 2 (state injection — `create_update`/`activate_update` called directly on `libspdm_secured_message_context_t`, simulating the key-update window without a full SPDM session)

**Compile command**:
```bash
LIBSPDM=<artifact>/libspdm
BUILD=<artifact>/build_tla

gcc -o test_bug1 \
    repro/test_bug1_rollback_commit_asymmetry.c \
    $LIBSPDM/unit_test/test_spdm_secured_message/spdm_tla_trace.c \
    -DSPDM_TLA_TRACE_ENABLE=1 \
    -I$LIBSPDM/include -I$LIBSPDM/include/internal \
    -I$LIBSPDM/include/industry_standard \
    -I$LIBSPDM/os_stub/mbedtlslib/include \
    -L$BUILD/lib \
    -Wl,--start-group \
    -lspdm_secured_message_lib -lspdm_crypt_lib -lcryptlib_mbedtls \
    -lmbedcrypto -lrnglib -lmalloclib -lmemlib -ldebuglib -lplatform_lib_null \
    -Wl,--end-group -lpthread -std=c11
```

**Run command**: `./test_bug1`

### Reproduction Result
**PASS** — bug triggered at Level 2. Exit code 0. All 14 assertions pass.

```
=================================================================
BUG-F2-MC1: Key Mismatch After Requester Commit (Rollback Safety)
=================================================================

[SETUP] Initialize requester and responder at epoch-0
  Baseline encode/decode at epoch-0: OK

[STEP 1] Responder receives KEY_UPDATE → create_update(REQUESTER)
  After create_update:
  rsp   : backup_valid=1  req_key[0]=0x10  req_seq=0
  rsp: backup_key[0]=0x01  backup_seq=1
  PASS: rsp.backup_valid=true after create_update

[STEP 2] Requester receives KEY_UPDATE_ACK → commit to new key
  After commit:
  req   : backup_valid=0  req_key[0]=0x10  req_seq=0
  PASS: req.backup_valid=false (committed, irrevocable)
  KEY UPDATE WINDOW OPEN: req at epoch-1, rsp at epoch-1 (backup epoch-0 valid)

  epoch-0 key[0]=0x01, epoch-1 key[0]=0x10

[STEP 3] Craft forged message (epoch-1 encoded, AEAD tag corrupted)
  Forged message: 36 bytes, AEAD tag XOR-flipped
  → will fail AEAD with epoch-1 key (wrong tag)
  → will fail AEAD with epoch-0 key (wrong key AND wrong tag)

[STEP 4a] Responder decodes forged msg with epoch-1 key
  decode result: 0x80010011
  PASS: TRY_DISCARD returned because backup_valid=true and AEAD failed

[STEP 4b] rsp_receive_send.c:209 → activate_update(REQUESTER, false)
  After rollback:
  rsp   : backup_valid=0  req_key[0]=0x01  req_seq=1
  PASS: rsp.backup_valid=false (backup cleared by activate_update)
  PASS: rsp.req_key[0] == epoch-0 value (old key restored)

[STEP 4c] rsp_receive_send.c:224 → retry decode with epoch-0 key
  retry result: 0x80020000 (expect error — forged AEAD tag)
  PASS: Retry decode also fails (forged tag fails old key too)
  PASS: No TRY_DISCARD on retry (backup_valid=false, no further rollback)

[BUG] rsp_receive_send.c:232 returns error — reset_key_update block skipped
  (In the real code: 'if (LIBSPDM_STATUS_IS_ERROR(status)) return status;')
  (The 'if (reset_key_update) create_update(...)' at line 249 is NOT reached)

[STEP 5] Post-attack state verification
  Responder state:
  rsp   : backup_valid=0  req_key[0]=0x01  req_seq=1
  Requester state:
  req   : backup_valid=0  req_key[0]=0x10  req_seq=0
  PASS: rsp.backup_valid=false → NO recovery path available
  PASS: rsp uses epoch-0 key (rolled back, never re-created)
  PASS: req.backup_valid=false (committed at step 2)
  PASS: req uses epoch-1 key (different from responder)
  PASS: req uses epoch-1 key (confirmed)

[STEP 6] Session liveness test: requester sends with epoch-1 key
  Requester encoded VERIFY_NEW_KEY: 36 bytes (epoch-1, seq=0)
  Responder decode result: 0x80020000
  PASS: Responder CANNOT decode VERIFY_NEW_KEY (epoch-1 msg vs epoch-0 key)
  PASS: No TRY_DISCARD — backup_valid=false — session PERMANENTLY BROKEN

=================================================================
SUMMARY
=================================================================
Tests passed: 14
Tests failed: 0

STATUS: BUG CONFIRMED
```

Key observations from the output:
- epoch-0 key[0]=0x01 (known test key), epoch-1 key[0]=0x10 (HKDF-derived, different)
- After rollback (Step 4b): responder has `req_key[0]=0x01` (epoch-0, old key) and `backup_valid=false`
- Requester has `req_key[0]=0x10` (epoch-1) and `backup_valid=false` (committed)
- Decode in Step 6 fails with 0x80020000 — the requester's epoch-1 ciphertext cannot be authenticated with the responder's epoch-0 key, and `backup_valid=false` means no TRY_DISCARD retry is possible

### Recommendation
Move the `reset_key_update` block to execute unconditionally whenever `reset_key_update=true`, regardless of whether the retry decode succeeds or fails. Concretely, in `libspdm_rsp_receive_send.c`, execute `libspdm_create_update_session_data_key(REQUESTER)` **before** checking `LIBSPDM_STATUS_IS_ERROR(status)`:

```c
/* Current (buggy): */
if (LIBSPDM_STATUS_IS_ERROR(status)) {   /* line 232 — exits before re-create */
    ...
    return status;
}
if (reset_key_update) {                  /* line 249 — only reached on success */
    libspdm_create_update_session_data_key(temp_session_context,
                                           LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    ...
}

/* Fix: */
if (reset_key_update) {                  /* always re-create after rollback */
    libspdm_create_update_session_data_key(temp_session_context,
                                           LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    ...
}
if (LIBSPDM_STATUS_IS_ERROR(status)) {   /* then check error */
    ...
    return status;
}
```

This mirrors the correct behavior already implemented in the symmetric requester function `libspdm_req_send_receive.c:302-313`, which runs the `reset_key_update` block before `return status`.

---

## NOTE-F1 — SeqMonotonicity (Spec Artifact)

### Source
**Code Review** (the F1 hunt `MC_hunt_F1.cfg` found a `SeqMonotonicity` violation, but it is a bag-model artifact, not a real violation — see bug-report.md).

### Status
**FALSE POSITIVE** — The `SeqMonotonicity` violation under `MC_hunt_F1.cfg` is a bag-model artifact caused by multiple copies of the same injected message accumulating. The underlying F1 mechanism (seq advance before AEAD check) is real code behavior but does not constitute a safety-invariant violation in the current model's terms.

The F1 code pattern (`libspdm_secmes_encode_decode.c:439`: seq incremented before AEAD check) is intentional: the sequence number is part of the AEAD additional data (not just the counter), so the counter must advance before authentication. The consequence — that a failed decode permanently advances the counter — is a known trade-off for replay protection, not a rollback-safety bug. No new finding.

---

## NOTE-F3-DEADLOCK — Encap Key Update Deadlock (Spec Artifact)

### Source
**Code Review** (the F3 hunt `MC_hunt_F3.cfg` found a TLC deadlock, but the deadlock state requires 6 unprocessed DATA messages alongside an in-progress encap key update — impossible in SPDM's half-duplex, synchronous request-response protocol).

### Status
**FALSE POSITIVE** — The deadlock requires an accumulation of 6 stale DATA messages that cannot occur in practice. The epoch mismatch pattern it reveals (Requester at epoch 1, Responder at epoch 2 in ResponseDir) occurs only through two consecutive encap flows with stale messages persisting between them — an unrealistic interleaving in the real synchronous protocol.

No new implementation bug found.

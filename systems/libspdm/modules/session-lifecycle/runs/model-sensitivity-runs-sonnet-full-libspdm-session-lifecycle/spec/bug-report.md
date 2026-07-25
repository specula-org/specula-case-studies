# Bug Report: libspdm Session Lifecycle — TLA+ Model Checking

**Date**: 2026-06-08  
**Method**: TLA+ model checking (TLC breadth-first search)  
**Spec**: `MC.tla` / `base.tla`  
**Runs**: base + 4 hunt configs (family1–family4)

---

## Summary

| ID | Invariant | Config | Classification | Status |
|----|-----------|--------|----------------|--------|
| MC-BUG-1 | `KeySynchronization` | `MC_hunt_family1.cfg` | Spec artifact | **PENDING REPAIR (RR-001)** |
| — | `BackupKeyWindow` | family1 | Not violated | Holds |
| — | `SessionTerminationConsistency` | family2 | Not violated | Holds |
| — | `SessionMonotonicity` | family2 | Not violated | Holds |
| — | `WatchdogLiveness` | family3 | Not violated | Holds |
| — | `UpdateKeyStateMachineNotStuck` | family4 | Vacuously safe | No violation |
| — | `ValidSessionStates` | all | Not violated | Holds |
| — | `ValidKeyStates` | all | Not violated | Holds |

---

## MC-BUG-1: Key Generation Desynchronization via Backup Decode Path

### Severity
**High** — permanent session-level decryption failure after any backup-key decode event during a KEY_UPDATE flow.

### Category
Family 1: Two-Party Key Update State Desynchronization

### Classification
**Case C — Real Implementation Bug** (spec correctly models implementation; invariant correctly captures the safety requirement; yet the implementation reaches the violating state).

### Root Cause

The responder's receive path at `libspdm_rsp_receive_send.c:197–263` performs a backup-key decode recovery: when decryption fails with the new (pending) key, the code reverts to the backup key and re-decodes, then calls `create_update_session_data_key(REQUESTER)` to re-derive the new key. This re-derive call increments the responder's internal RX key generation counter a **second time** in the same key-update round. The requester's TX key generation counter, however, only increments once (in `libspdm_req_key_update.c:199–215` after receiving KEY_UPDATE_ACK). After the key-update cycle completes, the responder expects to receive messages encrypted with generation `N+2`, but the requester is sending with generation `N+1`.

The mismatch is permanent — no in-protocol mechanism corrects the offset without a full session teardown.

### Counterexample (6 steps)

```
State 1: Init
  req_tx_gen=0, rsp_rx_gen=0, rsp_last_key_op="none"
  req_ku_state="idle", rsp_rx_backup_valid=FALSE

State 2: MCReqSendUpdateKey
  req_to_rsp = <<UPDATE_KEY>>
  req_ku_state = "update_sent"

State 3: MCRspRecvUpdateKey           [rsp_key_update_ack.c:127-141]
  rsp_rx_gen = 1   (first increment: create_update + g_tla.rsp_rx_gen++)
  rsp_rx_backup_valid = TRUE
  rsp_last_key_op = "update_key"
  rsp_to_req = <<KEY_UPDATE_ACK>>

State 4: MCDecodeWithBackupKey        [rsp_receive_send.c:209-266]
  rsp_rx_gen = 2   (SECOND increment: create_update + g_tla.rsp_rx_gen++ in backup path)
  rsp_last_key_op = "update_key"   (NOT reset — key bug in rsp_receive_send.c:249-263)
  rsp_rx_backup_valid = TRUE
  faultVars.decodeBackup = 1

State 5: MCReqRecvKeyUpdateAck        [req_key_update.c:199-234]
  req_tx_gen = 1   (only one increment: g_tla.req_tx_gen++)
  req_ku_state = "verify_sent"
  req_to_rsp = <<VERIFY_NEW_KEY>>

State 6: MCRspRecvVerifyNewKey        [rsp_key_update_ack.c:201-216]
  rsp_rx_backup_valid = FALSE   (backup committed)
  rsp_last_key_op = "none"      (reset)
  rsp_to_req = <<VERIFY_ACK>>

  --> KeySynchronization VIOLATED:
      rsp_rx_backup_valid=FALSE, req_rx_backup_valid=FALSE
      BUT rsp_rx_gen=2 != req_tx_gen=1
```

### Violated Invariant

```tla
KeySynchronization ==
    (rsp_rx_backup_valid = FALSE /\ req_rx_backup_valid = FALSE)
    => (rsp_rx_gen = req_tx_gen)
```

When both backup flags are cleared (key update cycle complete), the responder's expected RX generation must equal the requester's TX generation. After the backup decode path fires during a key update, this equality is broken.

### Affected Code Locations

| File | Lines | Role |
|------|-------|------|
| `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | 197–263 | Backup decode path — contains the spurious `create_update_session_data_key` call and extra `rsp_rx_gen++` |
| `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | 256–266 | `create_update_session_data_key(REQUESTER)` + `g_tla.rsp_rx_gen++` — second increment |
| `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c` | 127–141 | Normal `UPDATE_KEY` processing — first (correct) increment |
| `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c` | 158–199 | Normal `UPDATE_ALL_KEYS` processing — first (correct) increment |
| `library/spdm_requester_lib/libspdm_req_key_update.c` | 199–234 | Requester increments TX gen exactly once per round |

### Impact

After any backup-key decode event during a KEY_UPDATE flow:
- The responder's AEAD decryption expects key generation `N+2`
- The requester's AEAD encryption produces key generation `N+1`
- All subsequent requester→responder messages fail AEAD authentication
- The session is silently broken with no in-protocol recovery path

The backup-key decode path (`LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE`) is a legitimate error-recovery path intended to handle transient decryption failures. Any environment where both (a) a key update is in progress and (b) a transient decryption failure occurs can trigger this bug.

### Suggested Fix

In `libspdm_rsp_receive_send.c:256-266`, the backup-key re-derive should either:
1. Not call `create_update_session_data_key` at all (rely on the backup key remaining valid until the requester sends `VERIFY_NEW_KEY`), or
2. Ensure the generation counter is not incremented by the re-derive call in this context (e.g., save and restore the counter around the call, or use a flag to suppress the increment).

The invariant to restore: after the backup decode path completes, `rsp_rx_gen` must remain at the same value it had immediately after the preceding `RspRecvUpdateKey` step.

---

## Non-Findings

### Family 2: END_SESSION Termination Consistency

**Invariants checked**: `SessionTerminationConsistency`, `SessionMonotonicity`  
**States explored**: 305,703 generated, 74,234 distinct (complete state graph)  
**Result**: No violations

The expected bug scenario (encode failure leaves responder ESTABLISHED while requester is NOT_STARTED) does not manifest in this spec model because the requester can only reach NOT_STARTED by explicitly receiving the END_SESSION_ACK message. If encoding fails and no ACK is sent, the requester stays ESTABLISHED. The spec does not model requester-side timeout-based independent termination. The invariants hold for all reachable states.

### Family 3: Watchdog Liveness

**Invariant checked**: `WatchdogLiveness`  
**States explored**: 3,472,991 generated, 813,606 distinct (complete state graph)  
**Result**: No violations

The watchdog expiry and integrator termination flow is correctly modeled. The invariant `(watchdog_expired=TRUE /\ rsp_session_state=ESTABLISHED) => watchdog_active=TRUE` holds throughout. Non-heartbeat messages (like KEY_UPDATE messages that arrive via the same channel) do not reset the watchdog in this model, consistent with the implementation.

### Family 4: State Machine Stuck-State

**Invariant checked**: `UpdateKeyStateMachineNotStuck`  
**States explored**: 9,296,371 generated, 2,279,651 distinct (complete state graph)  
**Result**: No violations (vacuously safe)

The stuck-state condition `(rsp_last_key_op != KU_NONE /\ req_ku_state = IDLE /\ req_to_rsp = <<>>)` is unreachable in the current spec model. The reason: `req_ku_state` can only return to `IDLE` via `ReqRecvVerifyAck`, which can only fire after `RspRecvVerifyNewKey` sends a `VERIFY_ACK` — and `RspRecvVerifyNewKey` always resets `rsp_last_key_op = KU_NONE`. Therefore the stuck state (IDLE + non-NONE `rsp_last_key_op`) cannot coexist in any reachable state.

The underlying issue that Family 4 targets — `last_key_update_request` not being reset in `rsp_receive_send.c:249-263` — is real and is the enabling condition for MC-BUG-1. However, the full stuck-state scenario (where a subsequent `UPDATE_KEY` is rejected because `last_key_update_request` is still set) requires modeling requester-side timeout/retry behavior not present in this spec.

---

## Spec and Configuration Notes

### Spec Fix: Non-ASCII Characters (Preprocessing)

`MC.tla` and `base.tla` contained non-ASCII characters (`→`, `–`, `—`, `∈`) in comments that TLC's SANY parser cannot handle. These were replaced with ASCII equivalents (`->`, `-`, `--`, `in`) before model checking. This is a spec authoring issue, not a finding.

### Spec Fix: Multi-line CONSTANTS Declaration

`MC.tla`'s `CONSTANTS` block listed constants on multiple lines without commas, causing a TLC parse error ("Was expecting `====` or more Module body"). Fixed by adding commas between constant names. This is a TLA+/TLC parser quirk.

### Config Fix: Terminal State Deadlock (Case A)

The spec models a protocol with a natural terminal state (both parties `NOT_STARTED`, empty queues, watchdog stopped). TLC's default deadlock check treats this as an error. Since this is the expected end state of the session lifecycle protocol (and the spec doesn't model session re-establishment), deadlock checking was disabled (`-deadlock` flag). All hunt runs use this setting.

### Config Fix: `KeyGenBounded` as CONSTRAINT (Case A)

`KeyGenBounded` was listed as an `INVARIANTS` entry in all config files, but its purpose is purely to bound the state space (not to assert correctness). The `DecodeWithBackupKey` action legitimately increments `rsp_rx_gen` beyond the initial `MaxKeyGen` setting when multiple backup decode events occur. Moving `KeyGenBounded` to `CONSTRAINT` (so TLC prunes rather than errors at the bound) and increasing `MaxKeyGen` to accommodate backup decode increments (`MaxKeyGen_new = MaxKeyGen_old + MaxDecodeBackup + 1`) resolved false positive violations. All hunt runs use these updated settings.

---

## Model Checking Statistics

| Run | Config | States Generated | Distinct States | Result |
|-----|--------|-----------------|-----------------|--------|
| base2 | `MC.cfg` (MaxKeyGen=6) | 131,017,585 | 27,426,343 | No errors |
| family1 | `MC_hunt_family1.cfg` (MaxKeyGen=7) | 1,613 | 1,031 | **KeySynchronization VIOLATED** (spec artifact — see RR-001) |
| family2 | `MC_hunt_family2.cfg` (MaxKeyGen=2) | 305,703 | 74,234 | No errors |
| family3 | `MC_hunt_family3.cfg` (MaxKeyGen=2) | 3,472,991 | 813,606 | No errors |
| family4 | `MC_hunt_family4.cfg` (MaxKeyGen=8) | 9,296,371 | 2,279,651 | No errors |

---

## Phase 4: Bug Confirmation

**Date**: 2026-06-08  
**Method**: Code audit + state-injection reproduction test  
**Repro test**: `spec/repro/test_bug1_key_desync.c`

### MC-BUG-1 Confirmation

#### Code Audit

**Relevant files and call chain:**

| File | Lines | Role |
|------|-------|------|
| `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | 198–268 | Backup decode path — `activate(REQUESTER,false)` + retry + `create_update(REQUESTER)` |
| `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c` | 127–141 | Normal `UPDATE_KEY` processing — first `create_update(REQUESTER)` call |
| `library/spdm_secured_message_lib/libspdm_secmes_session.c` | 335–407 | `libspdm_create_update_session_data_key` — HKDF derivation |
| `library/spdm_secured_message_lib/libspdm_secmes_session.c` | 491–558 | `libspdm_activate_update_session_data_key` — restore-from-backup AND clear backup slot |

The bug report claimed that `rsp_receive_send.c:256–257` calls `create_update(REQUESTER)` a
**second** time per key-update round (after the first call in `rsp_key_update_ack.c:127–129`),
causing `rsp_rx_gen` to increment twice while `req_tx_gen` only increments once.

**Code audit finding**: The claim fails to account for the `activate(REQUESTER,false)` call
at `rsp_receive_send.c:210–211`, which executes BEFORE the second `create_update`. Examining
`libspdm_activate_update_session_data_key(use_new_key=false)` at `libspdm_secmes_session.c:499`:

1. **Restores** `application_secret` from `application_secret_backup` (active → gen-0).
2. **Clears** the backup slot: zeros `application_secret_backup.request_data_secret` and sets
   `requester_backup_valid = false`.

After `activate(false)`, the active key is `old_key` (gen-0). When `create_update(REQUESTER)`
is then called (`rsp_receive_send.c:256`):
1. Saves current active (`old_key`) to backup.
2. Derives `KDF(old_key) = new_key` (gen-1) as the new active.

Net effect: `active = KDF(old_key) = new_key` — **identical** to the state immediately after
the first `create_update` in `rsp_key_update_ack.c:127`. The backup decode sequence is
**idempotent**. No existing safeguard is missing; the code is correct.

**No trigger scenario leads to key desynchronization**: after the backup decode fires during
an in-progress key update, both sides end up committed to `gen-1 = KDF(old_key)`. The
`g_tla.rsp_rx_gen++` tracing instrumentation at `rsp_receive_send.c:266` is wrong — it counts
`create_update` call-count rather than net generation advances.

#### Developer Intent Investigation

The comment at `rsp_receive_send.c:245–265` explicitly documents the design intent:
> "Handle special case for bi-directional communication: If the Requester returns
> RESPONSE_NOT_READY error to KEY_UPDATE, the Responder needs to activate backup key to
> parse the error. Then later the Requester will return SUCCESS, the Responder needs new
> key. So we need to restore the environment by `libspdm_create_update_session_data_key()`
> again."

The code is deliberately designed this way for a specific SPDM protocol edge case. No git
history is available in this checkout. No code comments, TODOs, or FIXMEs indicate any
known problem. The symmetric path in `libspdm_req_send_receive.c:302–313` follows the same
`activate(false) + create_update` pattern (for the responder TX direction), confirming
consistent developer intent.

#### Reproduction

**Test**: `spec/repro/test_bug1_key_desync.c`  
**Build**: compile with `cc` against pre-built static libs in `build_tla/lib/`  
**Run**: `timeout 30 ./test_bug1_key_desync`

**Level 0** (black-box via public API):
- `libspdm_key_update(req, sid, true)` succeeded.
- `libspdm_heartbeat(req, sid)` after key update succeeded.
- Result: **PASS** — no desynchronization on normal path.

**Level 1**: N/A — no race window; the backup decode path is deterministic (triggered only by
a specific error status `LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE`).

**Level 2a** (state injection — idempotency check):
Directly called `create_update(REQ)` → `activate(false)` → `create_update(REQ)` on the
responder's secured-message context, then compared key material:
```
RSP req secret (gen-1, after 1st create_update): a466ca66d620853c...
RSP req secret (after backup-decode sequence):   a466ca66d620853c...  [MATCH]
REQ tx secret (gen-1, after create+activate):    a466ca66d620853c...  [MATCH]
[ASSERTION A] Secret after backup-decode == secret after 1st create_update: MATCH
[ASSERTION B] RSP active RX secret == REQ active TX secret: MATCH
```
Result: **PASS** — the sequence is idempotent; keys remain synchronized.

**Level 2b** (exact TLA counterexample replication, Steps 2–6):
Manually drove each TLA action on the secured-message contexts:
```
Step 2 RSP active (gen-1 pending):    a466ca66d620853c...
Step 3 RSP active (after backup-decode): a466ca66d620853c...  [Step2==Step3: MATCH]
Step 4 REQ tx key (gen-1 committed):  a466ca66d620853c...
Step 5 RSP active RX (gen-1 committed): a466ca66d620853c...
RSP committed RX key == REQ committed TX key: MATCH (invariant holds)
```
Result: **PASS** — `KeySynchronization` holds in the actual implementation for the exact
CE trace; the violation exists only in the model.

**Overall**: PASS — bug NOT reproduced. All escalation levels confirm false positive.

#### Final Classification

**PENDING REPAIR (RR-001)** — The `KeySynchronization` violation is a **spec modeling
artifact**. The `DecodeWithBackupKey` TLA action (`base.tla:318`) incorrectly increments
`rsp_rx_gen` by 1. In the real implementation, `activate(REQUESTER,false)` first rolls the
key state back to `old_key` before `create_update` is called, making the combined sequence
idempotent. The spec repair is to remove the `rsp_rx_gen + 1` increment from
`DecodeWithBackupKey`.

**Confidence**: High — the idempotency proof is deterministic (same HKDF input → same
output); no timing or environment sensitivity.

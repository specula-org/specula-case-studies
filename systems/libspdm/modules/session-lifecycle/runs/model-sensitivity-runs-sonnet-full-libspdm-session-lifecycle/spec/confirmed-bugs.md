# Confirmed Bugs — libspdm Session Lifecycle

**Phase**: 4 — Bug Confirmation  
**Date**: 2026-06-08  
**Input**: `spec/bug-report.md` (1 MC finding, 3 non-findings)

---

## MC-BUG-1: Key Generation Desynchronization via Backup Decode Path

- **Source**: MC (model checking produced an actual counterexample — `KeySynchronization` violated in `MC_hunt_family1.cfg`)
- **Status**: PENDING REPAIR (RR-001)
- **Repair request**: RR-001
- **Severity**: N/A (pending repair resolution; original severity High, downgraded pending false-positive determination)
- **Location**: `library/spdm_responder_lib/libspdm_rsp_receive_send.c:256–268` (code path); `spec/base.tla:318` (spec error)

### Description

The TLA `KeySynchronization` invariant was violated in model checking: after a
`DecodeWithBackupKey` event fires during a `KEY_UPDATE` flow, the model's `rsp_rx_gen`
counter reaches 2 while `req_tx_gen` reaches only 1, indicating a key generation
desynchronization after the key update cycle completes.

**However, the counterexample is a spec modeling artifact.** The `DecodeWithBackupKey`
TLA action increments `rsp_rx_gen` by 1, modeling the second `create_update(REQUESTER)`
call in `rsp_receive_send.c:256`. It fails to account for the preceding
`activate(REQUESTER,false)` call at `rsp_receive_send.c:210`, which restores the active
key to `old_key` before the second `create_update` is called. The combined effect of
`activate(false) + create_update` is therefore idempotent: it re-derives `KDF(old_key) =
new_key` (gen-1) — the same generation-1 key material as after the initial
`RspRecvUpdateKey` call. No actual generation advance occurs.

### Trigger scenario

1. Requester sends `UPDATE_KEY`.
2. Responder processes `UPDATE_KEY` → calls `create_update(REQUESTER)` → gen-1 pending, backup=gen-0.
3. Responder receives an incoming message encrypted with the OLD (gen-0) key → backup decode fires:
   - `activate(REQUESTER,false)`: restores active to gen-0, clears backup.
   - `create_update(REQUESTER)`: re-derives gen-1 from gen-0. State identical to step 2.
4. Requester processes `KEY_UPDATE_ACK` → `create_update(REQUESTER)` + `activate(true)` → gen-1 committed.
5. Responder receives `VERIFY_NEW_KEY` → `activate(true)` → gen-1 committed.
6. Both sides committed to gen-1 = `KDF(old_key)`. No mismatch.

### Developer intent investigation

The `rsp_receive_send.c:245–265` comment explicitly documents the intention:
> "Handle special case for bi-directional communication: If the Requester returns
> RESPONSE_NOT_READY error to KEY_UPDATE, the Responder needs to activate backup key to
> parse the error. Then later the Requester will return SUCCESS, the Responder needs new
> key. So we need to restore the environment by `libspdm_create_update_session_data_key()` again."

This is intentional, documented behavior. The implementation correctly handles the edge
case. No issues, PRs, or comments suggest this is known to be a bug. No git history
available for commit-level attribution.

The `g_tla.rsp_rx_gen++` instrumentation at `rsp_receive_send.c:266` is incorrect: it
counts `create_update` invocations rather than net key-generation advances. This is the
root cause of the spec-model mismatch.

### Reproduction test

**File**: `spec/repro/test_bug1_key_desync.c`

**Escalation levels attempted**:
- Level 0 (black-box): `libspdm_key_update` + `libspdm_heartbeat` → `PASS`
- Level 1: N/A (no race window; deterministic code path)
- Level 2a (state injection — idempotency): `activate(false)+create_update` → active key unchanged → `PASS`
- Level 2b (exact TLA counterexample steps 2–6): RSP and REQ both committed to gen-1 → `PASS`

**Reproduction result**: PASS on all levels (bug NOT reproduced)

```
=== SUMMARY ===
  Level 0  (normal key_update + heartbeat):            PASS
  Level 2a (activate(false)+create_update idempotency): PASS
  Level 2b (exact TLA counterexample replication):      PASS

OVERALL: PASS -- all levels pass, bug NOT reproduced.
CONCLUSION: MC-BUG-1 is a FALSE POSITIVE.
  activate(false) first restores the key to gen-0 (old_key) and CLEARS the backup,
  then create_update re-derives gen-1 (KDF(old_key)) -- identical material to before.
  The TLA model's DecodeWithBackupKey action incorrectly increments rsp_rx_gen
  without accounting for the preceding activate(false) rollback.
  Spec repair needed: base.tla:318 rsp_rx_gen should NOT increment.
```

### Key evidence from Level 2a

- After `create_update(REQUESTER)`: `RSP req secret = a466ca66d620853c...` (gen-1)
- After `activate(false)`: active restored to `eeeeeeee...` (gen-0), `backup_valid = 0`
- After `create_update(REQUESTER)` again: `RSP req secret = a466ca66d620853c...` (**same gen-1**)
- REQ TX secret after `create_update+activate(true)`: `a466ca66d620853c...` (**identical**)

### Recommendation

**Spec repair** (not an implementation fix):

In `base.tla`, change `DecodeWithBackupKey` (line 318):
```diff
- /\ rsp_rx_gen'          = rsp_rx_gen + 1
+ /\ rsp_rx_gen'          = rsp_rx_gen   (* activate(false) rolls back; create_update re-derives same gen *)
```

The implementation (`rsp_receive_send.c:197–268`) is correct. The `g_tla.rsp_rx_gen++`
tracing instrumentation at line 266 is wrong and should be removed (or changed to a comment).

---

## Non-findings (unchanged from bug-report.md)

- **Family 2** (`SessionTerminationConsistency`, `SessionMonotonicity`): No violations. Holds.
- **Family 3** (`WatchdogLiveness`): No violations. Holds.
- **Family 4** (`UpdateKeyStateMachineNotStuck`): No violations (vacuously safe).

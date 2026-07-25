# Brief Coverage Self-Audit

Maps brief §2 (Bug Families) / §5 (Invariants) / §6.1 (Model-Checkable Findings)
to spec and MC artifacts. Read from actual cfg files.

---

## §2 Bug Families → Hunt Configs

| Family | Description | Hunt cfg | Targeting invariant |
|--------|-------------|----------|---------------------|
| Family 1 | Two-Party Key Update State Desynchronization | `MC_hunt_family1.cfg` | `KeySynchronization`, `BackupKeyWindow` |
| Family 2 | END_SESSION Phase Ordering and Session Cleanup | `MC_hunt_family2.cfg` | `SessionTerminationConsistency`, `SessionMonotonicity` |
| Family 3 | Heartbeat Liveness and Session State Consistency | `MC_hunt_family3.cfg` | `WatchdogLiveness` |
| Family 4 | `last_key_update_request` Stuck After Rollback | `MC_hunt_family4.cfg` | `UpdateKeyStateMachineNotStuck` |

All four families have a targeting hunt config. ✓

---

## §5 Invariants → Spec Definition + Hunt Config Enablement

| Invariant | Defined in base.tla | Enabled in ≥1 hunt cfg |
|-----------|--------------------|-----------------------|
| `KeySynchronization` | ✓ (line ~182) | ✓ `MC_hunt_family1.cfg` |
| `BackupKeyWindow` | ✓ (line ~191) | ✓ `MC_hunt_family1.cfg` |
| `UpdateKeyStateMachineNotStuck` | ✓ (line ~200) | ✓ `MC_hunt_family4.cfg` |
| `SessionTerminationConsistency` | ✓ (line ~210) | ✓ `MC_hunt_family2.cfg` |
| `SessionMonotonicity` | ✓ (line ~218) | ✓ `MC_hunt_family2.cfg` |
| `WatchdogLiveness` | ✓ (line ~226) | ✓ `MC_hunt_family3.cfg` |

All six brief §5 invariants are defined and enabled in at least one hunt cfg. ✓

---

## §6.1 Model-Checkable Findings → Hunt Config Reachability

| Finding | Mechanism | Hunt cfg | Fault that makes it reachable |
|---------|-----------|----------|-------------------------------|
| MC1 | `last_key_update_request` not reset after `DecodeWithBackupKey`; subsequent UPDATE_KEY rejected | `MC_hunt_family4.cfg` | `MaxDecodeBackup=3` enables `DecodeWithBackupKey` up to 3×; `UpdateKeyStateMachineNotStuck` checked |
| MC2 | Double `create_update` on responder → key gen N+2 vs requester N+1 | `MC_hunt_family1.cfg` | `MaxDecodeBackup=2` + `MaxDropReqToRsp=1` allows message loss during key update window; `KeySynchronization` checked |
| MC3 | `RspEncodeEndSessionAckFail` leaves rsp ESTABLISHED, req NOT_STARTED → split | `MC_hunt_family2.cfg` | `MaxRspEncodeFail=2` enables encode failures; `SessionTerminationConsistency` checked |

All three §6.1 findings have a hunt cfg with fault bounds that make the scenario reachable. ✓

---

## MC.cfg Invariant Organization Check

`MC.cfg` lists structural invariants (`KeyGenBounded`, `ValidSessionStates`, `ValidKeyStates`)
as always-enabled, and all six extension (bug-family) invariants are **commented out**.
This matches the guide requirement: extension invariants commented out in `MC.cfg`, enabled
in `MC_hunt_*.cfg` files. ✓

---

## Gaps / Notes

- **VerifyNewKeyProgress (liveness)**: The brief §5 lists this as a liveness property. It is not
  implemented as a TLA+ temporal property (PROPERTY in cfg). Liveness checking in TLC requires
  fairness assumptions and significantly increases model-checking cost. The safety proxy
  (`UpdateKeyStateMachineNotStuck`) covers the relevant stuck-state scenario. If liveness is
  needed, add `WF_vars(ReqRecvVerifyAck)` to the spec and a `PROPERTIES` entry to `MC_hunt_family1.cfg`.

- **Family 3 (watchdog)**: `WatchdogLiveness` as defined is a safety invariant (no state where
  watchdog expired AND session still ESTABLISHED with watchdog still running). The brief's intent
  is "integrator must eventually call session termination," which is a liveness property. The
  current safety version catches the specific code path where watchdog is stopped only on
  END_SESSION_ACK and not on DECRYPT_ERROR / sequence-number overflow (rsp_receive_send.c:779–791
  vs 735–736). This is the actionable question from the brief.

- **TV1/TV2/TV3** (Test-Verifiable findings): Not modeled in TLA+; appropriate for harness-level
  fault injection tests. Out of scope for this spec.

- **CR1/CR2/CR3** (Code-Review-Only): Not modeled. Out of scope.

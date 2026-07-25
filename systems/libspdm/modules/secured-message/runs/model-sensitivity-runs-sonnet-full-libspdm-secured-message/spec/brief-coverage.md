# Brief Coverage Self-Audit

Mapping of brief §2 (Bug Families), §5 (Invariants), and §6.1 (Model-Checkable Findings)
to spec/MC artifacts.

---

## §2 Bug Families → Hunt Configs

| Family | Hunt Config | Targeting Actions | Status |
|--------|-------------|-------------------|--------|
| F1: Seq advance before AEAD/session-id | `MC_hunt_F1.cfg` | `InjectWrongSessionId`, `InjectAEADFailure`; `MaxWrongSessionId=2`, `MaxAEADFailure=2` | Covered |
| F2: Key update state machine | `MC_hunt_F2.cfg` | `InjectWrongEpochVerifyNewKey`; `MaxWrongEpochVNK=2`, `MaxKeyUpdateInit=3` | Covered |
| F3: Encap vs non-encap asymmetry | `MC_hunt_F3.cfg` | `EncapCreateAndActivateRspKey`; `MaxEncapInit=3`, `MaxAEADFailure=2` | Covered |
| F4: Seq epoch after key update + rollback | `MC_hunt_F4.cfg` | `SendResponseNotReady`; `MaxResponseNotReady=3`, `MaxKeyUpdateInit=2` | Covered |

---

## §5 Invariants → Hunt Config Enablement

Each invariant must appear enabled (uncommented) in ≥1 hunt config.

| Invariant | Brief §5 | Enabled in |
|-----------|----------|-----------|
| `KeyAgreement` | Yes | `MC_hunt_F2.cfg`, `MC_hunt_F3.cfg` |
| `SeqMonotonicity` | Yes | `MC_hunt_F1.cfg`, `MC_hunt_F4.cfg` |
| `BackupValidConsistency` | Yes | `MC_hunt_F2.cfg`, `MC.cfg` (structural) |
| `RollbackSafety` | Yes | `MC_hunt_F4.cfg`, `MC.cfg` |
| `VerifyNewKeyCommit` | Yes | `MC_hunt_F2.cfg`, `MC.cfg` |
| `SessionContinuity` | Yes (liveness) | **Gap — see note below** |

### SessionContinuity gap

`SessionContinuity` is defined in base.tla as a safety implication but is phrased as a liveness
property in the brief ("can always send and receive the next message"). It is not enabled in any
hunt config because:
1. Checking it as a safety invariant would require bounding message-send opportunities, which
   inflates state space without exposing the F1 bug more precisely than `SeqMonotonicity` does.
2. The practical consequence of F1 (permanent seq desync) is captured by `SeqMonotonicity`:
   once the receiver's seq exceeds the sender's last-sent seq by more than 1, no subsequent
   correct message can be decoded.

**Recommendation**: after spec convergence, add a temporal property
`<>[](update_phase = Idle => \E d \in Dirs : seq[Sender(d)][d] = seq[Receiver(d)][d])`
to a dedicated liveness hunt config to check F1's liveness claim.

---

## §6.1 Model-Checkable Findings → Hunt Config Reachability

| Finding | Description | Hunt Config | Fault setup that makes it reachable |
|---------|-------------|-------------|--------------------------------------|
| MC1 | Requester committed + responder TRY_DISCARD → KeyAgreement violation | `MC_hunt_F2.cfg` | `InjectWrongEpochVerifyNewKey` (MaxWrongEpochVNK=2) makes ResponderTryDiscardKeyUpdate fire when initiator_committed=TRUE |
| MC2 | RESPONSE_NOT_READY re-create → backup_seq N+1 mismatch | `MC_hunt_F4.cfg` | `SendResponseNotReady` (MaxResponseNotReady=3) drives RequesterHandleResponseNotReady; `RollbackSafety` catches divergence |
| MC3 | UPDATE_ALL_KEYS + concurrent encap → both sides compute different rsp keys | `MC_hunt_F2.cfg` (MaxEncapInit=1 + MaxKeyUpdateInit=3) | Both EncapCreateAndActivateRspKey and CreateUpdateResponderKey can fire in same update_phase=Idle window; `KeyAgreement` catches divergence |
| MC4 | backup_valid TRUE on both sides simultaneously → neither backup valid relative to other | `MC_hunt_F2.cfg` | BackupValidConsistency invariant checks `~(backup_valid[Req][d] /\ backup_valid[Rsp][d])` for all d |

### MC3 coverage note

The current spec models `update_phase` as a single global variable, which prevents concurrent
non-encap + encap updates from running truly simultaneously. The spec correctly models the
sequential protocol, but the concurrent-session scenario (MC3 as stated in the brief) would
require either:
(a) Removing the `update_phase = Idle` guard from `EncapCreateAndActivateRspKey` to allow
    encap to start during a non-encap PendingAck phase, or
(b) Modeling two separate `update_phase` variables (one per flow direction).

Current state: MC3 is partially covered by `MC_hunt_F2.cfg` (both flows enabled, TLC will find
any ordering where update_phase transitions allow overlap). The tightest scenario from the brief
(requester pre-creates rsp key + responder simultaneously initiates encap rsp key update)
requires option (b) for full coverage. Flag for spec revision after initial convergence.

---

## Summary

| Category | Brief items | Covered | Gap |
|----------|-------------|---------|-----|
| Bug Families | 4 | 4 | 0 |
| Safety Invariants | 6 | 5 | 1 (SessionContinuity liveness) |
| Model-Checkable Findings | 4 | 3 full + 1 partial | MC3 concurrent overlap |

All high-priority families (F1, F2) are fully covered. F3 and F4 are covered.
The two gaps are documented and have mitigation paths above.

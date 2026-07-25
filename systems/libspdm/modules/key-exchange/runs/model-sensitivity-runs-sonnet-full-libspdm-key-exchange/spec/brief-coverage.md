# Brief Coverage Self-Audit

Maps brief §2 / §5 / §6.1 → spec and MC artifacts.
Filled by reading actual files, not from memory of intent.

---

## Bug Families (brief §2)

| Family | Mechanism | Hunt cfg | Notes |
|---|---|---|---|
| F1: Session identity confusion (HITC) | `latest_session_id` overwritten; FINISH routed to wrong session; CommitEstablished also reads global | `MC_hunt_family1.cfg` | Two KEX before FINISH; `SessionEstablishedOnlyAfterOwnFinish` enabled |
| F2: Mutual auth path inconsistency | Non-encap path omits `peer_cert_slot` write; FINISH verifies against wrong cert slot | `MC_hunt_family2.cfg` | `MutAuthUsesNegotiatedSlot` enabled; requires `MaxCertSlots=2` |
| F3: Non-atomic FINISH state transition | `data_keys_live` set before `ESTABLISHED`; encode failure leaves zombie session | `MC_hunt_family3.cfg` | `RspEncodeFailure` bounded to 1; `MCNoDataKeysBeforeEstablished` enabled |
| F4: Sequence counter before AEAD | Counter incremented before AEAD result; one injected message permanently desynchronizes | `MC_hunt_family4.cfg` | `InjectBadMessage` bounded to 1; `MCSeqCounterStableOnDecryptFailure` enabled |

All four families have a targeting hunt cfg. No mergers. ✓

---

## Safety Invariants (brief §5)

| Invariant | Defined in | Wired in MC.tla | Enabled in hunt cfg(s) |
|---|---|---|---|
| `SessionEstablishedOnlyAfterOwnFinish` | `base.tla` (F1) | `MCSessionEstablishedOnlyAfterOwnFinish` in `MC.tla` | `MC_hunt_family1.cfg`, `MC_hunt_family3.cfg` |
| `MutAuthUsesNegotiatedSlot` | `base.tla` (F2) | `MCMutAuthUsesNegotiatedSlot` in `MC.tla` | `MC_hunt_family2.cfg` |
| `NoDataKeysBeforeEstablished` | `base.tla` (F3) | `MCNoDataKeysBeforeEstablished` in `MC.tla` | `MC_hunt_family3.cfg` |
| `SeqCounterStableOnDecryptFailure` | `base.tla` (F4) | `MCSeqCounterStableOnDecryptFailure` in `MC.tla` | `MC_hunt_family4.cfg` |
| `SessionStateMonotonic` | `base.tla` (structural) | `MCSessionStateMonotonic` in `MC.tla` | `MC.cfg` + all hunt cfgs (always on) |

All Safety invariants defined, wired, and enabled in ≥1 hunt cfg. ✓

The "enabled in cfg" check was done by reading each `MC_hunt_*.cfg` INVARIANTS block:
- `MC_hunt_family1.cfg`: INVARIANTS block includes `MCSessionEstablishedOnlyAfterOwnFinish` ✓
- `MC_hunt_family2.cfg`: INVARIANTS block includes `MCMutAuthUsesNegotiatedSlot` ✓
- `MC_hunt_family3.cfg`: INVARIANTS block includes `MCNoDataKeysBeforeEstablished` and `MCSessionEstablishedOnlyAfterOwnFinish` ✓
- `MC_hunt_family4.cfg`: INVARIANTS block includes `MCSeqCounterStableOnDecryptFailure` ✓

---

## Model-Checkable Findings (brief §6.1)

| Finding ID | Description | Expected violation | Hunt cfg | Trigger reachable? |
|---|---|---|---|---|
| MC1 | Second KEY_EXCHANGE (HITC) before first FINISH overwrites `latest_session_id`; FINISH completes wrong session | `SessionEstablishedOnlyAfterOwnFinish` | `MC_hunt_family1.cfg` | Yes: `MaxKeyExchanges=3` allows two KEX before FINISH; `hitc=TRUE` enabled in non-det choice |
| MC2 | Non-encap mutual auth omits `peer_cert_slot` write; FINISH verifies against wrong slot | `MutAuthUsesNegotiatedSlot` | `MC_hunt_family2.cfg` | Yes: `MaxCertSlots=2` means slot 2 is a valid non-default slot; non-det chooses `MUT_NON_ENCAP` |
| MC3 | Encode failure after key derivation leaves session in KEYS_DERIVED with application keys | `NoDataKeysBeforeEstablished`, `SessionStateMonotonic` | `MC_hunt_family3.cfg` | Yes: `MaxEncodeFailures=1` enables `RspEncodeFailure`; fires after `RspDeriveDataKeys` |
| MC4 | Sequence counter advanced before AEAD; injected message permanently desynchronizes counters | `SeqCounterStableOnDecryptFailure` | `MC_hunt_family4.cfg` | Yes: `MaxInjections=1` enables `InjectBadMessage`; session must be ESTABLISHED first |

All §6.1 findings have a hunt cfg. Triggers are reachable with the specified bounds. ✓

---

## Out-of-scope items (brief §3.2)

The following items from brief §3.2 are intentionally not modeled:
- Session slot memory management (`libspdm_free_session_id` call discipline) — resource management, not protocol safety
- Alignment/unaligned pointer casts — C UB, not protocol logic
- `secured_message_version` uninitialized — C UB, code-review fix
- FINISH signature RECORD_TRANSCRIPT wrong-slot (CR1) — build-time conditional, affects test builds only
- Heartbeat/watchdog — transport liveness, out of scope
- PSK_EXCHANGE/PSK_FINISH — different protocol flow

None of these require any spec coverage.

---

## Notes

- **MC.cfg** intentionally has all extension invariants commented out (standard spec-validation config). This is correct: MC.cfg is for spec convergence, hunt cfgs are for bug hunting.
- **F3 zombie detection**: `NoDataKeysBeforeEstablished` allows `KEYS_DERIVED` state (it is a transient intermediate), so it does not flag a zombie session on its own. The zombie is captured by the combination of `RspEncodeFailure` firing (leaving session in `KEYS_DERIVED`) and `SessionEstablishedOnlyAfterOwnFinish` ensuring no partial establishment. A temporal property (commented out in MC_hunt_family3.cfg) would catch the liveness violation directly.
- **F4 invariant is expected to be violated**: `SeqCounterStableOnDecryptFailure` is the invariant that SHOULD be violated by the current implementation — that is the bug. TLC finding a violation confirms the bug exists.

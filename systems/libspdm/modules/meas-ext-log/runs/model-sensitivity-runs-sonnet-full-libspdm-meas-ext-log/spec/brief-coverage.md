# Brief Coverage Self-Audit

Target: libspdm MEL paged-transfer
Source: modeling-brief.md §2 / §5 / §6.1

---

## Families (brief §2)

| Family | Priority | Hunt cfg |
|---|---|---|
| F1: multi-chunk consistency (no snapshot) | HIGH | `MC_hunt_family1_consistency.cfg` (targets MelConsistency, MC1) |
| F1: partial-header loop termination | HIGH | `MC_hunt_family1_header.cfg` (targets MelHeaderComplete, MC2) |
| F2: mel_spec negotiation bypass | MEDIUM | `MC_hunt_family2.cfg` (targets MelSpecValid + MelSpecPreSend, MC3) |
| F3: missing pre-send validation | MEDIUM (code review); LOW (TLA+) | No hunt cfg. Brief §3.1 explicitly excludes pure F3 from TLA+ scope. F3's interaction with F1 (mel_entries_len loop uses mel_offset, not number_of_entries) is covered by MC_hunt_family1_header.cfg. |
| F4: sample HAL bounds / null check | LOW | No hunt cfg. Brief §3.2 explicitly excludes F4: HAL-level concern, not protocol state space. |

---

## Invariants (brief §5)

| Invariant | Defined | Wired in MC.tla | Enabled in hunt cfg |
|---|---|---|---|
| MelConsistency | `base.tla` | `MC.tla` (commented `MCMelConsistency`) | `MC_hunt_family1_consistency.cfg` ✓ |
| MelHeaderComplete | `base.tla` | `MC.tla` (commented `MCMelHeaderComplete`) | `MC_hunt_family1_header.cfg` ✓ |
| MelSpecValid | `base.tla` | `MC.tla` (commented `MCMelSpecValid`) | `MC_hunt_family2.cfg` ✓ |
| MelSpecPreSend | `base.tla` | `MC.tla` (commented `MCMelSpecPreSend`) | `MC_hunt_family2.cfg` ✓ |

All four Safety invariants from brief §5 are defined, wired, and enabled in at least one hunt cfg.

---

## Findings (brief §6.1)

| ID | Expected violated invariant | Trigger mechanism | Hunt cfg | Reachable? |
|---|---|---|---|---|
| MC1 | MelConsistency | MelUpdate fires between chunk-1 and chunk-2 responses | `MC_hunt_family1_consistency.cfg` — MelUpdateLimit=1, MEL_SIZES={20}, MAX_CHUNK=12 forces two chunks | Yes: path documented in cfg comment |
| MC2 | MelHeaderComplete | First chunk portion_length < 16 bytes | `MC_hunt_family1_header.cfg` — MEL_SIZES={8} means max portion_len=8 < MEL_HEADER_SIZE=16 | Yes: guaranteed by constant |
| MC3 | MelSpecValid | mel_specification_sel=0x03 (INVALID) with KEY_EX_CAP=0 && PSK_CAP=0 | `MC_hunt_family2.cfg` — Init non-det has_session_cap; `NegotiateAlgorithmsWithoutSessionCap(INVALID)` is enabled when has_session_cap=FALSE | Yes: Init non-det allows has_session_cap=FALSE |

All three §6.1 model-checkable findings have a hunt cfg whose fault setup makes the trigger reachable.

---

## Gaps (explicit)

- **F3 (missing mel_spec != 0 pre-send check)**: MelSpecPreSend captures the observable outcome but the hunt config (`MC_hunt_family2.cfg`) targets `MelSpecValid` as the primary invariant. MelSpecPreSend is also enabled there — `SendGetMelFirstChunk` has no mel_spec guard, so when `mel_spec_conn=INVALID (3) ≠ 0`, the transfer proceeds and MelSpecPreSend remains true (3 ≠ 0). The actual F3 bug (sending when mel_spec_conn=0) requires `NegotiateAlgorithmsWithoutSessionCap(0)` followed by `SendGetMelFirstChunk`. This path is reachable in `MC_hunt_family2.cfg` (MEL_SPEC_UNSET=0 is in the wire_val set; MelSpecPreSend would be violated). No separate cfg needed.

- **F4 (HAL bounds)**: Intentionally not modeled. Per brief §3.2, this is a sample implementation concern, not a protocol-level property. TLA+ adds no value here.

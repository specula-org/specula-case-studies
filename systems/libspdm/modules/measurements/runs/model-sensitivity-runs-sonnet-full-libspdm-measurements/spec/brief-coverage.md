# Brief Coverage Self-Audit

Maps modeling-brief.md §2 (Bug Families) / §5 (Invariants) / §6.1 (MC Findings) to spec and MC artifacts.

---

## §2 Bug Families → Hunt Configs

| Family | Description | Hunt Config | Targeting invariants |
|--------|-------------|-------------|----------------------|
| Family 1 (HIGH) | L1/L2 Transcript Integrity | `MC_hunt_family1.cfg` | `MCL1L2Agreement`, `MCTranscriptNoSigBytes` |
| Family 2 (MEDIUM) | Response Structure Parsing | `MC_hunt_family2.cfg` | `MCParseWithinBounds` |
| Family 3 (MEDIUM) | Session/Non-Session Context Selection | `MC_hunt_family3.cfg` | `MCSessionConsistency`, `MCL1L2Agreement` |
| Family 4 (MEDIUM) | Slot ID / Key Binding | `MC_hunt_family4.cfg` | `MCSlotBinding` |
| Family 5 (LOW) | NOT_READY Token Replay | *(not modeled — see note below)* | — |

**Family 5 note**: The brief classifies this as LOW priority for TLA+ and recommends code review
instead. It is intentionally out of scope. No hunt config was generated. The token-wrap mechanism
would require modeling a uint8_t counter with 256 fire cycles, which is intractable for TLC.

---

## §5 Invariants → Hunt Configs (Enabled)

| Invariant | Brief entry | Defined in spec | Enabled in hunt cfg |
|-----------|-------------|-----------------|---------------------|
| `L1L2Agreement` | §5 row 1 | `base.tla` (L1L2Agreement) | `MC_hunt_family1.cfg`, `MC_hunt_family3.cfg` ✓ |
| `TranscriptNoSignatureBytes` | §5 row 2 | `base.tla` (TranscriptNoSignatureBytes) | `MC_hunt_family1.cfg` ✓ |
| `ParseWithinBounds` | §5 row 3 | `base.tla` (ParseWithinBounds) | `MC_hunt_family2.cfg` ✓ |
| `SlotBinding` | §5 row 4 | `base.tla` (SlotBinding) | `MC_hunt_family4.cfg` ✓ |
| `SessionConsistency` | §5 row 5 | `base.tla` (SessionConsistency) | `MC_hunt_family3.cfg` ✓ |
| `TranscriptGrowthOnlyMeasurements` | §5 row 6 | `base.tla` (structural comment) | *(structural; enforced by Next relation; not a checkable invariant in the current model — see note)* |

**TranscriptGrowthOnlyMeasurements note**: The brief describes this as a structural invariant.
In the spec, `message_m` only grows via `ResponderAppendRequest`, `ResponderBuildResponse`,
and `PartialRetryAccumulate` — all of which are triggered by GET_MEASUREMENTS actions. The
invariant is enforced by the action structure rather than as a separate predicate. To make it
explicit, add a check that `message_m_global` length never decreases except after a reset action.
This is deferred; the current hunt configs implicitly cover it via `L1L2Agreement`.

---

## §6.1 Findings → Hunt Config Reachability

| Finding | Description | Hunt config | Reachable? |
|---------|-------------|-------------|------------|
| MC1 | L1/L2 divergence via session/non-session interleave | `MC_hunt_family1.cfg`, `MC_hunt_family3.cfg` | Yes: both session and NULL session_id are non-deterministic in `RequesterSendGetMeasurements` |
| MC2 | Retry accumulation (issue #491/#524) causing L1/L2 divergence | `MC_hunt_family1.cfg` (`MaxRetryLimit=2`), `MC_hunt_family3.cfg` | Yes: `MCPartialRetryAccumulate` is bounded at 2, `L1L2Agreement` is checked |
| MC3 | Missing NONCE_SIZE guard → parse beyond buffer | `MC_hunt_family2.cfg` | Yes: `RequesterParseResponseNoSig` uses the buggy `buggy_min` guard; `ParseWithinBounds` checks `~parse_error`; MC will find small `response_size` where `parse_offset > response_size` |
| MC4 | NEED_RESYNC leaves active_sessions non-empty, stale message_m accepted | `MC_hunt_family3.cfg` (`MaxResyncLimit=2`) | Yes: `NeedResync` sets `connection_state=NOT_STARTED` but does NOT clear `active_sessions`; `SessionConsistency` will fire |

---

## Coverage Gaps and Honest Notes

1. **Family 5 not modeled**: Token-replay requires 256 bounded iterations — out of practical TLC scope. Code-review only (CR4 in the brief).

2. **RECORD_TRANSCRIPT_DATA_SUPPORT=0 mode**: The brief explicitly de-scopes the streaming hash mode. Only the managed-buffer (mode 1) path is modeled. The `L1L2ComputationFailure` action partially covers the hash-context-consumed-on-failure scenario but does not model the streaming hash state machine.

3. **Key usage bit mask (Family 4)**: The spec models `KeyUsageOK` as a helper but does not inject a false `multi_key_conn_rsp` value to specifically hunt the case where the key-usage check is skipped. The `MC_hunt_family4.cfg` reaches `SlotBinding` violations via slot mismatch; the key-usage gap is covered by code review (CR1 in the brief, TV2 for test verification).

4. **`TranscriptGrowthOnlyMeasurements` not a checkable invariant**: Encoded structurally in the spec's action set rather than as a separate Boolean invariant. Could be made explicit in a future iteration.

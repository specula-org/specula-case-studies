# Brief Coverage Self-Audit

Mapping from modeling-brief.md §2 / §5 / §6.1 → spec/MC artifacts.

## §2 Bug Families → Hunt Configs

| Family | Brief description | Hunt config | Invariant(s) enabled |
|--------|------------------|-------------|----------------------|
| 1 | Response state check ordering in SEND_EVENT handler | `MC_hunt_family1.cfg` | `MCRequestInFlightGuard`, `MCNoDualInFlightConflict` |
| 2 | SUBSCRIBE_NONE overrides EVENT_ALL_POLICY | `MC_hunt_family2.cfg` | `MCEventAllOverriddenToNone`, `MCSubscribeNoneBlocksEvents` |
| 3 | Event delivery before subscription acknowledgment | `MC_hunt_family3.cfg` | `MCSubscribeNoneBlocksEvents` |
| 4 | `crypto_request` flag inconsistency | — | Out of scope (brief §3.2: "Do Not Model") |

## §5 Invariants → Spec Location → Hunt Config

| Invariant | Spec variable/operator | Enabled in hunt cfg? |
|-----------|----------------------|----------------------|
| RequestInFlightGuard | `base.tla`: `RequestInFlightGuard`; `MC.tla`: `MCRequestInFlightGuard` | Yes — `MC_hunt_family1.cfg` |
| SubscribeNoneBlocksEvents | `base.tla`: `SubscribeNoneBlocksEvents`; `MC.tla`: `MCSubscribeNoneBlocksEvents` | Yes — `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg` |
| EventAllPolicyImpliesSubscribeAll | `base.tla`: `EventAllPolicyImpliesSubscribeAll`; `MC.tla`: `MCEventAllPolicyImpliesSubscribeAll` | Structural (always on in MC.cfg); also in `MC_hunt_family2.cfg` |
| EncapInFlightSessionValid | `base.tla`: `EncapInFlightSessionValid`; `MC.tla`: `MCEncapInFlightSessionValid` | Structural (always on); also in `MC_hunt_family3.cfg` |
| NoDualInFlightConflict | `base.tla`: `NoDualInFlightConflict`; `MC.tla`: `MCNoDualInFlightConflict` | Yes — `MC_hunt_family1.cfg` |

All five brief §5 invariants have a hunt config that enables them. ✓

## §6.1 Model-Checkable Findings → Hunt Config Reachability

| Finding | Expected violation | Hunt config | Reachable? |
|---------|-------------------|-------------|------------|
| MC-1: PROCESSING_ENCAP + direct SEND_EVENT (version mismatch) → VERSION_MISMATCH not REQUEST_IN_FLIGHT | `RequestInFlightGuard` | `MC_hunt_family1.cfg` | Yes: `MCHandleSendEventVersionMismatch` fires when `encap_event_in_flight=TRUE`; guard reads `last_send_event_response=RESP_VERSION_MISMATCH` |
| MC-2: EVENT_ALL_POLICY session → SUBSCRIBE_NONE via SUBSCRIBE_EVENT_TYPES | `EventAllOverriddenToNone`, `SubscribeNoneBlocksEvents` | `MC_hunt_family2.cfg` | Yes: `MCHandleKeyExchangeWithEventAll` then `MCHandleSubscribeNone`; `EventAllOverriddenToNone` fires when `event_all_policy=TRUE ∧ subscription_state=SUB_NONE` |
| MC-3: Encap SEND_EVENT in flight while SUBSCRIBE_NONE arrives | `EncapInFlightSessionValid`, `SubscribeNoneBlocksEvents` | `MC_hunt_family3.cfg` | Yes: `MCInitEncapSendEvent` (sets `encap_event_in_flight=TRUE`) then `MCHandleSubscribeNone`; `SubscribeNoneBlocksEvents` fires when `subscription_state=SUB_NONE ∧ encap_event_in_flight=TRUE` |

## Gaps and Limitations

1. **Family 1 version-match path**: When versions match and `response_state = PROCESSING_ENCAP`, the buggy handler still correctly returns `REQUEST_IN_FLIGHT` (because the response_state check at line 49 is reached). `HandleSendEventVersionMatch` models this correctly as `RESP_REQUEST_IN_FLIGHT`. The bug is only exploitable via version mismatch.

2. **HandleSubscribeEventTypes(TRUE) with response_state = PROCESSING_ENCAP**: The subscribe handler correctly checks response_state first. If `PROCESSING_ENCAP`, it returns REQUEST_IN_FLIGHT correctly. This guards Family 3 scenario partially — but InitEncapSendEvent itself has no guard. The model captures this via `MCInitEncapSendEvent` preceding `MCHandleSubscribeNone`.

3. **Family 4 (crypto_request flag)**: Explicitly out of scope (brief §3.2). No hunt config. The BUSY retry mechanism is implementation-level; no protocol state machine impact.

4. **MC_hunt_family1.cfg with version-match path**: `MCHandleSendEventVersionMatch` is unbounded in hunt_family1, which is correct — the version-match path reveals no bug. The violation only comes from `MCHandleSendEventVersionMismatch` (bounded to 2).

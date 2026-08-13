# Independent review: SONiC LinkMgrD e2e guidance replicas

## Summary

The focused LinkMgrD e2e guidance batch ran four independent replicas against `sonic-net/sonic-linkmgrd` snapshot `298adcd23a95eae918ab53c9697527e5c53a8cf8`.

The raw Phase 4 reports contain 35 disposition entries:

- 26 `REPRODUCED` entries.
- 4 `MASKED` entries.
- 3 `ENV_LIMITED` entries.
- 1 `FALSE POSITIVE`.
- 1 `DROPPED`.

After independent deduplication against the existing SONiC case-study records and upstream-known findings, this review promotes 8 additional reportable `New` bugs: 3 `Critical`, 4 `High`, and 1 `Medium`.

## Source replicas

| Replica | Run ID | Generated | Raw Phase 4 result |
| --- | --- | --- | --- |
| r1 | `linkmgrd-codex56sol-xhigh-e2e-guidance-r1-20260810` | 2026-08-11T06:39:20+00:00 | 4 reproduced New bugs, 1 masked finding, 1 dropped disposition |
| r2 | `linkmgrd-codex56sol-xhigh-e2e-guidance-r2-20260810` | 2026-08-11T13:34:49+00:00 | 8 reproduced New bugs, 1 masked finding, 1 env-limited finding |
| r3 | `linkmgrd-codex56sol-xhigh-e2e-guidance-r3-20260810` | 2026-08-11T14:36:18+00:00 | 3 reproduced New bugs, 1 reproduced Known bug, 1 masked finding, 2 env-limited findings |
| r4 | `linkmgrd-codex56sol-xhigh-e2e-guidance-r4-20260810` | 2026-08-11T22:32:54+00:00 | 9 reproduced New bugs, 1 reproduced Known bug, 1 masked finding, 1 false positive |

The original outputs remain in:

`/home/ubuntu/specula-linkmgrd-e2e-runner-20260810/runs/linkmgrd-codex56sol-xhigh-e2e-guidance-r{1,2,3,4}-20260810/linkmgrd/.specula-output/`

They are not copied here because the replica worktrees are large; r4 alone is roughly 272 GB. This directory preserves the curated case-study ledger and the provenance needed to re-open the raw artifacts locally.

## Promoted findings

| # | Evidence | Severity | Finding | Review decision |
| ---: | --- | --- | --- | --- |
| 1 | `r1 MC-1`, `r2 CR-1` | High | Queued pre-init active-active config replay can apply a superseded forced mux mode. | Promote as New: the stale callback reaches the DB-facing mux command path after a newer `Auto` config has been accepted. |
| 2 | `r1 MC-2`, `r2 CR-4` | High | Stale mux-wait acknowledgements or canceled wait callbacks can clear a newer wait epoch. | Promote as New: the stale completion can let peer-probe or forwarding-state work escape while a newer mux transition is still outstanding. |
| 3 | `r1 CR-4` | High | Cached default-route state is not replayed to late-created active-active ports. | Promote as New: route eligibility stays out-of-band and the port can retain stale mux/heartbeat behavior until another route notification arrives. |
| 4 | `r4 MC-2` | Critical | Active-standby default-route loss can leave local forwarding Active while route state is `NA`. | Promote as New: route-loss notification does not issue the expected Standby command, leaving a route-ineligible ToR forwarding. |
| 5 | `r4 MC-5`, supported by `r2 MC-1` | Critical | Active-standby handoff demotes the sender before successful peer takeover is established. | Promote as New: a lost takeover packet plus local send-complete handling can leave both ToRs Standby. |
| 6 | `r4 MC-4` | Critical | A delayed legitimate `COMMAND_SWITCH_ACTIVE` can create dual-active forwarding. | Promote as New: the active-standby peer request has no generation/current-mode guard, so an old takeover command can be accepted after the sender is Active again. |
| 7 | `r4 MC-8` | Medium | Software-cookie peer packets can publish `PeerActive` while peer type remains `UNKNOWN`. | Promote as New: the hardware-prober receive path accepts peer-positive evidence without classifying the peer session type, creating an identity invariant violation with downstream risk. |
| 8 | `r4 CR-2` | High | Active-standby `Active/Error/Up` entered by a mux-error event can skip recovery. | Promote as New only for the active-standby scope: the handler depends on link-prober state change and therefore omits recovery when `MuxError` is the last event. |

## Retained but not promoted

| Class | Examples | Reason |
| --- | --- | --- |
| Already represented in the SONiC `effort_EXP` ledger | Delayed heartbeat replies, stale hardware-session evidence, warm-restart duplicate accounting, stale warm Auto writes, and related stale timer/session cases. | These are valuable evidence but not additional case-study bugs because the 52-row `effort_EXP` ledger already records the mechanism family. |
| Known upstream issue | `r3 MC-2`, `r4 MC-6` | Both map to open `sonic-linkmgrd` Issue #285: peer desired Standby is not reasserted after peer observed state resets. |
| Masked or environment-limited | `r1 MC-3`, `r2 MC-4`, `r3 MC-3`, `r3 MC-4`, `r3 MC-6`, `r4 MC-1` | These may be useful engineering leads, but this case-study ledger promotes only reproduced, reportable bugs. |
| False positive or dropped | `r1 CR-1`, `r4 MC-3` | The Phase 4 disposition is not severity-bearing. |

## Scope notes

- `r4 CR-2` is intentionally narrowed to the active-standby `Active/Error/Up` behavior. The active-active `Wait/Error/Up` and `Unknown/Error/Up` parts overlap existing Issue #285-related coverage and are not counted as new here.
- `r1 CR-6` is retained as adjacent evidence for unguarded peer switch-active behavior, but the promoted dual-active mechanism is anchored on `r4 MC-4`.
- The promoted counts are additional to the pre-existing SONiC case-study records: 8 `New` LinkMgrD mechanisms, all reproduced and severity-bearing.

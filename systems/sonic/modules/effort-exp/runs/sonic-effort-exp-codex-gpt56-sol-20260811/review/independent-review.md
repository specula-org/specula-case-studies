# Independent review: SONiC effort_EXP reviewed bug ledger

## Summary

The reviewed `effort_EXP` SONiC batch contains 52 recordable bugs after deduplication and exclusion of non-recordable findings:

- 43 `New` and 9 `Known` bugs.
- 28 `Critical`, 21 `High`, and 3 `Medium` severity bugs.
- Modules covered: DASH HA, FDB, ICCPD, LinkMgrD, and warm reboot.

This record includes warm reboot `high/MC-2`. The management contract check found that `sonic-package-manager install --enable` is a supported management surface, and the implementation lacks an ordering or exclusion guard that prevents the install/enable operation from interleaving with warm-restart finalization. The finalizer-snapshot counterexample is therefore recordable.

This record excludes warm reboot `high/MC-5`, which remains deferred pending direct validation. It also excludes findings classified as `MASKED`, `ENV_LIMITED`, `FALSE POSITIVE`, or `DROPPED`.

## Count checks

| Dimension | Count |
| --- | ---: |
| Total recordable bugs | 52 |
| New bugs | 43 |
| Known bugs | 9 |
| Critical severity | 28 |
| High severity | 21 |
| Medium severity | 3 |
| Deferred candidates | 1 |

## Module distribution

| Module | Total | New | Known | Critical | High | Medium |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| DASH HA | 9 | 7 | 2 | 4 | 5 | 0 |
| FDB | 9 | 7 | 2 | 6 | 1 | 2 |
| ICCPD | 9 | 9 | 0 | 5 | 4 | 0 |
| LinkMgrD | 10 | 10 | 0 | 6 | 3 | 1 |
| Warm reboot | 15 | 10 | 5 | 7 | 8 | 0 |

## Recordable bugs

| # | Module | Evidence | Severity | Novelty | Finding |
| ---: | --- | --- | --- | --- | --- |
| 1 | DASH HA | `medium/MC-3` | Critical | Known | Peer ASIC Standby ACK gate missing before Pending Active. |
| 2 | DASH HA | `medium/CR-5` | Critical | New | Active persisted but BulkSync completion lost on crash. |
| 3 | DASH HA | `xhigh/MC-5` | Critical | Known | Delete/recreate race drops new SET via old actor. |
| 4 | DASH HA | `high/MC-5` | Critical | New | Cleanup reports success before dependencies are restored and leaves HA/BFD/route residue. |
| 5 | FDB | `max/MC-1` | Critical | Known | Delayed FLUSHED deletes post-flush relearn incarnation. |
| 6 | FDB | `high/MC-3` | Critical | New | Old-port AGE deletes new-port binding. |
| 7 | FDB | `high/MC-5` | Critical | New | MCLAG kernel programming failure loses retry and causes bad flooding. |
| 8 | FDB | `xhigh/MC-1` | Critical | New | Queued old SAI LEARN overwrites newer local owner. |
| 9 | FDB | `xhigh/MC-3` | Critical | New | VXLAN FDB still references deleted NHG. |
| 10 | FDB | `xhigh/MC-4` | Critical | New | Warm replay deletes unchanged APP_DB FDB row. |
| 11 | ICCPD | `medium/MC-1` | Critical | New | Peer send failure still advances sync and permanently loses ARP/ND progress. |
| 12 | ICCPD | `high/MC-3 + xhigh/MC-2` | Critical | New | Mclagsyncd FDB ADD/DEL failure recorded as success. |
| 13 | ICCPD | `max/MC-3` | Critical | New | Traffic-disable failure leaves MLAG port forwarding. |
| 14 | ICCPD | `xhigh/CR-5` | Critical | New | Stale generation interface-up ACK enables traffic. |
| 15 | ICCPD | `medium/CR-5` | Critical | New | Concurrent ARP/ND crossing leaves peers with opposite mappings. |
| 16 | LinkMgrD | `high/MC-5` | Critical | New | Double-decrements warm-restart pending count and prematurely marks RECONCILED. |
| 17 | LinkMgrD | `medium/MC-1` | Critical | New | Hardware session replacement reuses old Active evidence. |
| 18 | LinkMgrD | `xhigh/MC-3` | Critical | New | Auto cleanup publishes RECONCILED before persisted cleanup. |
| 19 | LinkMgrD | `xhigh/MC-1` | Critical | New | Delayed Standby completion overwrites newer Active config. |
| 20 | LinkMgrD | `xhigh/MC-4` | Critical | New | Link-down as final init event leaves physical MUX Active. |
| 21 | LinkMgrD | `xhigh/MC-5` | Critical | New | Lost peer-Standby actuation has no automatic retry. |
| 22 | Warm reboot | `high/MC-4` | Critical | New | Interrupted docker cp leaves truncated RDB and Redis startup permanently fails. |
| 23 | Warm reboot | `max/MC-3` | Critical | New | READY before orchagent actually completes freeze fence. |
| 24 | Warm reboot | `max/MC-4` | Critical | Known | VID/RID replacement tables become non-inverse and translation fails after reboot. |
| 25 | Warm reboot | `medium/MC-1` | Critical | New | Snapshot distribution failure starts warm swss from old Redis generation. |
| 26 | Warm reboot | `xhigh/MC-6` | Critical | New | Fabric/DPU warm lifecycle incomplete; SET success before vendor SAI. |
| 27 | Warm reboot | `xhigh/MC-7` | Critical | Known | Nondeterministic virtual-router match creates duplicate RIF and service exit. |
| 28 | Warm reboot | `xhigh/MC-8` | Critical | New | Route and label share wrong warm helper, causing cross-table write or label drop. |
| 29 | DASH HA | `medium/MC-1` | High | New | Compound config update silently skips later fields. |
| 30 | DASH HA | `medium/MC-2` | High | New | Peer replacement accepts old vote reply. |
| 31 | DASH HA | `high/MC-2` | High | New | Delayed HA-set retry rolls pairing back to old peer. |
| 32 | DASH HA | `xhigh/MC-3` | High | New | Actor transaction returns OK before commit and sender clears retry. |
| 33 | DASH HA | `xhigh/MC-4` | High | New | VoteRequest timeout is silently dropped and election stalls after recovery. |
| 34 | FDB | `high/MC-4` | High | New | LRU dedupe loses MAC MOVE count and bypasses move guard. |
| 35 | ICCPD | `xhigh/CR-1` | High | New | Wrong-RG application frame bypasses RG/session guard. |
| 36 | ICCPD | `medium/MC-3` | High | New | Function-static prev_state suppresses second MCLAG domain reconciliation. |
| 37 | ICCPD | `xhigh/MC-3` | High | New | Lost neighbor event has no complete resnapshot. |
| 38 | ICCPD | `xhigh/CR-3` | High | New | Live Sync Request pushes EXCHANGE to ERROR. |
| 39 | LinkMgrD | `high/MC-1` | High | New | Delayed heartbeat reply credited to newer probe generation. |
| 40 | LinkMgrD | `high/MC-2` | High | New | Delayed peer Active command bypasses local route eligibility. |
| 41 | LinkMgrD | `medium/CR-4` | High | New | Publishes Healthy long-term before hardware confirms Active. |
| 42 | Warm reboot | `high/MC-1` | High | New | Rebootbackend restart loses accepted reboot ownership/status. |
| 43 | Warm reboot | `high/MC-2` | High | New | Finalizer snapshot omits late warm-aware component and global warm finalizes early. |
| 44 | Warm reboot | `max/MC-1` | High | Known | Concurrent reboot old cleanup clears newer attempt flags. |
| 45 | Warm reboot | `medium/MC-3` | High | New | NAT restore ignores failure and deletes only retry artifact. |
| 46 | Warm reboot | `medium/MC-4` | High | New | Multi-ASIC stop for ASIC1 kills ASIC0 swss. |
| 47 | Warm reboot | `xhigh/MC-5` | High | Known | Flex-counter permanently uses temporary VID with empty RID. |
| 48 | Warm reboot | `xhigh/MC-9` | High | New | LAG member partial failure loses retry and leaves teamd residue. |
| 49 | Warm reboot | `xhigh/MC-12` | High | Known | Finalizer ignores or times out live participant then clears flag, causing cold-start flush. |
| 50 | FDB | `max/MC-3` | Medium | Known | VTEP replacement credits new member refcount to old endpoint. |
| 51 | FDB | `medium/MC-3` | Medium | New | Same-port MOVE permanently raises per-port FDB count. |
| 52 | LinkMgrD | `high/MC-3` | Medium | New | Two-stage dispatch drops intermediate composite transition/TX suspension. |

## Deferred or excluded

- Warm reboot `high/MC-5`: deferred. The proposed D-Bus transport-exception failure mode is plausible but still needs direct validation before recording.
- `MASKED`, `ENV_LIMITED`, `FALSE POSITIVE`, and `DROPPED` findings from the raw archives are excluded from this ledger.

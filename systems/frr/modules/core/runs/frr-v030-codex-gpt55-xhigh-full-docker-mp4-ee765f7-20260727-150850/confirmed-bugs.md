# Confirmation Report — frr

## Final Result

Reproduced bugs: 2 = 2 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 3
Dispositions: 3 total = 2 reproduced + 0 env-limited + 1 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | MASKED | no |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |

## Entry 1: Stale normal dataplane result mutates a newer route

- **Finding ID**: MC-1
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: zebra/zebra_rib.c:2060

## Description
`rib_process_result()` detects a stale dataplane sequence mismatch for `re`, but only logs it and continues into the success path. That path can mark the matched current route installed and send `ZAPI_ROUTE_INSTALLED` to BGP. In the Docker topotest runtime, the defect is masked because the current generation dataplane result is delivered immediately after the stale result and the kernel route is already the current r3 nexthop.

## Trigger scenario
BGP first installs `10.10.0.0/24` via r2, then a better route via r3 is added before Zebra main processes the first dataplane completion. Level 3 adds only timing delays in Zebra dataplane processing to force the stale generation-1 success to arrive after generation 2 exists.

## Developer intent
The code comment says the sequence check is meant “to detect stale results before continuing”, but the mismatch branch continues. BGP consumes installed owner notifications at `bgpd/bgp_zebra.c:3110` by clearing FIB pending and announcing the selected route. Prior-report search checked upstream issues/PRs and local git history; related reports such as [FRR #5215](https://github.com/FRRouting/frr/issues/5215) and [FRR #8611](https://github.com/FRRouting/frr/issues/8611) / [PR #8659](https://github.com/FRRouting/frr/pull/8659) do not report this exact success-path owner-notification mechanism.

## Reproduction result
Executed:
```bash
timeout 45m /home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/repro/test_bugMC-1_stale_dplane_success.sh
```

Output excerpt:
```text
docker_exit=0
level0: stale_notify=False current_gen=2 second_ctx_seen=True r1_best_nexthop=10.0.13.2 r1_kernel_route='10.10.0.0/24 nhid 16 via 10.0.13.2 dev r1-eth1 proto bgp metric 20' r4_route_present=True
level1: stale_notify=False current_gen=2 second_ctx_seen=True r1_best_nexthop=10.0.13.2 r1_kernel_route='10.10.0.0/24 nhid 16 via 10.0.13.2 dev r1-eth1 proto bgp metric 20' r4_route_present=True
level3: stale_notify=True current_gen=2 second_ctx_seen=True r1_best_nexthop=10.0.13.2 r1_kernel_route='10.10.0.0/24 nhid 16 via 10.0.13.2 dev r1-eth1 proto bgp metric 20' r4_route_present=True
level3: bgp_notify ctxId=0 causeGen=1 note=installed
level3: current_bgp_notify ctxId=0 causeGen=2 note=installed
level3: rib_process_result ctxId=1 gen=1 causeGen=1 seq=1 note=installed
```

The stale owner notification is real, but the live wrong-route consequence is masked: the current generation-2 kernel update and installed notification follow in the same result flow, and the observed kernel route is already via r3.

## Recommendation
On `re->dplane_sequence != seq`, stop processing that `re` as a successful current realization: skip installed/FIB/NHT/owner-notify mutation for stale results, or require a sequence match in `rib_route_match_ctx()` before assigning `re`.

---

## Entry 2: Late async route notify mutates the current selected route without generation gating

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: zebra/zebra_rib.c:2311

## Description
`rib_process_dplane_notify()` matches async `DPLANE_OP_ROUTE_NOTIFY` by route identity fields through `rib_route_match_ctx(re, ctx, false, true)` and does not compare a route generation or dataplane sequence. A late FPM offload notification for an older route event can therefore mutate the currently selected route, set offload/FIB state, run NHT evaluation, and notify the owner as installed.

## Trigger scenario
Run Zebra with `dplane_fpm_nl` and `--asic-offload=notify_on_offload`, enable BGP `suppress-fib-pending`, let r1 receive a BGP route, delay the first FPM offload notify, then change the route MED so BGP sends a second route generation to Zebra. Before the second generation receives its own FPM completion, send the delayed first-generation FPM `RTM_NEWROUTE` notify with `RTM_F_OFFLOAD`.

## Developer intent
The ordinary dataplane result path has stale-result checks using `dplane_sequence` at `zebra/zebra_rib.c:2054`, `:2060`, and `:2090`. The async notify path at `zebra/zebra_rib.c:2311` lacks that equivalent guard. BGP’s consumer at `bgpd/bgp_zebra.c:3110-3130` treats `ZAPI_ROUTE_INSTALLED` as authoritative, clearing `BGP_NODE_FIB_INSTALL_PENDING`, setting `BGP_NODE_FIB_INSTALLED`, and announcing the route. Prior-report search covered upstream issues/PRs and recently merged/closed PRs; adjacent reports such as https://github.com/FRRouting/frr/issues/14797 and https://github.com/FRRouting/frr/issues/15626 do not report this FPM late-notify generation-gate mechanism.

## Reproduction result
Test written and executed: `/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/repro/test_bugMC-2_late_fpm_notify.sh`

Command:
```bash
timeout 35m /home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/repro/test_bugMC-2_late_fpm_notify.sh
```

Output:
```text
collected 1 item
specula_mc2_late_fpm_notify/test_mc2_late_fpm_notify.py MC2_RESULT before_second_update fibPending=true fibInstalled=false metric=100
MC2_RESULT before_stale_notify fibPending=true fibInstalled=false metric=200
MC2_RESULT fpm_target_route_frames=2
MC2_RESULT sent_stale_first=True
MC2_RESULT sent_current_second=False
MC2_RESULT trace_counts rib_addnode=2 dplane_ctx_route_init=2 bgp_zebra_route_install=2
MC2_RESULT after_stale_notify fibPending=false fibInstalled=true metric=200
MC2_RESULT wrong_installed_from_stale_notify=true
.
============================== 1 passed in 49.64s ==============================
MC2 reproduction: PASS
```

REPRODUCED checklist:
1. Level 0 or Level 1 alone triggered it: yes. The test uses normal BGP/Zebra/FPM interfaces; Level 1 only controls FPM notify timing.
2. Level 2/3 was not used: no state injection and no FRR source patch.
3. Real consumer/caller: `bgpd/bgp_zebra.c:3110-3130` observes `ZAPI_ROUTE_INSTALLED`; the output shows BGP changed from `fibPending=true fibInstalled=false` to `fibPending=false fibInstalled=true` after only the stale first notify.
4. Masking/permanence: no downstream guard resolved it in the run. The current second notify was not sent (`sent_current_second=False`), and the BGP owner state remained installed until a future route event or later valid notify.

## Recommendation
Add generation/sequence gating to async route notifications, equivalent in spirit to the normal dataplane result path. `DPLANE_OP_ROUTE_NOTIFY` should carry enough route-generation or dataplane-sequence identity to reject stale notifications before mutating `dest->selected_fib`, offload flags, nexthop FIB flags, NHT state, or owner notifications.

---

## Entry 3: BGP suppress-fib pending can survive ZAPI route send failure with no outstanding work

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: bgpd/bgp_zebra.c:2076

## Description
`bgp_zebra_route_install()` sets `BGP_NODE_FIB_INSTALL_PENDING` before the queued non-EVPN `ZEBRA_ROUTE_ADD` is actually sent. If `zclient_send_message()` later returns `ZCLIENT_SEND_FAILURE`, `bgp_handle_route_announcements_to_zebra()` releases the queued inode and clears the schedule flag, but leaves `fibPending` set with no Zebra route, dataplane work, or owner notification outstanding.

## Trigger scenario
A transit BGP router runs `bgp suppress-fib-pending`. A peer advertises a new IPv4 route, BGP selects it, sets `BGP_NODE_FIB_INSTALL_PENDING`, and queues the Zebra install. The bgpd-to-zebra socket write then fails at the queued `ZEBRA_ROUTE_ADD`, matching counterexample State 4: `MCZapiSendFail(bgp0,p1)`.

## Developer intent
The code comment at `bgpd/bgp_zebra.c:2056` says suppress-fib pending means BGP expects Zebra installation before advertisement. Existing fixes cover adjacent cases, including withdrawal ordering and EVPN/no-ack paths, but not this non-EVPN queued send-failure path. I searched upstream issues/PRs and local git history for this exact mechanism; adjacent PRs such as https://github.com/FRRouting/frr/pull/15634 and https://github.com/FRRouting/frr/pull/21231 do not report or fix this site/mechanism.

## Reproduction result
Reproduction test written and executed: `/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/repro/test_bugMC-3_zapi_send_failure.sh`

```text
$ /home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/repro/test_bugMC-3_zapi_send_failure.sh
MC3 reproduction: source=/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/confirmation/MC-3/worktree
MC3 reproduction: image=ncp/frr-replay:ubuntu22-topotest
MC3 ladder: Level 0 baseline normal route advertisement, Level 1 timing-only no target trigger, Level 2 one admissible ZEBRA_ROUTE_ADD send failure.
MC3_RESULT level0_baseline_advertised=yes
MC3_RESULT level1_timing_only_triggered=no
MC3_RESULT fault_log=MC3_FAIL_ZEBRA_ROUTE_ADD count=48 errno=EIO
MC3_RESULT r2_bgp_fib_pending=true
MC3_RESULT r3_received_fault_route=false
MC3_RESULT r2_zebra_route_present=false
========================= 1 passed in 69.39s (0:01:09) =========================
MC3 reproduction: PASS
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**. Level 0 advertised normally; Level 1 timing-only did not trigger the send failure.
2. Level 2 precondition: public sequence was BGP sessions r1-r2-r3, `bgp suppress-fib-pending` on r2, r1 static route redistributed to BGP; the injected `EIO` corresponds to CE State 4 `MCZapiSendFail(bgp0,p1)`.
3. Real consumer/caller: `group_announce_route()` at `bgpd/bgp_updgrp_adv.c:1189` via `bgp_check_advertise()` at `bgpd/bgp_route.h:721`; observed by r3 missing the route.
4. Permanent or masked? No downstream retry/sync/owner notification resolved it in the run; after the failure r2 still had `fibPending=true`, r2 Zebra had no route, and r3 had no route. Only later external route churn would clear it.

## Recommendation
On non-EVPN `ZCLIENT_SEND_FAILURE` from the queued install path, preserve outstanding work by requeueing/replaying the route after reconnect, or explicitly convert the failed send into a reconciled install-failure state that clears pending without advertising an uninstalled route. Add a regression topotest covering queued `ZEBRA_ROUTE_ADD` send failure under `bgp suppress-fib-pending`.

---

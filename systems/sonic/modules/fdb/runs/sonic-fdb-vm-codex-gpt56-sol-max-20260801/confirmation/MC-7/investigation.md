# MC-7 investigation

## Scope and source evidence

- Finding source: model checking. The active repair-round-2 counterexample output
  `spec/output/repair_RR003_MC_hunt_scenario_5_restart_bfs.out` reports
  `Temporal property RestartConverges was violated` at output line 37 and gives
  a ten-state behavior. This corrects the stale pre-repair artifact path in the
  original investigation; the mechanism and state sequence are unchanged.
- Relevant counterexample actions and state changes:
  - State 2 (`MCFdbSyncCrash`, output line 180) puts the process down and NVO
    readiness false.
  - State 3 (`MCKernelNhgChangeWhileDown(g1)`, output line 319) makes
    `kernelNhg[g1] = TRUE` while `appNhg[g1] = FALSE`.
  - State 5 (`MCRestartReactive`, output line 597) makes `dumpSeen[g1]` and
    `missedDump[g1]` true while NVO readiness remains false.
  - State 6 (output line 736) makes NVO ready, but `appNhg[g1]` remains false.
  - States 7-9 (output lines 875, 1014, and 1153) complete replay, bake, and
    settle back in `restartPhase = "running"`; kernel NHG remains present and
    APP NHG remains absent. State 10 stutters.

## Step 1 — code audit

### Cited sites and behavior

- `fdbsyncd/fdbsyncd.cpp:30-31` registers the `FdbSync` object as the raw
  handler for `RTM_NEWNEXTHOP` and `RTM_DELNEXTHOP`.
- `fdbsyncd/fdbsyncd.cpp:77-90` subscribes to the kernel nexthop multicast
  group, adds the netlink socket to `Select`, issues `RTM_GETLINK`, and then
  issues the one-shot `RTM_GETNEXTHOP` dump.
- `fdbsyncd/fdbsyncd.cpp:89-94` waits for that nexthop dump before the CONFIG_DB
  subscriber is added to `Select` at `fdbsyncd/fdbsyncd.cpp:98-100`.
- `fdbsyncd/fdbsync.h:89` initializes `m_isEvpnNvoExist` to false.
- Kernel dump and live nexthop records follow the registered raw-message path:
  `FdbSync::onMsgRaw()` at `fdbsyncd/fdbsync.cpp:1349-1370` dispatches both
  `RTM_NEWNEXTHOP` and `RTM_DELNEXTHOP` to `onMsgNhg()`.
- `FdbSync::onMsgNhg()` at `fdbsyncd/fdbsync.cpp:1138-1144` returns before even
  parsing the record whenever `m_isEvpnNvoExist` is false. A valid singleton
  VTEP record would otherwise be written to `L2_NEXTHOP_GROUP_TABLE` and the
  internal map at `fdbsyncd/fdbsync.cpp:1240-1252`; a valid group would be
  written at `fdbsyncd/fdbsync.cpp:1254-1288`.
- CONFIG_DB readiness is processed later through
  `fdbsyncd/fdbsyncd.cpp:113-116`. `FdbSync::processCfgEvpnNvo()` only sets the
  flag and calls `updateAllLocalMac()` on a transition
  (`fdbsyncd/fdbsync.cpp:111-135`). It does not request another nexthop dump or
  replay a saved record.
- Repository-wide searches found only the startup `RTM_GETNEXTHOP` request at
  `fdbsyncd/fdbsyncd.cpp:89`; no later request, periodic NHG sync, or NVO-ready
  replay exists in fdbsyncd. A later, unrelated kernel `RTM_NEWNEXTHOP` update
  could incidentally repair a particular entry, but no quiescent-state resend
  is scheduled.
- Warm-restart assistance does not cover this table. The constructor registers
  only `VXLAN_FDB_TABLE` and `VXLAN_REMOTE_VNI_TABLE` at
  `fdbsyncd/fdbsync.cpp:40-45`, omitting `L2_NEXTHOP_GROUP_TABLE`. Consequently
  `AppRestartAssist::readTablesToMap()` / `reconcile()` only operate on those
  registered tables (`warmrestart/warmRestartAssist.cpp:131-163` and
  `warmrestart/warmRestartAssist.cpp:258-305`).
- The existing unit test
  `tests/mock_tests/fdbsyncd/fdbsyncd_ut.cpp:288-301` confirms that a valid
  `RTM_NEWNEXTHOP` record is intentionally ignored while NVO is false. The
  adjacent success test manually makes NVO true before delivering the record
  (`tests/mock_tests/fdbsyncd/fdbsyncd_ut.cpp:303-323`). There is no test that
  moves NVO from false to true after the early record.

### Call chain and reachability

Normal entry path:

1. FRR/zebra uses the Linux nexthop API to install an L2/FDB nexthop or group
   while fdbsyncd is down.
2. On fdbsyncd startup, `main()` constructs `FdbSync`, whose NVO flag begins
   false, and registers it with `NetDispatcher`.
3. `main()` issues `RTM_GETNEXTHOP`; the kernel returns the extant object as an
   `RTM_NEWNEXTHOP` dump record. `NetDispatcher` invokes the public raw-handler
   entry `FdbSync::onMsgRaw()`, which calls `onMsgNhg()`.
4. `onMsgNhg()` returns at line 1143 because CONFIG_DB readiness cannot yet have
   been selected by this loop.
5. The CONFIG_DB `VXLAN_EVPN_NVO` SET is subsequently popped and sets readiness
   true, but it neither replays the discarded record nor asks the kernel for a
   second dump.
6. With no later change to that kernel object, kernel and APP state remain
   divergent.

This producer sequence is part of the documented system design: the EVPN-MH
HLD says the kernel nexthop table maintains L2 NHGs, shows normal `ip nexthop`
FDB objects, and says fdbsyncd must handle L2-NHG notifications **and dump** and
program `L2_NEXTHOP_GROUP_TABLE` (HLD sections 2.2.4.1 and 3.3.5). It therefore
does not require an invented peer message or an illegal state.

The exact injected precondition available to a Level-2 harness also corresponds
to the supplied admissible counterexample transition: State 3,
`MCKernelNhgChangeWhileDown(g1)` (output line 319), followed by the startup dump
transition recorded in State 5 (output line 597).

### Real consumers and consequence path

- The design names `L2NhgOrch` as the consumer of
  `L2_NEXTHOP_GROUP_TABLE`. Production constructs that consumer at
  `orchagent/orchdaemon.cpp:526` and schedules it in the orch list at line 536.
  For APP_DB tables, `Orch::addConsumer()` constructs the production
  `ConsumerStateTable` transport at `orchagent/orch.cpp:1219`; the reproduction
  uses that same concrete transport rather than a fake observer.
  `L2NhgOrch::doTask()` dispatches this table at
  `orchagent/l2nhgorch.cpp:833-846`; its create path ultimately builds SAI L2
  next-hop and next-hop-group objects (`orchagent/l2nhgorch.cpp:48-87` and
  `orchagent/l2nhgorch.cpp:172-245`). An absent APP entry gives it no work from
  which to create those objects.
- `FdbOrch` is a second concrete consumer of the result. When a
  `VXLAN_FDB_TABLE` MAC references the missing group, it tests
  `gL2NhgOrch->hasActiveL2Nhg()` at `orchagent/fdborch.cpp:1232-1239`. The false
  result logs that the group is not known/active and leaves the MAC task
  pending instead of programming it. Since the discarded NHG produces no later
  APP event, this guard cannot become true in an otherwise quiescent system.

### Safeguards / possible masks to prove in Phase 2

- NVO gating itself prevents irrelevant NHGs from reaching APP_DB, but it is
  the early-return mechanism under investigation, not a later repair.
- The live netlink multicast subscription can repair the entry only if the
  kernel/FRR later changes or resends that same NHG. No code-level periodic
  resend or dump was found.
- `processCfgEvpnNvo()` replays local MACs only; it does not touch NHGs.
- `AppRestartAssist` cannot replay or reconcile the L2 NHG table because that
  table was not registered.
- The HLD says full warm reboot is outside the current design, which limits the
  warm-reboot promise; the audited path is also reachable on an ordinary
  fdbsyncd process crash/restart, for which the explicit startup dump exists.

### Concrete trigger scenario

1. Configure EVPN NVO and establish an EVPN-MH remote ES so zebra installs a
   valid kernel L2/FDB nexthop object.
2. Stop/crash fdbsyncd while leaving zebra and the kernel running.
3. Add or retain a valid kernel L2/FDB NHG while fdbsyncd is down.
4. Restart fdbsyncd while the CONFIG_DB NVO notification has not yet been
   processed.
5. The one-shot startup `RTM_GETNEXTHOP` dump delivers the existing record while
   the NVO flag is false, so `onMsgNhg()` discards it.
6. Process the legitimate NVO SET and allow startup/reconciliation to settle
   without modifying the kernel NHG.
7. Observe the kernel NHG remains present while APP_DB has no corresponding
   `L2_NEXTHOP_GROUP_TABLE` row; L2NhgOrch cannot construct the SAI object, and
   an FDB task referring to that group remains pending.

## Step 2 — developer-knowledge evidence

- `git blame` attributes the NHG table, startup nexthop subscription/dump, NVO
  early return, table writes, and ignore-without-NVO test to commit
  `f0c53b94514d3d99f44bef4267226dbb0a4f44c3`, merged as upstream PR
  [#4615](https://github.com/sonic-net/sonic-swss/pull/4615) on 2026-06-05.
- PR #4615 describes the change as wiring EVPN-MH into fdbsyncd and the data
  plane. Its review discussion explicitly says deletion of EVPN NVO clears L2
  NHG state, but neither that discussion nor the implementation describes a
  readiness-time replay. The tests assert both the gated drop and the successful
  ready-first case, but do not assert the drop-then-ready startup order.
- The upstream EVPN-MH HLD states at section 3.3.5 that fdbsyncd changes are
  required for “Handling of L2-NHG netlink notifications and dump from kernel”
  and “Programming of L2_NEXTHOP_GROUP_TABLE APP-DB entries based on kernel
  L2-NHG events.” It identifies fdbsyncd as producer and L2NhgOrch as consumer in
  the table schema section. This is direct evidence that a valid dump record is
  meant to reconstruct APP state.
- The same HLD, section 7, says warm reboot is not currently part of the design
  and specifically lists future L2-NHG reconciliation work. This is a scope
  caveat for full-system warm reboot, but the current code still implements an
  ordinary process-startup NHG dump and the trigger does not require BGP GR or a
  full warm reboot.
- No nearby TODO/FIXME, document statement, commit message, or test was found
  saying that permanently losing a valid startup dump record is intended or
  that a downstream component guarantees a resend after NVO readiness.

## Step 3 — known-status / precedent evidence

Issue-tracker and PR searches were run on 2026-08-01, including closed and
recently merged work:

- The repair-round-2 freshness recheck queried GitHub's issue/PR index for
  exact `RTM_GETNEXTHOP` and `L2_NEXTHOP_GROUP_TABLE` references,
  `fdbsyncd restart nexthop`, and every closed fdbsyncd PR updated since
  2026-06-01. Results remained limited to feature/precursor PRs #3226, #4039,
  #4262, #4538, and #4615, plus unrelated idempotent-delete fix #4674; none
  reports or fixes the dump-before-readiness/no-replay mechanism. A live
  `git ls-remote origin refs/heads/master` still resolved to
  `4f3dda156e52ed7647b1dbf900d54d87efaea455`.

- Exact repository searches for `"L2_NEXTHOP_GROUP_TABLE"`,
  `"RTM_GETNEXTHOP"`, `onMsgNhg`, fdbsyncd + nexthop-group + restart, and
  issue-only fdbsyncd + nexthop found feature PRs
  [#4262](https://github.com/sonic-net/sonic-swss/pull/4262),
  [#4615](https://github.com/sonic-net/sonic-swss/pull/4615), the open precursor
  [#3226](https://github.com/sonic-net/sonic-swss/pull/3226), and rebase PR
  [#4538](https://github.com/sonic-net/sonic-swss/pull/4538), but no filed issue
  or PR reporting this startup-drop / no-replay mechanism.
- A recent-closed-PR search for `fdbsyncd`, updated since 2026-06-01, returned
  #4262, [#4674](https://github.com/sonic-net/sonic-swss/pull/4674),
  [#4039](https://github.com/sonic-net/sonic-swss/pull/4039), and #4615.
  #4674 fixes duplicate VXLAN-FDB delete logging; the other three are feature
  development/precursor PRs. None reports or fixes MC-7's ordering mechanism.
- Organization-wide exact searches for `RTM_GETNEXTHOP` + restart and
  `L2_NEXTHOP_GROUP_TABLE` + warm restart returned no issue or PR.
- Review and issue comments on #4615, #4262, #4039, #4538, and #3226 were
  searched for restart/warm/NHG/NVO/dump/fdbsyncd discussion. They contain
  general warm-order concerns and other defects, but no report of the one-shot
  dump being discarded before NVO readiness.
- Live `origin/master` and the checkout both resolve to
  `4f3dda156e52ed7647b1dbf900d54d87efaea455` (2026-08-01); repository searches
  still show the single startup dump and no readiness replay at that tip.

Known-status evidence therefore records **Novelty: NEW**: the searches found no
prior report for this mechanism at this site. The feature PR that introduced
the code is developer knowledge/history, not a filed report of this defect.

# MC-5 investigation

## Scope and source evidence

- Finding: `MC-5`, "fpmsyncd publishes RECONCILED before route output is flushed".
- Source classification evidence: `spec/output/MC_hunt_scenario6_bfs.out` is a real TLC run, not a no-violation/code-review scenario. It reports `Invariant ReconciledImpliesOutputsPublished is violated` at line 35.
- The relevant trace transition is state 6, `MCFpmSyncdWarmRestartTimerExpired` (output lines 417-492), followed by state 7, `MCNextCompletion` (lines 493-568). State 7 has `derivedOutputs = {route_1, route_2}`, `outputBuffered = {route_1, route_2}`, `outputPublished = {}`, and `terminal(fpmsyncd_component) = "reconciled"`.
- Pinned revisions: build-image `d5a2f4d1df9fdf71e48777905cd3f032b3d78a94`; sonic-swss `b20a59691baca9ff6e4fbe46a7cd8223a3419117`; sonic-swss-common `c544c90acc862dddacdb454a2ad8d5eb1a68e105`.

## Step 1: code audit

### Relevant code and exact ordering

1. `src/sonic-swss/fpmsyncd/fpmsyncd.cpp:87-88` creates one `RedisPipeline` with `ROUTE_SYNC_PPL_SIZE` (50,000) and gives it to `RouteSync`.
2. `src/sonic-swss/fpmsyncd/routesync.cpp:169-182` constructs the non-ZMQ `ROUTE_TABLE` producer on that pipeline with `buffered=true` and gives the same producer and pipeline to `WarmStartHelper`.
3. During warm restart, legitimate FPM route updates are retained in the helper refresh map rather than sent to APPL_DB: `RouteSync::setRouteWithWarmRestart()` at `routesync.cpp:191-207` and `RouteSync::delWithWarmRestart()` at `routesync.cpp:217-224`.
4. The normal main loop starts restoration and its timer at `fpmsyncd.cpp:154-181`. Timer or EOIU-hold expiry enters the one-shot completion branch at `fpmsyncd.cpp:203-220` and calls `sync.onWarmStartEnd(applStateDb)` at line 214.
5. `RouteSync::onWarmStartEnd()` calls `m_warmStartHelper.reconcile()` at `routesync.cpp:3768-3781`.
6. `WarmStartHelper::reconcile()` generates all route-diff shapes through the buffered producer: stale delete at `warmRestartHelper.cpp:170-176`, explicit delete at lines 183-189, changed-route set at lines 195-206, and new-route set at lines 223-247.
7. In swss-common, buffered `ProducerStateTable::set()` and `del()` only append commands to the Redis pipeline (`common/producerstatetable.cpp:129-167` and `:170-200`); their conditional flush is skipped when `m_buffered` is true. `RedisPipeline::mayflush()` flushes automatically only at its capacity (`common/redispipeline.h:218-222`). Thus a small reconciliation remains pending.
8. After queuing those diffs, `WarmStartHelper::reconcile()` calls `setState(WarmStart::RECONCILED)` at `warmRestartHelper.cpp:250-259`. `setState()` delegates to `WarmStart::setWarmStartState()` (`warmRestartHelper.cpp:30-36`), whose separate STATE_DB `Table::hset` is synchronous at `sonic-swss-common/common/warm_restart.cpp:223-234`.
9. Control then returns through `RouteSync::onWarmStartEnd()`. Only after removing the timer does the caller execute `pipeline.flush()` at `fpmsyncd.cpp:216-219`. `RedisPipeline::flush()` consumes all pending replies and publishes at `sonic-swss-common/common/redispipeline.h:139-154`.

This code path matches the counterexample ordering for a reconciliation smaller than 50,000 queued commands: route diffs are buffered, STATE_DB becomes `reconciled`, and the APPL_DB route commands are executed by the explicit caller flush afterward.

### Reachability and concrete trigger

The precondition is reachable through the normal interfaces:

1. Enable system or BGP warm restart and retain at least one old `ROUTE_TABLE` entry.
2. Start `fpmsyncd`; `WarmStartHelper::checkAndStart()` and `runRestoration()` load the old APPL_DB content and enter `RESTORED` (`warmRestartHelper.cpp:49-75`, `:102-134`).
3. Zebra sends legitimate FPM `RTM_NEWROUTE`/`RTM_DELROUTE` messages while warm restart is in progress. The registered handlers at `fpmsyncd.cpp:97-100` reach `setRouteWithWarmRestart()` / `delWithWarmRestart()` and populate `m_refreshMap` without publishing the routes.
4. The warm-restart or EOIU-hold timer expires. This is counterexample state 6 / action `MCFpmSyncdWarmRestartTimerExpired`.
5. Reconciliation computes stale deletes, changed-route updates, and new-route adds. For a small diff the commands remain in the Redis pipeline while `RECONCILED` is synchronously visible; this is counterexample state 7 / action `MCNextCompletion`.
6. The next in-process statement performs the explicit pipeline flush.

### Real consumers and safeguards found

- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:16-21` lists BGP's `bgp` component. `get_component_state()` reads `WARM_RESTART_TABLE|bgp` at line 141, and `check_list()` treats `reconciled` as complete at lines 145-155. `wait_for_components_to_reconcile()` polls that state at lines 237-259; after all component waits, the script disables warm restart and saves the database at lines 299-310. This is a real external observer of the terminal value.
- The derived route-output consumer is orchagent's `RouteOrch`: `orchdaemon.cpp:361-372` attaches it to `APP_ROUTE_TABLE_NAME`, and `routeorch.cpp:603-643` consumes and programs route SET/DEL work.
- Safeguard 1: `RedisPipeline::mayflush()` auto-flushes if reconciliation fills the 50,000-command pipeline (`redispipeline.h:218-222`), so the cited ordering requires a smaller diff.
- Safeguard 2: the timer branch unconditionally calls `pipeline.flush()` immediately after `onWarmStartEnd()` and timer removal (`fpmsyncd.cpp:214-219`). This is downstream of the early state publication and must be tested rather than assumed.
- Safeguard 3: a pipeline owned by the exiting thread also attempts a destructor flush (`redispipeline.h:35-66`), though the ordinary long-running main loop relies on the explicit flush.

## Step 2: developer-knowledge evidence

- The originating routing warm-reboot PR, [sonic-swss PR #602](https://github.com/sonic-net/sonic-swss/pull/602), was merged on 2018-11-10. Its manual plan explicitly expects added, changed, and withdrawn routes not to reach AppDB until reconciliation and reports those cases passed. It does not test or discuss whether `RECONCILED` becomes externally visible before the reconciliation output is flushed.
- The swss-common warm-restart unit test states at `sonic-swss-common/tests/warm_restart_ut.cpp:85-91`: "Usually application will sync up with latest external env as to data state, after that it should set the state to RECONCILED for the observation of external tools." This documents that the state is meant for external observation after data synchronization.
- [sonic-swss PR #3241](https://github.com/sonic-net/sonic-swss/pull/3241), merged 2024-11-27, deliberately increased the route pipeline and delayed ordinary flushes to batch APP_DB traffic. Its change retained the unconditional `pipeline.flush()` in the warm-reconciliation timer branch.
- [sonic-swss-common PR #895](https://github.com/sonic-net/sonic-swss-common/pull/895), merged 2024-11-18, documents that buffered pipeline commands/publication are completed on flush. The fpmsyncd route producer uses buffered Redis output; its constructor currently uses the default per-command publication script, but the Redis command itself is still pending until the pipeline is flushed.
- `git blame` attributes the reconciliation state write and the immediate caller flush to the original warm-reboot commit `f3806851470dab266fa5eaf0b1361e0686a3e569` (PR #602). No nearby TODO/FIXME or test asserts the pre-flush terminal ordering as intended.
- The current swss-common unit test only asserts the route contents after `reconcile()` using a non-buffered test producer (`tests/mock_tests/warmrestarthelper_ut.cpp:20-24,90-104`), so it does not cover fpmsyncd's buffered producer configuration.

## Step 3: known-status and precedent search

Searches were run on 2026-08-01 against open and closed GitHub issues/PRs, followed by a fetch of both upstream `master` branches. Queries included:

- `repo:sonic-net/sonic-swss fpmsyncd reconciled flush`
- `repo:sonic-net/sonic-swss WarmStartHelper pipeline`
- `repo:sonic-net/sonic-swss "warm restart" pipeline`
- `repo:sonic-net/sonic-swss is:pr fpmsyncd flush`
- `repo:sonic-net/sonic-swss is:pr fpmsyncd RECONCILED`
- `repo:sonic-net/sonic-swss is:issue fpmsyncd "warm reboot"`
- `repo:sonic-net/sonic-buildimage is:issue fpmsyncd "warm reboot" route`
- `repo:sonic-net/sonic-mgmt is:pr fpmsyncd "warm reboot"`
- `repo:sonic-net/sonic-swss is:pr merged:>=2026-06-01 fpmsyncd`
- equivalent `sonic-swss-common` searches for `reconciled pipeline flush`.

The closest results were the feature PRs #602, #3241, and swss-common #895 above. [sonic-swss issue #4579](https://github.com/sonic-net/sonic-swss/issues/4579), moved to [sonic-buildimage issue #27412](https://github.com/sonic-net/sonic-buildimage/issues/27412), reports a different mechanism: the reconciliation timer expiring before BGP convergence and deleting still-valid routes. It does not report terminal-state publication before buffered route flush.

Recently merged/closed fpmsyncd results (including PRs #4803, #4680, #4630, #4333, #4615, #4657, #4668, #4645, and #4437) do not change or report this ordering. After fetching, `sonic-swss` upstream `master` was `4f3dda156e52ed7647b1dbf900d54d87efaea455`; it still calls `onWarmStartEnd()` and then `pipeline.flush()` in that order (current upstream `fpmsyncd.cpp:211-216`). The only diff from the pinned checkout in the affected main file was unrelated dynamic FIB-suppression subscription removal.

Known-status evidence: **Novelty: NEW**. No searched upstream issue, merged/closed PR, or current history entry reports this same mechanism at this same fpmsyncd/WarmStartHelper site.

No Phase-1 verdict is made here; the explicit flush and external observation must be exercised in Phase 2.

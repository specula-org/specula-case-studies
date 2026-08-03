# Investigation: MC-2 (repair continuation)

## Counterexample provenance

- The repair-round-2 artifact is `spec/output/repair_RR003_MC_hunt_mc2_stale_age_bfs.out`. It is a completed breadth-first TLC run and reports `Invariant StaleEventCannotDeleteNewer is violated`, 13,970 generated states, 4,552 distinct states, depth 13, and completion in three seconds.
- State 2 creates generation-1 LEARN `ev1`; State 3 creates generation-1 AGE `ev2`; State 4 creates same-key, same-destination generation-2 LEARN `ev3`. State 4's pending set contains all three events.
- States 5-8 select and commit `ev3`, leaving the generation-1 AGE pending. At State 8, ASIC, kernel, cache, `STATE_DB`, and observer are present at generation 2 on `p1`.
- States 9-11 then handle delayed `ev2`. State 9 records an AGE transaction with `eventGen=1` and `oldGen=2`; State 11 records `lastDeletion=[eventGen |-> 1, removedGen |-> 2, cause |-> "aged"]`. Cache and `STATE_DB` are absent while ASIC and kernel remain at generation 2.
- This supersedes the round-1 artifact reference and corrects the old event-id shorthand. The exact handler order is generation-2 LEARN followed by generation-1 AGE; generation-1 LEARN `ev1` remains pending.

## Production path and reachability

- The ASIC notification consumer uses `LruDedup` at `orchagent/fdborch.cpp:80-85`. `FdbOrch::doTask(NotificationConsumer&)` deserializes ordinary `fdb_event` payloads and calls public `FdbOrch::update()` at `orchagent/fdborch.cpp:1480`; that handler begins at line 371.
- The SAI ABI's `sai_fdb_event_notification_data_t` contains event type, FDB key, and attributes only (`saifdb.h:328-346`). `FdbData` stores bridge port/type/origin/destination metadata but no generation, event token, or incarnation (`orchagent/fdborch.h:71-94`).
- At the admissible State-4 handler boundary, both payloads are normal SAI notifications for the same MAC/BV/bridge port. The Level-2 test delivers generation-2 LEARN and then generation-1 AGE through public `FdbOrch::update()`; it neither prepopulates `m_entries` nor changes product logic.
- The current AGE branch assumes the notified entry has already left SAI/ASIC (`orchagent/fdborch.cpp:637-638`), then resolves the key to the mutable current cache row at line 640. Its only stale test compares bridge-port IDs at line 652, so it cannot distinguish same-port incarnations. Even for different ports the line-661 comment deliberately continues deletion. These are the conformance-instrumented equivalents of the finding's baseline lines 609-630.
- The dynamic local AGE path sets `update.add=false` at line 797 and calls `storeFdbEntryState()` at line 813. That helper erases the current `m_entries` row at line 212 and deletes `STATE_DB:FDB_TABLE` at line 231. The AGE branch makes no SAI `remove_fdb_entry` call.
- The conformance instrumentation currently present in the worktree adds only `#ifdef FDB_TLA_TRACE` observations around these operations. It adds no incarnation guard and does not change the deletion path.
- Correction to prior shorthand: the C++ cache has no literal "generation-2 field." In the current exact reproduction, generation-2 LEARN is the event that creates the row. In the alternative already-learned sequence, a same-port LEARN breaks as a duplicate at lines 555-557, leaving one unversioned row to represent the current hardware incarnation. The defect is deletion of that current logical row, not mutation of a stored generation number.

## Safeguards, consumers, and persistence

- `LruDedup` does not supply an incarnation check. The source comment states that LEARN and AGE are distinct byte strings and queue separately (`orchagent/fdborch.cpp:55-76`); a late AGE is therefore admitted rather than collapsed with the LEARN.
- Static, MCLAG-advertised, VXLAN-advertised, and EVPN-MH control-learn entries have separate returns, but the counterexample and executable test use the ordinary dynamic local path, so those guards do not fire.
- The real consumer `MuxOrch::getMuxPort()` calls `gFdbOrch->getPort()` at `orchagent/muxorch.cpp:1938`. The executable invoked this real method: it returned `Ethernet0` before delayed AGE and completed with an empty port afterward.
- `fdbsyncd` consumes `STATE_DB` updates at `fdbsyncd/fdbsyncd.cpp:105-107`. A DEL becomes `FDB_OPER_DEL` at `fdbsyncd/fdbsync.cpp:186-193`; if its row is cached, `updateLocalMac()` erases that cache at lines 395-400 and, with EVPN NVO configured, issues `bridge fdb del ...` at lines 419-424.
- The kernel refresh path cannot restore the row after that deletion: `macRefreshStateDB()` only replaces the kernel MAC when `m_fdb_mac` still contains the key (`fdbsyncd/fdbsync.cpp:597-641`). Startup/warm-restart performs dumps, but no steady-state timer or ASIC-to-`m_entries` reconciliation was found. Recovery therefore requires an independent later LEARN or restart replay; no current safeguard automatically resolves the wrong Mux lookup.

## Developer intent and existing tests

- The AGE comment at `orchagent/fdborch.cpp:637-638` states the intended contract: SAI/ASIC has already removed the notified entry, so only software is cleaned. The stale-port branch deliberately continues to bring SONiC and SAI into sync (`orchagent/fdborch.cpp:652-662`). That intent assumes the notification still denotes the current ASIC incarnation.
- Merged PR [#4586](https://github.com/sonic-net/sonic-swss/pull/4586) installs LRU deduplication for the FDB notification consumer. The adjacent code comment calls identical AGE payloads end-state-idempotent, but neither the queue nor `FdbData` adds incarnation information across an intervening re-learn.
- Existing `AgeNotificationStaleBridgePort` covers a different-port event and expects deletion. Existing `MacAgingAndRelearning` covers AGE followed by LEARN. Neither covers an old same-port AGE delivered after the newer LEARN.
- `git blame` attributes the key lookup/stale-port/deletion policy to the original 2021 EVPN/VXLAN implementation; the explanatory AGE comment was added by 2026 EVPN-MH PR #4615. No commit in current history adds a same-port incarnation check.

## Known-status / precedent search

- On 2026-08-01, GitHub's issue/PR tracker was re-searched across open and closed results for `FDB aged`, `FdbOrch stale`, `FDB relearn`, and all FDB PRs updated since 2026-05-01. Local history/blame was rechecked at the current handler site.
- Open PR [#4458](https://github.com/sonic-net/sonic-swss/pull/4458) handles an *unresolvable bridge-port ID* after a LAG transition. Open PR [#2623](https://github.com/sonic-net/sonic-swss/pull/2623) treats AGED as FLUSH after the bridge port was deleted. Neither concerns an older same-port AGE after re-learn.
- Merged PR [#4586](https://github.com/sonic-net/sonic-swss/pull/4586) adds byte-identical notification deduplication. Merged PR [#4674](https://github.com/sonic-net/sonic-swss/pull/4674) makes a downstream VXLAN-cache duplicate delete idempotent. Open PRs [#4533](https://github.com/sonic-net/sonic-swss/pull/4533), [#4604](https://github.com/sonic-net/sonic-swss/pull/4604), and [#4806](https://github.com/sonic-net/sonic-swss/pull/4806) change FDB notification transport/dedup/draining for storm pressure or ZMQ latency; none reports the older same-port AGE deleting the current incarnation. Recently merged FDB work also includes #4739, #4734, #4619, #4615, #4602, and #4507; none reports or fixes this mechanism at `FdbOrch::update()`.
- The tracker search returned no issue or PR describing an old same-port AGE deleting the current newer logical incarnation at this site. Known-status evidence is therefore `NEW`.

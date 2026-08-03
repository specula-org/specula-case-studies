# MC-1 investigation

## Scope and source

- Source revision: `4f3dda156e52ed7647b1dbf900d54d87efaea455`; a fresh `git fetch origin master` on 2026-08-01 resolved `origin/master` to the same revision.
- The supplied TLC output is a real violation: `spec/output/MC_hunt_mc1_stale_flush_final_bfs.out:36-38` reports `Invariant FlushAckMatchesRequest is violated` and begins a 15-state counterexample.
- The checkout already contained observational `FDB_TLA_TRACE` changes and corresponding mock-test build wiring. The same changes and SHA exist in `/users/Pial/targets/sonic-swss-fdb`; they add trace calls under a compile-time guard and do not change the flush decisions audited below.

## Step 1 — code audit

### Relevant implementation

- `orchagent/fdborch.h:71-94`: each cached `FdbData` has one `bool is_flush_pending`, defaulting to false. There is no request/epoch identity in the cache record.
- `orchagent/fdborch.cpp:1499-1575`: `flushFDBEntries()` constructs the SAI scope, calls `sai_fdb_api->flush_fdb_entries()`, and, on success, sets `is_flush_pending = true` for every cached entry matching that scope (`:1561-1570`). Repeating a successful request writes `true` again.
- `orchagent/fdborch.cpp:1457-1484`: normal ASIC_DB `fdb_event` notifications are deserialized and passed to public `FdbOrch::update()`.
- `orchagent/fdborch.cpp:965-982`: a `SAI_FDB_EVENT_FLUSHED` reaches `handleSyncdFlushNotif()`.
- `orchagent/fdborch.cpp:295-369`: the handler matches the callback's entry type, MAC/consolidated zero MAC, bridge port and/or BV scope, and the boolean pending flag. It has no request identity to compare.
- `orchagent/fdborch.cpp:242-290`: a match calls `clearFdbEntry()`, which removes the cache and STATE_DB record, decrements VLAN/port and CRM counters, and emits `SUBJECT_TYPE_FDB_CHANGE` with `add=false`.

### Normal entry points and call chain

1. `FdbOrch` registers the APPL_DB `FLUSHFDBREQUEST` notification consumer for `ALL`, `PORT`, `VLAN`, and `PORTVLAN` (`orchagent/fdborch.cpp:37-57`).
2. Its normal notification task accepts each request and either invokes SAI directly for `ALL` or calls `flushFDBEntries()` for the scoped forms (`orchagent/fdborch.cpp:1332-1455`). Two queued requests are processed serially by orchagent, but the first SAI callback may remain queued until after both calls return.
3. Normal topology operations also reach the same helper: port-down (`orchagent/fdborch.cpp:1796-1831`), VLAN-member removal (`:1833-1843`), and the documented bridge-port-removal path (`:1488-1498`). Thus overlapping outstanding callbacks do not require an illegal internal state.
4. syncd/SAI publishes `fdb_event` to ASIC_DB; `doTask(NotificationConsumer&)` deserializes it, `update()` recognizes `FLUSHED`, and `handleSyncdFlushNotif()` performs the cleanup (`orchagent/fdborch.cpp:1457-1484`, `:965-982`, `:295-369`).

### Counterexample mapping

- State 8, `MCFdbOrchFlushFDBEntriesRequest`, is the first request (`counterexample:1027-1169`). The trace still has a cache/STATE_DB generation-1 record while the model's ASIC contains generation 2.
- State 9, `MCFlushReactive`, completes request 1: the ASIC becomes absent and `pendingEpoch[k1] = 1` (`:1170-1312`).
- State 10 issues request 2 while the ASIC is already absent (`:1313-1455`).
- State 11 completes request 2 successfully and changes only the logical marker to epoch 2; the ASIC remains absent (`:1456-1598`).
- State 12 creates the delayed request-1 callback, with `epoch |-> 1`, while `pendingEpoch[k1] = 2` (`:1599-1753`).
- State 13 starts its cleanup and explicitly records `ackEpoch |-> 1` and `markedEpoch |-> 2` (`:1754-1896`).
- State 15 removes the generation-1 software record and reports the same epoch mismatch in `lastFlushCleanup`; the ASIC remains absent (`:2040-2189`).

This action order maps to normal public operations. The key end-state fact is that request 1 has already removed the only ASIC entry in State 9; request 2 is an idempotent successful flush over an empty matching ASIC set. The old callback's State-15 removal makes cache and STATE_DB agree with that absent ASIC state. No new entry incarnation is created between the two flush calls in this counterexample.

### Consumers and safeguards

- The request/callback path checks type, MAC, scope, and pending membership (`orchagent/fdborch.cpp:303-367`). The SAI notification data carries entry identity plus type/scope attributes, but no request token or epoch (Open Compute SAI `inc/saifdb.h`, notification-data documentation and struct: https://github.com/opencomputeproject/SAI/blob/master/inc/saifdb.h#L251-L304).
- `MirrorOrch` is a real `SUBJECT_TYPE_FDB_CHANGE` consumer and deactivates a matching mirror session on a delete (`orchagent/mirrororch.cpp:1739-1790`). In the supplied trace that delete is consistent with the already-absent ASIC record.
- `MuxOrch` receives the same notification but intentionally ignores deletes caused by aging/flush and waits for neighbor updates (`orchagent/muxorch.cpp:1948-1957`, dispatch at `:2466-2477`).
- `NeighOrch` handles the separate `SUBJECT_TYPE_FDB_FLUSH_CHANGE` emitted at topology-trigger time, not the later cache cleanup (`orchagent/neighorch.cpp:255-310`; producer `orchagent/fdborch.cpp:1771-1793`).
- No source consumer reads an epoch (none exists), and no consumer was found that treats “callback 1 cleared a marker last written by request 2” as an outcome distinct from “the successfully flushed entry is absent.”
- A learn/re-add between SAI removal and callback is a separate incarnation race. The supplied trace has a queued generation-2 learn event, but request 1 has already removed that generation from ASIC before the callback; it does not process a post-flush re-incarnation before State 15.

## Step 2 — developer-knowledge evidence

- Merged PR [#2136](https://github.com/sonic-net/sonic-swss/pull/2136) introduced this flag. Its stated intent is: “Add a flag to FDB entry to ensure that only the requested FDB entries will be deleted on flush notification.” The merged patch implements membership as one boolean and its tests set that boolean before a callback; neither the prose nor tests promise per-request acknowledgement identity.
- The same PR documents the actual three-stage concern as an FDB add occurring between SAI flush and orchagent callback. A 2025 comment reports the converse stale-learn case where a new entry has `is_flush_pending=false` and therefore survives the old callback. That is an incarnation/learn race, not two successful flushes overwriting an epoch owner.
- Earlier open PR [#1470](https://github.com/sonic-net/sonic-swss/pull/1470) proposed a reference count to prevent FDB add/delete during a flush. Its discussion describes the same asynchronous three-stage pipeline and reviewer concerns about dynamic/static and consolidated callback counts. It does not report two overlapping successful flush requests or an old callback consuming a newer request marker; the later merged design was the boolean in #2136.
- Commit `8dae35645962b0ce8b9b4ddc80d64162b51b5f65` is the merged #2136 patch. `git blame` attributes the pending checks and writes to that commit; later refactors preserve the boolean semantics.
- Existing `tests/mock_tests/fdborch/flush_syncd_notif_ut.cpp` exercises individual consolidated/non-consolidated callbacks and manually marks entries pending. It has no overlapping-request/old-first-callback test. The current SAI API documentation defines flush as removing all matching entries and defines callback payload scope/type, with no request ID.

## Step 3 — known-status and precedent search

- Tracker searches covered open/closed issues and open/closed/merged PRs for `is_flush_pending`, `fdb flush notification`, `fdb flush pending`, `fdb flush race`, `fdb stale flush`, `SAI_FDB_EVENT_FLUSHED`, `two flush`, `second flush`, `multiple flush`, and `overlapping flush`.
- Recently merged/closed results were rechecked, including #4734, #4615, #4527, #2401, #2254, and #2136. `origin/master` was also fetched and searched through 2026-08-01.
- #1470/#2136 are same-site asynchronous-flush precedents, but they report add/learn during a pending callback, not this finding's two-successful-flush epoch mismatch. No issue or PR was found reporting the exact overlapping-request mechanism asserted by MC-1.
- Novelty evidence: `NEW` for this exact mechanism at this site.

## Phase-1 reachability record

Concrete sequence: learn one dynamic FDB entry through a normal SAI event; send two valid matching `FLUSHFDBREQUEST` operations before consuming callbacks; let both SAI calls return success (the first removes the entry, the second finds no matching hardware entry); then deliver the legitimate callback created by request 1 before any callback for request 2. This reaches the boolean rewrite and old-first cleanup without private-function calls, timing-only source changes, or an inadmissible peer message.

## Repair round 1 continuation — post-flush relearn

### Correction to the earlier trace analysis

The earlier statements that no new entry incarnation exists before cleanup and that the old callback leaves all stores aligned apply only to the pre-repair overlapping-request counterexample. They do **not** describe `spec/output/repair_final_RR001_mc1_bfs.out`. The repaired invariant exposes a distinct, reachable sequence with a real post-flush generation 2, so those statements are superseded for the current finding:

- State 7 requests a dynamic flush over generation 1 (`repair_final_RR001_mc1_bfs.out:950-969`).
- State 8 completes the successful SAI flush: ASIC generation 1 is absent and the cached key has pending epoch 1 (`:1101-1113`).
- State 9 is an admissible `MCSaiLearnEvent(k1,p1,ev1)` that creates ASIC/kernel generation 2 on the same key and port while the software record and pending marker still describe generation 1 (`:1252-1265`, `:1313-1319`, `:1356-1368`).
- Event handling makes the current software incarnation generation 2 without removing the marker; by State 13 ASIC, cache, kernel, observer, and STATE_DB all hold generation 2 while `pendingEpoch[k1] = 1` (`:1862-1875`, `:1898-1903`, `:1960-1972`, `:2005-2010`).
- State 14 creates the delayed epoch-1 callback from the original generation-1 snapshot (`:2013-2057`). State 17 records `ackGen = 1` deleting `removedGen = 2`; ASIC/kernel retain generation 2 while cache and STATE_DB are absent (`:2478-2497`, `:2538-2539`, `:2576-2588`, `:2613-2626`).

### Current code audit and reachability

- The only per-key flush ownership state remains `bool is_flush_pending` (`orchagent/fdborch.h:71-94`). A successful scoped SAI flush sets it on every matching cached entry (`orchagent/fdborch.cpp:1499-1575`, specifically `:1561-1569`).
- A normal `SAI_FDB_EVENT_LEARNED` reaches `FdbOrch::update()` through the ASIC_DB `fdb_event` consumer (`orchagent/fdborch.cpp:1457-1484`, then `:371-422`). For an already-cached learned entry on the same bridge port, the current duplicate path returns/breaks without constructing a fresh `FdbData`; in particular it does not clear `is_flush_pending` (`:451-569`). Thus a hardware relearn after the SAI flush naturally leaves the old boolean attached to the only software record for that key.
- A later valid `SAI_FDB_EVENT_FLUSHED` reaches `handleSyncdFlushNotif()` (`orchagent/fdborch.cpp:965-980`). The handler checks only callback scope, entry type, MAC/zero-MAC, and the boolean (`:295-359`), then `clearFdbEntry()` erases the cache and STATE_DB record, decrements counters, and emits a delete (`:242-289`). It cannot distinguish the post-flush relearn because neither `FdbData` nor the SAI callback carries an incarnation/request token.
- The concrete normal sequence is: process a dynamic `LEARNED(k,p)` notification; process one matching public `FLUSHFDBREQUEST PORTVLAN`; let the successful SAI call remove that ASIC entry and leave its callback queued; receive traffic that causes SAI to learn the same key on the same port and deliver `LEARNED(k,p)`; then consume the older consolidated `FLUSHED` callback. All messages pass the ordinary notification consumers; no internal bug precondition is injected.

### Consequence and safeguards

- `MuxOrch::getMuxPort()` is a real caller of `FdbOrch::getPort()` (`orchagent/muxorch.cpp:1921-1945`). Before the callback it resolves the relearned key to `Ethernet0`; after the callback it returns an empty port even though the ASIC still contains the entry. Production call sites include neighbor/MUX resolution at `orchagent/muxorch.cpp:1862`, `:1897`, `:2129`, `:2231`, and `:2303`.
- `MirrorOrch` is also affected: it consults `FdbOrch::getPort()` while resolving VLAN mirror destinations (`orchagent/mirrororch.cpp:807-843`) and consumes the false delete notification by deactivating a matching session (`:1739-1790`).
- `MuxOrch::updateFdb()` intentionally ignores delete notifications caused by aging/flush (`orchagent/muxorch.cpp:1948-1957`), but that is not a mask for `getMuxPort()`; the latter still reads the now-empty FDB cache. The Level-0 reproduction invokes `getMuxPort()` again without delivering another event and obtains the same empty result.
- `FdbOrch` has no periodic FDB reconciliation timer: its only `SelectableTimer` dispatch is the unrelated MacMoveGuard recovery timer (`orchagent/fdborch.cpp:1315-1330`). Once the legitimate generation-2 `LEARNED` event has been consumed and the delayed callback deletes its software representation, no loopback/resend repairs it. A later independent age/move/relearn can change the state, but the divergence otherwise persists.

### Developer knowledge and novelty correction

- Merged PR [#2136](https://github.com/sonic-net/sonic-swss/pull/2136) reported this same three-stage site and mechanism: after the SAI flush call but before orchagent consumes the delayed flush notification, processing an FDB add can make ASIC_DB/sairedis and the orchagent cache inconsistent. Its stated intent was to ensure that only entries covered by the request are deleted. The boolean patch fixed fresh inserts whose new `FdbData` starts false, but it did not cover the same-key/same-port SAI duplicate path, which preserves the old record and true bit.
- A later comment on that PR ([issuecomment-3466008089](https://github.com/sonic-net/sonic-swss/pull/2136#issuecomment-3466008089)) reports the converse stale-learn ordering in SONiC 202505, confirming the asynchronous flush/learn window remains operational. It is related evidence, not the reproduced direction here.
- The earlier `Novelty: NEW` determination was for the now-repaired *two overlapping flush requests / epoch overwrite* mechanism. The current post-flush-add mechanism is already reported by #2136 at the same handler and flag, so current novelty is `KNOWN (cite: https://github.com/sonic-net/sonic-swss/pull/2136; fix-status: unfixed)`.
- The current tracker re-check covered open/closed issues and open/closed/merged PRs, including recently closed/merged #4527, #4603, and #4615 and open #4604. None repairs the sticky pending bit on a same-key/same-port relearn. Local `origin/master` and HEAD are both `4f3dda156e52ed7647b1dbf900d54d87efaea455`.

## Repair round 2 continuation

### Current counterexample and implementation match

- `spec/output/repair_RR003_MC_hunt_mc1_stale_flush_bfs.out:36` reports the same `FlushAckMatchesRequest` violation. State 7 requests a flush, State 8 completes it and sets `pendingEpoch[k1] = 1`, State 9 performs the admissible same-key/same-port `MCSaiLearnEvent`, and States 10-13 finish that generation-2 event while retaining the epoch-1 marker. State 17 records `lastDeletion = [eventGen |-> 1, removedGen |-> 2, cause |-> "flush"]` and `lastFlushCleanup = [ackGen |-> 1, removedGen |-> 2, ...]`; ASIC and kernel remain present at generation 2 while cache and STATE_DB are absent (`:2478-2626`).
- Current HEAD and `origin/master` remain `4f3dda156e52ed7647b1dbf900d54d87efaea455`. `FdbData` still has only `bool is_flush_pending` (`orchagent/fdborch.h:84`); a successful scoped flush still sets it (`orchagent/fdborch.cpp:1561-1569`); the same-port duplicate-LEARN path still breaks without replacing or clearing the cached flag (`:451-569`); and the delayed callback still checks only type, MAC, scope, and that flag before `clearFdbEntry()` (`:295-369`). No repaired-spec assumption changed this code mapping.
- The reachable Level-0 sequence remains: ordinary ASIC_DB `LEARNED(k,p)` notification; ordinary APPL_DB `FLUSHFDBREQUEST PORTVLAN`; successful SAI removal of generation 1 with its callback delayed; legitimate traffic-driven ASIC relearn and ASIC_DB `LEARNED(k,p)` for generation 2; then the queued consolidated `FLUSHED` notification. The round-2 reproduction sends these inputs through the production `NotificationConsumer` paths and injects no `FdbData` state.

### Consequence and mask audit

- The reproduction instantiates the production `MuxOrch` and calls `MuxOrch::getMuxPort()` (`orchagent/muxorch.cpp:1921-1945`). It resolves `Ethernet0` after the generation-2 relearn, then returns an empty port after the delayed callback despite the mock ASIC oracle remaining present. A second call returns empty again.
- `MuxOrch::updateFdb()` discards flush/aging delete notifications (`orchagent/muxorch.cpp:1948-1957`) and therefore does not repair the cache-backed query. `FdbOrch` has no FDB reconciliation timer; its only selectable-timer dispatch is the unrelated MacMoveGuard recovery timer (`orchagent/fdborch.cpp:1315-1330`). No loopback, resend, periodic dump, or caller guard was found that restores the consumed generation-2 event. A later independent FDB event can change the state, but absent one the divergence persists.

### Developer knowledge and known status re-check

- GitHub's open/closed issue-and-PR search was rerun on 2026-08-01 for `is_flush_pending`, `SAI_FDB_EVENT_FLUSHED`, `flush notification` with FDB, and `stale flush`, sorted by recent update. It included recent merged/closed FDB work such as #4527, #4615, #4619, #4734, and #4739. Local history confirms none removes the boolean-only ownership design; `git log -S is_flush_pending` still attributes its introduction to commit `8dae3564` (#2136), with later FDB changes retaining it.
- Merged PR [#2136](https://github.com/sonic-net/sonic-swss/pull/2136) expressly reports the same three-stage site: if FdbOrch processes an FDB add between the successful SAI flush and FdbOrch's delayed notification cleanup, ASIC_DB/sairedis and the FdbOrch cache can become inconsistent. It introduced this exact pending flag and callback guard. The same-key/same-port duplicate path is an unfixed case of that already-reported mechanism, so the current finding remains `KNOWN (cite: https://github.com/sonic-net/sonic-swss/pull/2136; fix-status: unfixed)`.
- The initial pre-repair `NEW` statement remains inapplicable to the current finding: it described only the repaired-away two-overlapping-flush epoch mismatch. Round 2 again confirms the post-flush-relearn mechanism and the prior correction to `KNOWN`.

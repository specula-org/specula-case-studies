# MC-5 investigation

## Scope and artifact provenance

- Source revision: `4f3dda156e52ed7647b1dbf900d54d87efaea455` in the supplied `worktree`.
- The checkout already contains uncommitted, conditional `FDB_TLA_TRACE` instrumentation plus one flush-failure trace test. Those changes are not part of MC-5's production behavior; the relevant production lines are unchanged from the cited commits.
- The supplied TLC output is a real counterexample: `UniqueEffectiveDestination` is violated after eight states. The transition sequence is `MCSaiLearnEvent(k1,p1,ev1)`, `MCSaiMoveEvent(k1,p1,ev2)`, four `MCEventHandlers` steps that finish `ev1`, then `MCNext` consumes `ev2` as a repair failure. Final state: `eventQueue = {}`, `fdbFailure[k1] = TRUE`, `fdbRetry[k1] = FALSE`, `fdbCompensated[k1] = FALSE`, ASIC/kernel generation 2, and cache/STATE_DB/observer generation 1. Both modeled generations have destination `p1`, bridge-port generation 1, and kind `dynamic`.

## Step 1 — code audit

### Entry path and cited sites

- `orchagent/notifications.cpp:16-25` serializes a real SAI FDB callback onto ASIC_DB's `NOTIFICATIONS` channel in ZMQ southbound mode.
- `orchagent/fdborch.cpp:59-91` installs the real `NotificationConsumer`/`Notifier` for `fdb_event` messages. Its LRU policy deduplicates only byte-identical payloads; the comment explicitly says distinct event types and ports remain distinct.
- `orchagent/fdborch.cpp:1332-1350` pops one notification payload. `orchagent/fdborch.cpp:1457-1483` deserializes each legitimate SAI event, obtains its bridge port/type attributes, and calls public notification handler `FdbOrch::update(...)` at line 1480.
- `orchagent/fdborch.cpp:371-413` resolves the notification's real bridge port and VLAN before entering the event switch. Missing real objects return before any MOVE handling.
- The cited MOVE repair loop is `orchagent/fdborch.cpp:869-904`. It is reachable only when the cache entry both (a) has `FDB_ORIGIN_MCLAG_ADVERTIZED` and (b) has a bridge-port ID different from the MOVE notification (`:870-873`). It attempts `ALLOW_MAC_MOVE=false`, `TYPE=DYNAMIC`, and the new `BRIDGE_PORT_ID` (`:882-897`). A failure is logged, with no retry/rollback, and iteration continues (`:897-902`).
- After that guarded block, the handler updates counters, calls `storeFdbEntryState(update)` without inspecting its Boolean return (`orchagent/fdborch.cpp:906-935`), and synchronously notifies observers (`:935`).
- `storeFdbEntryState` represents a local entry solely by bridge port, type, origin, destination type/value, ESI, and VNI. For an existing entry with the same bridge-port ID and a non-MCLAG origin, it explicitly logs `duplicate` and returns false (`orchagent/fdborch.cpp:146-168`). Otherwise it replaces `m_entries`, writes only `port` and `type` to `STATE_DB` (`:170-202`), and removes a prior MCLAG remote row when ownership becomes local (`:185-196`). There is no real `generation` field in `FdbData`, `FdbEntry`, or either state table.

### Exact counterexample reachability

The trace's exact normal sequence is reachable: a legitimate `LEARN` for a dynamic MAC on `p1`, followed by a legitimate `MOVE` notification for the same MAC and the same `p1`, with both notifications admitted before the first is handled. The notification queue preserves LEARN versus MOVE because their payload/event types differ.

After processing the LEARN, however, the cached entry has `FDB_ORIGIN_LEARN`. Therefore the later same-port MOVE cannot enter the MCLAG repair loop: the origin guard at `orchagent/fdborch.cpp:870` is false, and the different-port guard at `:872` is also false. The handler reaches `storeFdbEntryState`, whose same-port/non-MCLAG duplicate guard at `orchagent/fdborch.cpp:155-161` returns false. The caller ignores that return and still sends an add notification containing the same real port.

The real code therefore has no operation that can retain or expose a stale incarnation number in this sequence: no incarnation number is stored. The hardware event, cache, STATE_DB fields, and observer update all identify the same effective destination (`p1`) and dynamic type.

### Reachability of the cited MCLAG SAI-failure block

A separate normal sequence reaches `orchagent/fdborch.cpp:894-902`:

1. Publish `MCLAG_FDB_TABLE|Vlan40:<mac>` with `{port: p1, type: dynamic}`; `FdbOrch::doTask(Consumer&)` assigns `FDB_ORIGIN_MCLAG_ADVERTIZED` at `orchagent/fdborch.cpp:1093-1096` and calls `addFdbEntry` at `:1260`.
2. Hardware legitimately moves that MAC to a different bridge port `p2` and emits `SAI_FDB_EVENT_MOVE` for `p2`.
3. A SAI set failure can then occur in the three-attribute repair loop.

On that path, even if each set returns failure, the loop merely logs and continues. The subsequent `storeFdbEntryState` sees a different bridge port, replaces the MCLAG cache row with a local `FDB_ORIGIN_LEARN` row for `p2`, deletes the MCLAG STATE_DB row, writes local STATE_DB `port=p2,type=dynamic`, and notifies observers with `p2`. Thus the prerequisites for the SAI repair loop and the exact counterexample's same-port duplicate-store outcome are mutually exclusive in the implementation.

### Real consumers and safeguards recorded

- `FdbOrch::getPort` returns the bridge port from `m_entries` (`orchagent/fdborch.cpp:1014-1044`). Its real callers are `MuxOrch::getMuxPort` (`orchagent/muxorch.cpp:1921-1945`) and mirror-session resolution (`orchagent/mirrororch.cpp:807-840`). Neither API has or reads an FDB generation/incarnation.
- Observer delivery is synchronous (`orchagent/observer.h:55-60`). `MuxOrch::updateFdb` consumes `update.entry.port_name` (`orchagent/muxorch.cpp:1948-1992`), and `MirrorOrch::updateFdb` consumes `update.port.m_port_id` (`orchagent/mirrororch.cpp:1739-1791`). Both receive the MOVE notification's real port even when `storeFdbEntryState` returns false.
- The LRU queue can collapse byte-identical repeats before handling, but it does not merge LEARN with MOVE and is not needed to correct a same-destination outcome.
- No periodic generation reconciliation exists because the production cache/state schema contains no generation. Warm-start `bake()` refills from STATE_DB (`orchagent/fdborch.cpp:108-121`); it does not create an incarnation field.

## Step 2 — developer-knowledge evidence

- The code itself documents end-state idempotence: `orchagent/fdborch.cpp:68-72` says repeated identical LEARN/AGE payloads are no-ops and collapsing byte-identical duplicates preserves final `FDB_TABLE` state. Closed PR [#4603](https://github.com/sonic-net/sonic-swss/pull/4603) similarly says duplicate FDB events may be collapsed while preserving correctness; merged PR [#4586](https://github.com/sonic-net/sonic-swss/pull/4586) installed the LRU policy.
- Merged PR [#1331](https://github.com/sonic-net/sonic-swss/pull/1331) introduced the MCLAG remote/local ownership paths, including the same-port exception to the ordinary duplicate guard and the log-and-continue SAI set handling. It supplies no retry or compensation requirement.
- Merged PR [#2811](https://github.com/sonic-net/sonic-swss/pull/2811) added the cited MOVE repair loop. Its stated intent is to change a remotely learned MCLAG MAC's hardware type from static to dynamic and clear `allow_move` after a hardware MOVE. It does not describe a failure/retry policy.
- Merged PR [#2201](https://github.com/sonic-net/sonic-swss/pull/2201) documents the observable consumer contract: MOVE must fill `update.entry.port_name` because `MuxOrch::updateFdb` makes decisions from it. Current MOVE code sets that field at `orchagent/fdborch.cpp:907` before notifying.
- Existing mock tests exercise ordinary LEARN/MOVE and MCLAG MOVE paths, but the MCLAG setup tests at `tests/mock_tests/fdborch/fdborch_vxlan_ut.cpp:3621-3746` directly seed `m_entries` and do not assert failure ownership. `MclagFdbAddDelete` at `:4146-4187` demonstrates the real MCLAG table API sequence.

## Step 3 — known-status / precedent search

Known-status search covered open and closed issues, merged and closed PRs, exact log strings, `set_fdb_entry_attribute`, `SAI_FDB_EVENT_MOVE`, MCLAG MOVE, retry/failure terms, and all recently updated FDB/FdbOrch PRs through 2026-08-01.

- PR #2811 is the same code site but reports the older absence of the repair operation, not failure consumption after the operation exists.
- Issue [#2913](https://github.com/sonic-net/sonic-swss/issues/2913) contains a similar `macUpdate-Failed` log, but at `addFdbEntry`; `handleSaiSetStatus` exits orchagent after an asynchronous flush removed the object. Merged PR [#3524](https://github.com/sonic-net/sonic-swss/pull/3524) fixes that different flush-versus-ICCPD race by suppressing a flush on an MCLAG port.
- Recently merged/closed FDB PRs #4527, #4586/#4603, #4619, #4734, and #4739 concern batch type bleed, queue deduplication, ZMQ notification forwarding, flush type, and an EVPN neighbor-first race, respectively. None reports failure ownership at the cited MOVE loop or a stale same-port FDB incarnation.

Known status recorded from this search: **Novelty: NEW** (no upstream report found for this mechanism at this site).

## Repair round 1 continuation — remote AGE retry ownership

### Replacement counterexample and corrected premise

The round-1 Phase 3 run produced a different counterexample for `FailedWorkRetainsRetryIntent`: `spec/output/repair_final_MC_hunt_scenario_2_incarnation_bfs.out`. The earlier investigation remains the evidence for the superseded LEARN/MOVE incarnation trace; it does not establish reachability of this replacement trace.

The replacement trace performs `MCFdbOrchMclagAdvertise(k1,p1)` at output line 175, records `cacheOrigin = "mclag"` at line 245, but records the installed ASIC entry as `kind = "dynamic"` at lines 178-183. `MCSaiAgeEvent(k1,ev1)` then removes that current entry at lines 314-322. State 4 consumes the event after a modeled recreate failure while `fdbRetry = FALSE` and the queue is empty (lines 459-514), leaving cache and STATE_DB present while ASIC and kernel are absent (lines 529-595).

That first transition is not faithful to the implementation. A logical MCLAG row with `type=dynamic` is deliberately translated to `SAI_FDB_ENTRY_TYPE_STATIC` by `addFdbEntry` (`orchagent/fdborch.cpp` at HEAD lines 2035-2043), and `ALLOW_MAC_MOVE=true` is added at lines 2052-2058. The installed SAI header describes `SAI_SWITCH_ATTR_FDB_AGING_TIME` as the aging time for **dynamic** FDB entries (`saiswitch.h:1524-1533`) and makes `ALLOW_MAC_MOVE` valid only for a static entry (`saifdb.h:181-191`). Therefore a normal SAI aging transition cannot remove the current remote entry created by the preceding MCLAG API action. The supplied statement that SAI ages this current MCLAG-owned entry is corrected: the trace conflates the row's logical `dynamic` label with its hardware SAI type.

### Production behavior at the reported site

- A real SAI callback enters through `orchagent/notifications.cpp:16-25`, the `NotificationConsumer` configured at `orchagent/fdborch.cpp:59-91`, and `FdbOrch::doTask(NotificationConsumer&)` at `orchagent/fdborch.cpp:1332-1483` before `FdbOrch::update` handles AGE.
- If an AGE notification nevertheless targets a cached MCLAG/VXLAN-advertised row, HEAD lines 679-720 reconstruct a static entry with `ALLOW_MAC_MOVE=true`, call `create_fdb_entry` at line 713, only log an error at lines 714-719, and return unconditionally at line 720. The notification is one-shot and this path creates neither a Consumer task nor another retry owner.
- Ordinary `addFdbEntry` failures differ: `orchagent/fdborch.cpp:2197-2207` calls `handleSaiCreateStatus` and retains the Consumer work item when the task is retryable. No corresponding owner exists in the notification branch.
- A forced, trace-shaped AGE notification can therefore demonstrate the conditional dropped-recreate behavior, but only after injecting the unreachable premise that the current SAI-static MCLAG entry was aged out. A stale AGE notification arriving after a replacement remote entry exists does not supply that premise: the replacement remains in hardware, and a recreate is at most an already-exists operation.
- No periodic steady-state resend was found. Base `Orch::doTask` drains registered queues, and `bake()` only replays table state during restart. Thus the conditional state would persist if the impossible removal premise were admitted; this does not make the premise reachable.

### Real API ladder and observable consequence

The executable test `repro/test_bugMC-5_remote_age_retry.sh` drives `MCLAG_FDB_TABLE` through the normal table/Consumer API. Level 0 captures the actual SAI attributes and proves the row is installed as STATIC with `ALLOW_MAC_MOVE=true`. Level 1 adds timing and repeated orch drains; no AGE/recreate occurs. Level 2 is an explicit negative control matching trace step `MCSaiAgeEvent(k1,ev1)`: it marks the ASIC entry absent, injects the serialized event through the real notification queue, forces `SAI_STATUS_TABLE_FULL`, and confirms the conditional notification-consumption symptom. It labels this premise `admissible=false`. Level 3 is not used because no source patch may manufacture dynamic aging eligibility.

The real downstream cache consumer `MuxOrch::getMuxPort` (`orchagent/muxorch.cpp:1921-1945`, call to `FdbOrch::getPort` at line 1938) would observe the stale cached port only under the Level-2 premise. No real caller observes a wrong outcome after the admissible Level-0/1 sequence. The replacement counterexample is consequently a specification-repair case, not a reproduced production bug.

### Developer intent and refreshed known-status search

- The MCLAG HLD change in [SONiC PR #596](https://github.com/sonic-net/SONiC/pull/596) explicitly replaced remote dynamic aging/reinstallation with a static hardware representation plus MAC-move permission so remote MACs are not aged while hardware moves remain possible.
- [sonic-swss PR #1331](https://github.com/sonic-net/sonic-swss/pull/1331) introduced the MCLAG FDB ownership implementation containing this mapping and the defensive AGE branch.
- A refreshed search covered open/closed upstream issues, exact log text, and recently merged/closed FDB PRs through 2026-08-01. No report was found for the exact log-and-return failure mechanism at HEAD line 713. The closest records describe the original feature and unrelated FDB fixes, so novelty remains **NEW**.

Repair target: **SPEC_REPAIR**. The model must distinguish an advertised row's logical type from the installed SAI type (or track explicit aging eligibility), and `MCSaiAgeEvent` must not remove the current MCLAG/VXLAN static entry through ordinary dynamic aging.

### Executed reproduction result

`repro/test_bugMC-5_remote_age_retry.sh` executed against revision `4f3dda156e52ed7647b1dbf900d54d87efaea455` and exited 0. The single gtest passed in 202 ms. Its captured output is in `confirmation/MC-5/reproduction-output.txt`; the decisive records are:

- Level 0: `programmed_sai_type=STATIC allow_mac_move=true ... REMOTE_ENTRY_NOT_AGE_ELIGIBLE`.
- Level 1: two timing-assisted drains leave the notification depth and recreate count at zero (`NO_TRIGGER`).
- Level 2: exact `MCSaiAgeEvent(k1,ev1)` injection is labeled `admissible=false`; under that negative control, `SAI_STATUS_TABLE_FULL` consumes the notification with no pending tasks/retry owner while cache/STATE_DB remain and the test-held ASIC state is absent.
- Level 3: no source patch was used, because making the static current entry dynamic-age-eligible would change production logic.
- Final: `live_harm=NOT_REPRODUCED ... repair_target=SPEC_REPAIR`.

Final disposition for the replacement trace: **PENDING REPAIR**.

## Repair round 2 continuation — delayed LEARN overrides a newer MCLAG row

### Current counterexample and corrected evidence

RR-003's repair correctly removed the prior model artifact: an advertised
logical MCLAG `dynamic` row is now installed as SAI `static`, and ordinary
aging requires an age-eligible dynamic ASIC row.  The current counterexample
is independent of that repaired premise and violates
`UniqueEffectiveDestination` after nine states
(`spec/output/repair_RR003_MC_hunt_scenario_2_incarnation_bfs.out:35`).
The same result with `MaxRepairFailureLimit=0` is recorded in RR-003's
validation (`RR-003.md:44-47`), so repair-failure injection is not required.

- State 2 queues a valid generation-1 LEARN after installing the learned
  dynamic row (`:176-184`, `:231-237`).
- State 3 ages that row and retains both the generation-1 LEARN and AGE
  notifications (`:321-329`, `:376-389`).
- State 4 installs a newer generation-2 MCLAG row on the same destination as
  SAI static and records MCLAG cache ownership while both notifications remain
  queued (`:473-481`, `:528-556`).
- The remaining LEARN starts with old cache generation 2 but event generation
  1 (`:770-778`, `:840-852`), changes the current ASIC type to dynamic, and
  eventually changes cache ownership to `learn` (`:1048-1056`, `:1118-1130`).
  The final cache/observer generation is 1 while ASIC/kernel remain generation
  2 (`:1187-1222`, `:1257-1285`).

One ordering detail is corrected from the model trace when mapped to the real
consumer.  The model's event set consumes AGE before LEARN (`:625-701`), while
the production LRU-dedup notification queue keeps distinct LEARN and AGE
payloads in producer FIFO order.  The executable reproduction therefore uses
the real order LEARN then AGE.  The stale LEARN still performs the reported
takeover; the following queued AGE strengthens the live result by deleting the
now-local software row while leaving the newly rewritten hardware row in
place.  Thus the model's AGE-first suffix is not claimed as a production queue
ordering, but the current stale-LEARN mechanism is preserved and reproduced.

### Source audit for the current mechanism

At uninstrumented HEAD, `FdbOrch::update` looks up only the FDB key at
`orchagent/fdborch.cpp:439`; neither the notification nor `FdbData` carries an
incarnation that can be compared with the current row.  If that current row is
MCLAG-owned and has the same bridge port, lines 464-503 deliberately treat the
LEARN as a remote-to-local conversion.  The comment at lines 470-471 assumes
the notification describes the current hardware learn.  The branch writes
`SAI_FDB_ENTRY_TYPE_DYNAMIC` at lines 480-491 and unconditionally calls
`storeFdbEntryState` at line 500.

`storeFdbEntryState` then writes `FDB_ORIGIN_LEARN`
(`orchagent/fdborch.cpp:169-178`), deletes the prior MCLAG ownership row
(`:184-190`), and writes the local FDB row (`:191-195`).  There is no freshness
guard at any of these transitions.  This is the implementation of the
counterexample's generation-1 LEARN overwriting generation-2 ownership.

After that conversion, the queued AGE no longer enters the MCLAG/VXLAN
recreation guard at `orchagent/fdborch.cpp:679-720`, because the origin is now
LEARN.  It executes ordinary cleanup at lines 766-790.  That path does not call
`remove_fdb_entry`; it assumes the aged hardware incarnation is already gone.
Here that assumption refers to the old learned row, while the MCLAG row was
installed and rewritten afterward, so the current dynamic hardware row is
left unmanaged.

### Executed real-interface ladder

`repro/test_bugMC-5_delayed_learn_mclag.sh` builds on the existing mock-orch
harness but drives the production interfaces: a serialized
`port_state_change` brings Ethernet0 up through `PortsOrch`; serialized valid
SAI FDB notifications enter `NotificationConsumer::readData` and
`FdbOrch::doTask(NotificationConsumer&)`; the newer row enters through
`MCLAG_FDB_TABLE` and its real `Consumer`.  No production behavior is patched,
no impossible row is fabricated, and no SAI failure is injected.

- Level 0 consumes LEARN and AGE normally before publishing MCLAG.  The final
  entry remains MCLAG-owned and SAI static (`outcome=NO_TRIGGER`).
- Level 1 changes only executor scheduling: LEARN and AGE remain queued while
  the MCLAG table consumer runs.  The test verifies queue depth 2 and LEARN at
  the FIFO head.  Draining that LEARN changes the current row to dynamic,
  writes local ownership, and removes MCLAG state.  Draining AGE then leaves
  APPL_DB's MCLAG intent present but removes cache and both ownership tables,
  while the dynamic hardware row remains and `remove_fdb_entry` has zero
  calls.
- Two ordinary idle Orch drains leave the same state.  The already-consumed
  APPL_DB task has no retry/resend owner.
- The actual `MuxOrch::getMuxPort` consumer calls `FdbOrch::getPort` at
  `orchagent/muxorch.cpp:1938` and observes an empty port instead of the
  intended `Ethernet0`.  This is asserted by the test, not argued only.

The final execution exited 0 and passed in 208 ms.  Its exact output is stored
in `confirmation/MC-5/reproduction-output.txt`.

### Downstream behavior and permanence

There is no automatic in-repo reconciliation that masks the result.
`MuxOrch::updateFdb` intentionally ignores deletes at
`orchagent/muxorch.cpp:1948-1957`.  `FdbSync::processStateFdb` and
`processStateMclagRemoteFdb` consume the incorrect local SET/DEL and remote DEL
at `fdbsyncd/fdbsync.cpp:165-225` and `:228-288`; they do not restore FdbOrch's
cache.  `MclagLink::setFdbEntry` writes `MCLAG_FDB_TABLE` only on a new inbound
ICCPD ADD/DEL message (`mclagsyncd/mclaglink.cpp:465-518`).  Consequently the
bad state persists indefinitely under idle processing.  A later external MAC
event, ICCPD resend, or session resynchronization can create a new update, but
that is new external input rather than a downstream safeguard that repairs
this execution.

### Developer knowledge and refreshed known-status search

PR [#1331](https://github.com/sonic-net/sonic-swss/pull/1331) introduced the
same-port MCLAG remote-to-local feature; its intent matches the comments at
`fdborch.cpp:470-471` for a current local learn, but it contains no queued-event
incarnation rule.  The prior searches for the superseded traces remain useful
precedent evidence, but they do not report this replacement mechanism.

A refreshed upstream issue/PR and git-history search covered exact terms
`stale LEARN`, MCLAG AGE/FDB notification, MCLAG remote-to-local, FdbOrch race,
and every closed/merged FdbOrch PR updated since 2026-05-01.  The exact stale
notification-incarnation mechanism was not found.  The closest results were
the original feature PR #1331, the different one-arm flush race in
[#3524](https://github.com/sonic-net/sonic-swss/pull/3524), and the unrelated
EVPN neighbor-first race in
[#4739](https://github.com/sonic-net/sonic-swss/pull/4739).  Novelty therefore
remains **NEW**.

Current disposition: **REPRODUCED** at Level 1.

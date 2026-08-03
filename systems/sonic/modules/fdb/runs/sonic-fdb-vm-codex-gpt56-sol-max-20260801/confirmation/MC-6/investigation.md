# MC-6 investigation evidence

## Scope and provenance

- Source checkout: `sonic-net/sonic-swss`, commit
  `4f3dda156e52ed7647b1dbf900d54d87efaea455` (2026-07-31).
- Finding source: the repair-round-2 TLC output
  `spec/output/repair_RR003_MC_hunt_scenario_3_deferred_bfs.out`. It contains an
  actual `Invariant LatestDesiredWins is violated` counterexample, rather than
  a no-violation hunt result.
- The checkout already contained unrelated local trace instrumentation in
  `orchagent/fdborch.cpp`, `tests/mock_tests/Makefile.am`, and
  `tests/mock_tests/fdborch/fdborch_vxlan_ut.cpp`, plus three untracked trace
  files. Those edits are preserved and are not evidence for MC-6.

## Code audit

### Relevant representation and sites

- `orchagent/fdborch.h:96-107`: `SavedFdbEntry` stores a MAC, VLAN ID, and the
  full `FdbData`, but equality identifies only `(mac, vlanId)`. Deferred work is
  `unordered_map<string, vector<SavedFdbEntry>>`; it has neither a generation
  nor a latest-value map.
- `orchagent/fdborch.cpp:1066-1285`: `FdbOrch::doTask(Consumer&)` is the normal
  AppDB entry point. For `VXLAN_FDB_TABLE`, it parses `remote_vtep` into
  `FdbDest::VTEP` and `dest_value`, calls `addFdbEntry`, and erases the consumer
  item only when that call succeeds. A dependency-deferred item is therefore
  removed from the consumer by the caller only after it has been copied into
  `saved_fdb_entries` by `addFdbEntry`.
- `orchagent/fdborch.cpp:1907-1952`: `addFdbEntry` appends a fresh
  `SavedFdbEntry` whenever the destination port/bridge port is missing. On a
  P2MP-only SAI, it also appends when the remote endpoint is not yet in the
  VLAN's L2MC endpoint-membership map. The append path does not replace an older
  saved value for the same `(VLAN, MAC)`.
- `orchagent/fdborch.cpp:1833-1869`: `updateVlanMember` moves and clears the
  entire vector for the notified port, then invokes `addFdbEntry` in vector
  insertion order. Entries whose dependencies are still missing append
  themselves back to the vector.
- `orchagent/portsorch.cpp:7789-7938`: `PortsOrch::addVlanFloodGroups` installs
  an endpoint-specific L2MC member and emits `SUBJECT_TYPE_VLAN_MEMBER_CHANGE`
  with `{vlan, port, add=true}`. The notification has no endpoint field, so the
  FDB replay examines every saved entry on that common P2MP tunnel port.
- `orchagent/portsorch.cpp:8117-8131`: with a non-empty endpoint argument,
  `PortsOrch::isVlanMember` checks exact membership in
  `vlan.m_vlan_info.l2mc_members`.
- `orchagent/fdborch.cpp:2145-2167,2277,2322,2385`: a successful replay passes
  `FdbData::dest_value` to SAI as `SAI_FDB_ENTRY_ATTR_ENDPOINT_IP`, creates or
  updates the ASIC FDB entry, caches that value in `m_entries`, and then emits
  the FDB observer notification.

### Normal call chain and reachability

The normal call chain is:

1. A producer writes `VXLAN_FDB_TABLE:<vlan>:<mac>` with
   `remote_vtep=<endpoint>` to AppDB.
2. `FdbOrch::doTask(Consumer&)` parses it and calls `addFdbEntry`.
3. If the P2MP endpoint is not yet a VLAN endpoint member, `addFdbEntry` saves
   it in the vector and returns true, causing the consumer to erase its only
   queued copy; the saved vector then owns the deferred work.
4. A remote-VNI/VLAN endpoint later becomes ready through `PortsOrch`, which
   updates `l2mc_members` and sends `SUBJECT_TYPE_VLAN_MEMBER_CHANGE`.
5. `FdbOrch::update` calls `updateVlanMember`, which replays the saved vector.
6. The first now-eligible entry reaches `sai_fdb_api->create_fdb_entry` with its
   endpoint IP.

The ordering is reachable during normal operation. Upstream PR #2756 records a
real AppDB startup-ordering case in which VXLAN FDB entries arrived before their
EVPN NVO dependency and required later retry
(`https://github.com/sonic-net/sonic-swss/pull/2756`). The current P2MP code adds
an analogous endpoint-membership dependency for each remote VTEP. More
directly, the current upstream P2MP integration test at
`tests/test_evpn_fdb_p2mp.py:270-322` uses the public `ProducerStateTable` API
to SET the same `VXLAN_FDB_TABLE` key first to `6.6.6.6` and then to
`8.8.8.8`, with no intervening DEL, and requires the ASIC endpoint to become
the second value. The reproduction uses that same producer API and merely
schedules `FdbOrch` after each accepted update.

The dependency is not coupled to the desired FDB update. `FdbSync` owns
separate `ProducerStateTable` instances for `VXLAN_FDB_TABLE` and
`VXLAN_REMOTE_VNI_TABLE` (`fdbsyncd/fdbsync.h:95-96`, initialized at
`fdbsyncd/fdbsync.cpp:32-45`). IMET events take the separate
`imetAddRoute` path at `fdbsyncd/fdbsync.cpp:669-696`; MAC events take
`macAddVxlan` at `fdbsyncd/fdbsync.cpp:787-859`. Therefore accepting a newer
MAC destination does not synthesize, loop back, or guarantee a later IMET
membership event for that new endpoint.

### Concrete trigger sequence

With an existing VLAN and a common P2MP source-tunnel bridge port, and with
neither remote endpoint yet in the VLAN endpoint-membership map:

1. Submit a normal `VXLAN_FDB_TABLE` SET for key `K=(Vlan40, MAC)` with remote
   endpoint `p1`. It is saved as the first vector element.
2. Submit a newer normal SET for the same key `K` with remote endpoint `p2`.
   It is appended as the second vector element; AppDB's desired value is now
   `p2`.
3. Let the old endpoint `p1` become a VLAN endpoint member first. The ordinary
   VLAN-member notification replays both elements in insertion order.
4. The old `p1` entry now succeeds and is programmed/cached. The newer `p2`
   entry still lacks its endpoint dependency and is saved again.

This matches the current repair-round-2 counterexample: state 2 saves generation
1 / `p1`; state 3 appends generation 2 / `p2`; state 4 is
`MCFdbOrchUpdateVlanMemberDependencyAppears(k1)`; state 5 selects generation 1;
state 6 programs ASIC destination `p1`; and state 8 stores/applies generation 1
while desired generation 2 remains `p2` and its saved entry remains pending.
Correction to the round-1 evidence: RR003 no longer contains the third,
repeated `p2` SET. The current trace is the original two-SET sequence, and the
updated reproduction below uses exactly those two SETs.

### Safeguards and downstream behavior found

- A later, separate endpoint-membership event for `p2` causes another replay
  and can update the ASIC to `p2`. No periodic retry, AppDB re-read, generation
  comparison, or autonomous reconciliation was found in `FdbOrch`; without
  that new external dependency event, the cached/ASIC value remains `p1`.
- The first replay does not consume the newer value: it stays in
  `saved_fdb_entries`. That retention is not a caller guard against programming
  `p1`.
- `FdbUpdate` observers do not receive the VTEP endpoint value, so they cannot
  correct the stale endpoint. The direct real consumer is the SAI/ASIC
  forwarding plane at `orchagent/fdborch.cpp:2277`: traffic for the MAC uses
  endpoint `p1` although AppDB's latest desired endpoint is `p2`.
- No synchronous loopback or resend was found after the SAI create/cache path.

## Developer-knowledge evidence

- Commit `41caa74f` / PR #406 introduced `saved_fdb_entries` with the stated
  purpose of holding FDB entries "until ports are ready" and replaying them
  after VLAN-member notification. Its test submits an FDB before VLAN/member
  creation and expects eventual ASIC installation.
- Commit `a960e2ee` / PR #1275 added EVPN VXLAN FDB support. Its historical
  `tests/test_evpn_fdb.py` update case writes the same MAC first with one remote
  VTEP and then another and expects the ASIC endpoint to equal the newer VTEP
  when both dependencies are ready. The current P2MP counterpart retains the
  same public `ProducerStateTable.set` update contract at
  `tests/test_evpn_fdb_p2mp.py:270-322`.
- Commit `f0c53b94` / PR #4615 added the P2MP endpoint-membership check and the
  current destination representation
  (`https://github.com/sonic-net/sonic-swss/pull/4615`). Its discussion and
  tests do not mention multiple deferred SETs, generation coalescing, or
  insertion-order replay.
- Nearby comments describe the saved work as a retry until a port/member is
  created and explicitly put unsuccessful replays back into the saved vector.
  No TODO, documented acceptance, or test asserting obsolete deferred replay
  was found.
- Current tests exercise ordinary VTEP create/update/delete paths, but no test
  submits multiple SETs for one key while `saved_fdb_entries` holds the old
  value.

## Known-status / precedent search

The GitHub issue/PR tracker was re-searched on 2026-08-01 across open, closed,
and merged items, and local history was searched through the checkout's
2026-07-31 HEAD. Queries covered `saved_fdb_entries`, `updateVlanMember`,
deferred/queued FDB replay, obsolete/stale `remote_vtep`, P2MP FDB updates, and
coalescing/latest intent. An exact upstream issue search over
`saved_fdb_entries`, `updateVlanMember`, and `remote_vtep` returned zero issues.
The symbol searches returned only PRs for the different MCLAG restoration,
flush, feature-introduction, and dependency mechanisms listed below.

- PRs #2608, #2609, and #2610 touch `saved_fdb_entries` for an MCLAG stale
  static-MAC restoration problem, but report a different trigger and code path.
- Issue #1134 reports ordering between a flush request and FDB adds across
  different AppDB channels, not multiple values in this saved vector
  (`https://github.com/sonic-net/sonic-swss/issues/1134`).
- PRs #2642 and #2756 report missing VXLAN/NVO dependencies and retries, but not
  obsolete replay after a newer same-key SET.
- Recent FDB changes #4734 and #4739 address flush-all behavior and a neighbor /
  MAC-delete ordering issue, respectively; neither changes or reports deferred
  SET coalescing.

The recently closed/merged PR search (`updated:>=2026-07-01`) also covered PRs
#4734 and #4739; no later merged or closed PR reported or fixed FIFO replay of
obsolete same-key saved VXLAN FDB values.

The round-2 re-check queried GitHub's issue/PR tracker on 2026-08-01. Exact
searches for `saved_fdb_entries` returned only PRs #2610/#2608/#2609 (MCLAG
static-MAC restoration), #1275 (VXLAN feature introduction), and #1295 (link
down flush); `updateVlanMember` returned #4734, #4262, #1575, and #1295. A
`remote_vtep deferred FDB` search returned only superseded EVPN-MH PR #4262,
and an issue-only `deferred FDB` search returned zero results. The
`updated:>=2026-07-01 FDB VXLAN` PR search found #4780 (open static L2
configuration), merged #4734 (dynamic-only flush), merged #4739
(neighbor-first remote-MAC race), and unmerged #4262. Their bodies and touched
paths describe different mechanisms; none coalesces or validates
`saved_fdb_entries`. `git ls-remote origin refs/heads/master` still resolved to
the tested `4f3dda156e52ed7647b1dbf900d54d87efaea455`.

Known-status evidence: no issue, PR, advisory, CVE, or recent merged/closed PR
found in the searched history reports this same append-only deferred-SET replay
mechanism at `FdbOrch::updateVlanMember`. The closest reports concern different
sites or prerequisites.

## Repair-round-2 continuation

- The production sites above are unchanged in `worktree-2`: saved work is still
  a vector, P2MP deferral still uses unconditional `push_back`, and replay still
  iterates insertion order without checking current AppDB intent.
- Pre-existing local changes add TLA trace instrumentation and one unrelated
  flush-failure test. They do not change `SavedFdbEntry`, the P2MP deferral
  branches, replay ordering, or SAI FDB behavior. This round added only
  finding-local fixture wiring and capability responses selecting a valid
  P2MP-only SAI platform.
- The final Level-0 trigger writes the two same-key intents through
  `ProducerStateTable.set`, the same API and update shape used by the upstream
  P2MP integration update test. No saved-vector field or other internal
  precondition is injected.

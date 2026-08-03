# MC-4 investigation

## Scope and source

- Finding: `MC-4`, "Bridge-port teardown continues after its FDB flush fails".
- Source: model checking. The current repair-round-2 TLC output is a real counterexample: `spec/output/repair_RR003_MC_hunt_mc6_topology_reuse_bfs.out:34` reports `Invariant NoDanglingTopologyReference is violated`.
- Current counterexample sequence:
  - State 2 at output line 175 is `MCSaiLearnEvent(k1,p1,ev2)` and has a dynamic ASIC FDB entry present at destination `p1`, bridge-port generation 1.
  - State 3 at line 320 is `MCPortsOrchRemoveBridgePortBegin(p1)`; the bridge port remains present and enters `adminDown`.
  - State 4 at line 465 is `MCTopologyReactive`, which requests the port-scoped `flushFDBEntries` operation and enters `awaitFlush`.
  - State 5 at line 610 is `MCSaiFlushFailure(1)`; the ASIC FDB entry and bridge port both remain present.
  - State 6 at line 755 is `MCTopologyReactive`; it sets `bpPresent[p1] = FALSE` and `lastRemovedGeneration[p1] = 1` while the ASIC FDB entry still names `p1` generation 1.
- Correction to the repair-round-1 record: that trace inserted an explicit VLAN-member-removal action and numbered final removal State 7. RR003 removes that explicit action and numbers final removal State 6. RR003 also leaves `vlanMember[p1] = TRUE` through the flush failure, whereas the real APP_DB caller completes `removeVlanMember` before entering `removeBridgePort`; this is an additional lifecycle-ordering divergence, not evidence that the dangling delete can bypass the SAI reference guard.

## Step 1: code audit

### Relevant code

- `orchagent/fdborch.h:143-144` declares `flushFDBEntries` with return type `void`.
- In clean source commit `4f3dda156e52ed7647b1dbf900d54d87efaea455`, `orchagent/fdborch.cpp:1443-1503` constructs a dynamic-entry flush. The SAI call is at line 1486. On error, lines 1487-1490 only log `Flushing FDB failed`; there is no result for the caller. Only success marks matching software entries `is_flush_pending` at lines 1492-1502. The working tree's conditional trace instrumentation shifts these line numbers but does not change control flow or return values.
- `orchagent/portsorch.cpp:7470-7531` implements `removeBridgePort`. It lowers bridge-port admin state, removes STP ports, calls `gFdbOrch->flushFDBEntries(...)` at line 7506, and calls `sai_bridge_api->remove_bridge_port(...)` at line 7510 without an intervening acknowledgement or status check for the flush.
- A failed bridge removal is not ignored inside `removeBridgePort`: `orchagent/portsorch.cpp:7511-7519` passes it to `handleSaiRemoveStatus`. `orchagent/saihelper.cpp:768-769` maps `SAI_STATUS_OBJECT_IN_USE` to `task_need_retry`, and `orchagent/saihelper.cpp:809-821` converts that to `false`.
- The normal VLAN-member DEL caller does ignore that `false`: `orchagent/portsorch.cpp:6103-6109` calls `removeBridgePort(port)` without testing its return and then erases the APP_DB task.

### Normal call chain and reachability

The normal external sequence is an APP_DB VLAN-member lifecycle:

1. A port and VLAN are configured through `PORT_TABLE`, `VLAN_TABLE`, and `VLAN_MEMBER_TABLE`.
2. A dynamic FDB entry is learned on that VLAN member; a SAI `SAI_FDB_EVENT_LEARNED` notification reaches `FdbOrch::update`.
3. A `DEL` for `VLAN_MEMBER_TABLE:Vlan<N>:<port>` reaches `PortsOrch::doVlanMemberTask`.
4. `removeVlanMember` notifies observers; `FdbOrch::updateVlanMember` calls `flushFDBEntries(port bridge OID, VLAN OID)` at clean-source `orchagent/fdborch.cpp:1753-1763`.
5. With the bridge-port reference count now zero, `doVlanMemberTask` calls `removeBridgePort` at `orchagent/portsorch.cpp:6105-6107`; that method issues its second, port-scoped FDB flush and then attempts SAI bridge-port removal.

This call chain is reachable during ordinary create/remove VLAN-member operations. A SAI flush error is also an allowed runtime return, not an input rejected by this code.

### Safeguards and potentially observable outcomes

- The real sairedis metadata implementation counts object references. `/tmp/mc6-sonic-sairedis-20260801/meta/Meta.cpp:1633-1652` rejects removal of a non-switch object with a nonzero reference count as `SAI_STATUS_OBJECT_IN_USE`.
- SAI metadata declares `SAI_FDB_ENTRY_ATTR_BRIDGE_PORT_ID` as an object-ID reference whose allowed type is `SAI_OBJECT_TYPE_BRIDGE_PORT` in `/tmp/mc6-sonic-sairedis-20260801/SAI/meta/saimetadata.c:56786-56806`.
- Therefore, an FDB entry retained after a failed flush should contribute a reference that can prevent the final bridge-port delete. Phase 2 must prove this guard fires rather than assume it.
- If it fires, the exact MC State-6 transition (FDB present but bridge port absent) differs from the implementation. A separate caller-level effect is possible because `doVlanMemberTask` erases the DEL even when `removeBridgePort` returns false; the port can remain admin-down with its bridge-port OID and no queued retry.

### Concrete trigger scenario

Configure a physical port as a VLAN member, learn a dynamic FDB entry whose SAI bridge-port attribute names that port, make both removal-path SAI FDB flushes return a legitimate failure, and delete the VLAN member through its APP_DB consumer. Observe whether teardown is attempted, whether SAI actually deletes or rejects the referenced bridge port, whether the FDB survives, and whether the caller retains or erases the task.

## Step 2: developer-knowledge evidence

- Commit history shows the cleanup is intentional. The original bridge-port cleanup change (`#1451`) described removing FDB entries before removing a bridge port. Current commit `cd117626402d2e0f58536f9809e51fcfbb71cb2c` restored dynamic-only `flushFDBEntries` at both VLAN-member and bridge-port removal sites.
- [sonic-buildimage issue #27835](https://github.com/sonic-net/sonic-buildimage/issues/27835), opened 2026-06-11, reports the same production call sites and ordering: an unsupported FDB flush fails, sairedis logs that the bridge-port reference count is nonzero, and `removeBridgePort` fails with `rv:-17`. It identifies VLAN-member create/remove as the public trigger.
- [sonic-swss PR #4734](https://github.com/sonic-net/sonic-swss/pull/4734), merged 2026-07-06 as `cd117626`, fixes that report's `SAI_FDB_FLUSH_ENTRY_TYPE_ALL` trigger by restoring dynamic-only flush. It does not change `flushFDBEntries` from `void` or condition bridge-port removal on flush success.
- [sonic-swss PR #3211](https://github.com/sonic-net/sonic-swss/pull/3211) is still open. It reports a bridge-port remove blocked by a static FDB reference and proposes making `doVlanMemberTask` honor `removeBridgePort` failure and retry. This is evidence about the caller task-erasure behavior, while its static-entry trigger differs from MC-4's failed dynamic flush.
- [sonic-swss issue #290](https://github.com/sonic-net/sonic-swss/issues/290) independently records sairedis refusing a bridge-port removal when FDB references remain.
- No existing test found in the checkout exercised a failed `flushFDBEntries` followed by the real virtual-SAI bridge-port reference guard. The pre-existing `TraceFlushFDBEntriesFailure` mock test invokes only the flush function and checks no consumer consequence.

## Step 3: known-status and precedent

- Tracker searches covered open and closed issues and recently merged/closed PRs for `flushFDBEntries`, `Flushing FDB failed`, `removeBridgePort`, `OBJECT_IN_USE`, VLAN-member deletion, and FDB references. Local `git log`, `git blame`, and the current origin/master history were also checked.
- Novelty evidence: **KNOWN**. Issue #27835 reports the same failed-flush-then-bridge-removal sequence at the same `updateVlanMember`/`removeBridgePort` sites and includes the sairedis reference-guard result.
- Fix status for the mechanism under investigation: **unfixed**. PR #4734 fixed one concrete unsupported-enum cause of flush failure, but the current code still exposes no flush status and still attempts teardown after every other SAI flush error. The open PR #3211 also leaves the VLAN-member caller's ignored `removeBridgePort` result unresolved.
- Because this finding is MC-sourced from an actual violation trace, the code-review-known pre-filter does not apply; Phase 2 proceeds.

## Repair round 1 continuation

- The current source still has a `void` `FdbOrch::flushFDBEntries`; its SAI call at `orchagent/fdborch.cpp:1555` logs failure at lines 1556-1559 without returning status. `PortsOrch::removeBridgePort` still calls it at `orchagent/portsorch.cpp:7506` and immediately attempts `remove_bridge_port` at line 7510.
- The repaired trace still omits the real SAI-reference outcome. Its State 6 has `asic[k1].present = TRUE` and `bpPresent[p1] = TRUE` after the failed flush, but its next `MCTopologyReactive` step sets `bpPresent[p1] = FALSE`. In the implementation, sairedis metadata rejects exactly that removal while the FDB's `SAI_FDB_ENTRY_ATTR_BRIDGE_PORT_ID` reference remains.
- Executed `repro/test_bugMC-4_bridge_port_flush_guard.sh` against the rebuilt native mock-test binary. The Level-2 precondition instantiates repaired State 2 with the real virtual-SAI FDB API and a real learned notification; deletion enters through the normal `VLAN_MEMBER_TABLE` consumer. Both admissible flush calls return failure, bridge-port removal returns `SAI_STATUS_OBJECT_IN_USE (-17)`, the FDB and bridge port remain, and the bridge port is admin-down. The caller nevertheless erases the VLAN-member task and schedules no retry.
- This continuation preserves the earlier Level-0 and Level-1 results: normal flush/removal succeeded at Level 0; Level 1 proved teardown continues after flush failure when no retained FDB reference exists. No source patch or timing modification was used. Level 3 remains unnecessary because Level 2 deterministically proves the guard.
- Repair-round command and output:

```text
$ timeout 10m .../repro/test_bugMC-4_bridge_port_flush_guard.sh
RUN: .../tests/mock_tests/tests --gtest_filter=VxlanFdbOrchTest.MC4RepairTraceIsBlockedBySaiReferenceGuard
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.MC4RepairTraceIsBlockedBySaiReferenceGuard
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.MC4RepairTraceIsBlockedBySaiReferenceGuard
MC4 REPAIR TRACE State2: learned_fdb_present=yes, bridge_port_present=yes
MC4 REPAIR TRACE State6: flush_status=failed, flush_calls=2, fdb_present=yes, bridge_port_present=yes
MC4 IMPLEMENTATION MASK: remove_status=-17, expected_OBJECT_IN_USE=-17, bridge_port_present=yes, fdb_present=yes, admin_state=down
MC4 CALLER: vlan_member_task_erased=yes, retry_scheduled=no
MC4 MODEL MISMATCH: repaired_State7_bridge_port_present=no is unreachable
[       OK ] VxlanFdbOrchTest.MC4RepairTraceIsBlockedBySaiReferenceGuard (250 ms)
[----------] 1 test from VxlanFdbOrchTest (250 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (250 ms total)
[  PASSED  ] 1 test.
RESULT: PASS - repaired State 7 is blocked by the real SAI reference guard; the caller still erases its task
```

## Repair round 2 continuation

- RR003 remains a real TLC violation (`spec/output/repair_RR003_MC_hunt_mc6_topology_reuse_bfs.out:34`), but the implementation mapping is unchanged. RR003 State 5 retains both the learned FDB entry and bridge port after `MCSaiFlushFailure(1)`; State 6 then removes the bridge-port generation. sairedis instead returns `SAI_STATUS_OBJECT_IN_USE` before that state change.
- Current source commit `4f3dda156e52ed7647b1dbf900d54d87efaea455` still declares `flushFDBEntries` as `void` (`orchagent/fdborch.h:143-144`), logs its SAI failure without returning it (`orchagent/fdborch.cpp:1486-1490`), and has `removeBridgePort` call it immediately before `remove_bridge_port` (`orchagent/portsorch.cpp:7506-7510`). `doVlanMemberTask` still ignores the returned `false` from failed bridge-port removal and erases the DEL (`orchagent/portsorch.cpp:6107-6109`).
- sairedis commit `9bd6103824e4590b24fbce2bc014d8902b51eccb` declares `SAI_FDB_ENTRY_ATTR_BRIDGE_PORT_ID` as an object-ID reference to a bridge-port object (`SAI/meta/saimetadata.c:56786-56806`) and rejects removal of a referenced non-switch object with `SAI_STATUS_OBJECT_IN_USE` (`meta/Meta.cpp:1633-1652`).
- The issue-tracker re-check on 2026-08-01 covered the exact prior report and the recently merged/closed fix PR. `sonic-buildimage#27835` is closed and records the same failed-flush/removal sequence plus `rv:-17`; `sonic-swss#4734` merged on 2026-07-06 as `cd117626`, fixing its unsupported flush-all cause but retaining the `void` dynamic-flush API and unconditional removal attempt. `sonic-swss#3211` remains open and addresses the caller's ignored bridge-removal failure for a different static-FDB trigger. Novelty therefore remains **KNOWN**, and this broader mechanism remains unfixed.
- Artifact/bootstrap preflight found no existing binary or configured Makefile in the worktree. The preserved virtual-SAI package at `/tmp/fdb-harness-bootstrap-test/root` contained `libsaivs.so`, `libsaimeta.so`, SAI/swss headers, and the prior evidence's dependency marker. The worktree was configured and the native mock-test binary rebuilt successfully from the current source SHA; a clean second run produced the output below.
- Escalation continuation: the prior Level 0 result (normal lifecycle succeeds) and Level 1 result (flush failures are hidden and teardown continues without a retained FDB reference) remain established. At Level 2, RR003 State 2 was instantiated using the real virtual-SAI FDB API and learned-notification entry point; deletion then entered through the normal APP_DB VLAN-member consumer. This deterministically proved the reference guard, so Level 3 was neither necessary nor permitted to create a different symptom. No production logic was patched.
- Exact command and output:

```text
$ timeout 10m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-4_bridge_port_flush_guard.sh
PRECHECK: source_sha=4f3dda156e52ed7647b1dbf900d54d87efaea455, virtual_sai=/tmp/fdb-harness-bootstrap-test/root/usr/lib/x86_64-linux-gnu/libsaivs.so
RUN: /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-4/worktree/tests/mock_tests/tests --gtest_filter=VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard
MC4 RR2 TRACE State2: learned_fdb_present=yes, bridge_port_present=yes
MC4 RR2 TRACE State5: flush_status=failed, flush_calls=2, fdb_present=yes, bridge_port_present=yes
MC4 IMPLEMENTATION MASK: remove_status=-17, expected_OBJECT_IN_USE=-17, bridge_port_present=yes, fdb_present=yes, admin_state=down
MC4 CALLER: vlan_member_task_erased=yes, retry_scheduled=no
MC4 MODEL MISMATCH: RR003_State6_bridge_port_present=no is unreachable
[       OK ] VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard (209 ms)
[----------] 1 test from VxlanFdbOrchTest (209 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (209 ms total)
[  PASSED  ] 1 test.
RESULT: PASS - RR003 State 6 is blocked by the real SAI reference guard; the caller still erases its task
```

- Checklist evidence: Level 0 or Level 1 alone did **not** trigger the claimed dangling-reference violation. Level 2 corresponds exactly to RR003 State 2 (`MCSaiLearnEvent(k1,p1,ev2)`) and is reachable via `APP_DB port/VLAN/member SET → dynamic FDB learn → APP_DB member DEL → SAI flush failure → bridge-port removal attempt`. The real caller is `PortsOrch::doVlanMemberTask` at `orchagent/portsorch.cpp:6107-6109`; it observes/removes its task despite the failed bridge-port operation. The claimed dangling state is never created because the sairedis reference guard fires synchronously. The adjacent stranded state remains until unrelated recovery, but it does not satisfy `NoDanglingTopologyReference` because the bridge port was retained.

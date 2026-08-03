# MC-3 investigation evidence

## Scope and source

- Repository: `sonic-net/sonic-swss`, checkout `4f3dda156e52ed7647b1dbf900d54d87efaea455` (`origin/master` and the live upstream `refs/heads/master` both resolved to this SHA on 2026-08-01).
- Cited site: `orchagent/l2nhgorch.cpp:581-654`, especially the removal/accounting at lines 620-623, the replacement credit at line 634, and the cached-IP update at line 653.
- Current repair-round MC evidence: `spec/output/repair_RR003_MC_hunt_mc4_vtep_replacement_bfs.out` is a real TLC violation of `TunnelRefExact`. State 6 runs `MCL2NhgUpdateVtepIpBegin(ep1,ep2)`; State 7 removes `ep1` and changes its reference from 1 to 0; State 8 installs member `ep2` but changes `ep1` back to 1 while `ep2` remains 0. Thus the violating state has `nhgMembers[g1] = {ep2}` and `tunnelRefs = [ep1 |-> 1, ep2 |-> 0]`.
- Repair-loop correction: round 1 cited States 5-7 in `repair_final_MC_hunt_mc4_vtep_replacement_bfs.out`; the current RR003 trace shifts the same `ep1 -> ep2` replacement to States 6-8. Still earlier evidence cited an older States 10-12 `ep2 -> ep1` trace. These state-number and symbolic-order changes do not change the mechanism, and the reproduction's `192.0.2.10 -> 192.0.2.20` direction matches the current trace.

## Step 1 — code audit

### What the cited code does

`L2NhgOrch::updateL2NhgVtepIp()` iterates every L2 next-hop group containing `nh_id`. For each group it:

1. resolves and removes the SAI member/next hop for `m_nhg_vtep[nh_id].ip` (`orchagent/l2nhgorch.cpp:596-623`);
2. decrements the L2-NHG-local count and calls `VxlanTunnel::updateRemoteEndPointIpRef(old_ip, false)` plus cleanup (`:620-623`);
3. creates a SAI next hop and member with `new_vtep_ip` (`:625-633`);
4. credits `updateRemoteEndPointIpRef(m_nhg_vtep[nh_id].ip, true)` (`:634`) even though the cache is not assigned `new_vtep_ip` until after the entire loop (`:653`).

The SAI member therefore names the new endpoint while the `VxlanTunnel::tnl_users_` IP reference names the old endpoint. The separate `m_nhg_vtep[nh_id].ref_count` returns to the correct numeric total but does not encode which endpoint owns that total.

### Normal call chain and reachability

- Linux/FRR sends an admissible `RTM_NEWNEXTHOP` with an existing next-hop ID and a replacement gateway. `FdbSync::onMsgRaw()` dispatches it at `fdbsyncd/fdbsync.cpp:1349-1370`.
- `FdbSync::onMsgNhg()` accepts a gateway next hop and writes `remote_vtep=<new IP>` under the same ID in `L2_NEXTHOP_GROUP_TABLE` at `fdbsyncd/fdbsync.cpp:1197-1252`. Existing upstream mock tests establish that these gateway and group netlink messages are accepted (`tests/mock_tests/fdbsyncd/fdbsyncd_ut.cpp:965-1024`), though they do not cover replacement.
- Production constructs `L2NhgOrch` for that APP_DB table at `orchagent/orchdaemon.cpp:524-536`.
- Its executor dispatches a normal SET through `doTask()` -> `doL2NhgTask()` -> `updateL2Nhg()` at `orchagent/l2nhgorch.cpp:798-845`; an existing ID with a different `remote_vtep` enters `updateL2NhgVtepIp()` at `:720-734`.

A concrete normal sequence is: configure an EVPN NVO; create remote-VNI/IMET users so P2P tunnels for old and new endpoints exist; receive gateway next hop ID 10 for the old endpoint; receive group ID 100 containing member 10; then receive a replacement gateway for ID 10 naming the new endpoint. Equivalently at the L2NhgOrch normal APP_DB boundary: `SET 10 remote_vtep=192.0.2.10`, `SET 100 nexthop_group=10`, `SET 10 remote_vtep=192.0.2.20`.

### Consumers and safeguards

- Old and new tunnel existence is checked at `orchagent/l2nhgorch.cpp:606` and `:625`; SAI removal and creation failures return false for retry. Those checks do not alter the successful-path endpoint used at `:634`.
- `VxlanTunnel::updateRemoteEndPointIpRef()` mutates the endpoint-keyed `tnl_users_` map at `orchagent/vxlanorch.cpp:1109-1143`.
- `VxlanTunnel::cleanupDynamicDIPTunnel()` and `VxlanTunnelOrch::delTunnelUser()` consume the combined endpoint count to decide tunnel/bridge-port deletion at `orchagent/vxlanorch.cpp:1251-1271` and `:1812-1832`. Consequently, removal of the new endpoint's last IMR user can delete the new tunnel despite a live NHG member, while the stale old credit can retain the old endpoint.
- A successful SET is erased from `Consumer::m_toSync` at `orchagent/l2nhgorch.cpp:824-830`. Re-delivery of the same payload sees the cached IP already equal to the new value (`:726`) and does not re-run accounting. No periodic reconciliation for these endpoint-keyed IP references was found.
- The delete path uses the now-new cached IP when decrementing/cleaning a group member (`orchagent/l2nhgorch.cpp:133-154`), so it cannot transfer the stale old credit; it can instead decrement an uncredited new endpoint.

## Step 2 — developer-knowledge evidence

- `git blame` attributes the whole function to `88a8adbf094a` (2026-05-27), “Add standalone EVPN-MH code and tests (#4608).” The current repository and GitHub path history show no later commit touching `orchagent/l2nhgorch.cpp`.
- The original EVPN-MH PR discussion explicitly says: “We have also fixed the ref-count bug you noted (using `new_vtep_ip` instead of stale `m_nhg_vtep[nh_id].ip`)” and a reviewer thanks the author for the ref-count fix: <https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135> and <https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4349558932>. This is direct developer evidence that the intended replacement credit belongs to the new endpoint.
- PR #4615 review separately requested end-to-end verification of the new L2NHG/VXLAN combined refcount and documented that tunnel cleanup depends on it: <https://github.com/sonic-net/sonic-swss/pull/4615#discussion_r3314087802> and <https://github.com/sonic-net/sonic-swss/pull/4615#discussion_r3321022949>.
- Existing tests cover FdbSync gateway/group creation and VxlanTunnel increment/decrement in isolation, but repository searches found no L2NhgOrch VTEP-replacement test and no assertion coupling a replacement SAI member to the endpoint-keyed tunnel credit.
- Nearby comments state the intended operation is to “Delete the SAI next hop for old vtep and add the SAI next hop for new vtep” (`orchagent/l2nhgorch.cpp:605`) and explicitly identify the different-IP branch as “changing vtep ip” (`:726-731`).

## Step 3 — known status / precedent

Tracker searches covered open and closed issues/PRs for `updateL2NhgVtepIp`, `L2NhgOrch VTEP refcount`, `remote_vtep replacement`, and `updateRemoteEndPointIpRef`, plus all commits touching the file and the recent merged integration PRs #4608/#4615. The exact mechanism and site were already reported in closed, unmerged PR #4262 at <https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135>.

The repair-round recheck on 2026-08-01 searched the upstream GitHub tracker (including closed PR comments) for `updateL2NhgVtepIp`, `new_vtep_ip` plus `stale`, and `L2NhgOrch` plus `ref-count`. The two exact-mechanism searches returned only PR #4262; the broader ref-count search also returned integration PRs #3913 and #4608. GitHub reports #4262 closed on 2026-07-01 with `merged_at: null`, while `git ls-remote origin refs/heads/master` still resolves to `4f3dda156e52ed7647b1dbf900d54d87efaea455`; that tree retains the stale argument at line 634.

Novelty evidence: `KNOWN (cite: https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135; fix-status: unfixed)`. The earlier PR branch reportedly contained the one-argument fix, but current upstream master still credits `m_nhg_vtep[nh_id].ip` at line 634 and has no later commit at this file, so the deployed upstream status is unfixed. The other tracker hits (#3480 and #2352) concern P2MP state reporting and an iterator lifetime bug, respectively, not this mechanism.

Because the source is an actual MC counterexample, known status is recorded but does not invoke the code-review-only drop pre-filter.

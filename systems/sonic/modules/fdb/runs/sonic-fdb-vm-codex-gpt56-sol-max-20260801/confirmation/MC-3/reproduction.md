# MC-3 reproduction record

## Preflight

- The target checkout had no generated `Makefile`, `config.status`, `.libs` tree, or mock-test binary. The host has `g++`, GoogleTest archives, and `libswsscommon`, but lacks the SAI development headers and `libsaivs`/`libsairedis`/`libsaimeta` libraries required by the repository-wide mock binary.
- The checkout itself documents that those SONiC dependencies must come from VS build artifacts. No compatible artifact or prior successful local build recipe was present in this finding directory.
- The bounded fallback was a self-contained source harness. It compiles the complete target `orchagent/l2nhgorch.cpp` unchanged and extracts the relevant real `VxlanTunnel`/`VxlanTunnelOrch` consumer methods unchanged from `orchagent/vxlanorch.cpp:1013-1272,1711-1835`. Minimal dependency stubs accept normal table/SAI operations; notably, the tunnel SAI stub refuses deletion when a live SAI next hop still references the tunnel.
- Source provenance printed by the test: `4f3dda156e52ed7647b1dbf900d54d87efaea455`. The copied L2 source is checked byte-for-byte with `cmp` before compilation.
- Repair-round preflight also verified `git diff HEAD -- orchagent/l2nhgorch.cpp orchagent/vxlanorch.cpp` is empty. The existing unrelated checkout modifications do not overlap either compiled production source file.

## Escalation ladder

- Level 0 — triggered. The test establishes old/new tunnels through the real extracted `VxlanTunnelOrch::addTunnelUser()` normal IMR path, then submits normal `L2_NEXTHOP_GROUP_TABLE` SET/DEL operations through the public base executor. There are no delays, failpoints, internal-map writes, state injection, or source modifications.
- Levels 1-3 — not reached because Level 0 demonstrated both the violated accounting relation and a downstream consumer consequence.

## Command

```text
timeout 5m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-3_vtep_replacement.sh
```

The repair-round-2 continuation reran this command on 2026-08-01 and it exited 0.

## Actual output

```text
SOURCE_SHA=4f3dda156e52ed7647b1dbf900d54d87efaea455
SOURCE_UNMODIFIED=l2nhgorch.cpp plus vxlanorch.cpp:1013-1272,1711-1835
LEVEL=0 interface=L2_NEXTHOP_GROUP_TABLE normal_SET_DEL no_failpoints
INITIAL member_endpoint=192.0.2.10 old_ip_ref=1 new_ip_ref=0 l2_ref=1
REPLACEMENT actual_member_endpoint=192.0.2.20 actual_old_ip_ref=1 actual_new_ip_ref=0 l2_ref=1
REPLACEMENT expected_member_endpoint=192.0.2.20 expected_old_ip_ref=0 expected_new_ip_ref=1
RESEND old_ip_ref=1 new_ip_ref=0 corrected=no
NEW_IMR_DELETE new_tunnel_present=0 new_dynamic_tunnel_cached=0 active_sai_members=1 member_endpoint=192.0.2.20 sai_tunnel_delete_refusals=1
NEW_IMR_DELETE expected_new_tunnel_present=1 expected_new_dynamic_tunnel_cached=1 while_active_sai_members=1
OLD_IMR_DELETE old_tunnel_present=1 old_total_ref=1 old_ip_ref=1
OLD_IMR_DELETE expected_old_tunnel_present=0 expected_old_total_ref=-1
GROUP_DELETE active_sai_members=0 stale_old_tunnel_present=1 stale_old_ip_ref=1
BUG_TRIGGERED stale_old_credit=1 missing_new_credit=1 new_tunnel_deleted_while_member_live=1 old_tunnel_leaked=1 permanent_after_resend=1
```

The replacement lines reproduce current `repair_RR003_MC_hunt_mc4_vtep_replacement_bfs.out` State 8: the member is on new endpoint `ep2` while old endpoint `ep1` has the credit. This corrects round 1's State 7 numbering and the still earlier record's reference to an older State 12 trace; the concrete endpoint direction in the test was already the current trace's old-to-new direction. The real extracted `delTunnelUser()`/`deleteDynamicDIPTunnel()` consumer then removes the new tunnel's port, endpoint entry, and dynamic-tunnel cache while its SAI member remains. The mock SAI explicitly refused the hardware tunnel removal due that live reference, proving that refusal does not repair or mask the orchagent state: the production caller ignores the false return and discards its own state. A resend leaves the mismatch unchanged, and group cleanup leaves the stale old credit/tunnel.

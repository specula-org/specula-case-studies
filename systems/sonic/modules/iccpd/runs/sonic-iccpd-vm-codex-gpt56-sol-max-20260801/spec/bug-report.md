# Bug Report — iccpd

## Summary

- Scenarios tested: 4
- Bugs found: 3
- Configs run: `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg`
- Final convergence: all four implementation traces passed strong replay; the final 30-minute `MC.cfg` BFS reached depth 15 with 580,164,674 generated and 128,912,090 distinct states without an enabled-invariant violation.

## Bug 1: Crash after socket teardown permanently skips peer failover cleanup

- **Scenario**: 1 — warm recovery and reconstruction
- **Severity**: High
- **Invariant violated**: `MCWarmRecoveryTerminates`
- **Config**: `MC_hunt_scenario1.cfg`
- **Counterexample**: 16 states; `spec/output/MC_hunt_scenario1_bfs_validated.out` (1,361,429 generated states, 356,965 distinct states, depth 19)

### Trace Summary

1. Node `n1` reaches its heartbeat timeout and tears down the peer session. This records a pending ordinary failover cleanup: the session is down, `cleanupDone` is false, and the disconnect handler has not completed.
2. Other independent work runs, but no action performs `n1`'s `mlacp_peer_disconn_handler` cleanup.
3. `n1` dies abruptly after socket teardown and before the cleanup call. The crash destroys the volatile disconnect program counter while the model's history variable retains the unresolved obligation.
4. Restart creates fresh userspace state, reconnects `mclagsyncd`, performs the initial neighbor dump, and receives VLAN membership. None of these startup paths replays the missed FDB, isolation, traffic-gating, or remote-interface cleanup.
5. The behavior stutters with `n1` disconnected, `cleanupDone = FALSE`, and the cleanup obligation permanently pending.

### Root Cause

`scheduler_session_disconnect_handler` closes/unregisters the peer socket before it calls `mlacp_peer_disconn_handler`. An ungraceful process death in that gap can therefore occur after the externally visible disconnect but before the failover side effects. Those side effects are not transactional or persisted: only `mlacp_peer_disconn_handler` converts FDB state, publishes ICCP-down, clears isolation, re-enables traffic, and deletes remote interface state. A normal finalizer does call the disconnect handler, but an abrupt death bypasses it. On restart, `system_init`/`system_create_csm` zero the userspace state and `scheduler_init` reconstructs interfaces and neighbors without detecting or replaying the missed cleanup.

### Affected Code

- `src/iccpd/src/scheduler.c:844`: socket unregister/cleanup precedes peer failover cleanup at line 851.
- `src/iccpd/src/mlacp_link_handler.c:2391`: the ordinary disconnect branch performs the FDB, isolation, traffic, and remote-interface recovery effects.
- `src/iccpd/src/system.c:57`: initialization zeroes the volatile system state; fresh CSM allocation is likewise zeroed at line 188.
- `src/iccpd/src/scheduler.c:375`: startup reconstructs interfaces, neighbors, and syncd connectivity but has no missed-cleanup reconciliation.
- `dockers/docker-iccpd/supervisord.conf:39`: the `iccpd` program is configured with `autorestart=false`, increasing the duration of retained stale state after a crash.

### Recommendation

Make disconnect cleanup idempotent and crash-consistent. Persist a cleanup-required marker before socket teardown, clear it only after every failover side effect succeeds, and reconcile any outstanding marker during startup before forwarding is enabled. Also ensure the daemon/container is restarted after unexpected exit; restart alone is not sufficient without the reconciliation barrier.

---

## Bug 2: Uncorrelated resync requests accept an earlier response as the latest transaction

- **Scenario**: 2 — synchronization transaction integrity
- **Severity**: High
- **Invariant violated**: `MCSyncEnvelopeOrdering`
- **Config**: `MC_hunt_scenario2.cfg`
- **Counterexample**: 10 states; `spec/output/MC_hunt_scenario2_bfs_validated.out` (453,208 generated states, 144,225 distinct states, depth 13)

### Trace Summary

1. Established node `n1` prepares and fully writes resync request 1.
2. Before request 1's response arrives, another `need_to_sync` event makes `n1` prepare request 2, replacing its semantic outstanding request with 2.
3. Node `n2` receives request 1 and starts its ordered Start/Data/End response for request 1.
4. The first response's Sync Start reaches `n1` while request 2 is the current outstanding transaction.
5. `n1` accepts the Start solely from its flag and installs response envelope 1 even though its outstanding request is 2. `MCSyncEnvelopeOrdering` fails immediately; a later stale End can likewise clear the current wait state.

### Root Cause

The established `mlacp_exchange_handler` branch has no one-outstanding-request guard: every new `need_to_sync` clears the flag and sends another request. The wire protocol cannot distinguish those requests because `mlacp_prepare_for_sync_request_tlv` hard-codes `req_num` to zero. Although the responder echoes that number, `mlacp_sync_recv_syncData` checks only the Start/End flag and never correlates `req_num` with the current request. Consequently, an earlier response can be applied to and complete a later logical transaction, allowing stale configuration or replicated object state to be treated as current.

### Affected Code

- `src/iccpd/src/mlacp_fsm.c:1544`: established resync sends whenever `need_to_sync` is set, without serializing against an outstanding response.
- `src/iccpd/src/mlacp_sync_prepare.c:49`: every Sync Request writes request number zero at line 83.
- `src/iccpd/src/mlacp_sync_prepare.c:105`: Sync Data echoes the same uninformative request number at line 139.
- `src/iccpd/src/mlacp_fsm.c:538`: Sync Start/End processing clears wait state based only on flags and does not compare request identity.

### Recommendation

Allow only one outstanding resync per session, assign a monotonically changing request identifier, and require every Start/Data/End envelope to match it. Clear the outstanding request only after a matching End, with timeout/retry or session reset for failed transactions. Do not apply response data outside a validated envelope.

---

## Bug 3: Failed traffic-disable leaves a flapping MLAG port forwarding before current isolation

- **Scenario**: 3 — data-plane isolation and acknowledgement
- **Severity**: High
- **Invariant violated**: `MCCurrentIsolationBeforeTraffic`
- **Config**: `MC_hunt_scenario3.cfg`
- **Counterexample**: 5 states; `spec/output/MC_hunt_scenario3_bfs_validated.out` (548 generated states, 308 distinct states, depth 9)

### Trace Summary

1. Node `n1` loses the matching peer-interface record and then observes `mclagsyncd` EOF, leaving the sidecar unavailable.
2. Its local PortChannel transitions DOWN. The implementation attempts one traffic-disable write, but with the sidecar unavailable that write cannot establish the disabled state.
3. The same PortChannel rapidly transitions UP. This creates transition generation 2 and a new isolation requirement, but forwarding remains enabled because the failed DOWN operation was neither latched nor retried.
4. The peer still reflects isolation generation 0. Both local and peer links are up while traffic is enabled before current-generation peer isolation, violating `MCCurrentIsolationBeforeTraffic`.

### Root Cause

`mlacp_portchannel_state_handler` invokes traffic disable only on the DOWN event. `mlacp_link_disable_traffic_distribution` marks `is_traffic_disable` only if its one-shot sidecar write succeeds; on error it records no retry obligation and returns `void`. The later UP path does not re-establish the safety gate, so forwarding can remain enabled while isolation for the new transition is unproved. Sidecar recovery is also fragile: the event loop ignores `iccp_mclagsyncd_msg_handler`'s error return, and the reconnect loop tests only whether the stale descriptor is positive.

### Affected Code

- `src/iccpd/src/mlacp_link_handler.c:2067`: the PortChannel handler calls traffic disable only for a DOWN transition at lines 2092–2097.
- `src/iccpd/src/mlacp_link_handler.c:3588`: failed traffic-disable programming leaves `is_traffic_disable` false and retains no retry state.
- `src/iccpd/src/mlacp_link_handler.c:530`: the sidecar write can fail or short-write and returns `MCLAG_ERROR` without durable recovery.
- `src/iccpd/src/iccp_netlink.c:2212`: the syncd event handler's error return is ignored.
- `src/iccpd/src/scheduler.c:469`: reconnect occurs only when `sync_fd <= 0`, so an EOF on a stale positive descriptor is not repaired.

### Recommendation

Treat forwarding disable as a required, acknowledged safety transition. On sidecar EOF or write failure, close/reset the descriptor, retain and retry the operation, and keep traffic disabled (or fail closed) until both local programming and peer isolation for the current generation are confirmed. Carry a transition generation in the peer acknowledgement so stale ACKs cannot release the gate.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 4 — transport activity vs. scheduler progress | `MC_hunt_scenario4.cfg` | BFS: 16,570,839 generated / 4,530,241 distinct, depth 25; simulation: 12,771,082 checked states / 863,655 traces, depth 100 | No violation in either 30-minute run |

The Scenario 4 result is time-bounded, not an exhaustive proof: BFS still had 1,057,252 queued states at cutoff. The required deeper simulation also found no error.

## Specification Fixes During Hunting

- Disabled node symmetry in the three liveness hunting configs because TLC cannot soundly reconstruct temporal counterexamples modulo symmetry.
- Included `faultCounters` in `ModelView`; those counters affect future action enabledness and cannot be projected away.
- Made the finite body-read retry and remote-close EOF paths weakly fair while retaining the live-peer partial-header stall as an unfair environment wait.
- Required the sole scheduler to be enabled before a node can emit additional non-progress traffic, process syncd EOF, or reconnect syncd.

The first two Scenario 4 outputs were retained as superseded diagnostic artifacts; neither is reported as an implementation bug.

# MC-3 investigation record

## Scope and source

- Source: MC. The supplied counterexample `spec/output/MC_hunt_scenario3_bfs_validated.out` reports `Invariant MCCurrentIsolationBeforeTraffic is violated` and contains five states.
- Source checkout: `9df8ccbf72c31948741b5554d09c38ac6c1ec6e9` (`origin/master`). The checkout was already dirty on entry with 46 lines of TLA trace instrumentation across six tracked files and a locally built `src/iccpd/src/iccpd`; those pre-existing edits were preserved.
- The instrumentation changes only add trace hooks and route ICCP peer writes through a wrapper whose normal mode calls `write(2)` unchanged (`src/iccpd/src/tla_trace.c:875-897`). The affected mclagsyncd send path itself is not replaced.

## Counterexample sequence

The actual trace, rather than the finding summary alone, is:

1. State 1: both LAGs and the sidecar connection are up; node n1 has generation 0 and forwarding enabled.
2. State 2: `MCmlacp_peer_mlag_intf_delete_handler(n1)` makes n1's peer interface unknown.
3. State 3: `MCiccp_mclagsyncd_msg_handler_EOF(n1)` makes `syncdConnected = FALSE` while leaving `syncdFdPositive = TRUE`.
4. State 4: `MCmlacp_portchannel_state_handler(n1,FALSE)` advances n1 to generation 1, marks the local LAG down, and leaves forwarding enabled with `trafficApplyPending = "Disable"`.
5. State 5: `MCmlacp_portchannel_state_handler(n1,TRUE)` advances n1 to generation 2 while the peer still knows generation 0; forwarding remains enabled and the invariant is violated.

The trace's `applyFail` counter remains zero. Therefore the trace specifically exercises the ignored-EOF/stale-positive-descriptor route and reaches the violation before a separate modeled traffic-apply transition. A failed real send is one implementation realization after that stale EOF, but is not a distinct counterexample action in this trace.

## Code audit and call chain

### Normal PortChannel event path

- A normal kernel `RTM_NEWLINK` message is dispatched by `iccp_route_event_handler` (`src/iccpd/src/iccp_netlink.c:1537-1552`).
- A lower-layer state transition calls `iccp_from_netlink_port_state_handler` (`src/iccpd/src/iccp_netlink.c:1035-1067`).
- That handler walks configured MLAG CSM/LAG lists and calls `mlacp_portchannel_state_handler` for the matching PortChannel (`src/iccpd/src/iccp_ifm.c:1260-1306`).
- `mlacp_portchannel_state_handler` updates peer-link isolation, MAC/L2/L3 state, and `po_active`; on DOWN it synchronously calls `mlacp_link_disable_traffic_distribution` (`src/iccpd/src/mlacp_link_handler.c:2068-2103`).
- In EXCHANGE, the disable helper makes one call to `mlacp_link_set_traffic_dist_mode`; it sets `is_traffic_disable = true` only when that call returns success and retains no retry marker on failure (`src/iccpd/src/mlacp_link_handler.c:3594-3626`; uninstrumented HEAD site `src/iccpd/src/mlacp_link_handler.c:3588-3613`).
- The actual send helper retries only `EAGAIN`/`EWOULDBLOCK` a bounded number of times, then returns `MCLAG_ERROR`; every other send error returns immediately (`src/iccpd/src/mlacp_link_handler.c:365-430`). `mlacp_link_set_traffic_dist_mode` propagates a short/failed write as `MCLAG_ERROR` (`src/iccpd/src/mlacp_link_handler.c:531-581`).

### Sidecar EOF and reconnect path

- `iccp_mclagsyncd_msg_handler` treats `recv(...) == 0` as a closed socket and returns `MCLAG_ERROR`, but it does not close the fd or set `sync_fd = -1` (`src/iccpd/src/mlacp_link_handler.c:3356-3427`).
- `iccp_handle_events` calls that handler and discards its return value (`src/iccpd/src/iccp_netlink.c:2213-2217`; uninstrumented HEAD site `src/iccpd/src/iccp_netlink.c:2212-2215`).
- The scheduler reconnects only when `sync_fd <= 0` (`src/iccpd/src/scheduler.c:475-499`; uninstrumented HEAD site `src/iccpd/src/scheduler.c:461-479`).
- `iccp_connect_syncd` also returns success without attempting a connection whenever `sync_fd >= 0` (`src/iccpd/src/mlacp_link_handler.c:2568-2583`).
- A correct close/reset helper exists (`syncd_info_close`, `src/iccpd/src/mlacp_link_handler.c:2635-2651`) but is not used by the EOF event path.

### Acknowledgement behavior and safeguards

- Developer comments state the intended ordering: disable packet TX/RX when the MLAG interface goes down and re-enable only after it comes up and an ACK is received (`src/iccpd/src/mlacp_link_handler.c:2096-2099`). The TLV header says the ACK indicates that peer port isolation has been applied (`src/iccpd/include/mlacp_tlv.h:446-470`).
- `mlacp_fsm_recv_if_up_ack` guards against an ACK received while the local interface is down, but otherwise enables traffic (`src/iccpd/src/mlacp_fsm.c:759-793`). It carries only interface type/id and isolation state, not a flap generation.
- The peer sends an up ACK for every received up state even if `mlacp_fsm_update_Aggport_state` returned an error, including when the peer-interface record does not exist (`src/iccpd/src/mlacp_fsm.c:508-535`). This maps to the trace's peer-interface deletion prerequisite.
- Peer state sends do have an explicit resend obligation through `lif->changed`: failed peer sends leave the flag set (`src/iccpd/src/mlacp_fsm.c:1634-1645`). No analogous obligation exists for a failed local traffic-disable send.
- Other calls to the disable helper are limited to the initial DOWN handler, peer-connect replay for a currently-down interface, or config-sync handling (`src/iccpd/src/mlacp_link_handler.c:2100-2102`, `src/iccpd/src/mlacp_link_handler.c:2258-2264`, `src/iccpd/src/mlacp_fsm.c:1613-1632`). A simple DOWN/UP after the failed attempt clears neither a retry marker nor schedules another attempt.
- Session disconnect cleanup can re-enable an interface only if `is_traffic_disable` is already true (`src/iccpd/src/mlacp_link_handler.c:2411-2423`), so it does not repair the failed-disable state where that flag stayed false.
- The process installs a handler only for `SIGUSR1`; it does not ignore `SIGPIPE` (`src/iccpd/src/iccp_main.c:141-182`). A send to a fully closed stale socket can therefore terminate the process instead of reaching the return-value path. A bounded-`EAGAIN` failure on a live but non-consuming sidecar does reach the claimed return-value path without `SIGPIPE`; reproduction must distinguish these outcomes.

## Real downstream consumer

The superproject pins sonic-swss commit `b20a59691baca9ff6e4fbe46a7cd8223a3419117`. At that exact commit:

- Real `mclagsyncd` dispatches message types 6/7 to `MclagLink::mclagsyncdSetTrafficDisable` (`mclagsyncd/mclaglink.cpp:1880-1930`).
- That consumer publishes `traffic_disable=true|false` through the `LAG_TABLE` `ProducerStateTable` (`mclagsyncd/mclaglink.cpp:1288-1317`). Before orchagent consumption, the genuine output is visible in the `_LAG_TABLE:<lag>` APP_DB staging hash; failure to change it to `true` after a DOWN is therefore an observable consumer-side data inconsistency, not just an internal iccpd boolean.
- A candidate downstream caveat was found: the same pinned open-source `PortsOrch::doLagTask` recognizes `mtu`, `learn_mode`, `oper_status`, `lag_id`, `switch_id`, and `tpid`, but has no `traffic_disable` branch; it erases the task after processing the recognized attributes (`orchagent/portsorch.cpp:6210-6269`, `orchagent/portsorch.cpp:6294-6375`). Phase 2 must not assume this masks the finding; the skill requires runtime proof before a `MASKED` verdict.

## Reachability assessment and concrete trigger

All input events are ordinary production events: configuration creates a CSM/LAG, a peer ICCP session reaches EXCHANGE, the peer deletes/reconfigures its MLAG interface, mclagsyncd exits or stops consuming its TCP socket, and kernel PortChannel state changes DOWN then UP. The normal entry path from netlink to the one-shot disable is shown above.

Concrete implementation trigger to test:

1. Establish an ICCP CSM in EXCHANGE with a configured local PortChannel and a real mclagsyncd TCP consumer.
2. Deliver the legitimate peer-interface deletion represented by counterexample State 2.
3. Stop/close the real sidecar so iccpd observes the State-3 EOF, or stall it and fill the socket so the bounded nonblocking send fails without changing core logic.
4. Flap the PortChannel DOWN then UP through normal link-state operations.
5. Observe whether real mclagsyncd ever dispatches type 7 and writes `traffic_disable=true`, whether iccpd retains a retry/reconnect obligation, and whether a later mechanism repairs the missing command.

## Developer-knowledge evidence

- `git blame` attributes the one-shot disable, bounded send helper, comments describing ACK ordering, and sidecar receive behavior to commit `82b6bcfbb3f0306763850fc343ec9f6d100dc4a2` / PR #4819, “MCLAG enhacements ICCPd initial code commit.” The commit/PR says it implemented the MCLAG enhancements HLD and should be verified by MCLAG behavior; it does not document accepting lost traffic-disable requests.
- The same PR discussion reported mclagsyncd socket closures, but the cited fix was sonic-swss PR #1832. That fix only changes `MSG_BATCH_SIZE` initialization in mclagsyncd and is not the ignored EOF, stale `sync_fd`, or missing retry at this iccpd site.
- The sonic-swss development branch removed a traffic-disable DVS test in commit `532f1e744e8a8e946fea34d3e533824f14952185` with the message “Remove as the change may not be supported on non-brcm for PortChannel settings.” This is evidence about downstream platform coverage, not a filed report of the iccpd EOF/write-retry defect.
- No iccpd unit-test directory or existing test exercising sidecar EOF plus PortChannel flap was present in the checkout.

## Known-status / precedent search

Tracker searches covered both issues and PRs, including closed/merged results, for `iccpd mclagsyncd`, `traffic distribution`, `sync_fd`, `mclagsyncd reconnect`, and `is_traffic_disable`. The 100 most recently closed upstream PRs were also scanned for ICCP/MLAG/traffic-distribution/socket terms.

Potentially nearby reports were re-checked and are different mechanisms:

- sonic-buildimage issue #9984 reports a mclagsyncd segfault and broad docker outage, not iccpd ignoring sidecar EOF or losing a traffic-disable write: https://github.com/sonic-net/sonic-buildimage/issues/9984
- issue #6640 concerns failure to start/listen on port 2626, not loss of a previously established connection: https://github.com/sonic-net/sonic-buildimage/issues/6640
- PR #7684 concerns incorrect link oper-state after warm reboot, not sidecar reconnect/write handling: https://github.com/sonic-net/sonic-buildimage/pull/7684
- PR #4819 introduced the affected code and contains the different `MSG_BATCH_SIZE` socket incident described above: https://github.com/sonic-net/sonic-buildimage/pull/4819

No issue, merged/closed PR, CVE/advisory, or commit message found in the permitted tracker/git-history search reports this same mechanism at these sites. Known status recorded for Phase 2: `Novelty: NEW`.

## Build/artifact preflight

- Existing binary: `src/iccpd/src/iccpd`, ELF x86-64 PIE, debug info present, build ID `cb10585b404a6400afc94453e5b3afce7569ca90`, timestamp 2026-08-01 00:32:26 -0500.
- `src/iccpd/config.log` records a successful GCC build with `-O0 -g -DICCPD_TLA_TRACE`; the source SHA and tracked instrumentation diff were captured above. The relevant mclagsyncd send code is unmodified, so the artifact is compatible with a real-interface Level-0/1 check while its trace-only provenance remains explicit.
- Compatible `libswsscommon` headers/library and Redis are installed. The real pinned sonic-swss mclagsyncd sources compiled successfully after supplying two schema constants absent from the newer installed header, so Phase 2 can use a real consumer rather than a mock.
- No built mclagsyncd/orchagent or SAI virtual-switch runtime was present. Hardware/ASIC packet-forwarding observation may therefore be an environment boundary even if the genuine mclagsyncd-visible data inconsistency is reproduced.

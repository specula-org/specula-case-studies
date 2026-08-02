# Confirmation Report — iccpd

## Final Result

Reproduced bugs: 3 = 3 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 4
Dispositions: 4 total = 3 reproduced + 0 env-limited + 1 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | MASKED | no |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | CR-4 | REPRODUCED | yes |

## Entry 1: Crash after socket teardown permanently skips peer failover cleanup

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: src/iccpd/src/scheduler.c:844
- **Severity**: High
- **Reproduction test**: [test_bugMC-1_crash_window.sh](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/repro/test_bugMC-1_crash_window.sh) — Level 1

## Description

`scheduler_session_disconnect_handler` closes the peer socket at line 848, then calls `mlacp_peer_disconn_handler` at line 851. An abrupt process death between those operations loses the volatile cleanup obligation. Restart reconstructs userspace state but does not replay ICCP-down publication or the remaining failover cleanup.

No issue or recently merged/closed PR reporting this mechanism was found. The closest result, [sonic-buildimage issue #16075](https://github.com/sonic-net/sonic-buildimage/issues/16075), concerns stack smashing in a different function and is not the same defect.

## Trigger scenario

Two clean, exact-revision `iccpd` instances established a real ICCP session using real TCP, kernel interfaces, `mclagsyncd`, and isolated Redis databases. After the peer died, a Level 1 timing breakpoint stopped the local process at the first instruction of `mlacp_peer_disconn_handler`; GDB proved `sock_fd=-1` and the production scheduler caller. The local process was then killed, matching counterexample state 11, and restarted while the peer remained dead.

## Developer intent

`mlacp_peer_disconn_handler` explicitly publishes ICCP down at `mlacp_link_handler.c:2397`, clears isolation, restores traffic, converts FDB entries, and deletes remote interfaces. Comments at lines 2393-2396 require the down notification before isolation cleanup. Startup comments at lines 601-610 acknowledge that down processing may occur before mclagsyncd connects, but there is no later reconciliation.

## Reproduction result

Command:

```text
timeout 180s ./test_bugMC-1_crash_window.sh
```

Exit status: `0`.

```text
BUILD sonic-buildimage=9df8ccbf72c31948741b5554d09c38ac6c1ec6e9 sonic-swss=b20a59691baca9ff6e4fbe46a7cd8223a3419117
BUILD iccpd_sha256=84d6535646f7333b682b5b7e247a199e534791fec60bc629bbc2adb0d1aca6a4 mclagsyncd_sha256=aa44f44185dc5e88871bb70653b0457b0ac265823afa9d471dafd0f7af768b0f
LEVEL0_PRE oper_status=up
LEVEL0_RESULT=not_triggered close_after_teardown=0 observed_oper_status=down
LEVEL1_PRE oper_status=up
LEVEL1_BREAKPOINT_HIT sock_fd=-1
#0  mlacp_peer_disconn_handler (csm=0x55c34eba1920) at mlacp_link_handler.c:2350
#1  0x000055c31f79e7d7 in scheduler_session_disconnect_handler (csm=0x55c34eba1920) at scheduler.c:851
AFTER_CRASH oper_status=up
POST_RESTART_2S oper_status=up
POST_RESTART_8S oper_status=up
DOWNSTREAM_RECOVERY_OBSERVED=no (waited >2x configured session_timeout after reconnect)
TEST_RESULT=BUG_REPRODUCED level=1
```

Correct behavior is demonstrated by the Level 0 control, which published `oper_status=down`. With the crash window held, the real mclagsyncd consumer at `mclaglink.cpp:1320-1359` retained `up` after restart. The production MC-LAG CLI consumes this state at `sonic_cli_mclag.py:384-403`.

## Recommendation

Make disconnect cleanup idempotent and crash-consistent. Startup should reconcile peer-derived FDB, isolation, traffic-distribution, remote-interface, and ICCP state after mclagsyncd is connected, using a durable pending/completed marker or an unconditional disconnected-state reconciliation barrier.

## REPRODUCED checklist

1. **Did Level 0 or Level 1 alone trigger it?** yes — Level 1 used only timing assistance around a real peer death and normal restart.
2. **Level 2/3 precondition evidence:** Not applicable; neither state injection nor source modification was used. The process death also corresponds exactly to counterexample state 11, `MCsystem_finalize_Crash(n1)`.
3. **Real consumer/caller:** `sonic-swss/mclagsyncd/mclaglink.cpp:1320-1359` retains the wrong State DB result; `sonic-mgmt-framework/CLI/actioner/sonic_cli_mclag.py:384-403` reads and presents it.
4. **Permanent or masked?** Permanent for the disconnected epoch. It remained wrong beyond two session timeouts, and no sync, resend, loopback, or caller guard repaired it. A future peer reconnection would be a new external event, not automatic recovery of the skipped cleanup.

---

## Entry 2: Uncorrelated resync requests accept an earlier response as the latest transaction

- **Finding ID**: MC-2
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: src/iccpd/src/mlacp_fsm.c:1569
- **Severity**: High

## Description

Established resynchronization has no outstanding-request guard, always emits request number zero, and accepts Sync Start/End without validating that number. This contradicts RFC 7275’s nonzero unique request-number and response-association requirements. Searches of upstream [issues](https://github.com/sonic-net/sonic-buildimage/issues?q=sync_req_num), open/closed [PRs](https://github.com/sonic-net/sonic-buildimage/pulls?q=mlacp+resync), refreshed history, and the [original MCLAG PR](https://github.com/sonic-net/sonic-buildimage/pull/2514) found no prior report of this mechanism.

The defect is masked as an independent live bug: processing the first established resync also moves the responder from `EXCHANGE` to `ERROR` at `mlacp_fsm.c:1460`. It then consumes request two without emitting response two. Consequently, the observed stale state is carried by that separate FSM defect and cannot be attributed solely to MC-2’s missing correlation.

## Trigger scenario

1. In established `EXCHANGE`, a NAK sets `need_to_sync`.
2. `mlacp_exchange_handler()` sends request one without marking it outstanding.
3. A second NAK arrives before response one, causing request two.
4. Both wire requests have `req_num=0`.
5. Response one’s Start/Data/End is accepted and applied while request two is logically latest.
6. The responder’s separate `EXCHANGE→ERROR` transition prevents response two.

The Level-2 state injection corresponds exactly to counterexample States 2 and 4. The later System-ID snapshot is also reachable through the normal interface-MAC observation at `scheduler.c:519-531`.

## Developer intent

[RFC 7275 §7.2.9](https://www.rfc-editor.org/rfc/rfc7275.html#section-7.2.9) reserves zero for unsolicited synchronization and requires a solicited request number to identify the request uniquely. [§7.2.10](https://www.rfc-editor.org/rfc/rfc7275.html#section-7.2.10) associates Start/End delimiters with that request number.

The zero assignment and non-validating receiver date to the 2020 MCLAG import. No nearby comment, test, commit, or PR states that overlapping uncorrelated resyncs are intentional.

## Reproduction result

Test: [test_bugMC-2_sync_envelope.c](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/repro/test_bugMC-2_sync_envelope.c:1)  
Investigation: [investigation.md](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-2/investigation.md:1)

- Level 0: no. The daemon refused normal black-box startup because UID 20008 is non-root.
- Level 1: a rootless user/network namespace allowed daemon startup, but no configured second SONiC peer, `mclagsyncd`, or legitimate two-NAK timing source existed.
- Level 2: succeeded using the admissible counterexample states, real loopback TCP, unmodified production message builders, the normal scheduler callback, and `mlacp_fsm_transit()`.
- Level 3: not attempted because Level 2 conclusively proved the mask.

Actual output:

```text
LEVEL 2: inject admissible CE States 2/4 (established need_to_sync edges); use real TCP + production scheduler/FSM
REQUESTS: two resync sends completed before responder read request 1; wait_for_sync_data=0
WIRE request 1: req_num=0; responder state after full response=MLACP_STATE_ERROR
WIRE request 2: req_num=0; latest peer snapshot is 02:00:00:00:00:02; system_config_changed=1
RESPONSE 1 envelope: START req_num=0
RESPONSE 1 envelope: END req_num=0
REAL CONSUMER mclagsyncd: applied response-1 system_id=02:00:00:00:00:01
REQUESTER remote_system after response 1: id=02:00:00:00:00:01 priority=100 frames=3
SECOND RESPONSE: absent; production responder remains MLACP_STATE_ERROR and consumes request 2 without replying
CONTROL: latest snapshot 02:00:00:00:00:02 was not observed by requester or mclagsyncd
MASK PROVED: req_num=0/no outstanding guard is real, but MC-2 live harm cannot be isolated: mlacp_sync_send_all_info_handler's separate EXCHANGE->ERROR transition carries the stale-state consequence
```

The real consumer is `mclagsyncd`, reached through `mlacp_fsm_update_system_conf()` and `mlacp_link_set_iccp_system_id()` at `src/iccpd/src/mlacp_sync_update.c:76`. The stale value remains for the tested session, but that permanence is caused by the separate responder transition that suppresses response two.

## Recommendation

Use monotonic nonzero request IDs; allow only one outstanding resync while coalescing later triggers; validate matching Start/Data/End envelopes before applying data or clearing waits. Separately, prevent `mlacp_sync_send_all_info_handler()` from advancing an established responder into `MLACP_STATE_ERROR`, then add an overlapping-resync regression test.

---

## Entry 3: Failed traffic-disable leaves a flapping MLAG port forwarding before current isolation

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Severity**: High
- **Location**: src/iccpd/src/mlacp_link_handler.c:3588

## Description

A failed mclagsyncd traffic-disable write leaves `is_traffic_disable` false without retaining any retry obligation. A subsequent PortChannel UP therefore remains forwarding-enabled while its peer-interface state is unknown, and the stale positive sidecar descriptor prevents automatic reconnection.

The upstream issue tracker, git history, and recently merged/closed PRs were searched; nearby reports such as [#9984](https://github.com/sonic-net/sonic-buildimage/issues/9984), [#6640](https://github.com/sonic-net/sonic-buildimage/issues/6640), and [#7684](https://github.com/sonic-net/sonic-buildimage/pull/7684) concern different mechanisms.

## Trigger scenario

Two genuine iccpd/mclagsyncd nodes reached MLACP Exchange. The peer’s target interface was removed through CONFIG_DB, matching the counterexample prerequisite. Level 0 graceful EOF reached the stale-descriptor condition but Linux’s TCP half-close continued accepting writes locally.

At Level 1, the genuine sidecar was paused and its per-namespace TCP window bounded while normal peer PortChannel events created backpressure. Once iccpd’s real TX counter recorded sidecar-send failures, the untouched target was flapped DOWN/UP through RTM_NEWLINK. Its disable write failed, and the sidecar was then crashed and restarted to test recovery.

## Developer intent

Comments in [mlacp_link_handler.c](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-3/worktree/src/iccpd/src/mlacp_link_handler.c:2096) require traffic to be disabled on DOWN and re-enabled only after UP plus peer acknowledgement. However, the disable helper makes one attempt, while the scheduler reconnects only when `sync_fd <= 0`.

The complete investigation is recorded in [investigation.md](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-3/investigation.md).

## Reproduction result

Executed [test_bugMC-3_stale_syncd_flap.py](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/repro/test_bugMC-3_stale_syncd_flap.py):

```text
$ cd /users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-3/worktree
$ ../../../repro/test_bugMC-3_stale_syncd_flap.py
source_head=9df8ccbf72c31948741b5554d09c38ac6c1ec6e9
mclagsyncd_source=b20a59691baca9ff6e4fbe46a7cd8223a3419117
prior_level0_attempt=graceful sidecar EOF; TCP half-close accepted post-EOF writes locally
trigger_level=1 (SIGSTOP sidecar plus bounded TCP window; normal LAG operations)
peer_target_interface_known_before_flap=False
startup_process_status={'sync_a': None, 'sync_b': None, 'iccp_a': None, 'iccp_b': None}
initial_exchange=yes
nodeA_initial_state:
The MCLAG's keepalive is: OK
MCLAG info sync is: completed
Domain id: 1
Local Ip: 10.77.0.1
Peer Ip: 10.77.0.2
Peer Link Interface: PortChannel1
Keepalive time: 1
sesssion Timeout : 30
Peer Link Mac: be:2d:18:a2:41:0c
Role: Active
MCLAG Interface: PortChannel203,PortChannel200,PortChannel201,PortChannel100,PortChannel204,PortChannel205,PortChannel202
Loglevel: NOTICE
target_forwarding_enabled_baseline=True
real_mclagsyncd_APPL_DB_baseline_traffic_disable=false
sidecar_socket_while_paused=ESTAB 0      0      127.0.0.1:38010 127.0.0.6:2626
SetRemoteIntfSts_TX_OK_baseline=28
SetRemoteIntfSts_TX_OK_after_churn=258
SetRemoteIntfSts_TX_ERROR_baseline=0
SetRemoteIntfSts_TX_ERROR_after_churn=10
peer_primer_flap_cycle_limit=4000
SetRemoteIntfSts_TX_ERROR_before_target=10
TrafficDistDisable_TX_ERROR_before_target=0
nodeA_iccpd_alive_after_failed_disable=True
target_traffic_disable_before_restart=false
replacement_sidecar_waiting_without_connection=True
target_traffic_disable_after_restart_wait=false
nodeA_target_port_after_restart_wait:
Ifindex: 4
Type: PortChannel
PortName: PortChannel100
MAC: 8a:1f:42:c6:04:24
IPv4Address: 0.0.0.0
Prefixlen: 32
State: Up
IsL3Interface: No
MemberPorts:
PortchannelIsUp: 1
IsIsolateWithPeerlink: Yes
IsTrafficDisable: No
VlanList:
nodeA_relevant_log_lines:
<none captured>
TrafficDistDisable_TX_OK=7
TrafficDistDisable_TX_ERROR=1
assert_target_oper_up=True
assert_iccpd_forwarding_flag_remained_enabled=True
assert_real_consumer_never_received_disable=True
assert_stale_fd_prevented_reconnect=True
assert_disable_send_failed=True
RESULT=REPRODUCED
```

The expected result was `traffic_disable=true`, `IsTrafficDisable: Yes`, or a retained retry obligation before forwarding could resume.

## Reproduction checklist

1. **Did Level 0 or Level 1 alone trigger it?** yes — Level 1 used only real CONFIG_DB/netlink operations, genuine daemons, sidecar timing control, and a bounded TCP window. No daemon state injection or source patch was used.
2. **Level 2/3 sequence:** not applicable.
3. **Real consumer/caller:** genuine `MclagLink::mclagsyncdSetTrafficDisable` at `mclagsyncd/mclaglink.cpp:1288` left its ProducerStateTable output at `traffic_disable=false`; [mclagdctl.c](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-3/worktree/src/iccpd/src/mclagdctl/mclagdctl.c:576) independently observed `IsTrafficDisable: No`.
4. **Permanent or later repaired/masked?** Persistent and not self-healing. A replacement sidecar remained unconnected, APP_DB stayed `false`, and the target stayed forwarding-enabled. No timer, resend, sync, loopback, or caller guard repaired it; recovery requires a new external transition, daemon restart, or manual intervention.

## Recommendation

Close and invalidate `sync_fd` on EOF/read errors, reconnect the sidecar, and retain a fail-closed traffic-disable obligation until application acknowledgement. Retry with bounded backoff and permit forwarding only after a generation-correlated peer-isolation acknowledgement.

---

## Entry 4: Transport activity and scheduler progress diverge

- **Finding ID**: CR-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/CR-4/debate.md

# CR-4 — Transport activity and scheduler progress diverge

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: src/iccpd/src/scheduler.c:154

## Description

The real daemon’s single scheduler blocks inside peer-frame reads, preventing signal handling, heartbeat expiry, and FSM transitions. Complete but unsupported APP frames separately refresh heartbeat without protocol progress, while mclagsyncd EOF leaves a positive stale descriptor that permanently suppresses reconnection.

Upstream and recently closed PR searches found no report of this exact mechanism. PR [#4819](https://github.com/sonic-net/sonic-buildimage/pull/4819) introduced the relevant logic but reported a different mclagsyncd-side problem. Current upstream still contains the affected paths.

Investigation record: [investigation.md](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/CR-4/investigation.md)

## Trigger scenario

Using only normal wire interfaces:

1. Start clean, unmodified iccpd and connect through its mclagsyncd configuration socket.
2. Connect a peer from its configured source address.
3. Exercise four legitimate adversarial conditions:
   - Deliver one byte of an eight-byte ICCP header and hold the TCP connection open.
   - Deliver a complete header plus one body byte.
   - Send complete unknown U-bit APP frames below the heartbeat timeout without completing ICCP synchronization.
   - Close and restart the mclagsyncd listener after its initial connection.

## Developer intent

The body-retry comment acknowledges that receive calls had become stuck and attempts to bound them to one keepalive interval. The heartbeat comment deliberately treats every complete peer message as activity for large synchronizations. Neither intent accounts for blocking the only scheduler, unsupported frames indefinitely reserving a session, or retaining a closed mclagsyncd fd.

PR #4819 also records that ICCPd had no component-level tests at the time ([discussion](https://github.com/sonic-net/sonic-buildimage/pull/4819#issuecomment-813540632)). Deployment scripts do not mask mclagsyncd EOF by restarting iccpd.

## Reproduction result

Test: [test_bugCR-4_transport_scheduler.py](/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/repro/test_bugCR-4_transport_scheduler.py)

Escalation: Level 0 black-box. No source modification, failpoint, internal function call, or state injection was used.

Command, from `.specula-output/repro`:

```text
timeout 3m ./test_bugCR-4_transport_scheduler.py
```

Actual output, exit code 0:

```text
CR-4 Level 0 black-box reproduction
preflight: prepared_binary=/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/CR-4/worktree/src/iccpd/src/iccpd trace_instrumented=true reused=no
preflight: clean_source_sha=9df8ccbf72c31948741b5554d09c38ac6c1ec6e9
preflight: build=autoreconf -if; ./configure CFLAGS='-O0 -g'; make -j2
preflight: clean_binary=/tmp/cr4-clean-head-n3qokjpd/src/iccpd/src/iccpd
partial_header: sent=1/8-header-bytes capability_rx=16B queued_SIGUSR1=yes
partial_header: alive_after_4.2s=True peer_open=True wchan=wait_woken
partial_header: exited_after_peer_release=True rc=0
partial_body: sent=8-byte-header+1/12-body-bytes session_timeout=3s capability_rx=16B
partial_body: alive_after_5.3s=True peer_open=True queued_SIGUSR1=yes wchan=hrtimer_nanosleep
nonprogress_app: frame_hex=0703001000000064000500040000000180200000 sent=9 elapsed=6.3s peer_open=True
nonprogress_app: mclagdctl: The MCLAG's keepalive is: ERROR
nonprogress_app: mclagdctl: MCLAG info sync is: incomplete
nonprogress_app: mclagdctl: sesssion Timeout : 3
nonprogress_app: replacement_while_traffic_rejected=True
nonprogress_app: first_closed_after_traffic_stopped=True
nonprogress_app: replacement_after_timeout_accepted=True capability_rx=16B
syncd_eof: initial_connection=accepted replacement_accepts=0 after=2.0s daemon_alive=True
RESULT: BUG TRIGGERED (4/4 Level 0 black-box scenarios)
```

The decisive observations are:

- A queued warm-reboot signal remained unprocessed past the session timeout until the fragmented header read was released.
- The partial-body path remained in `hrtimer_nanosleep` past its configured timeout.
- Unsupported frames kept synchronization incomplete while causing a replacement peer to be rejected.
- A restarted mclagsyncd listener received zero reconnects.

### Required checklist

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0 alone**.
2. Level 2/3 reachability sequence: **N/A; neither was used**.
3. Real consumers/callers observing wrong outcomes:
   - Signal-pipe consumer `iccp_receive_signal_handler()` at `src/iccpd/src/scheduler.c:434`, dispatched from `src/iccpd/src/iccp_netlink.c:2218`.
   - Replacement peer acceptance at `src/iccpd/src/scheduler.c:300`.
   - mclagsyncd reconnect caller `iccp_connect_syncd()` at `src/iccpd/src/mlacp_link_handler.c:2562`.
4. Permanent or masked? **Not masked.** Header blockage lasts while the TCP stream remains open; stale `sync_fd` lasts for the daemon lifetime; unsupported traffic prevents recovery for as long as it continues. The demonstrated timeout recovery occurred only after removing that trigger.

## Recommendation

Use nonblocking incremental per-connection frame parsing and return to epoll between fragments; never sleep inside the event handler. Track protocol progress separately from transport activity, bound pre-operational sessions, and consume or reject unsupported APP messages. On mclagsyncd EOF/error, remove the fd from epoll, close it, set `sync_fd = -1`, and retry connection.

---

# Instrumentation Guide: sonic-iccpd

Guide for the Phase 3 (validation) agent to adjust instrumentation when trace validation reveals issues.

## Architecture

- **Language**: C (autotools build system)
- **Category**: A (distributed, single-threaded event loop)
- **Trace module**: `harness/src/tla_trace.h` + `harness/src/tla_trace.c`
- **Test driver**: `harness/src/test_harness.c` (replaces `iccp_main.c`)
- **Message routing**: `iccp_csm_send()` patched via `#ifdef TLA_TRACE_TEST` to call `tla_route_message()` which enqueues via `iccp_csm_enqueue_msg()` (preserving real byte-order conversion path)

## Instrumentation Points (after apply.sh)

| Event | File | Location | Pattern |
|-------|------|----------|---------|
| SendHeartbeat | mlacp_fsm.c | After `time(&csm->heartbeat_send_time);` | `mlacp_sync_send_heartbeat` function |
| MlacpInitToStage1 | mlacp_fsm.c | After `MLACP(csm).current_state = MLACP_STATE_STAGE1;` | `mlacp_fsm_transit`, INIT block |
| MlacpStageSendAllInfo | mlacp_fsm.c | After `MLACP(csm).current_state++;` before `break;` | `mlacp_sync_send_all_info_handler` |
| MlacpSendSyncRequest | mlacp_fsm.c | After `MLACP(csm).wait_for_sync_data = 1;` (2nd occurrence) | `mlacp_stage_sync_request_handler` |
| MlacpReceiveSyncDone | mlacp_fsm.c | After `MLACP(csm).current_state++;` (2nd occurrence) | `mlacp_stage_sync_request_handler` |
| MlacpSendSyncRequestFromExchange | mlacp_fsm.c | After `iccp_csm_send` in need_to_sync block | `mlacp_exchange_handler` |
| MlacpReceiveNAK (SysConfig) | mlacp_fsm.c | After `MLACP(csm).node_id--;` | `mlacp_sync_recv_nak_handler` |
| MlacpReceiveNAK (Other) | mlacp_fsm.c | After `MLACP(csm).need_to_sync = 1;` | `mlacp_sync_recv_nak_handler` |
| ReceiveSysConfig | mlacp_sync_update.c | After `MLACP(csm).node_id++;` | `mlacp_fsm_update_system_conf` |
| ReceiveHeartbeat | mlacp_sync_update.c | After `time(&csm->heartbeat_update_time);` | `mlacp_fsm_update_heartbeat` |
| PeerWarmBoot | mlacp_sync_update.c | After `time(&csm->peer_warm_reboot_time);` | `mlacp_fsm_update_warmboot` |
| HeartbeatTimeout | scheduler.c | Before `scheduler_session_disconnect_handler(csm);` | `heartbeat_check` |
| SessionDisconnect | scheduler.c | After `iccp_csm_status_reset(csm, 0);` | `scheduler_session_disconnect_handler` |
| TcpConnect | test_harness.c | Emitted by test driver | Test setup (spec connects both peers atomically) |
| IccpBecomeOperational | test_harness.c | Emitted by test driver | Test setup |

## How to Add a New Field to an Event

1. Edit `tla_trace.h` — add parameter to the appropriate `tla_trace_emit_*` function
2. Edit `tla_trace.c` — add the field to the JSON fprintf in the function body
3. At the instrumentation point, pass the new value to the emit call
4. Rebuild: `cd artifact/.../src && make -f Makefile.test`

## How to Add a New Event Type

1. Copy an existing `tla_trace_emit()` call pattern from the instrumented source
2. Add the emit call at the desired location in the source file
3. Use the pattern-based approach in `apply.sh` (see `insert_after_pattern` or `insert_before_pattern`)
4. Add the corresponding `Trace*` action wrapper in `Trace.tla`
5. Add it to the `TraceNext` disjunction

## How to Move a Capture Point (before/after)

Use `insert_before_pattern` instead of `insert_after_pattern` in `apply.sh`, or change the target pattern string.

## How to Rebuild and Re-run

```bash
cd .specula-output
bash harness/apply.sh          # re-apply instrumentation (auto-cleans first)
cd artifact/sonic-buildimage/src/iccpd/src
make -f Makefile.test clean && make -f Makefile.test -j$(nproc)
./iccpd_test ../../../../../../traces
```

Or use the one-command script:
```bash
cd .specula-output && bash harness/run.sh
```

## Key Byte-Order Note

The iccpd message wire format uses `htons()` for header fields. The real receive path converts via:
1. `iccp_csm_enqueue_msg()` — converts `LDPHdr.msg_type` with `ntohs`
2. `app_csm_enqueue_msg()` — converts `ICCParameter.type` with `ntohs`

The test harness routes through `iccp_csm_enqueue_msg()` to preserve this conversion. If you bypass this (e.g., calling `mlacp_enqueue_msg()` directly), header field comparisons in the FSM code will fail due to byte-order mismatch.

## Events Not Yet Instrumented

These events exist in Trace.tla but don't appear in current traces:

- **MlacpReceiveSyncRequestInExchange**: Needs conditional emit in `mlacp_sync_send_all_info_handler` when caller state was EXCHANGE (currently emits `MlacpStageSendAllInfo` for all states)
- **MlacpSendNAK**: Needs instrumentation in `iccp_csm_prepare_nak_msg`
- **LocalMacLearn/Age, MacUpdateFromSyncd**: Needs MAC operation test scenarios
- **ReceivePeerMac{Add,AddNew,Del}**: Needs MAC sync test scenarios
- **PortDown/PortUp**: Needs port state change test scenarios
- **SendWarmBoot/WarmBootTimeout**: Needs warm boot test scenarios
- **HeartbeatTimeout**: Needs timer manipulation in test harness

## Trace Validation Notes

- Use `Trace_test.cfg` (with `SPECIFICATION TraceSpec`) instead of `Trace.cfg` for validation
- Run with `-deadlock` flag: `java -cp ... tlc2.TLC -deadlock -config Trace_test.cfg Trace.tla`
- The spec's Init non-deterministically assigns roles. Only paths with the correct role assignment (matching the trace) will succeed
- Set `JSON=../traces/handshake.ndjson` environment variable for trace file

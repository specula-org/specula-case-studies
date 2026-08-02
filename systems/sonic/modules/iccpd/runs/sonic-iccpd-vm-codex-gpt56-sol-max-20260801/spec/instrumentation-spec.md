# Instrumentation Specification: iccpd

This document is the handoff from the TLA+ model to trace instrumentation for
SONiC iccpd revision 9df8ccbf72c31948741b5554d09c38ac6c1ec6e9. The system is
Category A, so the harness emits one globally ordered NDJSON trace.

## Section 1: Trace event schema

### Event envelope

Every line is one JSON object with this shape. Every state field is mandatory;
Trace.tla intentionally has no conditional field checks.

    {
      "tag": "trace",
      "timestamp": "<monotonic-or-controller-sequence>",
      "event": {
        "name": "<exact spec action name>",
        "nid": "n1",
        "args": {
          "up": false,
          "version": -1
        },
        "state": {
          "sessionUp": true,
          "crashed": false,
          "disconnectPC": "Idle",
          "warmAnnounced": false,
          "graceArmed": false,
          "graceAge": 0,
          "cleanupDone": true,
          "recoveryPending": false,
          "startupPC": "Running",
          "kernelTruth": 1,
          "observedState": 1,
          "snapshotReady": true,
          "advertisedState": 1,
          "resyncPending": false,

          "syncEpoch": 0,
          "syncPhase": "Exchange",
          "outstandingReq": -1,
          "responderEpoch": -1,
          "syncSendStep": "Idle",
          "activeEnvelope": -1,
          "configEpoch": -1,
          "aggConfigEpoch": -1,
          "stateEpoch": -1,
          "syncComplete": 0,
          "dirtyVersion": -1,
          "peerVersion": 1,
          "envelopeViolation": false,
          "configOrderViolation": false,
          "legalResyncActive": false,
          "errorReason": "None",

          "schedulerEnabled": true,
          "streamState": "Idle",
          "sessionActivity": 0,
          "protocolProgress": 0,
          "heartbeatAge": 0,
          "nonProgressTraffic": false,
          "ignoredAppFrames": 0,
          "syncdConnected": true,
          "syncdFdPositive": true,

          "lagGen": 0,
          "localLagUp": true,
          "lagDirty": false,
          "peerKnownGen": 0,
          "peerLagUp": true,
          "peerInterfaceKnown": true,
          "isolationDesired": true,
          "isolationPendingGen": -1,
          "isolationAppliedEnabled": true,
          "isolationAppliedGen": 0,
          "trafficEnabled": true,
          "trafficApplyPending": "None",
          "ackPending": -1,
          "ackGen": 0,

          "outWireDepth": 0,
          "inWireDepth": 0,
          "inboxDepth": 0,
          "peerInboxDepth": 0,
          "txContext": "None",
          "txKind": "None",
          "sendOutcome": "None"
        }
      }
    }

Use -1 for NoEpoch, NoVersion, and NoGen. The strings in all enum fields must
match base.tla exactly. The args object is always present; use up=false and
version=-1 when an action has no parameter.

### State field mapping

The model intentionally includes both directly readable C state and trace-only
shadow/monitor state. Shadow fields must be updated only by the tracer; they
must not affect iccpd behavior.

| Trace field | TLA+ state | Implementation source / derivation |
|---|---|---|
| sessionUp | recovery[i].sessionUp | csm->sock_fd > 0 plus operational application/session hook |
| crashed | recovery[i].crashed | test supervisor process lifecycle |
| disconnectPC | recovery[i].disconnectPC | tracer shadow: Idle, Detected after socket close, Handled after peer-disconnect branch |
| warmAnnounced | recovery[i].warmAnnounced | csm->peer_warm_reboot_time != 0 |
| graceArmed | recovery[i].graceArmed | csm->warm_reboot_disconn_time != 0 |
| graceAge | recovery[i].graceAge | bounded logical clock derived from warm_reboot_disconn_time |
| cleanupDone | recovery[i].cleanupDone | tracer shadow set after mlacp_peer_disconn_handler ordinary tail |
| recoveryPending | recovery[i].recoveryPending | tracer obligation shadow set at disconnect, cleared only by reconnect/ordinary cleanup |
| startupPC | recovery[i].startupPC | tracer shadow around scheduler_init, neighbor dump, and VLAN membership |
| kernelTruth | recovery[i].kernelTruth | abstract version of the selected kernel object queried by the harness |
| observedState | recovery[i].observedState | abstract version in iccpd ARP/ND/FDB cache |
| snapshotReady | recovery[i].snapshotReady | tracer barrier after required interface/VLAN reconstruction |
| advertisedState | recovery[i].advertisedState | last abstract object version passed to a positive peer write |
| resyncPending | recovery[i].resyncPending | sys->need_sync_netlink_again |
| syncEpoch | sync[i].epoch | tracer monotonic counter incremented for each prepared request |
| syncPhase | sync[i].phase | MLACP(csm).current_state mapped to Init/Stage1/Stage2/Exchange/Error |
| outstandingReq | sync[i].outstanding | tracer semantic request epoch; wire req_num remains zero |
| responderEpoch | sync[i].responderEpoch | tracer provenance copied from dequeued request |
| syncSendStep | sync[i].sendStep | MLACP(csm).sync_state plus Start/Object abstraction |
| activeEnvelope | sync[i].activeEnvelope | tracer provenance from accepted Start |
| configEpoch | sync[i].configEpoch | tracer epoch of last accepted system config |
| aggConfigEpoch | sync[i].aggConfigEpoch | tracer epoch of last accepted aggregation config |
| stateEpoch | sync[i].stateEpoch | tracer epoch of last accepted aggregation state |
| syncComplete | sync[i].complete | tracer semantic completion attributed at End |
| dirtyVersion | sync[i].dirtyVersion | selected object's queued delta version, or -1 |
| peerVersion | sync[i].peerVersion | selected peer object version accepted into local cache |
| envelopeViolation | sync[i].envelopeViolation | tracer monitor using semantic frame/request provenance |
| configOrderViolation | sync[i].configOrderViolation | tracer monitor for config-before-state within the semantic epoch |
| legalResyncActive | sync[i].legalResyncActive | tracer shadow set when SyncReq is handled in Exchange |
| errorReason | sync[i].errorReason | tracer shadow; LegalResyncAdvance for Exchange++ caused by full-response helper |
| schedulerEnabled | runtime[i].schedulerEnabled | false while the sole event loop is inside modeled blocking read/retry |
| streamState | runtime[i].streamState | tracer read shim: Idle/PartialHeader/BodyRetry |
| sessionActivity | runtime[i].sessionActivity | saturating count of complete peer frames |
| protocolProgress | runtime[i].protocolProgress | saturating count of modeled mLACP handler progress |
| heartbeatAge | runtime[i].heartbeatAge | bounded logical equivalent of now-heartbeat_update_time |
| nonProgressTraffic | runtime[i].nonProgressTraffic | test-controller source mode |
| ignoredAppFrames | runtime[i].ignoredAppFrames | saturating shadow of csm->app_csm.app_msg_list growth |
| syncdConnected | runtime[i].syncdConnected | actual sidecar socket health from test shim, not fd sign |
| syncdFdPositive | runtime[i].syncdFdPositive | sys->sync_fd > 0 |
| lagGen | lag[i].gen | tracer counter incremented on each selected LAG up/down transition |
| localLagUp | lag[i].localUp | local_if->po_active |
| lagDirty | lag[i].dirty | local_if->changed |
| peerKnownGen | lag[i].peerKnownGen | semantic generation of last matched peer state frame |
| peerLagUp | lag[i].peerUp | peer_if->po_active |
| peerInterfaceKnown | lag[i].peerInterfaceKnown | matching PIF lookup result |
| isolationDesired | lag[i].isolationDesired | local_if->isolate_to_peer_link |
| isolationPendingGen | lag[i].isolationPendingGen | tracer shadow between desired mutation and external return |
| isolationAppliedEnabled | lag[i].isolationAppliedEnabled | external-effect shadow updated only on proven success |
| isolationAppliedGen | lag[i].isolationAppliedGen | generation associated with proven successful isolation |
| trafficEnabled | lag[i].trafficEnabled | inverse of local_if->is_traffic_disable, confirmed by sidecar return |
| trafficApplyPending | lag[i].trafficApplyPending | tracer shadow None/Enable/Disable around external call |
| ackPending | lag[i].ackPending | tracer semantic generation awaiting ACK send |
| ackGen | lag[i].ackGen | semantic provenance of last received ACK; not a wire field |
| outWireDepth / inWireDepth | wire lengths | logical frame queue maintained by send/delivery hooks |
| inboxDepth / peerInboxDepth | inbox lengths | decoded logical receive queue maintained by delivery/handler hooks |
| txContext / txKind | txContext/txFrame | tracer shadow from prepare until the matching send-result event |
| sendOutcome | sendOutcome | Full, Partial, Failed, or None from write shim |

### Frame provenance

The wire protocol does not carry the model's epoch or generation. The harness
must attach a trace-only frame identifier at preparation, preserve FIFO order
per TCP direction, and associate send/delivery/receive events with that
identifier. It then derives semantic epoch/gen for shadow state. This metadata
must never be placed on the real socket.

## Section 2: Action-to-code mapping

Every row is one spec action and one exact event name. “Common state” means the
entire mandatory state object above. The trigger is the logical post-state
boundary used by Trace.tla.

| # | Spec action / event name | Code location | Trigger point | Fields and notes |
|---:|---|---|---|---|
| 1 | mlacp_sync_send_warmboot_flag | scheduler.c:412-430 | After mlacp_prepare_for_warm_reboot succeeds and before iccp_csm_send | Common state; txContext=Warmboot, txKind=Warmboot |
| 2 | mlacp_fsm_update_warmboot | mlacp_sync_update.c:1342-1350 | After time(&csm->peer_warm_reboot_time) | Common state; consume the delivered Warmboot shadow frame |
| 3 | scheduler_session_disconnect_handler | scheduler.c:831-856 | After scheduler_csm_socket_cleanup, before mlacp_peer_disconn_handler; use only for external/session-loss cause | Common state; set disconnectPC=Detected and recoveryPending=true |
| 4 | mlacp_peer_disconn_handler_Grace | mlacp_link_handler.c:2376-2389 | After warm marker clear and warm_reboot_disconn_time set, immediately before return | Common state |
| 5 | mlacp_peer_disconn_handler_Cleanup | mlacp_link_handler.c:2391-2439 | At ordinary handler tail after remote-interface cleanup | Common state |
| 6 | iccp_csm_status_reset | iccp_csm.c:129-166; scheduler.c:851-853 | Immediately after iccp_csm_status_reset returns | Common state; logical TCP/inbox queues for this sole pair are zero |
| 7 | mlacp_fsm_transit_WarmTimeout | mlacp_fsm.c:935-965 | After the timeout branch calls ordinary peer-disconnect handling | Common state; emit only if the branch is genuinely reached |
| 8 | system_finalize_Crash | system.c:94-173 | Synthesized by the supervisor after process death/descriptor close | Common state from supervisor plus tracer shadow; no in-process logger is assumed |
| 9 | scheduler_init_Restart | system.c:60-92,175-190; scheduler.c:375-395 | First tracer hook after fresh System/CSM construction, before neighbor dump | Common state |
| 10 | iccp_neigh_get_init | scheduler.c:383-395; iccp_ifm.c:188-268,448-528 | After the one startup neighbor dump returns | Common state |
| 11 | iccp_mclagsyncd_vlan_mbr_update_handler | mlacp_link_handler.c:3295-3324 | After all VLAN membership entries in the message are applied | Common state |
| 12 | do_arp_learn_from_kernel | iccp_ifm.c:116-305,407-588 | After selected ARP/ND cache entry and delta queue are updated | Common state |
| 13 | iccp_netlink_route_sock_event_handler_Error | iccp_netlink.c:2059-2075 | Immediately after need_sync_netlink_again=1 | Common state |
| 14 | iccp_netlink_sync_again | iccp_netlink.c:2027-2056 | After flags are cleared and GETLINK/team work returns | Common state |
| 15 | iccp_csm_transit_Reconnect | iccp_csm.c:297-367; app_csm.c:85-95; mlacp_fsm.c:1008-1015 | After app becomes operational and mLACP enters Stage1/resync queues are populated | Common state |
| 16 | mlacp_stage_sync_request_handler | mlacp_fsm.c:1497-1517; mlacp_sync_prepare.c:49-98 | After request buffer preparation and semantic outstanding assignment, before iccp_csm_send | Common state; txKind=SyncReq |
| 17 | mlacp_exchange_handler_PrepareResync | mlacp_fsm.c:1544-1576 | After need_to_sync is cleared and request buffer prepared, before write | Common state; txKind=SyncReq |
| 18 | mlacp_sync_recv_syncReq | mlacp_fsm.c:557-570,1296-1340 | Logical hook after request dequeue/semantic provenance capture and immediately before send-all loop | Common state; shadow inbox is consumed at this hook |
| 19 | mlacp_sync_send_all_info_handler_Prepare | mlacp_fsm.c:1393-1463; sender helpers at 195-440 | After each Start/config/state/object/End buffer is prepared, before its write | Common state; txKind identifies current stage |
| 20 | mlacp_sync_sender_handler_SkipObject | mlacp_fsm.c:260-366,1393-1455 | When abstract MAC/ARP/ND delta queues are empty, after helpers return and before sender stage advances | Common state |
| 21 | mlacp_sync_recv_syncData_Start | mlacp_fsm.c:538-550 | After Start flag processing and semantic-envelope shadow update | Common state |
| 22 | mlacp_sync_recv_sysConf | mlacp_fsm.c:447-486,1296-1311 | After system config mutation succeeds/returns | Common state |
| 23 | mlacp_sync_recv_aggConf | mlacp_fsm.c:488-505,1296-1328 | After aggregation config mutation succeeds/returns | Common state |
| 24 | mlacp_sync_recv_aggState | mlacp_fsm.c:508-535,1296-1332 | After abstract aggregation-state receipt used by sync envelope, excluding the separate LAG ACK path event | Common state |
| 25 | mlacp_sync_recv_ObjectData | mlacp_fsm.c:1296-1359; mlacp_sync_update.c:843-1252 | After selected MAC/ARP/ND object is accepted into local peer view | Common state |
| 26 | mlacp_sync_recv_syncData_End | mlacp_fsm.c:538-568,1497-1517 | After wait_for_sync_data clears and requester stage increment is applied | Common state |
| 27 | mlacp_portchannel_state_handler | mlacp_link_handler.c:2067-2099,287-305,1304-1354 | Logical hook after generation/local state/dirty update and before separate external traffic result | Common state plus args.up |
| 28 | mlacp_exchange_handler_PreparePortState | mlacp_fsm.c:1634-1645 | After Aggport-state buffer preparation, before iccp_csm_send | Common state; txKind=PortState |
| 29 | mlacp_fsm_update_Aggport_state | mlacp_sync_update.c:165-210; mlacp_fsm.c:508-534 | Logical hook after match/desired/pending shadows are set, before external isolation result and ACK prepare | Common state |
| 30 | update_peerlink_isolate_from_all_csm_lif_Apply | mlacp_link_handler.c:1021-1220 | After syncd/kernel/STATE_DB isolation success is proved by shims | Common state |
| 31 | update_peerlink_isolate_from_all_csm_lif_Fail | mlacp_link_handler.c:1021-1220 | After any modeled syncd/system/helper isolation failure or ignored nonzero result | Common state |
| 32 | mlacp_fsm_send_if_up_ack | mlacp_fsm.c:1676-1709; mlacp_tlv.h:447-470 | After ACK buffer preparation, before iccp_csm_send | Common state; txKind=IfUpAck |
| 33 | mlacp_fsm_recv_if_up_ack | mlacp_fsm.c:759-793 | Logical hook after current po_active check sets Enable pending, before sidecar result | Common state |
| 34 | mlacp_link_disable_traffic_distribution_Success | mlacp_link_handler.c:3588-3613 | After mlacp_link_set_traffic_dist_mode returns 0 and is_traffic_disable becomes true | Common state |
| 35 | mlacp_link_disable_traffic_distribution_Fail | mlacp_link_handler.c:3588-3613 | After nonzero disable result; is_traffic_disable remains unchanged | Common state |
| 36 | mlacp_link_enable_traffic_distribution_Success | mlacp_link_handler.c:3622-3638 | After enable returns 0 and is_traffic_disable becomes false | Common state |
| 37 | mlacp_link_enable_traffic_distribution_Fail | mlacp_link_handler.c:3622-3638 | After nonzero enable result; is_traffic_disable remains unchanged | Common state |
| 38 | mlacp_peer_mlag_intf_delete_handler | mlacp_link_handler.c:2143-2168 | After matching PIF removal | Common state |
| 39 | mlacp_fsm_update_Agg_conf | mlacp_sync_update.c:85-158 | After peer interface create/find succeeds | Common state |
| 40 | scheduler_csm_read_callback_Complete | scheduler.c:129-253; iccp_netlink.c:2225-2235 | In iccp_handle_events after callback succeeds and heartbeat update completes, before mLACP handler | Common state; advance logical source wire and destination inbox |
| 41 | scheduler_csm_read_callback_Corrupt | scheduler.c:172-239 | At injected/observed corrupt partial-frame transition into body retry | Common state |
| 42 | scheduler_csm_read_callback_PartialHeader | scheduler.c:129-170 | In recv shim after 1-7 header bytes arrive and before the next blocking recv | Common state |
| 43 | scheduler_csm_read_callback_ReadError | scheduler.c:155-167,193-257 | After EOF/error releases blocked read and before the peer-disconnect branch | Common state; use this cause instead of also emitting scheduler_session_disconnect_handler |
| 44 | app_csm_EnableNonProgressTraffic | app_csm.c:100-145 | Test-controller event immediately before it begins the unsupported-frame stream | Common state |
| 45 | iccp_csm_send_NonProgress | iccp_csm.c:245-281; app_csm.c:122-145 | After each full write of the selected unsupported APP frame | Common state |
| 46 | app_csm_enqueue_msg_NonProgress | app_csm.c:100-166 | After insertion into app_msg_list | Common state; increment ignored backlog shadow |
| 47 | scheduler_transit_fsm_Tick | scheduler.c:102-126,462-486 | Once per harness-controlled logical timer tick after the scheduler reaches FSM transit | Common state |
| 48 | heartbeat_check | scheduler.c:74-87 | After timeout detection establishes disconnect shadow, before invoking the split peer-disconnect path | Common state; do not also emit action 3 for this cause |
| 49 | iccp_mclagsyncd_msg_handler_EOF | mlacp_link_handler.c:3350-3417; iccp_netlink.c:2212-2215 | In caller after handler returns MCLAG_ERROR with EOF while sys->sync_fd is still positive | Common state |
| 50 | scheduler_loop_ReconnectSyncd | scheduler.c:469-474 | After iccp_connect_syncd succeeds on the fd<=0 branch | Common state |
| 51 | iccp_csm_send_Full | iccp_csm.c:245-281 plus caller sites mlacp_fsm.c:195-440,1438-1463,1497-1517,1569-1645,1676-1709 and scheduler.c:412-430 | After rc==msg_len and the immediate caller bookkeeping represented by FinishSend has executed | Common state; outcome Full |
| 52 | iccp_csm_send_Partial | Same as action 51 | After 0<rc<msg_len and immediate caller bookkeeping | Common state; outcome Partial; logical wire frame valid=false |
| 53 | iccp_csm_send_Failed | Same as action 51 | After rc<=0 and immediate caller bookkeeping | Common state; outcome Failed; no logical wire append |
| 54 | iccp_netlink_ObjectUpdate | iccp_netlink.c:668-1070; mlacp_link_handler.c:2654-2925 | After selected kernel/cache version and dirty delta are updated | Common state plus args.version |

### Send-result hook requirement

Actions 51-53 include the immediate caller behavior after iccp_csm_send returns:
full-response stage advancement, destructive delta removal already performed at
prepare, and the PortChannel changed-flag rule that treats any positive rc as
success. A logger placed only inside iccp_csm_send fires too early. Implement a
small trace wrapper/macro at every modeled call site, or defer its event until
that caller's immediate bookkeeping is complete. The wrapper must preserve the
real return value and behavior exactly.

## Section 3: Special considerations

### 3.1 Bootstrap

TraceInit represents an already stable pair: both nodes are in Exchange,
selected snapshot/object version is 1 on both sides, isolation for generation
0 is applied, and traffic is enabled. Start trace capture only after reaching
that barrier, or emit a separate normalization preamble before the first event.
Node IDs must be exactly n1 and n2 unless Trace.cfg is changed consistently.

### 3.2 Single global ordering

iccpd is single-threaded per process, but the two peer processes need a common
order. The test controller should assign the final sequence number. Preserve
send-before-delivery and per-direction FIFO causality; when two local events
are otherwise concurrent, either controller order is valid if it respects
those edges.

### 3.3 Split actions inside one C call stack

The model deliberately exposes failure boundaries that execute in one event
loop call stack: disconnect detection/grace/reset, peer state/side effect/ACK,
ACK receive/traffic apply, and buffer prepare/write/caller bookkeeping. Emit
the listed logical events at the specified internal hook points. Do not replace
them with one composite event.

### 3.4 Ghost epoch and generation

sync request number is really zero and IF_UP ACK really has no generation.
Epoch/gen fields are trace-only provenance maintained by the harness. They
must never strengthen receive conditions or alter packets. Their purpose is
to let Trace.tla determine whether the implementation accepted stale intent.

### 3.5 External applied state

isolationAppliedEnabled/isolationAppliedGen and trafficEnabled must reflect
confirmed external results, not merely desired flags. Wrap the syncd write,
ebtables system call, STATE_DB helper, and traffic-mode helper so the event
records the actual return. Where production code ignores a return, the tracer
records it but leaves production control flow untouched.

### 3.6 Blocking reads and process death

PartialHeader and BodyRetry events require a socket/read shim because no code
runs after entering a truly blocking recv. system_finalize_Crash is emitted by
the supervisor because a killed process cannot log a post-crash event. The
supervisor and restarted tracer must retain the ghost obligation/frame ledger.

### 3.7 Serialization

- Use JSON booleans, not 0/1, for Boolean fields.
- Encode NoEpoch, NoVersion, and NoGen as -1.
- Use exact enum spelling from base.tla.
- Saturate logical counters at Trace.cfg MaxProgress.
- The default trace path is ../traces/trace.ndjson. Set Trace.cfg JSONPath (or
  the runner's equivalent IOEnv.JSON override) for per-run files.

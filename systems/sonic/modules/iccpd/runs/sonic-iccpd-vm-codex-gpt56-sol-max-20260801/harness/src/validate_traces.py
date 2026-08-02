#!/usr/bin/env python3
"""Strict structural checks and instrumentation coverage for iccpd traces."""

from __future__ import annotations

import json
import pathlib
import sys


STATE_FIELDS = {
    "sessionUp", "crashed", "disconnectPC", "warmAnnounced", "graceArmed",
    "graceAge", "cleanupDone", "recoveryPending", "startupPC",
    "kernelTruth", "observedState", "snapshotReady", "advertisedState",
    "resyncPending", "syncEpoch", "syncPhase", "outstandingReq",
    "responderEpoch", "syncSendStep", "activeEnvelope", "configEpoch",
    "aggConfigEpoch", "stateEpoch", "syncComplete", "dirtyVersion",
    "peerVersion", "envelopeViolation", "configOrderViolation",
    "legalResyncActive", "errorReason", "schedulerEnabled", "streamState",
    "sessionActivity", "protocolProgress", "heartbeatAge",
    "nonProgressTraffic", "ignoredAppFrames", "syncdConnected",
    "syncdFdPositive", "lagGen", "localLagUp", "lagDirty", "peerKnownGen",
    "peerLagUp", "peerInterfaceKnown", "isolationDesired",
    "isolationPendingGen", "isolationAppliedEnabled", "isolationAppliedGen",
    "trafficEnabled", "trafficApplyPending", "ackPending", "ackGen",
    "outWireDepth", "inWireDepth", "inboxDepth", "peerInboxDepth",
    "txContext", "txKind", "sendOutcome",
}

TRACE_ACTIONS = {
    "mlacp_sync_send_warmboot_flag", "mlacp_fsm_update_warmboot",
    "scheduler_session_disconnect_handler",
    "mlacp_peer_disconn_handler_Grace",
    "mlacp_peer_disconn_handler_Cleanup", "iccp_csm_status_reset",
    "mlacp_fsm_transit_WarmTimeout", "system_finalize_Crash",
    "scheduler_init_Restart", "iccp_neigh_get_init",
    "iccp_mclagsyncd_vlan_mbr_update_handler", "do_arp_learn_from_kernel",
    "iccp_netlink_route_sock_event_handler_Error", "iccp_netlink_sync_again",
    "iccp_csm_transit_Reconnect", "mlacp_stage_sync_request_handler",
    "mlacp_exchange_handler_PrepareResync", "mlacp_sync_recv_syncReq",
    "mlacp_sync_send_all_info_handler_Prepare",
    "mlacp_sync_sender_handler_SkipObject",
    "mlacp_sync_recv_syncData_Start", "mlacp_sync_recv_sysConf",
    "mlacp_sync_recv_aggConf", "mlacp_sync_recv_aggState",
    "mlacp_sync_recv_ObjectData", "mlacp_sync_recv_syncData_End",
    "mlacp_portchannel_state_handler",
    "mlacp_exchange_handler_PreparePortState",
    "mlacp_fsm_update_Aggport_state",
    "update_peerlink_isolate_from_all_csm_lif_Apply",
    "update_peerlink_isolate_from_all_csm_lif_Fail",
    "mlacp_fsm_send_if_up_ack", "mlacp_fsm_recv_if_up_ack",
    "mlacp_link_disable_traffic_distribution_Success",
    "mlacp_link_disable_traffic_distribution_Fail",
    "mlacp_link_enable_traffic_distribution_Success",
    "mlacp_link_enable_traffic_distribution_Fail",
    "mlacp_peer_mlag_intf_delete_handler", "mlacp_fsm_update_Agg_conf",
    "scheduler_csm_read_callback_Complete",
    "scheduler_csm_read_callback_Corrupt",
    "scheduler_csm_read_callback_PartialHeader",
    "scheduler_csm_read_callback_ReadError",
    "app_csm_EnableNonProgressTraffic", "iccp_csm_send_NonProgress",
    "app_csm_enqueue_msg_NonProgress", "scheduler_transit_fsm_Tick",
    "heartbeat_check", "iccp_mclagsyncd_msg_handler_EOF",
    "scheduler_loop_ReconnectSyncd", "iccp_csm_send_Full",
    "iccp_csm_send_Partial", "iccp_csm_send_Failed",
    "iccp_netlink_ObjectUpdate",
}

INSTRUMENTED_ACTIONS = {
    "mlacp_sync_send_warmboot_flag", "mlacp_fsm_update_warmboot",
    "scheduler_session_disconnect_handler",
    "mlacp_peer_disconn_handler_Grace",
    "mlacp_peer_disconn_handler_Cleanup", "iccp_csm_status_reset",
    "mlacp_portchannel_state_handler",
    "mlacp_link_disable_traffic_distribution_Success",
    "mlacp_link_disable_traffic_distribution_Fail",
    "mlacp_link_enable_traffic_distribution_Success",
    "mlacp_link_enable_traffic_distribution_Fail",
    "scheduler_csm_read_callback_Complete",
    "scheduler_csm_read_callback_Corrupt",
    "scheduler_csm_read_callback_PartialHeader",
    "scheduler_csm_read_callback_ReadError", "iccp_csm_send_Full",
    "iccp_csm_send_Partial", "iccp_csm_send_Failed",
}


def validate(path: pathlib.Path) -> set[str]:
    seen: set[str] = set()
    previous_ts = -1
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        raise ValueError(f"{path}: empty trace")

    for number, line in enumerate(lines, 1):
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{number}: invalid JSON: {exc}") from exc
        if record.get("tag") != "trace":
            raise ValueError(f"{path}:{number}: tag must be 'trace'")
        try:
            timestamp = int(record["timestamp"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"{path}:{number}: invalid real timestamp") from exc
        if timestamp <= previous_ts or timestamp < 1_000_000_000_000:
            raise ValueError(f"{path}:{number}: timestamp is not real/monotonic")
        previous_ts = timestamp

        event = record.get("event")
        if not isinstance(event, dict):
            raise ValueError(f"{path}:{number}: event must be an object")
        name = event.get("name")
        if name not in TRACE_ACTIONS:
            raise ValueError(f"{path}:{number}: unknown action {name!r}")
        if event.get("nid") not in {"n1", "n2"}:
            raise ValueError(f"{path}:{number}: invalid node ID")
        if set(event.get("args", {})) != {"up", "version"}:
            raise ValueError(f"{path}:{number}: args schema mismatch")
        state = event.get("state")
        if not isinstance(state, dict) or set(state) != STATE_FIELDS:
            missing = sorted(STATE_FIELDS - set(state or {}))
            extra = sorted(set(state or {}) - STATE_FIELDS)
            raise ValueError(
                f"{path}:{number}: state schema mismatch; "
                f"missing={missing}, extra={extra}"
            )
        seen.add(name)
    return seen


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} TRACE...", file=sys.stderr)
        return 2
    observed: set[str] = set()
    for raw_path in sys.argv[1:]:
        path = pathlib.Path(raw_path)
        actions = validate(path)
        observed.update(actions)
        print(f"{path.name}: valid NDJSON, {sum(1 for _ in path.open())} events")
    covered = sorted(INSTRUMENTED_ACTIONS & observed)
    uncovered = sorted(INSTRUMENTED_ACTIONS - observed)
    print(f"instrumented action coverage: {len(covered)}/{len(INSTRUMENTED_ACTIONS)}")
    print("covered: " + ", ".join(covered))
    if uncovered:
        print("documented-uncovered: " + ", ".join(uncovered))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

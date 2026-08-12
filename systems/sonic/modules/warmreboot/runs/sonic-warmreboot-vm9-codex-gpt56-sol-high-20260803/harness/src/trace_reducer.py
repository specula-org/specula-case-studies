#!/usr/bin/env python3
"""Fail-closed causal linearizer and TLA+ shadow-state reducer."""

import copy
import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

ASICS = ("asic0", "asic1")
COMPONENTS = ("orchagent", "xcvrd")
MAX_EPOCH = 8
MAX_IN_FLIGHT = 8

REQUIRED_OBSERVED = {
    "HandleRebootRequestAccept": {"method", "request_digest", "manager_status", "active", "thread_joinable"},
    "StartThreadLaunchFailure": {"request_digest", "active", "last_status", "thread_joinable"},
    "HostServiceIssueRebootAccept": {"request_digest", "dbus_return_status"},
    "HostServiceTransportFailure": {"request_digest", "exception_class", "active", "status"},
    "WaitForPlatformRebootStart": {"request_digest", "timer_started", "dbus_outcome"},
    "PlatformRebootDeadline": {"request_digest", "timer_stopped", "status", "failure_text"},
    "HandleRebootFinishJoinable": {"active", "manager", "joinable", "status"},
    "HandleRebootFinishNonJoinable": {"active", "manager", "joinable", "status"},
    "FastRebootBegin": {"request_digest", "reboot_type", "namespace_list"},
    "EnableWarmRestart": {"namespace", "command", "exit_code", "resulting_enable"},
    "RegisterWarmComponent": {"component", "service", "scope"},
    "WarmComponentReconciled": {"component", "namespace", "raw_value", "read_result"},
    "FinalizerTimeoutAsReady": {"component", "namespace", "marker", "raw_value"},
    "FinalizerDeadline": {"incomplete_components", "namespace", "iteration_count"},
    "FinalizeNamespace": {"namespace", "prior_warm_flag", "new_warm_flag", "command_exit"},
    "FinalizeGlobal": {"child_results", "prior_global_flag", "new_global_flag"},
    "SaveDatabase": {"exit_code", "saved_boot_id", "config_checksum"},
}


def initial_state() -> Dict[str, Any]:
    return {
        "backend": {
            "alive": True,
            "active": False,
            "manager": "idle",
            "requestEpoch": 0,
            "nextEpoch": 1,
            "dbusPhase": "none",
            "localTimer": False,
            "hostPending": False,
            "hostEpoch": 0,
            "hostStatus": "idle",
            "failureClass": "none",
            "failureCause": "none",
            "threadJoinable": False,
        },
        "shutdown": {
            "platformPhase": "idle",
            "rollbackEnabled": True,
            "producerState": {asic: "running" for asic in ASICS},
            "inFlight": {asic: 0 for asic in ASICS},
            "consumerState": {asic: "running" for asic in ASICS},
            "stoppedAtCommit": set(),
            "postCommitFailure": False,
        },
        "warm": {
            "bootEpoch": 0,
            "flagEpoch": {asic: 0 for asic in ASICS},
            "snapshotEpoch": {asic: 0 for asic in ASICS},
            "snapshotValidity": {asic: "none" for asic in ASICS},
            "snapshotSchema": {asic: "compatible" for asic in ASICS},
            "copyComplete": {asic: False for asic in ASICS},
            "snapshotQuiescent": {asic: False for asic in ASICS},
            "namespaceFailed": {asic: False for asic in ASICS},
            "restoreDecision": {asic: "none" for asic in ASICS},
            "restoreEpoch": {asic: 0 for asic in ASICS},
            "consumedSnapshotEpoch": {asic: 0 for asic in ASICS},
            "restoredEpoch": {component: 0 for component in COMPONENTS},
            "required": set(),
            "readiness": {component: "unknown" for component in COMPONENTS},
            "deadlineExpired": False,
            "finalizedNsEpoch": {asic: 0 for asic in ASICS},
            "finalizedEpoch": 0,
            "dbSavedEpoch": 0,
        },
    }


def json_value(value: Any) -> Any:
    if isinstance(value, set):
        return sorted(value)
    if isinstance(value, dict):
        return {key: json_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_value(item) for item in value]
    return value


def require_schema(raw: Dict[str, Any]) -> None:
    if raw.get("tag") != "raw" or not isinstance(raw.get("event"), dict):
        raise ValueError("collector input is not a raw event envelope")
    event = raw["event"]
    for field in ("name", "source", "process_instance", "local_seq", "monotonic_ns", "observed"):
        if field not in event:
            raise ValueError(f"raw event missing {field}: {event}")
    required = REQUIRED_OBSERVED.get(event["name"])
    if required is None:
        raise ValueError(f"unrecognized/unimplemented raw event {event['name']}")
    missing = required - set(event["observed"])
    if missing:
        raise ValueError(f"{event['name']} missing observed fields: {sorted(missing)}")
    if "asic" in event and event["asic"] not in ASICS:
        raise ValueError(f"unknown ASIC {event['asic']}")
    if "component" in event and event["component"] not in COMPONENTS:
        raise ValueError(f"unknown component {event['component']}")


def all_required_restored(state: Dict[str, Any]) -> bool:
    warm = state["warm"]
    return all(warm["restoredEpoch"][component] == warm["bootEpoch"] for component in warm["required"])


def apply_if_enabled(state: Dict[str, Any], raw: Dict[str, Any]) -> Optional[Set[str]]:
    event = raw["event"]
    name = event["name"]
    backend = state["backend"]
    shutdown = state["shutdown"]
    warm = state["warm"]
    asic = event.get("asic")
    component = event.get("component")

    if name == "HandleRebootRequestAccept":
        if not (backend["alive"] and backend["manager"] == "idle" and not backend["active"] and backend["nextEpoch"] <= MAX_EPOCH):
            return None
        backend.update(active=True, manager="in_progress", requestEpoch=backend["nextEpoch"],
                       nextEpoch=backend["nextEpoch"] + 1, dbusPhase="calling",
                       failureClass="none", failureCause="none", threadJoinable=True)
        return {"backend"}

    if name == "StartThreadLaunchFailure":
        if not (backend["alive"] and backend["manager"] == "idle" and not backend["active"] and backend["nextEpoch"] <= MAX_EPOCH):
            return None
        backend.update(active=True, manager="in_progress", requestEpoch=backend["nextEpoch"],
                       nextEpoch=backend["nextEpoch"] + 1, dbusPhase="finished",
                       failureClass="retriable", failureCause="thread_launch", threadJoinable=False)
        return {"backend"}

    if name == "HostServiceIssueRebootAccept":
        if not (backend["alive"] and backend["dbusPhase"] == "calling" and not backend["hostPending"]):
            return None
        backend.update(dbusPhase="delivered", hostPending=True,
                       hostEpoch=backend["requestEpoch"], hostStatus="accepted")
        return {"backend"}

    if name == "HostServiceTransportFailure":
        if not (backend["alive"] and backend["dbusPhase"] == "calling"):
            return None
        backend.update(dbusPhase="failed", failureClass="definitive", failureCause="transport")
        return {"backend"}

    if name == "WaitForPlatformRebootStart":
        if not (backend["alive"] and backend["dbusPhase"] == "delivered" and not backend["localTimer"]):
            return None
        backend["localTimer"] = True
        return {"backend"}

    if name == "PlatformRebootDeadline":
        if not (backend["alive"] and backend["localTimer"]):
            return None
        backend.update(localTimer=False, dbusPhase="finished", failureClass="definitive", failureCause="timeout")
        return {"backend"}

    if name == "HandleRebootFinishJoinable":
        if not (backend["alive"] and backend["dbusPhase"] in {"failed", "finished"} and backend["threadJoinable"]):
            return None
        backend.update(active=False, manager="idle", requestEpoch=0, threadJoinable=False)
        return {"backend"}

    if name == "HandleRebootFinishNonJoinable":
        if not (backend["alive"] and backend["dbusPhase"] == "finished" and not backend["threadJoinable"]):
            return None
        backend["manager"] = "idle"
        return {"backend"}

    if name == "FastRebootBegin":
        if not (backend["hostPending"] and backend["hostEpoch"] > 0 and shutdown["platformPhase"] == "idle"):
            return None
        shutdown["platformPhase"] = "precommit"
        warm.update(
            bootEpoch=backend["hostEpoch"], required=set(),
            restoredEpoch={component_name: 0 for component_name in COMPONENTS},
            readiness={component_name: "unknown" for component_name in COMPONENTS},
            deadlineExpired=False, finalizedNsEpoch={asic_name: 0 for asic_name in ASICS},
            finalizedEpoch=0, dbSavedEpoch=0,
            restoreDecision={asic_name: "none" for asic_name in ASICS},
            restoreEpoch={asic_name: 0 for asic_name in ASICS},
            consumedSnapshotEpoch={asic_name: 0 for asic_name in ASICS},
            namespaceFailed={asic_name: False for asic_name in ASICS},
        )
        return {"shutdown", "warm"}

    if name == "EnableWarmRestart":
        if not (asic in ASICS and shutdown["platformPhase"] == "precommit" and warm["flagEpoch"][asic] != warm["bootEpoch"]):
            return None
        warm["flagEpoch"][asic] = warm["bootEpoch"]
        return {"warm"}

    if name == "RegisterWarmComponent":
        if not (component in COMPONENTS and warm["bootEpoch"] > 0 and component not in warm["required"]):
            return None
        warm["required"].add(component)
        return {"warm"}

    if name == "WarmComponentReconciled":
        if not (component in warm["required"] and warm["readiness"][component] == "unknown"):
            return None
        warm["readiness"][component] = "ready"
        warm["restoredEpoch"][component] = warm["bootEpoch"]
        return {"warm"}

    if name == "FinalizerTimeoutAsReady":
        if not (component in warm["required"] and warm["readiness"][component] == "unknown"):
            return None
        warm["readiness"][component] = "timeout"
        return {"warm"}

    if name == "FinalizerDeadline":
        if not (warm["bootEpoch"] > 0 and not warm["deadlineExpired"]):
            return None
        warm["deadlineExpired"] = True
        return {"warm"}

    if name == "FinalizeNamespace":
        if not (asic in ASICS and warm["bootEpoch"] > 0 and
                warm["finalizedNsEpoch"][asic] != warm["bootEpoch"] and
                (warm["deadlineExpired"] or all_required_restored(state))):
            return None
        warm["finalizedNsEpoch"][asic] = warm["bootEpoch"]
        warm["flagEpoch"][asic] = 0
        return {"warm"}

    if name == "FinalizeGlobal":
        if not (warm["bootEpoch"] > 0 and
                all(warm["finalizedNsEpoch"][asic_name] == warm["bootEpoch"] for asic_name in ASICS) and
                warm["finalizedEpoch"] != warm["bootEpoch"]):
            return None
        warm["finalizedEpoch"] = warm["bootEpoch"]
        return {"warm"}

    if name == "SaveDatabase":
        if not (warm["finalizedEpoch"] == warm["bootEpoch"] and warm["dbSavedEpoch"] != warm["bootEpoch"]):
            return None
        warm["dbSavedEpoch"] = warm["bootEpoch"]
        return {"warm"}

    raise ValueError(f"no reducer for {name}")


def enrich(raw_events: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    for raw in raw_events:
        require_schema(raw)
    pending = sorted(
        copy.deepcopy(list(raw_events)),
        key=lambda item: (
            int(item["event"]["monotonic_ns"]),
            str(item["event"]["process_instance"]),
            int(item["event"]["local_seq"]),
        ),
    )
    state = initial_state()
    output: List[Dict[str, Any]] = []

    while pending:
        selected = None
        for index, raw in enumerate(pending):
            trial = copy.deepcopy(state)
            modified = apply_if_enabled(trial, raw)
            if modified is not None:
                selected = (index, raw, trial, modified)
                break
        if selected is None:
            summary = [item["event"]["name"] for item in pending]
            raise ValueError(f"no causally valid next event; pending={summary}; state={json_value(state)}")

        index, raw, state, modified = selected
        pending.pop(index)
        event = copy.deepcopy(raw["event"])
        event["trace_epoch"] = state["warm"]["bootEpoch"] or state["backend"]["requestEpoch"]
        event["state"] = {record: json_value(copy.deepcopy(state[record])) for record in sorted(modified)}
        output.append({"tag": "trace", "ts": raw.get("ts", event["monotonic_ns"]), "event": event})

    return output


def load_ndjson(path: Path) -> List[Dict[str, Any]]:
    with path.open(encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if line.strip()]


def write_ndjson(path: Path, records: Iterable[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as stream:
        for record in records:
            stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True))
            stream.write("\n")


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("raw", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    write_ndjson(args.output, enrich(load_ndjson(args.raw)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

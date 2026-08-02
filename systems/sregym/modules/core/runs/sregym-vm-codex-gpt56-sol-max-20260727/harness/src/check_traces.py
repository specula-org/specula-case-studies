#!/usr/bin/env python3
"""Schema, timestamp, and event-coverage checks for generated SREGym traces."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EVENTS = {
    "StartProblem",
    "LoadBaselineState",
    "BeginBaselineCapture",
    "ObserveBaseline",
    "PersistBaselineState",
    "DeployProblem",
    "InjectFault",
    "AdvanceToFirstStage",
    "SendSubmission",
    "DelayOrDuplicate",
    "ReceiveSubmission",
    "RetrySubmission",
    "ConductorSubmitAccept",
    "ConductorSubmitDuplicate",
    "ConductorSubmitLate",
    "Acknowledge",
    "BeginEvaluation",
    "BeginOracle",
    "CompleteOracle",
    "CompleteEvaluation",
    "AdvanceStageAfterEvaluation",
    "FinishEvaluationFuture",
    "AgentMitigate",
    "AgentTimeout",
    "AgentExit",
    "AgentExitWaitTimeout",
    "AgentExitAfterEvaluation",
    "FinishProblemCheck",
    "BeginCleanup",
    "CompleteRecovery",
    "ReconcileDelete",
    "ReconcileRestore",
    "CompleteCleanup",
    "NoiseManagerStart",
    "BeginNoiseApply",
    "CompleteNoiseApply",
    "NoiseLoopExit",
    "NoiseManagerStop",
    "NoiseManagerJoinComplete",
    "NoiseManagerJoinTimeout",
    "NoiseManagerCleanupRecorded",
    "NoiseManagerForceRemove",
    "NoiseManagerStopReturn",
    "AgentMutate",
    "Crash",
    "Restart",
    "ReplaceCluster",
    "RestartPod",
    "ReattachFault",
}

STATE_FIELDS = {
    "process_up",
    "run_gen",
    "stage",
    "stage_owner",
    "run_stage",
    "max_stage_rank",
    "waiting_for_agent",
    "deployed_run",
    "timeout_fired",
    "agent_exit_state",
    "done_runs",
    "results_version",
    "done_results_version",
    "eval_in_flight",
    "eval_run",
    "eval_stage",
    "eval_request",
    "eval_origin_run",
    "eval_origin_stage",
    "eval_phase",
    "cleanup_state",
    "cleanup_run",
    "submission_queue",
    "received_queue",
    "pending_acks",
    "accepted_by_stage",
    "graded_acceptances",
    "timed_out_acceptances",
    "request_status",
    "request_origin_run",
    "request_origin_stage",
    "request_retries",
    "cluster_gen",
    "baseline_gen",
    "baseline_complete",
    "observed_fields",
    "baseline_resources",
    "baseline_values",
    "baseline_capture_state",
    "baseline_authoritative",
    "persisted_baseline",
    "persisted_baseline_gen",
    "persisted_baseline_complete",
    "cluster_resources",
    "preexisting",
    "run_created",
    "resource_value",
    "pre_run_value",
    "delete_issued",
    "noise_epoch",
    "noise_run",
    "noise_running",
    "live_noise_epochs",
    "noise_epoch_run",
    "noise_loop_count",
    "apply_in_flight",
    "active_noise",
    "noise_stop_state",
    "noise_stop_owner",
    "fault_injected_runs",
    "fault_effective",
    "workload_healthy",
    "pod_gen",
    "reinjection_active",
    "reattach_pending",
    "oracle_state",
    "oracle_run",
    "oracle_stage",
    "oracle_passed",
    "quiescence_observed",
}


def check(path: Path) -> tuple[int, set[str]]:
    count = 0
    names: set[str] = set()
    previous_timestamp = 0
    previous_sequence = 0
    with path.open(encoding="utf-8") as stream:
        for line_number, raw_line in enumerate(stream, start=1):
            if not raw_line.strip():
                raise AssertionError(f"{path}:{line_number}: blank NDJSON line")
            item = json.loads(raw_line)
            if item.get("tag") != "trace":
                raise AssertionError(f"{path}:{line_number}: tag must be 'trace'")
            timestamp = item.get("timestamp_ns")
            if not isinstance(timestamp, int) or timestamp <= 1_000_000_000_000_000:
                raise AssertionError(f"{path}:{line_number}: timestamp_ns is not a real epoch-ns timestamp")
            if timestamp < previous_timestamp:
                raise AssertionError(f"{path}:{line_number}: timestamp moved backwards")
            previous_timestamp = timestamp
            sequence = item.get("sequence")
            if sequence != previous_sequence + 1:
                raise AssertionError(f"{path}:{line_number}: non-contiguous writer sequence")
            previous_sequence = sequence
            event = item.get("event")
            if not isinstance(event, dict):
                raise AssertionError(f"{path}:{line_number}: missing event object")
            name = event.get("name")
            if name not in EVENTS:
                raise AssertionError(f"{path}:{line_number}: unknown event {name!r}")
            if not isinstance(event.get("params"), dict):
                raise AssertionError(f"{path}:{line_number}: params must be an object")
            state = event.get("state")
            if not isinstance(state, dict) or set(state) != STATE_FIELDS:
                missing = sorted(STATE_FIELDS - set(state or {}))
                extra = sorted(set(state or {}) - STATE_FIELDS)
                raise AssertionError(
                    f"{path}:{line_number}: wrong full-state fields; missing={missing}, extra={extra}"
                )
            if len(state["run_stage"]) != 3 or len(state["noise_epoch_run"]) != 5:
                raise AssertionError(f"{path}:{line_number}: Trace.cfg array bounds are not respected")
            count += 1
            names.add(name)
    if count == 0:
        raise AssertionError(f"{path}: empty trace")
    return count, names


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_traces.py TRACE.ndjson [...]", file=sys.stderr)
        return 2
    covered: set[str] = set()
    for argument in sys.argv[1:]:
        path = Path(argument)
        count, names = check(path)
        covered.update(names)
        print(f"{path.name}: {count} valid events, {len(names)} event types")
    print(f"coverage: {len(covered)}/{len(EVENTS)} instrumented event types")
    print("covered: " + ", ".join(sorted(covered)))
    uncovered = EVENTS - covered
    if uncovered:
        print("uncovered (documented in INSTRUMENTATION.md): " + ", ".join(sorted(uncovered)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

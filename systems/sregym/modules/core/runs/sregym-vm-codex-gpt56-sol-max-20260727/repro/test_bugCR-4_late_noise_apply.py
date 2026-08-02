#!/usr/bin/env python3
"""CR-4 reproduction: an in-flight noise apply completes after stop cleanup.

Escalation:
  Level 0: report whether a real kubectl/cluster is available.
  Level 1: use public NoiseManager lifecycle calls with timing assistance at
           the Kubernetes command boundary to expose the late apply.
  Level 2: model the reachable Chaos Mesh controller effect of that legitimate
           PodChaos CR and feed it to the repository's real
           SustainedReadinessOracle consumer.

The timing adapter emits only Kubernetes states reachable from the manifest
that NoiseManager itself creates. No NoiseManager/oracle source is modified.
"""

from __future__ import annotations

import random
import shlex
import shutil
import subprocess
import sys
import threading
import time
import types
from pathlib import Path
from types import SimpleNamespace

import yaml


SPECULA_OUTPUT = Path(__file__).resolve().parents[1]
WORKTREE = SPECULA_OUTPUT / "confirmation" / "CR-4" / "worktree"
sys.path.insert(0, str(WORKTREE))


def level0_preflight() -> str:
    """Read-only Level-0 preflight for a real Kubernetes endpoint."""
    kubectl = shutil.which("kubectl")
    if kubectl is None:
        return "UNAVAILABLE: kubectl is not installed"
    try:
        probe = subprocess.run(
            [kubectl, "cluster-info"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"UNAVAILABLE: kubectl cluster-info failed: {type(exc).__name__}"
    if probe.returncode != 0:
        detail = (probe.stderr or probe.stdout).strip().splitlines()
        return f"UNAVAILABLE: no reachable cluster ({detail[0] if detail else 'unknown error'})"
    return "AVAILABLE"


class TimedKubernetesBoundary:
    """Small, stateful Kubernetes/Chaos-Mesh boundary for Levels 1 and 2.

    The first legitimate apply is delayed past NoiseManager's five-second
    join. When the accepted manifest is PodChaos/pod-failure, the adapter
    exposes the normal Kubernetes observation produced by that controller
    action: the selected pod remains Running but its container is not ready.
    """

    def __init__(self, first_apply_delay: float = 6.2):
        self.first_apply_delay = first_apply_delay
        self.apply_started = threading.Event()
        self._lock = threading.Lock()
        self._apply_count = 0
        self._resources: dict[tuple[str, str], dict] = {}
        self.command_log: list[tuple[float, str]] = []
        self.apply_completions: list[tuple[float, str, str, str]] = []
        self.force_scan_snapshots: list[tuple[str, int]] = []
        self.pod_ready = True

    def _record_command(self, command: str) -> None:
        with self._lock:
            self.command_log.append((time.monotonic(), command))

    def _resource_names(self, kind: str | None = None) -> list[str]:
        with self._lock:
            values = [
                f"{resource_kind}/{name}"
                for (resource_kind, name) in self._resources
                if kind is None or resource_kind.lower() == kind.lower()
            ]
        return sorted(values)

    def resources(self) -> list[str]:
        return self._resource_names()

    def exec_command(self, command: str, input_data=None):
        del input_data
        self._record_command(command)

        if command == "kubectl get ns chaos-mesh":
            return "chaos-mesh   Active\n"
        if command.startswith(
            "kubectl get pods -n chaos-mesh -l app.kubernetes.io/component=controller-manager"
        ):
            return "chaos-controller-manager-0   1/1   Running\n"
        if command.startswith("kubectl get crd"):
            return (
                "customresourcedefinition.apiextensions.k8s.io/"
                "podchaos.chaos-mesh.org\n"
                "customresourcedefinition.apiextensions.k8s.io/"
                "networkchaos.chaos-mesh.org\n"
            )

        if command.startswith("kubectl apply -f "):
            tokens = shlex.split(command)
            manifest_path = Path(tokens[tokens.index("-f") + 1])
            manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
            kind = manifest["kind"]
            name = manifest["metadata"]["name"]
            action = manifest["spec"]["action"]

            with self._lock:
                self._apply_count += 1
                apply_number = self._apply_count
            if apply_number == 1:
                self.apply_started.set()
                time.sleep(self.first_apply_delay)

            with self._lock:
                self._resources[(kind, name)] = manifest
                completed_at = time.monotonic()
                self.apply_completions.append((completed_at, kind, name, action))
                if kind == "PodChaos" and action in {"pod-failure", "pod-kill"}:
                    self.pod_ready = False
            return f"{kind.lower()}.chaos-mesh.org/{name} created\n"

        if command.startswith("kubectl get podchaos.chaos-mesh.org --all-namespaces"):
            names = self._resource_names("PodChaos")
            with self._lock:
                self.force_scan_snapshots.append(("podchaos", len(names)))
            return " ".join(f"chaos-mesh/{entry.split('/', 1)[1]}" for entry in names)

        if command.startswith("kubectl get networkchaos.chaos-mesh.org --all-namespaces"):
            names = self._resource_names("NetworkChaos")
            with self._lock:
                self.force_scan_snapshots.append(("networkchaos", len(names)))
            return " ".join(f"chaos-mesh/{entry.split('/', 1)[1]}" for entry in names)

        if command.startswith("kubectl delete "):
            tokens = shlex.split(command)
            kind, name = tokens[2], tokens[3]
            with self._lock:
                removed = self._resources.pop((kind, name), None)
                if removed and kind == "PodChaos":
                    self.pod_ready = True
            return f'{kind.lower()}.chaos-mesh.org "{name}" deleted\n'

        if command.startswith("kubectl get PodChaos ") or command.startswith(
            "kubectl get NetworkChaos "
        ):
            tokens = shlex.split(command)
            kind, name = tokens[2], tokens[3]
            with self._lock:
                exists = (kind, name) in self._resources
            return f"{kind.lower()}.chaos-mesh.org/{name}\n" if exists else ""

        if command.startswith("kubectl patch "):
            return ""

        raise AssertionError(f"Unexpected command from production NoiseManager: {command}")

    def list_pods(self, namespace: str):
        assert namespace == "hotel-reservation"
        with self._lock:
            ready = self.pod_ready
        state = SimpleNamespace(waiting=None, terminated=None)
        container = SimpleNamespace(name="frontend", ready=ready, state=state)
        pod = SimpleNamespace(
            metadata=SimpleNamespace(name="frontend-0"),
            status=SimpleNamespace(phase="Running", container_statuses=[container]),
        )
        return SimpleNamespace(items=[pod])


def load_production_classes(boundary: TimedKubernetesBoundary):
    """Import production classes while supplying their external dependency."""
    kubectl_module = types.ModuleType("sregym.service.kubectl")
    kubectl_module.KubeCtl = lambda: boundary
    sys.modules["sregym.service.kubectl"] = kubectl_module

    from sregym.generators.noise.manager import NoiseManager

    # The repository's sregym.conductor package initializer eagerly imports
    # the whole Python-3.12 application. This host has Python 3.10, while the
    # oracle module under test itself is compatible and has no such runtime
    # dependency. Expose the real package path without executing that unrelated
    # initializer, then import the production oracle file normally.
    import sregym

    conductor_package = types.ModuleType("sregym.conductor")
    conductor_package.__path__ = [str(WORKTREE / "sregym" / "conductor")]
    conductor_package.__package__ = "sregym.conductor"
    sys.modules["sregym.conductor"] = conductor_package
    setattr(sregym, "conductor", conductor_package)

    from sregym.conductor.oracles.sustained_readiness import SustainedReadinessOracle

    NoiseManager._instance = None
    return NoiseManager, SustainedReadinessOracle


def make_oracle(oracle_class, boundary, sustained_period: float):
    problem = SimpleNamespace(kubectl=boundary, namespace="hotel-reservation")
    return oracle_class(
        problem=problem,
        buffer_period=0.5,
        sustained_period=sustained_period,
        check_interval=0.1,
    )


def main() -> None:
    level0 = level0_preflight()
    print(f"LEVEL0_PREFLIGHT={level0}")

    boundary = TimedKubernetesBoundary()
    NoiseManager, SustainedReadinessOracle = load_production_classes(boundary)

    baseline = make_oracle(SustainedReadinessOracle, boundary, sustained_period=0.3).evaluate()
    print(f"BASELINE_ORACLE_SUCCESS={baseline['success']}")

    manager = NoiseManager()
    manager.set_problem_context({"namespace": "hotel-reservation", "app_name": "hotel-reservation"})

    # Normal random selection, made repeatable. Seed 1 selects
    # PodChaos/pod-failure first, so the in-flight apply itself is the harmful CR.
    random.seed(1)
    manager.start()
    if not boundary.apply_started.wait(timeout=2):
        raise AssertionError("NoiseManager did not reach its normal kubectl apply")
    original_worker = manager._background_thread
    if original_worker is None:
        raise AssertionError("NoiseManager did not create its worker")

    stop_started_at = time.monotonic()
    manager.stop()
    stop_returned_at = time.monotonic()
    stop_elapsed = stop_returned_at - stop_started_at

    worker_alive_at_stop_return = original_worker.is_alive()
    resources_at_stop_return = boundary.resources()
    active_records_at_stop_return = list(manager.active_experiments)
    delete_commands_at_stop_return = [
        command for _, command in boundary.command_log if command.startswith("kubectl delete ")
    ]

    print(f"STOP_ELAPSED_SECONDS={stop_elapsed:.3f}")
    print(f"WORKER_ALIVE_AT_STOP_RETURN={worker_alive_at_stop_return}")
    print(f"RESOURCES_AT_STOP_RETURN={resources_at_stop_return}")
    print(f"ACTIVE_RECORDS_AT_STOP_RETURN={active_records_at_stop_return}")
    print(f"DELETE_COMMANDS_AT_STOP_RETURN={delete_commands_at_stop_return}")
    print(f"FORCE_SCAN_SNAPSHOTS_AT_STOP={boundary.force_scan_snapshots}")

    if not worker_alive_at_stop_return:
        raise AssertionError("Timing assistance did not exceed the five-second join")
    if resources_at_stop_return or active_records_at_stop_return:
        raise AssertionError("Apply unexpectedly completed before stop returned")
    if delete_commands_at_stop_return:
        raise AssertionError("Cleanup unexpectedly had a recorded experiment to delete")

    # This is the same real oracle class wired into
    # liveness_probe_too_aggressive.py:44. Conductor invokes it immediately
    # after NoiseManager.stop() returns.
    post_stop_result = make_oracle(
        SustainedReadinessOracle,
        boundary,
        sustained_period=2.5,
    ).evaluate()

    original_worker.join(timeout=8)
    if original_worker.is_alive():
        raise AssertionError("Original worker did not finish within the bounded test")

    late_resources = boundary.resources()
    late_records = list(manager.active_experiments)
    first_completion = boundary.apply_completions[0]
    late_apply_after_stop = first_completion[0] > stop_returned_at

    print(
        "FIRST_APPLY_COMPLETION="
        f"{first_completion[1]}/{first_completion[2]} action={first_completion[3]}"
    )
    print(f"LATE_APPLY_AFTER_STOP_RETURN={late_apply_after_stop}")
    print(f"LATE_RESOURCES={late_resources}")
    print(f"LATE_ACTIVE_RECORDS={late_records}")
    print(f"REAL_ORACLE_RESULT_AFTER_STOP={post_stop_result}")

    if not late_apply_after_stop:
        raise AssertionError("Apply did not complete after stop returned")
    if not late_resources or not late_records:
        raise AssertionError("Late experiment was not externally present and internally recorded")
    if post_stop_result.get("success") is not False:
        raise AssertionError("Real sustained-readiness consumer did not observe the late PodChaos effect")

    # A later normal teardown stop can remove the now-recorded CR, but it cannot
    # revise the already returned/stored oracle result for this stage.
    manager.stop()
    resources_after_second_stop = boundary.resources()
    recovered_control = make_oracle(
        SustainedReadinessOracle,
        boundary,
        sustained_period=0.3,
    ).evaluate()

    print(f"RESOURCES_AFTER_SECOND_STOP={resources_after_second_stop}")
    print(f"RECOVERED_CONTROL_ORACLE_SUCCESS={recovered_control['success']}")
    print(f"RECORDED_RESULT_AFTER_SECOND_STOP={post_stop_result['success']}")

    if resources_after_second_stop:
        raise AssertionError("Later cleanup control did not remove recorded resources")
    if recovered_control.get("success") is not True:
        raise AssertionError("Control oracle did not recover after later cleanup")
    if post_stop_result.get("success") is not False:
        raise AssertionError("Previously observed wrong result was unexpectedly revised")

    print("LEVEL1_RACE_ONLY=PASS: public start/stop returned before its apply completed")
    print(
        "LEVEL2_REACHABLE_CONSUMER=PASS: legitimate PodChaos -> "
        "controller marks target container unready -> real SustainedReadinessOracle fails"
    )
    print("LEVEL3=NOT_NEEDED")
    print("BUG_TRIGGERED=yes")


if __name__ == "__main__":
    main()

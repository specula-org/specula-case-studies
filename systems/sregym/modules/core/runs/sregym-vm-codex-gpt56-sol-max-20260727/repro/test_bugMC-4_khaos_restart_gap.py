#!/usr/bin/env python3
"""MC-4 reproduction: exercise the real Khaos monitor and conductor API.

Escalation record:
  Level 0: report whether the real kubectl/Khaos black-box path is available.
  Level 1: report whether timing assistance can be applied to that live path.
  Level 2: instantiate the reachable MCRestartPod state at the Kubernetes
           boundary, then execute the unchanged real monitor and public API.
  Level 3: do not modify source once Level 2 proves the downstream mask fires.

The Level-2 boundary double models facts provided by Kubernetes/Khaos, not an
impossible peer response: a restarted container has a new container ID and host
PID, while the old PID-scoped probe no longer affects it. This is exactly state
10, MCRestartPod, in MC_hunt_scenario4_bfs.out.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import enum
import hashlib
import importlib.util
import shutil
import subprocess
import sys
import threading
import time
import types
from pathlib import Path
from types import SimpleNamespace
from typing import Any


def module(name: str, **attributes: Any) -> types.ModuleType:
    result = types.ModuleType(name)
    result.__dict__.update(attributes)
    sys.modules[name] = result
    return result


class Noop:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def __getattr__(self, name: str):
        return lambda *args, **kwargs: None


class BaseModel:
    def __init__(self, **values: Any) -> None:
        for key, value in values.items():
            setattr(self, key, value)


class FastAPI:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def post(self, *args: Any, **kwargs: Any):
        return lambda function: function

    def get(self, *args: Any, **kwargs: Any):
        return lambda function: function


class FastMCP:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def tool(self, *args: Any, **kwargs: Any):
        return lambda function: function


class HTTPException(Exception):
    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class Console:
    def print(self, *args: Any, **kwargs: Any) -> None:
        pass


class TraceProbe:
    def __init__(self) -> None:
        self.events: list[str] = []
        self.acknowledged: list[str | None] = []

    def restart_pod(self) -> None:
        self.events.append("RestartPod")

    def reattach_fault(self) -> None:
        self.events.append("ReattachFault")

    @contextlib.contextmanager
    def received_submission_context(self, request_id: str | None):
        yield request_id

    def acknowledge(self, request_id: str | None) -> None:
        self.acknowledged.append(request_id)

    def retry_submission(self) -> None:
        pass


def install_import_shells(worktree: Path, trace_probe: TraceProbe) -> None:
    """Stub optional dependencies only; target source files stay unchanged."""
    if not hasattr(enum, "StrEnum"):
        class StrEnum(str, enum.Enum):
            pass

        enum.StrEnum = StrEnum  # type: ignore[attr-defined]

    sregym = module("sregym", tla_trace=trace_probe)
    sregym.__path__ = [str(worktree / "sregym")]

    module("pydantic", BaseModel=BaseModel, Field=lambda *args, **kwargs: None)
    module("sregym.conductor.oracles.alert_oracle", AlertOracle=Noop)
    module(
        "sregym.conductor.oracles.llm_as_a_judge.llm_as_a_judge_oracle",
        LLMAsAJudgeOracle=Noop,
    )
    module("sregym.conductor.problems.base", Problem=Noop)
    module("sregym.generators.fault.inject_hw", HWFaultInjector=Noop)
    module("sregym.generators.fault.inject_kernel", KernelInjector=Noop)
    module("sregym.paths", TARGET_MICROSERVICES=worktree)
    module("sregym.service.apps.hotel_reservation", HotelReservation=Noop)
    module("sregym.utils.decorators", mark_fault_injected=lambda function: function)

    pyfiglet = module("pyfiglet", figlet_format=lambda value: value)
    pyfiglet.__path__ = []
    fastapi = module(
        "fastapi",
        FastAPI=FastAPI,
        Header=lambda *args, **kwargs: object(),
        HTTPException=HTTPException,
    )
    fastapi.__path__ = []
    fastmcp = module("fastmcp", FastMCP=FastMCP)
    fastmcp.__path__ = []
    fastmcp_server = module("fastmcp.server")
    fastmcp_server.__path__ = []
    module("fastmcp.server.http", create_sse_app=lambda *args, **kwargs: object())
    rich = module("rich")
    rich.__path__ = []
    module("rich.markdown", Markdown=Noop)
    module("rich.panel", Panel=Noop)
    starlette = module("starlette")
    starlette.__path__ = []
    module("starlette.routing", Mount=Noop)
    module("uvicorn", Config=Noop, Server=Noop)
    module("logger", console=Console())


def load_source(name: str, path: Path) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


class RestartingKubernetesBoundary:
    """Faithful external facts for CE state 9 -> state 10 (MCRestartPod)."""

    pod_ref = "hotel-reservation/mongodb-0"

    def __init__(self) -> None:
        self.kubectl = None
        self._lock = threading.Lock()
        self._container_id = "container-generation-0"
        self._host_pid = 4100
        self._attached_pids = {4100}
        self._container_reads = 0
        self.initial_monitor_pass = threading.Event()
        self.reinjected = threading.Event()
        self.reinjection_time: float | None = None

    def _get_pods_on_node(self, namespace: str, node: str) -> list[str]:
        return [self.pod_ref]

    @staticmethod
    def _split_ns_pod(pod_ref: str) -> tuple[str, str]:
        return tuple(pod_ref.split("/", 1))  # type: ignore[return-value]

    def _get_container_id(self, namespace: str, pod: str) -> str:
        with self._lock:
            self._container_reads += 1
            result = self._container_id
            if self._container_reads >= 2:
                self.initial_monitor_pass.set()
            return result

    def _get_host_pid_on_node(self, node: str, container_id: str) -> int:
        # Real code comments explicitly note this lookup can take seconds.
        time.sleep(0.10)
        with self._lock:
            if container_id != self._container_id:
                raise RuntimeError("container changed again during PID lookup")
            return self._host_pid

    def _exec_khaos_fault_on_node(
        self,
        node: str,
        fault_type: str,
        host_pid: int,
        params: list[int | str] | None,
    ) -> None:
        with self._lock:
            self._attached_pids.add(host_pid)
            self.reinjection_time = time.monotonic()
            self.reinjected.set()

    def restart_container(self) -> float:
        """Equivalent real operation: Kubernetes replaces/restarts the container."""
        with self._lock:
            self._container_id = "container-generation-1"
            self._host_pid = 4200
        return time.monotonic()

    def snapshot(self) -> tuple[str, int, tuple[int, ...], bool]:
        with self._lock:
            return (
                self._container_id,
                self._host_pid,
                tuple(sorted(self._attached_pids)),
                self._host_pid in self._attached_pids,
            )


class DiagnosisConductorBoundary:
    """The reachable conductor state exposed in CE state 9 and state 10."""

    def __init__(self) -> None:
        self.submission_stage = "diagnosis"
        self.submit_calls = 0

    async def submit(self, solution: str | None) -> dict[str, str]:
        self.submit_calls += 1
        return {"status": "ok", "message": "Submission received"}


def git_head(worktree: Path) -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"],
        cwd=worktree,
        text=True,
        timeout=10,
    ).strip()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def live_preflight() -> tuple[bool, str]:
    kubectl = shutil.which("kubectl")
    if kubectl is None:
        return False, "kubectl missing; no real Kubernetes/Khaos black-box path"
    try:
        context = subprocess.check_output(
            [kubectl, "config", "current-context"],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=10,
        ).strip()
    except Exception as exc:
        return False, f"kubectl exists but no usable context: {type(exc).__name__}: {exc}"
    return False, f"context {context!r} found, but this test will not mutate an unverified shared cluster"


def reproduce(worktree: Path) -> None:
    khaos_path = worktree / "sregym/conductor/problems/khaos_faults.py"
    api_path = worktree / "sregym/conductor/conductor_api.py"
    if not khaos_path.is_file() or not api_path.is_file():
        raise FileNotFoundError(f"not an SREGym worktree: {worktree}")

    print(f"SOURCE_HEAD={git_head(worktree)}")
    print(f"KHAOS_SOURCE_SHA256={sha256(khaos_path)}")
    print(f"API_SOURCE_SHA256={sha256(api_path)}")

    live_ready, live_reason = live_preflight()
    print(f"LEVEL0={'AVAILABLE' if live_ready else 'BLOCKED'}: {live_reason}")
    print(
        "LEVEL1=BLOCKED: timing-only assistance cannot run without the "
        "Level-0 Kubernetes/Khaos runtime"
    )

    trace_probe = TraceProbe()
    install_import_shells(worktree, trace_probe)
    khaos_module = load_source("mc4_khaos_faults", khaos_path)
    api_module = load_source("mc4_conductor_api", api_path)

    injector = RestartingKubernetesBoundary()
    monitor = khaos_module._FaultReinjectionMonitor(
        injector=injector,
        namespace="hotel-reservation",
        node="worker-1",
        fault_type="write_error",
        params=[100],
    )
    monitor.start()
    try:
        if not injector.initial_monitor_pass.wait(timeout=2):
            raise AssertionError("monitor did not complete its initial no-change pass")
        # Ensure the normal loop has entered its documented five-second wait.
        time.sleep(0.05)

        before = injector.snapshot()
        if not before[3]:
            raise AssertionError(f"control fault should initially be effective: {before}")

        restart_time = injector.restart_container()
        during = injector.snapshot()
        if during[3]:
            raise AssertionError(f"old PID attachment unexpectedly affects new PID: {during}")

        conductor = DiagnosisConductorBoundary()
        api_module.set_conductor(conductor)
        status_during = asyncio.run(api_module.get_status())
        request = api_module.SubmitRequest(solution="diagnosis-during-reattach-gap")
        accepted_during = asyncio.run(api_module.submit_solution(request))

        if status_during != {"stage": "diagnosis"}:
            raise AssertionError(f"public status did not expose diagnosis: {status_during}")
        if accepted_during.get("status") != "200" or conductor.submit_calls != 1:
            raise AssertionError(
                f"public diagnosis submission was not accepted: {accepted_during}, "
                f"submit_calls={conductor.submit_calls}"
            )

        print(
            "LEVEL2_GAP: CE_STEP=State10:MCRestartPod "
            f"stage={status_during['stage']} cid={during[0]} current_pid={during[1]} "
            f"attached_pids={list(during[2])} fault_effective={during[3]} "
            f"api_submit_status={accepted_during['status']} submit_calls={conductor.submit_calls}"
        )

        if not injector.reinjected.wait(timeout=7):
            raise AssertionError("normal monitor did not reattach within one polling interval")
        after = injector.snapshot()
        if not after[3]:
            raise AssertionError(f"monitor ran but new PID is still unattached: {after}")
        if injector.reinjection_time is None:
            raise AssertionError("missing reinjection timestamp")
        elapsed = injector.reinjection_time - restart_time
        if elapsed < 4.5:
            raise AssertionError(
                f"restart was not placed after a monitor pass; gap only {elapsed:.3f}s"
            )
        if trace_probe.events != ["RestartPod", "ReattachFault"]:
            raise AssertionError(f"unexpected monitor trace: {trace_probe.events}")

        print(
            "LEVEL2_MASK: "
            f"elapsed_seconds={elapsed:.3f} current_pid={after[1]} "
            f"attached_pids={list(after[2])} fault_effective={after[3]} "
            f"trace_events={trace_probe.events}"
        )
        print(
            "LEVEL3=NOT_ESCALATED: Level 2 positively proved the normal downstream "
            "monitor fires; a source delay would only widen the same masked interval"
        )
        print(
            "RESULT=MASKED: diagnosis is publicly available while the replacement "
            "PID is unattached, then the ordinary polling monitor reattaches the fault"
        )
    finally:
        monitor.stop()


def main() -> None:
    output_root = Path(__file__).resolve().parents[1]
    default_worktree = output_root / "confirmation/MC-4/worktree"
    parser = argparse.ArgumentParser()
    parser.add_argument("--worktree", type=Path, default=default_worktree)
    args = parser.parse_args()
    reproduce(args.worktree.resolve())


if __name__ == "__main__":
    main()

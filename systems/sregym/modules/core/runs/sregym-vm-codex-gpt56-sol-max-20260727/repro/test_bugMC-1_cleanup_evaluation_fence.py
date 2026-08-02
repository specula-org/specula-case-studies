#!/usr/bin/env python3
"""Deterministic reproduction for MC-1.

Escalation:
  Level 0: report whether the checkout's real cluster prerequisites exist.
  Level 1: timing assistance alone cannot bootstrap a missing cluster/runtime.
  Level 2: replace only unavailable infrastructure/framework boundaries, reach
           the diagnosis state through Conductor.start_problem(), then execute
           the real submission endpoint, Conductor lifecycle, executor, timeout
           cleanup, and status endpoint.

The Level-2 precondition is not hand-built. It is reached by the normal
start_problem() call sequence and corresponds to counterexample State 9:
stage="diagnosis" and waitingForAgent=TRUE. The subsequent scheduling order
matches States 10-16: queued request -> timeout/exit future snapshot -> request
admission -> evaluation in flight -> driver teardown.
"""

from __future__ import annotations

import asyncio
import enum
import logging
import os
import shutil
import sys
import threading
import types
from pathlib import Path
from types import SimpleNamespace
from typing import Any


OUTPUT_ROOT = Path(__file__).resolve().parents[1]
WORKTREE = OUTPUT_ROOT / "confirmation" / "MC-1" / "worktree"
sys.path.insert(0, str(WORKTREE))


def install_module(name: str, **attributes: Any) -> types.ModuleType:
    module = types.ModuleType(name)
    module.__dict__.update(attributes)
    sys.modules[name] = module
    return module


def install_package(name: str, **attributes: Any) -> types.ModuleType:
    module = install_module(name, **attributes)
    module.__path__ = []  # type: ignore[attr-defined]
    return module


class DummyService:
    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        pass

    def __getattr__(self, _name: str):
        return lambda *_args, **_kwargs: None


class StubDiagnosisOracleType:
    pass


class StartProblemResult(enum.Enum):
    SUCCESS = "success"
    SKIPPED_KHAOS_REQUIRED = "skipped_khaos_required"


def install_conductor_dependencies() -> None:
    """Stub imports that talk to Kubernetes; lifecycle code remains real."""

    install_module("sregym.conductor.constants", StartProblemResult=StartProblemResult)
    install_module("sregym.conductor.oracles.detection", DetectionOracle=DummyService)
    install_module(
        "sregym.conductor.oracles.diagnosis_oracle",
        DiagnosisOracle=StubDiagnosisOracleType,
    )
    install_module("sregym.conductor.problems.registry", ProblemRegistry=DummyService)
    install_module(
        "sregym.conductor.utils",
        is_ordered_subset=lambda values, allowed: all(value in allowed for value in values),
    )
    install_module(
        "sregym.generators.fault.inject_remote_os",
        RemoteOSFaultInjector=DummyService,
    )
    install_module(
        "sregym.generators.fault.inject_virtual",
        VirtualizationFaultInjector=DummyService,
    )
    install_module(
        "sregym.generators.noise.manager",
        get_noise_manager=lambda: DummyService(),
    )
    install_module("sregym.observer.jaeger", Jaeger=DummyService)
    install_module("sregym.observer.otel_collector", OtelCollector=DummyService)
    install_module(
        "sregym.paths",
        CLUSTER_BASELINE_STATE_FILE=Path("/nonexistent/mc1-baseline.json"),
    )
    install_module("sregym.service.apps.app_registry", AppRegistry=DummyService)
    install_module(
        "sregym.service.cluster_state",
        ClusterStateManager=DummyService,
    )
    install_module("sregym.service.dm_flakey_manager", DmFlakeyManager=DummyService)
    install_module("sregym.service.k8s_proxy", KubernetesAPIProxy=DummyService)
    install_module("sregym.service.khaos", KhaosController=DummyService)
    install_module("sregym.service.kubectl", KubeCtl=DummyService)
    install_module("sregym.service.mcp_server", MCPServer=DummyService)
    install_module("sregym.service.telemetry.loki", Loki=DummyService)
    install_module("sregym.service.telemetry.prometheus", Prometheus=DummyService)


class DecoratedApp:
    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        pass

    def post(self, _path: str):
        return lambda function: function

    def get(self, _path: str):
        return lambda function: function


class StubHTTPException(Exception):
    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class StubFastMCP:
    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        pass

    def tool(self, **_kwargs: Any):
        return lambda function: function


class StubBaseModel:
    def __init__(self, **values: Any) -> None:
        self.__dict__.update(values)


class StubConsole:
    def print(self, *_args: Any, **_kwargs: Any) -> None:
        pass


def install_api_dependencies() -> None:
    """Let the actual endpoint functions load without installing web servers."""

    install_module(
        "fastapi",
        FastAPI=DecoratedApp,
        Header=lambda default=None, **_kwargs: default,
        HTTPException=StubHTTPException,
    )
    install_package("fastmcp", FastMCP=StubFastMCP)
    install_package("fastmcp.server")
    install_module(
        "fastmcp.server.http",
        create_sse_app=lambda *_args, **_kwargs: object(),
    )
    install_module("pydantic", BaseModel=StubBaseModel)
    install_module("pyfiglet", figlet_format=lambda value: value)
    install_package("rich")
    install_module("rich.markdown", Markdown=lambda value: value)
    install_module("rich.panel", Panel=lambda *args, **kwargs: (args, kwargs))
    install_package("starlette")
    install_module("starlette.routing", Mount=lambda *args, **kwargs: (args, kwargs))
    install_module("uvicorn", Config=DummyService, Server=DummyService)
    install_package("logger", console=StubConsole())


class FakeApp:
    """Minimal app boundary with the same externally visible deploy/delete state."""

    def __init__(self, timeline: list[str]) -> None:
        self.timeline = timeline
        self.deployed = False
        self.cleanup_count = 0
        self.conductor = None

    def cleanup(self) -> None:
        future = self.conductor._submit_future
        future_done = future is None or future.done()
        self.timeline.append(f"app_cleanup(future_done={future_done})")
        self.cleanup_count += 1
        self.deployed = False


class SlowDiagnosisOracle:
    """A slow successful judge, matching production's executor-based LLM judge."""

    def __init__(
        self,
        app: FakeApp,
        timeline: list[str],
        evaluation_started: threading.Event,
        release_evaluation: threading.Event,
    ) -> None:
        self.app = app
        self.timeline = timeline
        self.evaluation_started = evaluation_started
        self.release_evaluation = release_evaluation

    def evaluate(self, _solution: str) -> dict[str, Any]:
        self.timeline.append("evaluation_started")
        self.evaluation_started.set()
        if not self.release_evaluation.wait(timeout=5):
            raise TimeoutError("test did not release the deliberately slow evaluation")
        self.timeline.append(f"evaluation_resumed(app_deployed={self.app.deployed})")
        return {"success": True, "judge": "slow-success"}


class FakeMitigationOracle:
    def capture_baseline(self) -> None:
        pass

    def evaluate(self) -> dict[str, Any]:
        return {"success": True}


class FakeProblem:
    def __init__(
        self,
        timeline: list[str],
        evaluation_started: threading.Event,
        release_evaluation: threading.Event,
    ) -> None:
        self.timeline = timeline
        self.app = FakeApp(timeline)
        self.diagnosis_oracle = SlowDiagnosisOracle(
            self.app,
            timeline,
            evaluation_started,
            release_evaluation,
        )
        self.mitigation_oracle = FakeMitigationOracle()

    def requires_khaos(self) -> bool:
        return False

    def inject_fault(self) -> None:
        self.timeline.append("fault_injected")

    def recover_fault(self) -> None:
        self.timeline.append("fault_recovered")


class FakeRegistry:
    def __init__(self, problem: FakeProblem) -> None:
        self.problem = problem

    def get_problem_instance(self, _problem_id: str) -> FakeProblem:
        return self.problem


def flatten_driver_snapshot(results: dict[str, Any]) -> dict[str, Any]:
    """The result-copy logic used by main.py:458-467."""

    snapshot: dict[str, Any] = {"problem_id": "mc1-fixture", "attempt": 1}
    for stage, outcome in results.items():
        if isinstance(outcome, dict):
            for key, value in outcome.items():
                snapshot[f"{stage}.{key}"] = value
        else:
            snapshot[stage] = outcome
    return snapshot


async def reproduce() -> None:
    missing = [
        binary
        for binary in ("kubectl", "helm", "docker")
        if shutil.which(binary) is None
    ]
    print(f"LEVEL 0 RESULT: end-to-end cluster run unavailable; missing={missing}")
    print(
        "LEVEL 1 RESULT: timing-only cluster run unavailable because sleeps "
        "cannot supply the missing cluster tools"
    )
    print(
        "LEVEL 2 PRECONDITION: reached via Conductor.start_problem(); "
        "counterexample State 9 has stage=diagnosis, waitingForAgent=TRUE"
    )

    os.environ.pop("SREGYM_TRACE_FILE", None)
    os.environ.pop("SREGYM_TRACE_REQUEST_IDS", None)
    install_conductor_dependencies()
    install_api_dependencies()

    from sregym.conductor.conductor import Conductor, ConductorConfig
    from sregym.conductor import conductor_api

    timeline: list[str] = []
    evaluation_started = threading.Event()
    release_evaluation = threading.Event()
    problem = FakeProblem(timeline, evaluation_started, release_evaluation)

    class LightweightConductor(Conductor):
        """Use real lifecycle methods with only external I/O replaced."""

        def dependency_check(self, _binaries: list[str]) -> None:
            pass

        def fix_kubernetes(self) -> None:
            pass

        def get_problem_stages(self) -> None:
            self.tasklist = ["diagnosis", "mitigation"]

        def undeploy_app(self) -> None:
            if self.app.deployed:
                self.app.cleanup()

        def deploy_app(self) -> None:
            self.submission_stage = "setup"
            self.app.deployed = True
            timeline.append("app_deployed")

    conductor = LightweightConductor(ConductorConfig(enable_noise=False))
    conductor.problem_id = "mc1-fixture"
    conductor.problems = FakeRegistry(problem)
    problem.app.conductor = conductor
    start_result = await conductor.start_problem()
    assert start_result is StartProblemResult.SUCCESS
    assert conductor.submission_stage == "diagnosis"
    assert conductor.waiting_for_agent is True
    conductor_api.set_conductor(conductor)

    request_queued = asyncio.Event()
    allow_handler = asyncio.Event()
    submission_accepted = asyncio.Event()

    async def queued_public_request() -> dict[str, str]:
        timeline.append("request_queued")
        request_queued.set()
        await allow_handler.wait()
        timeline.append("request_handler_entered")
        response = await conductor_api.submit_solution(
            SimpleNamespace(solution="valid diagnosis"),
            trace_request_id=None,
        )
        timeline.append("submit_accepted")
        submission_accepted.set()
        return response

    request_task = asyncio.create_task(queued_public_request())
    await request_queued.wait()

    # This is main.py:411-413's one-time process-exit snapshot. The queued
    # request has not entered the route yet, so no future is visible.
    timeline.append("timeout_fired")
    evaluation_in_flight_at_exit = (
        conductor._submit_future is not None and not conductor._submit_future.done()
    )
    timeline.append(f"agent_exit_snapshot(in_flight={evaluation_in_flight_at_exit})")
    assert evaluation_in_flight_at_exit is False

    # Model the normal agent-process cleanup interval between timeout/exit
    # detection and conductor teardown. The already queued HTTP request runs
    # during that interval, exactly as States 14-15 permit.
    allow_handler.set()
    await submission_accepted.wait()
    submit_response = await request_task
    evaluation_did_start = await asyncio.to_thread(evaluation_started.wait, 2)
    assert evaluation_did_start
    assert conductor._submit_future is not None
    assert not conductor._submit_future.done()

    timeline.append("driver_teardown_started")
    conductor.finish_after_agent_timeout(agent_timeout=1)
    timeline.append(f"driver_teardown_returned(stage={conductor.submission_stage})")

    assert problem.app.cleanup_count == 1
    assert problem.app.deployed is False
    assert conductor.submission_stage == "done"
    assert not conductor._submit_future.done()

    # This snapshot is the result consumed/published by main.py after its
    # timeout branch leaves the wait loop. It is never refreshed later.
    published_snapshot = flatten_driver_snapshot(conductor.results)
    timeline.append("driver_snapshot_copied")
    assert "Diagnosis.success" not in published_snapshot

    release_evaluation.set()
    await asyncio.wrap_future(conductor._submit_future)
    timeline.append(f"evaluation_future_finished(stage={conductor.submission_stage})")

    # Exercise the real public status endpoint after all asynchronous work has
    # completed. Evaluation advances from diagnosis to mitigation even though
    # teardown already deleted the app.
    status_polls = []
    for _ in range(3):
        status_polls.append(await conductor_api.get_status())
        await asyncio.sleep(0.01)

    assert conductor.results["Diagnosis"]["success"] is True
    assert conductor.submission_stage == "mitigation"
    assert conductor.waiting_for_agent is True
    assert problem.app.deployed is False
    assert all(status == {"stage": "mitigation"} for status in status_polls)
    assert "Diagnosis.success" not in published_snapshot

    print("CE_SEQUENCE: " + " -> ".join(timeline))
    print(f"SUBMIT_RESPONSE: {submit_response}")
    print(
        "OVERLAP_PROOF: app_cleanup(future_done=False), "
        f"cleanup_count={problem.app.cleanup_count}"
    )
    print(f"DRIVER_PUBLISHED_SNAPSHOT: {published_snapshot}")
    print(f"LIVE_RESULTS_AFTER_FUTURE: {conductor.results}")
    print(f"STATUS_POLLS_AFTER_ALL_WORK: {status_polls}")
    print(
        "PERMANENCE_PROOF: three post-future /status polls remain mitigation "
        f"while app_deployed={problem.app.deployed}; published snapshot remains "
        "without Diagnosis.success"
    )
    print(
        "PASS: MC-1 reproduced: teardown overlapped an admitted evaluation, "
        "the driver snapshot lost its grade, and /status reopened mitigation "
        "after the app was deleted"
    )


def main() -> int:
    logging.basicConfig(level=logging.CRITICAL)
    try:
        asyncio.run(reproduce())
    except Exception as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

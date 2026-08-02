#!/usr/bin/env python3
"""Reproduce MC-2 through SREGym's real HTTP submission endpoint.

Level 0 sends an immediate duplicate while diagnosis evaluation is running and
shows the existing in-flight guard discards it.

Level 1 uses Python's runtime thread tracing as a timing-only breakpoint. It
pauses the unmodified evaluator after `_evaluating` is cleared but before
`current_stage_index` advances. A duplicate request enters through POST
`/submit`, observes diagnosis at the endpoint, gets the normal RuntimeError
retry, and is then accepted as mitigation after the evaluator is released.

Kubernetes-facing collaborators are replaced with inert test doubles so the
normal Conductor.start_problem() state machine can run without a cluster. The
submission API, retry loop, Conductor.submit(), evaluator, stage advancement,
result writes, and teardown ordering are the repository's actual code.
"""

from __future__ import annotations

import asyncio
import json
import linecache
import logging
import os
import re
import socket
import sys
import threading
import time
import types
from pathlib import Path
from typing import Any

import requests
import uvicorn
from starlette.applications import Starlette


SCRIPT_PATH = Path(__file__).resolve()
OUTPUT_ROOT = SCRIPT_PATH.parent.parent
REPO_ROOT = OUTPUT_ROOT / "confirmation" / "MC-2" / "worktree"
CONDUCTOR_PATH = (REPO_ROOT / "sregym" / "conductor" / "conductor.py").resolve()
API_PATH = (REPO_ROOT / "sregym" / "conductor" / "conductor_api.py").resolve()

DIAGNOSIS_BODY = "diagnosis-origin-copy: frontend root cause"
MITIGATION_SIGNAL = "legitimate mitigation completed"


def _module(name: str, *, package: bool = False, **attributes: Any) -> types.ModuleType:
    module = types.ModuleType(name)
    if package:
        module.__path__ = []  # type: ignore[attr-defined]
    for key, value in attributes.items():
        setattr(module, key, value)
    sys.modules[name] = module
    return module


class _DummyService:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def __getattr__(self, name: str):
        def no_op(*args: Any, **kwargs: Any):
            return None

        return no_op


class _DummyConsole:
    def print(self, *args: Any, **kwargs: Any) -> None:
        pass


class _DummyFastMCP:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def tool(self, *args: Any, **kwargs: Any):
        def decorate(function):
            return function

        return decorate


def _install_external_dependency_stubs() -> None:
    """Stub only infrastructure/MCP presentation dependencies, not core logic."""

    class ProblemRegistry:
        def get_problem_instance(self, problem_id: str):
            raise AssertionError("test registry must be installed before start_problem")

    class DiagnosisOracle:
        pass

    class DetectionOracle:
        def __init__(self, problem: Any) -> None:
            self.problem = problem

    class NoiseManager:
        def stop(self) -> None:
            pass

        def start(self) -> None:
            pass

        def set_stage(self, stage: str) -> None:
            pass

    noise_manager = NoiseManager()

    _module("logger", console=_DummyConsole(), init_logger=lambda: None)
    _module(
        "sregym.conductor.oracles.detection",
        DetectionOracle=DetectionOracle,
    )
    _module(
        "sregym.conductor.oracles.diagnosis_oracle",
        DiagnosisOracle=DiagnosisOracle,
    )
    _module(
        "sregym.conductor.problems.registry",
        ProblemRegistry=ProblemRegistry,
    )
    _module(
        "sregym.generators.fault.inject_remote_os",
        RemoteOSFaultInjector=_DummyService,
    )
    _module(
        "sregym.generators.fault.inject_virtual",
        VirtualizationFaultInjector=_DummyService,
    )
    _module(
        "sregym.generators.noise.manager",
        get_noise_manager=lambda: noise_manager,
    )
    _module("sregym.observer.jaeger", Jaeger=_DummyService)
    _module("sregym.observer.otel_collector", OtelCollector=_DummyService)
    _module("sregym.service.apps.app_registry", AppRegistry=_DummyService)
    _module("sregym.service.cluster_state", ClusterStateManager=_DummyService)
    _module("sregym.service.dm_flakey_manager", DmFlakeyManager=_DummyService)
    _module("sregym.service.k8s_proxy", KubernetesAPIProxy=_DummyService)
    _module("sregym.service.khaos", KhaosController=_DummyService)
    _module("sregym.service.kubectl", KubeCtl=_DummyService)
    _module("sregym.service.mcp_server", MCPServer=_DummyService)
    _module("sregym.service.telemetry.loki", Loki=_DummyService)
    _module("sregym.service.telemetry.prometheus", Prometheus=_DummyService)

    _module("pyfiglet", figlet_format=lambda text: text)
    _module("fastmcp", package=True, FastMCP=_DummyFastMCP)
    _module("fastmcp.server", package=True)
    _module(
        "fastmcp.server.http",
        create_sse_app=lambda *args, **kwargs: Starlette(),
    )

    class Markdown:
        def __init__(self, value: str) -> None:
            self.value = value

    class Panel:
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            pass

    _module("rich", package=True)
    _module("rich.markdown", Markdown=Markdown)
    _module("rich.panel", Panel=Panel)


if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

# Observational Specula tracing must be off; the reproduction does not depend on
# its shadow state or request identifiers.
os.environ.pop("SREGYM_TRACE_FILE", None)
os.environ.pop("SREGYM_TRACE_REQUEST_IDS", None)

_install_external_dependency_stubs()

from sregym import tla_trace  # noqa: E402
from sregym.conductor import conductor as conductor_module  # noqa: E402
from sregym.conductor import conductor_api  # noqa: E402
from sregym.conductor.constants import StartProblemResult  # noqa: E402
from clients.tierzero import driver as tierzero_driver  # noqa: E402

tla_trace.close()


class FakeApp:
    namespace = "mc2-test"
    name = "mc2-test"
    app_name = "mc2-test"
    description = "MC-2 submission lifecycle test"
    namespaces = ["mc2-test"]

    def __init__(self) -> None:
        self.cleanup_calls = 0

    def cleanup(self) -> None:
        self.cleanup_calls += 1


class FakeDiagnosisOracle:
    def __init__(self, delay_seconds: float) -> None:
        self.delay_seconds = delay_seconds
        self.calls: list[str] = []

    def evaluate(self, solution: str) -> dict[str, Any]:
        self.calls.append(solution)
        if self.delay_seconds:
            # Represents an ordinary slow diagnosis judge, not a source hook.
            time.sleep(self.delay_seconds)
        return {"success": True, "oracle": "diagnosis"}


class FakeMitigationOracle:
    def __init__(self, problem: "FakeProblem") -> None:
        self.problem = problem
        self.baseline_captures = 0
        self.repaired_observations: list[bool] = []

    def capture_baseline(self) -> None:
        self.baseline_captures += 1

    def evaluate(self) -> dict[str, Any]:
        repaired = self.problem.repaired
        self.repaired_observations.append(repaired)
        return {
            "success": repaired,
            "oracle": "mitigation",
            "repaired_at_evaluation": repaired,
        }


class FakeProblem:
    def __init__(self, diagnosis_delay: float) -> None:
        self.app = FakeApp()
        self.fault_injected = False
        self.repaired = False
        self.recovery_calls = 0
        self.diagnosis_oracle = FakeDiagnosisOracle(diagnosis_delay)
        self.mitigation_oracle = FakeMitigationOracle(self)

    def requires_khaos(self) -> bool:
        return False

    def inject_fault(self) -> None:
        self.fault_injected = True
        self.repaired = False

    def recover_fault(self) -> None:
        self.recovery_calls += 1
        self.fault_injected = False


class FakeRegistry:
    def __init__(self, problem: FakeProblem) -> None:
        self.problem = problem

    def get_problem_instance(self, problem_id: str) -> FakeProblem:
        return self.problem


class EvaluationCapture(logging.Handler):
    """Observe the real evaluator's stage/body logging without changing it."""

    _PATTERN = re.compile(r"^Evaluating stage '([^']+)'$")

    def __init__(self) -> None:
        super().__init__(level=logging.INFO)
        self.records: list[tuple[str, str | None]] = []
        self._lock = threading.Lock()

    def emit(self, record: logging.LogRecord) -> None:
        match = self._PATTERN.match(record.getMessage())
        if match:
            with self._lock:
                self.records.append((match.group(1), getattr(record, "sol", None)))

    def snapshot(self) -> list[tuple[str, str | None]]:
        with self._lock:
            return list(self.records)


def make_conductor(diagnosis_delay: float) -> tuple[Any, FakeProblem, EvaluationCapture]:
    problem = FakeProblem(diagnosis_delay)
    conductor = conductor_module.Conductor(
        conductor_module.ConductorConfig(deploy_loki=False, enable_noise=False)
    )
    conductor.problem_id = "mc2-test"
    conductor.problems = FakeRegistry(problem)
    conductor._baseline_captured = False

    # These replace only external cluster provisioning. start_problem(),
    # _build_stage_sequence(), fault injection, submission, evaluation, stage
    # advancement, result recording, and teardown ordering remain production code.
    conductor.dependency_check = lambda binaries: None
    conductor.fix_kubernetes = lambda: None
    conductor.get_problem_stages = lambda: setattr(
        conductor, "tasklist", ["diagnosis", "mitigation"]
    )
    conductor.undeploy_app = lambda: None

    def deploy_fixture() -> None:
        conductor.submission_stage = "setup"

    conductor.deploy_app = deploy_fixture

    capture = EvaluationCapture()
    conductor.logger.setLevel(logging.INFO)
    conductor.logger.addHandler(capture)

    result = asyncio.run(conductor.start_problem())
    assert result == StartProblemResult.SUCCESS, result
    assert conductor.submission_stage == "diagnosis"
    assert conductor.waiting_for_agent is True
    return conductor, problem, capture


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


class RunningServer:
    def __init__(self, conductor: Any) -> None:
        self.conductor = conductor
        self.port = reserve_port()
        self.base_url = f"http://127.0.0.1:{self.port}"
        self.server = uvicorn.Server(
            uvicorn.Config(
                conductor_api.app,
                host="127.0.0.1",
                port=self.port,
                log_level="error",
                access_log=False,
                lifespan="off",
            )
        )
        self.thread = threading.Thread(
            target=self.server.run,
            name=f"mc2-http-{self.port}",
            daemon=True,
        )

    def __enter__(self) -> "RunningServer":
        conductor_api.set_conductor(self.conductor)
        self.thread.start()
        deadline = time.monotonic() + 10
        while not self.server.started and self.thread.is_alive():
            if time.monotonic() >= deadline:
                raise TimeoutError("uvicorn did not start")
            time.sleep(0.01)
        if not self.thread.is_alive():
            raise RuntimeError("uvicorn exited during startup")
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.server.should_exit = True
        self.thread.join(timeout=10)
        if self.thread.is_alive():
            raise TimeoutError("uvicorn did not stop")

    def post(self, solution: str, timeout: float = 10) -> requests.Response:
        return requests.post(
            f"{self.base_url}/submit",
            json={"solution": solution},
            timeout=timeout,
        )

    def status(self) -> str:
        response = requests.get(f"{self.base_url}/status", timeout=5)
        response.raise_for_status()
        return str(response.json()["stage"])

    def wait_for_stage(self, expected: set[str], timeout: float = 10) -> str:
        deadline = time.monotonic() + timeout
        last = ""
        while time.monotonic() < deadline:
            last = self.status()
            if last in expected:
                return last
            time.sleep(0.01)
        raise TimeoutError(f"stage did not reach {expected}; last={last!r}")


def response_summary(response: requests.Response) -> dict[str, Any]:
    return {"http": response.status_code, "json": response.json()}


def wait_for_future(conductor: Any, timeout: float = 10) -> None:
    future = conductor._submit_future
    if future is None:
        raise AssertionError("Conductor has no submission future")
    future.result(timeout=timeout)


def level0_immediate_duplicate() -> None:
    """Pure public-API attempt: the existing in-flight guard should fire."""

    conductor, problem, capture = make_conductor(diagnosis_delay=0.35)
    try:
        with RunningServer(conductor) as server:
            first = server.post(DIAGNOSIS_BODY)
            immediate_duplicate = server.post(DIAGNOSIS_BODY)
            stage_after_diagnosis = server.wait_for_stage({"mitigation", "done"})

            level0_records = capture.snapshot()
            cross_stage = ("mitigation", DIAGNOSIS_BODY) in level0_records

            print("LEVEL0 mode=pure-public-http")
            print("LEVEL0 first_response=" + json.dumps(response_summary(first), sort_keys=True))
            print(
                "LEVEL0 immediate_duplicate_response="
                + json.dumps(response_summary(immediate_duplicate), sort_keys=True)
            )
            print(f"LEVEL0 stage_after_diagnosis={stage_after_diagnosis}")
            print("LEVEL0 evaluations=" + json.dumps(level0_records))
            print(f"LEVEL0 cross_stage_triggered={str(cross_stage).lower()}")

            if cross_stage:
                raise AssertionError(
                    "Level 0 unexpectedly hit the narrow transition; Level 1 must not run"
                )

            # Complete the control run correctly: a distinct mitigation action
            # occurs before its distinct submission and receives a passing grade.
            assert stage_after_diagnosis == "mitigation"
            problem.repaired = True
            legitimate = server.post(MITIGATION_SIGNAL)
            server.wait_for_stage({"done"})
            wait_for_future(conductor)
            control_records = capture.snapshot()
            assert control_records == [
                ("diagnosis", DIAGNOSIS_BODY),
                ("mitigation", MITIGATION_SIGNAL),
            ], control_records
            assert conductor.results["Mitigation"]["success"] is True
            print(
                "LEVEL0 control_legitimate_mitigation_response="
                + json.dumps(response_summary(legitimate), sort_keys=True)
            )
            print("LEVEL0 outcome=safeguard_discarded_immediate_duplicate; escalating_to_level1")
    finally:
        conductor.logger.removeHandler(capture)


def level1_transition_timing() -> None:
    """Timing-only pause at the real transition, with all requests over HTTP."""

    conductor, problem, capture = make_conductor(diagnosis_delay=0)
    transition_window = threading.Event()
    release_transition = threading.Event()
    retry_sleep_seen = threading.Event()
    trace_failures: list[str] = []
    window_snapshot: dict[str, Any] = {}
    retry_snapshot: dict[str, Any] = {}
    pause_once = threading.Event()

    def timing_trace(frame, event: str, arg):
        if event != "line":
            return timing_trace

        filename = Path(frame.f_code.co_filename).resolve()
        source_line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()

        if (
            filename == CONDUCTOR_PATH
            and frame.f_code.co_name == "_submit_evaluate_and_advance"
            and "next_index = self.current_stage_index + 1" in source_line
            and frame.f_locals.get("self") is conductor
            and frame.f_locals.get("stage_name") == "diagnosis"
            and not pause_once.is_set()
        ):
            pause_once.set()
            window_snapshot.update(
                {
                    "stage": conductor.submission_stage,
                    "waiting_for_agent": conductor.waiting_for_agent,
                    "evaluating": conductor._evaluating,
                    "current_stage_index": conductor.current_stage_index,
                }
            )
            transition_window.set()
            if not release_transition.wait(timeout=10):
                trace_failures.append("timed out waiting to release evaluator transition")

        if (
            filename == API_PATH
            and frame.f_code.co_name == "submit_solution"
            and "await asyncio.sleep(1)" in source_line
            and not retry_sleep_seen.is_set()
        ):
            retry_snapshot.update(
                {
                    "stage": conductor.submission_stage,
                    "waiting_for_agent": conductor.waiting_for_agent,
                    "evaluating": conductor._evaluating,
                    "current_stage_index": conductor.current_stage_index,
                }
            )
            retry_sleep_seen.set()

        return timing_trace

    # threading.settrace affects only subsequently created threads. Both the
    # uvicorn API thread and executor threads are created after this call.
    threading.settrace(timing_trace)
    duplicate_result: dict[str, Any] = {}

    try:
        with RunningServer(conductor) as server:
            first = server.post(DIAGNOSIS_BODY)
            if not transition_window.wait(timeout=10):
                raise TimeoutError("did not reach post-evaluation/pre-advance window")

            assert window_snapshot == {
                "stage": "diagnosis",
                "waiting_for_agent": False,
                "evaluating": False,
                "current_stage_index": 0,
            }, window_snapshot

            def delayed_duplicate() -> None:
                try:
                    response = server.post(DIAGNOSIS_BODY, timeout=15)
                    duplicate_result["response"] = response_summary(response)
                except BaseException as error:  # preserve client-thread failure
                    duplicate_result["error"] = repr(error)

            duplicate_thread = threading.Thread(
                target=delayed_duplicate,
                name="mc2-delayed-duplicate-client",
            )
            duplicate_thread.start()

            if not retry_sleep_seen.wait(timeout=10):
                raise TimeoutError("duplicate did not enter the endpoint retry branch")

            assert retry_snapshot == {
                "stage": "diagnosis",
                "waiting_for_agent": False,
                "evaluating": False,
                "current_stage_index": 0,
            }, retry_snapshot

            # Timing assistance ends here. Production code advances diagnosis to
            # mitigation; the unchanged endpoint wakes and retries its same body.
            release_transition.set()
            duplicate_thread.join(timeout=20)
            if duplicate_thread.is_alive():
                raise TimeoutError("duplicate HTTP request did not complete")
            if "error" in duplicate_result:
                raise AssertionError(duplicate_result["error"])

            server.wait_for_stage({"done"}, timeout=10)
            wait_for_future(conductor)
            records = capture.snapshot()

            assert records == [
                ("diagnosis", DIAGNOSIS_BODY),
                ("mitigation", DIAGNOSIS_BODY),
            ], records
            assert problem.mitigation_oracle.repaired_observations == [False]
            assert conductor.results["Mitigation"]["success"] is False
            assert conductor.submission_stage == "done"

            # A real mitigation action and submission after the stale grade cannot
            # repair the result: the public endpoint reports that grading is done.
            problem.repaired = True
            result_before_late_submit = dict(conductor.results["Mitigation"])
            late_legitimate = server.post(MITIGATION_SIGNAL)
            result_after_late_submit = dict(conductor.results["Mitigation"])
            assert late_legitimate.json()["status"] == "done"
            assert result_after_late_submit == result_before_late_submit
            assert capture.snapshot() == records

            # Execute a real repository caller, not a hand-written stand-in.
            # TierZero consumes /status here and its main flow branches on "done"
            # at driver.py:324-327, returning before it runs mitigation.
            tierzero_driver.CONDUCTOR_URL = server.base_url
            consumer_stage = tierzero_driver.wait_for_stage(
                {"mitigation", "done"},
                timeout=2,
            )
            assert consumer_stage == "done"

            print("LEVEL1 mode=public-http-plus-timing-only-runtime-breakpoint")
            print("LEVEL1 first_response=" + json.dumps(response_summary(first), sort_keys=True))
            print("LEVEL1 transition_window=" + json.dumps(window_snapshot, sort_keys=True))
            print("LEVEL1 endpoint_retry_window=" + json.dumps(retry_snapshot, sort_keys=True))
            print(
                "LEVEL1 delayed_duplicate_response="
                + json.dumps(duplicate_result["response"], sort_keys=True)
            )
            print("LEVEL1 evaluations=" + json.dumps(records))
            print(
                "LEVEL1 mitigation_repaired_at_evaluation="
                + str(problem.mitigation_oracle.repaired_observations[0]).lower()
            )
            print(f"LEVEL1 final_stage={conductor.submission_stage}")
            print(
                "LEVEL1 persisted_mitigation_success="
                + str(conductor.results["Mitigation"]["success"]).lower()
            )
            print(
                "LEVEL1 late_legitimate_mitigation_response="
                + json.dumps(response_summary(late_legitimate), sort_keys=True)
            )
            print(
                "REAL_CONSUMER clients/tierzero/driver.py:170-185 returned "
                f"stage={consumer_stage}; branch at :324-327 skips mitigation"
            )
            print(
                "PERSISTED_CONSUMER main.py:462-467 "
                f"publishes Mitigation.success={conductor.results['Mitigation']['success']}"
            )
            print(
                "DOWNSTREAM_RESOLUTION none: late legitimate submission was not evaluated "
                "and the stored grade stayed false"
            )
            print(
                "EXPECTED stale diagnosis retry rejected; remain at mitigation until "
                "a post-repair mitigation submission"
            )
            print(
                "ACTUAL stale diagnosis retry accepted for mitigation; benchmark finalized "
                "before any mitigation action/submission"
            )
            print("RESULT BUG_TRIGGERED MC-2")
    finally:
        release_transition.set()
        threading.settrace(None)
        conductor.logger.removeHandler(capture)

    if trace_failures:
        raise AssertionError(trace_failures)


def main() -> None:
    print(f"SOURCE_REPO={REPO_ROOT}")
    print(f"SOURCE_SHA=d9a0663e3930d90bd98122e8a852cf8d27c410ec")
    print(f"PYTHON={sys.version.split()[0]}")
    level0_immediate_duplicate()
    level1_transition_timing()


if __name__ == "__main__":
    main()

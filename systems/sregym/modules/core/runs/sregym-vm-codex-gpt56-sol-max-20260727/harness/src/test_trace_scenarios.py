"""Deterministic trace scenarios over the instrumented real SREGym code.

The tests execute the actual Conductor, ClusterStateManager, Conductor API, and
NoiseManager methods.  Only external Kubernetes/service boundaries are replaced
with in-memory test doubles, as a real fresh cluster is not available in the
Phase 2.5 worker.
"""

from __future__ import annotations

import asyncio
import enum
import logging
import os
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any


SOURCE_ROOT = Path(__file__).resolve().parents[2]
if str(SOURCE_ROOT) not in sys.path:
    sys.path.insert(0, str(SOURCE_ROOT))


def _module(name: str, **attributes: Any) -> types.ModuleType:
    module = types.ModuleType(name)
    module.__dict__.update(attributes)
    sys.modules[name] = module
    return module


class _Noop:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def __getattr__(self, name: str):
        return lambda *args, **kwargs: None


class _StartProblemResult(enum.Enum):
    SUCCESS = "success"
    SKIPPED_KHAOS_REQUIRED = "skipped_khaos_required"


class _DiagnosisOracle:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass


class _ProblemRegistry:
    def get_problem_instance(self, problem_id: str):
        raise AssertionError("scenario must install its problem registry")


class _BaseModel:
    def __init__(self, **values: Any) -> None:
        for key, value in values.items():
            setattr(self, key, value)


class _FastAPI:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def post(self, *args: Any, **kwargs: Any):
        return lambda function: function

    def get(self, *args: Any, **kwargs: Any):
        return lambda function: function


class _HTTPException(Exception):
    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class _FastMCP:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def tool(self, *args: Any, **kwargs: Any):
        return lambda function: function


class _Console:
    def print(self, *args: Any, **kwargs: Any) -> None:
        pass

    def log(self, *args: Any, **kwargs: Any) -> None:
        pass


class _ApiException(Exception):
    def __init__(self, message: str = "", status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class _V1Taint:
    def __init__(self, key: str, value: str | None, effect: str) -> None:
        self.key = key
        self.value = value
        self.effect = effect


class _NullApi(_Noop):
    def __getattr__(self, name: str):
        return lambda *args, **kwargs: SimpleNamespace(items=[])


class _StubKubeCtl(_Noop):
    pass


def _install_import_stubs() -> None:
    """Install only the dependency shells needed to import the real modules."""

    client_module = _module(
        "kubernetes.client",
        CoreV1Api=lambda: _NullApi(),
        RbacAuthorizationV1Api=lambda: _NullApi(),
        StorageV1Api=lambda: _NullApi(),
        ApiextensionsV1Api=lambda: _NullApi(),
        AdmissionregistrationV1Api=lambda: _NullApi(),
        CustomObjectsApi=lambda: _NullApi(),
        V1Taint=_V1Taint,
    )
    rest_module = _module("kubernetes.client.rest", ApiException=_ApiException)
    client_module.rest = rest_module
    kubernetes_module = _module("kubernetes", client=client_module)
    kubernetes_module.__path__ = []

    _module("sregym.conductor.constants", StartProblemResult=_StartProblemResult)
    _module("sregym.conductor.oracles.detection", DetectionOracle=_Noop)
    _module("sregym.conductor.oracles.diagnosis_oracle", DiagnosisOracle=_DiagnosisOracle)
    _module("sregym.conductor.problems.registry", ProblemRegistry=_ProblemRegistry)
    _module("sregym.generators.fault.inject_remote_os", RemoteOSFaultInjector=_Noop)
    _module("sregym.generators.fault.inject_virtual", VirtualizationFaultInjector=_Noop)
    _module("sregym.observer.jaeger", Jaeger=_Noop)
    _module("sregym.observer.otel_collector", OtelCollector=_Noop)
    _module("sregym.service.apps.app_registry", AppRegistry=_Noop)
    _module("sregym.service.dm_flakey_manager", DmFlakeyManager=_Noop)
    _module("sregym.service.k8s_proxy", KubernetesAPIProxy=_Noop)
    _module("sregym.service.khaos", KhaosController=_Noop)
    _module("sregym.service.kubectl", KubeCtl=_StubKubeCtl)
    _module("sregym.service.mcp_server", MCPServer=_Noop)
    _module("sregym.service.telemetry.loki", Loki=_Noop)
    _module("sregym.service.telemetry.prometheus", Prometheus=_Noop)

    pyfiglet = _module("pyfiglet", figlet_format=lambda value: value)
    pyfiglet.__path__ = []
    fastapi = _module(
        "fastapi",
        FastAPI=_FastAPI,
        Header=lambda *args, **kwargs: object(),
        HTTPException=_HTTPException,
    )
    fastapi.__path__ = []
    fastmcp = _module("fastmcp", FastMCP=_FastMCP)
    fastmcp.__path__ = []
    fastmcp_server = _module("fastmcp.server")
    fastmcp_server.__path__ = []
    _module("fastmcp.server.http", create_sse_app=lambda *args, **kwargs: object())
    _module("pydantic", BaseModel=_BaseModel)
    rich = _module("rich")
    rich.__path__ = []
    _module("rich.markdown", Markdown=_Noop)
    _module("rich.panel", Panel=_Noop)
    starlette = _module("starlette")
    starlette.__path__ = []
    _module("starlette.routing", Mount=_Noop)
    _module("uvicorn", Config=_Noop, Server=_Noop)
    _module("logger", console=_Console())


_install_import_stubs()

from sregym import tla_trace  # noqa: E402
from sregym.conductor import conductor as conductor_module  # noqa: E402
from sregym.conductor import conductor_api  # noqa: E402
from sregym.generators.noise import manager as noise_module  # noqa: E402
from sregym.service.cluster_state import ClusterStateManager  # noqa: E402


class _Metadata:
    def __init__(self, name: str, labels: dict[str, str] | None = None) -> None:
        self.name = name
        self.labels = dict(labels or {})


class _Named:
    def __init__(self, name: str) -> None:
        self.metadata = _Metadata(name)


class _Taint:
    def __init__(self, key: str, value: str | None, effect: str) -> None:
        self.key = key
        self.value = value
        self.effect = effect


class _Node:
    def __init__(self, name: str, labels: dict[str, str], taints: list[dict[str, Any]]) -> None:
        self.metadata = _Metadata(name, labels)
        self.spec = SimpleNamespace(
            taints=[_Taint(item["key"], item.get("value"), item["effect"]) for item in taints]
        )


class _Items:
    def __init__(self, items: list[Any]) -> None:
        self.items = items


class FakeCluster:
    def __init__(self) -> None:
        self.namespaces = {"baseline-ns"}
        self.cluster_roles: set[str] = set()
        self.cluster_role_bindings: set[str] = set()
        self.persistent_volumes: set[str] = set()
        self.storage_classes: set[str] = set()
        self.crds: set[str] = set()
        self.validating_webhooks: set[str] = set()
        self.mutating_webhooks: set[str] = set()
        self.node_labels = {"node-1": {"stable": "yes"}}
        self.node_taints = {"node-1": []}
        self.coredns = {"Corefile": "stable"}

    def overwrite_preexisting(self) -> None:
        self.node_labels["node-1"]["stable"] = "agent"
        tla_trace.agent_mutate(tla_trace.PRE_RESOURCE, "overwrite")


class FakeCoreV1:
    def __init__(self, cluster: FakeCluster) -> None:
        self.cluster = cluster

    def list_namespace(self) -> _Items:
        return _Items([_Named(name) for name in sorted(self.cluster.namespaces)])

    def list_persistent_volume(self) -> _Items:
        return _Items([_Named(name) for name in sorted(self.cluster.persistent_volumes)])

    def list_node(self) -> _Items:
        return _Items(
            [
                _Node(name, self.cluster.node_labels[name], self.cluster.node_taints[name])
                for name in sorted(self.cluster.node_labels)
            ]
        )

    def read_namespaced_config_map(self, name: str, namespace: str):
        return SimpleNamespace(data=dict(self.cluster.coredns))

    def replace_namespaced_config_map(self, name: str, namespace: str, body: Any) -> None:
        self.cluster.coredns = dict(body.data or {})

    def delete_persistent_volume(self, name: str) -> None:
        self.cluster.persistent_volumes.discard(name)

    def patch_node(self, name: str, body: dict[str, Any]) -> None:
        if "metadata" in body:
            for key, value in body["metadata"]["labels"].items():
                if value is None:
                    self.cluster.node_labels[name].pop(key, None)
                else:
                    self.cluster.node_labels[name][key] = value
        if "spec" in body:
            taints = body["spec"]["taints"] or []
            self.cluster.node_taints[name] = [
                {"key": item.key, "value": item.value, "effect": item.effect}
                for item in taints
            ]


class FakeRbacV1:
    def __init__(self, cluster: FakeCluster) -> None:
        self.cluster = cluster

    def list_cluster_role(self) -> _Items:
        return _Items([_Named(name) for name in sorted(self.cluster.cluster_roles)])

    def list_cluster_role_binding(self) -> _Items:
        return _Items([_Named(name) for name in sorted(self.cluster.cluster_role_bindings)])

    def delete_cluster_role(self, name: str) -> None:
        self.cluster.cluster_roles.discard(name)

    def delete_cluster_role_binding(self, name: str) -> None:
        self.cluster.cluster_role_bindings.discard(name)


class FakeStorageV1:
    def __init__(self, cluster: FakeCluster) -> None:
        self.cluster = cluster

    def list_storage_class(self) -> _Items:
        return _Items([_Named(name) for name in sorted(self.cluster.storage_classes)])

    def delete_storage_class(self, name: str) -> None:
        self.cluster.storage_classes.discard(name)


class FakeApiExtensionsV1:
    def __init__(self, cluster: FakeCluster) -> None:
        self.cluster = cluster

    def list_custom_resource_definition(self) -> _Items:
        return _Items([_Named(name) for name in sorted(self.cluster.crds)])

    def delete_custom_resource_definition(self, name: str) -> None:
        self.cluster.crds.discard(name)


class FakeAdmissionV1:
    def __init__(self, cluster: FakeCluster) -> None:
        self.cluster = cluster

    def list_validating_webhook_configuration(self) -> _Items:
        return _Items([_Named(name) for name in sorted(self.cluster.validating_webhooks)])

    def list_mutating_webhook_configuration(self) -> _Items:
        return _Items([_Named(name) for name in sorted(self.cluster.mutating_webhooks)])

    def delete_validating_webhook_configuration(self, name: str) -> None:
        self.cluster.validating_webhooks.discard(name)

    def delete_mutating_webhook_configuration(self, name: str) -> None:
        self.cluster.mutating_webhooks.discard(name)


class FakeKubectl:
    def __init__(self, cluster: FakeCluster) -> None:
        self.cluster = cluster
        self.fail_deploy_once = False

    def exec_command(self, command: str, input_data: str | None = None) -> str:
        if self.fail_deploy_once and "metrics-server" in command:
            self.fail_deploy_once = False
            raise RuntimeError("simulated process-ending deploy failure")
        if "get storageclass openebs-device" in command:
            return "openebs.io/local\nWaitForFirstConsumer"
        if "get crd -o name" in command:
            return ""
        if " --ignore-not-found -o name" in command:
            return ""
        return "ok"

    def delete_namespace(self, name: str) -> None:
        self.cluster.namespaces.discard(name)

    def gc_orphan_localpv_dirs(self) -> dict[str, int]:
        return {}

    def wait_for_ready(self, namespace: str) -> None:
        pass

    def is_emulated_cluster(self) -> bool:
        return False


class FakeApp:
    def __init__(self, cluster: FakeCluster) -> None:
        self.cluster = cluster
        self.namespace = "run-ns"
        self.namespaces = [self.namespace]
        self.name = "trace-app"
        self.app_name = self.name
        self.description = "instrumented trace application"
        self.deployed = False

    def deploy(self) -> None:
        self.deployed = True
        self.cluster.namespaces.add(self.namespace)

    def start_workload(self) -> None:
        pass

    def cleanup(self) -> None:
        # Deliberately leave the namespace for real reconciliation code to
        # observe and delete, exercising current-minus-baseline cleanup.
        self.deployed = False


class FakeDiagnosisOracle(_DiagnosisOracle):
    def __init__(
        self,
        started: threading.Event | None = None,
        release: threading.Event | None = None,
    ) -> None:
        self.started = started
        self.release = release

    def load_diagnosis_checkpoint(self) -> None:
        pass

    def evaluate(self, solution: str) -> dict[str, Any]:
        if self.started is not None:
            self.started.set()
        if self.release is not None and not self.release.wait(timeout=10):
            raise TimeoutError("scenario did not release the diagnosis oracle")
        return {"success": True}


class FakeMitigationOracle:
    def capture_baseline(self) -> None:
        pass

    def evaluate(self) -> dict[str, Any]:
        return {"success": True}


class FakeProblem:
    def __init__(
        self,
        cluster: FakeCluster,
        started: threading.Event | None = None,
        release: threading.Event | None = None,
    ) -> None:
        self.app = FakeApp(cluster)
        self.diagnosis_oracle = FakeDiagnosisOracle(started, release)
        self.mitigation_oracle = FakeMitigationOracle()

    def requires_khaos(self) -> bool:
        # Trace.tla's InjectFault action tracks a reinjection monitor.
        return True

    def inject_fault(self) -> None:
        pass

    def recover_fault(self) -> None:
        pass


class FakeRegistry:
    def __init__(self, factory):
        self.factory = factory

    def get_problem_instance(self, problem_id: str) -> FakeProblem:
        return self.factory()


class FakeService:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    def deploy(self) -> None:
        pass

    def create_external_name_service(self, namespace: str) -> None:
        pass

    def ensure_deployed(self) -> None:
        pass


def make_cluster_state(cluster: FakeCluster, kubectl: FakeKubectl) -> ClusterStateManager:
    manager = object.__new__(ClusterStateManager)
    manager.kubectl = kubectl
    manager.baseline = None
    manager.core_v1 = FakeCoreV1(cluster)
    manager.rbac_v1 = FakeRbacV1(cluster)
    manager.storage_v1 = FakeStorageV1(cluster)
    manager.apiextensions_v1 = FakeApiExtensionsV1(cluster)
    manager.admission_v1 = FakeAdmissionV1(cluster)
    return manager


def wait_until(predicate, message: str, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise TimeoutError(message)


class TraceScenarioTests(unittest.TestCase):
    def setUp(self) -> None:
        logging.disable(logging.CRITICAL)
        self.tempdir = tempfile.TemporaryDirectory(prefix="sregym-trace-")
        self.addCleanup(self.tempdir.cleanup)
        self.noise_managers: list[Any] = []

        trace_path = os.environ.get("SPECULA_TRACE_FILE")
        if not trace_path:
            self.fail("SPECULA_TRACE_FILE is required")
        request_ids_by_test = {
            "test_normal_diagnosis": ["req-normal"],
            "test_duplicate_transport": ["req-duplicate"],
            "test_timeout_cleanup_and_late_submission": ["req-eval", "req-late"],
            "test_crash_restart_loads_baseline": ["trace-default-request"],
        }
        tla_trace.initialize(trace_path, request_ids_by_test[self._testMethodName], strict=True)

    def tearDown(self) -> None:
        # Close first so terminating harness-owned daemon threads cannot append
        # lifecycle events after the scenario's intentional endpoint.
        tla_trace.close()
        for manager in self.noise_managers:
            manager.running = False
            thread = manager._background_thread
            if thread is not None:
                thread.join(timeout=2)
            manager._background_thread = None
        noise_module.NoiseManager._instance = None
        logging.disable(logging.NOTSET)

    def make_conductor(
        self,
        cluster: FakeCluster,
        *,
        enable_noise: bool,
        started: threading.Event | None = None,
        release: threading.Event | None = None,
    ):
        conductor = conductor_module.Conductor(
            conductor_module.ConductorConfig(deploy_loki=False, enable_noise=enable_noise)
        )
        kubectl = FakeKubectl(cluster)
        conductor.kubectl = kubectl
        conductor.cluster_state = make_cluster_state(cluster, kubectl)
        conductor._baseline_captured = False
        conductor.problems = FakeRegistry(lambda: FakeProblem(cluster, started, release))
        conductor.problem_id = "trace-problem"
        conductor.dependency_check = lambda binaries: None
        conductor.fix_kubernetes = lambda: None
        conductor.get_problem_stages = lambda: setattr(conductor, "tasklist", ["diagnosis", "mitigation"])
        conductor.khaos = FakeService()
        conductor.dm_flakey_manager = FakeService()
        conductor.prometheus = FakeService()
        conductor.jaeger = FakeService()
        conductor.otel_collector = FakeService()
        conductor.loki = FakeService()
        conductor.mcp_server = FakeService()
        conductor_module.CLUSTER_BASELINE_STATE_FILE = Path(self.tempdir.name) / "cluster-baseline.json"

        if enable_noise:
            noise_module.NoiseManager._instance = None
            manager = noise_module.NoiseManager()
            manager.kubectl = kubectl
            manager._chaos_mesh_ready = True
            manager._ensure_chaos_mesh_installed = lambda: setattr(manager, "_chaos_mesh_ready", True)
            manager._loop_sleep_seconds = 0.01
            self.noise_managers.append(manager)
        return conductor

    def start_problem(self, conductor: Any) -> None:
        result = asyncio.run(conductor.start_problem())
        self.assertEqual(result, _StartProblemResult.SUCCESS)
        if conductor.config.enable_noise:
            manager = noise_module.get_noise_manager()
            wait_until(
                lambda: bool(manager.active_experiments),
                "noise manager did not apply its first real experiment",
            )

    def submit_via_real_api(self, conductor: Any, request_id: str, solution: str = "diagnosis") -> None:
        conductor_api.set_conductor(conductor)
        request = conductor_api.SubmitRequest(solution=solution)
        result = asyncio.run(
            conductor_api.submit_solution(request, trace_request_id=request_id)
        )
        self.assertEqual(result["status"], "200")

    def wait_for_evaluation(self, conductor: Any) -> None:
        future = conductor._submit_future
        self.assertIsNotNone(future)
        future.result(timeout=15)

    def test_normal_diagnosis(self) -> None:
        cluster = FakeCluster()
        conductor = self.make_conductor(cluster, enable_noise=True)
        self.start_problem(conductor)

        request_id = tla_trace.send_submission("req-normal")
        self.submit_via_real_api(conductor, request_id)
        self.wait_for_evaluation(conductor)

        self.assertEqual(conductor.submission_stage, "mitigation")
        self.assertTrue(conductor.waiting_for_agent)
        wait_until(
            lambda: bool(noise_module.get_noise_manager().active_experiments),
            "noise did not restart for mitigation",
        )

    def test_duplicate_transport(self) -> None:
        started = threading.Event()
        release = threading.Event()
        cluster = FakeCluster()
        conductor = self.make_conductor(
            cluster,
            enable_noise=True,
            started=started,
            release=release,
        )
        self.start_problem(conductor)

        request_id = tla_trace.send_submission("req-duplicate")
        tla_trace.delay_or_duplicate(request_id)
        self.submit_via_real_api(conductor, request_id, "first copy")
        self.assertTrue(started.wait(timeout=10))
        self.submit_via_real_api(conductor, request_id, "delayed copy")
        release.set()
        self.wait_for_evaluation(conductor)

        self.assertEqual(conductor.submission_stage, "mitigation")

    def test_timeout_cleanup_and_late_submission(self) -> None:
        cluster = FakeCluster()
        conductor = self.make_conductor(cluster, enable_noise=True)
        self.start_problem(conductor)

        eval_request = tla_trace.send_submission("req-eval")
        self.submit_via_real_api(conductor, eval_request)
        self.wait_for_evaluation(conductor)
        wait_until(
            lambda: bool(noise_module.get_noise_manager().active_experiments),
            "noise did not restart before timeout cleanup",
        )

        cluster.overwrite_preexisting()
        tla_trace.agent_mitigate()

        # The request passes the transport/API precheck at mitigation, then the
        # driver times out and tears down before Conductor.submit consumes it.
        late_request = tla_trace.send_submission("req-late")
        claimed_request, received_index = tla_trace.receive_submission(late_request)
        conductor.finish_after_agent_timeout(17)

        with tla_trace.request_context(claimed_request, received_index):
            result = asyncio.run(conductor.submit("arrived after precheck"))
            self.assertTrue(result["timed_out"])
            tla_trace.acknowledge(claimed_request)

        self.assertEqual(conductor.submission_stage, "done")
        self.assertNotIn("run-ns", cluster.namespaces)
        self.assertEqual(cluster.node_labels["node-1"]["stable"], "yes")

    def test_crash_restart_loads_baseline(self) -> None:
        cluster = FakeCluster()
        first = self.make_conductor(cluster, enable_noise=False)
        first.kubectl.fail_deploy_once = True
        with self.assertRaisesRegex(RuntimeError, "process-ending deploy failure"):
            asyncio.run(first.start_problem())

        # This call represents the durable harness supervisor observing that
        # the instrumented process exited without Conductor teardown.
        tla_trace.crash()

        second = self.make_conductor(cluster, enable_noise=False)
        self.start_problem(second)

        self.assertEqual(second.submission_stage, "diagnosis")
        self.assertTrue(second._baseline_captured)


if __name__ == "__main__":
    unittest.main(verbosity=2)

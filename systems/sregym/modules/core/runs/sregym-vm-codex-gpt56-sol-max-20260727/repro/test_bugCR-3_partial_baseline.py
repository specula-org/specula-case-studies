#!/usr/bin/env python3
"""CR-3 reproduction using ClusterStateManager's public persistence/reconcile APIs.

The in-process HTTP server speaks the Kubernetes API shapes consumed by the
project's declared kubernetes client dependency. It returns one legitimate,
transient HTTP 503 for ClusterRole listing, then recovers. No internal
ClusterStateManager state is injected and the source under test is not patched.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


OUTPUT_ROOT = Path(__file__).resolve().parents[1]
WORKTREE = OUTPUT_ROOT / "confirmation" / "CR-3" / "worktree"
SOURCE_FILE = WORKTREE / "sregym" / "service" / "cluster_state.py"

if not SOURCE_FILE.exists():
    raise SystemExit(f"source checkout not found: {SOURCE_FILE}")

# The checkout's KubeCtl wrapper pulls in unrelated CLI/UI dependencies. The
# manager only needs these three methods in this reproduction, so provide the
# same collaborator interface while all resource operations still travel
# through the real generated Kubernetes API client over HTTP.
kubectl_stub = types.ModuleType("sregym.service.kubectl")


class KubeCtlAdapter:
    def __init__(self, core_v1: Any | None = None):
        self.core_v1 = core_v1

    def delete_namespace(self, name: str) -> None:
        assert self.core_v1 is not None
        self.core_v1.delete_namespace(name)

    def gc_orphan_localpv_dirs(self) -> dict[str, int]:
        return {}

    def exec_command(self, _command: str) -> str:
        return ""


kubectl_stub.KubeCtl = KubeCtlAdapter
sys.modules["sregym.service.kubectl"] = kubectl_stub
sys.path.insert(0, str(WORKTREE))
os.environ.pop("SREGYM_TRACE_FILE", None)

from kubernetes import client  # noqa: E402
from sregym.service.cluster_state import ClusterStateManager  # noqa: E402


def status_body(code: int, reason: str, message: str) -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "Status",
        "metadata": {},
        "status": "Failure" if code >= 400 else "Success",
        "reason": reason,
        "message": message,
        "code": code,
    }


class ClusterFixture:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.roles: dict[str, dict[str, Any]] = {}
        self.fail_next_cluster_role_lists = 0
        self.cluster_role_list_statuses: list[int] = []
        self.deleted_roles: list[str] = []
        self.created_roles: list[str] = []
        self.replaced_roles: list[str] = []

    @staticmethod
    def normalize_role(body: dict[str, Any]) -> dict[str, Any]:
        name = body["metadata"]["name"]
        return {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": {"name": name, "resourceVersion": "1"},
            "rules": body.get("rules") or [],
        }


class KubernetesHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], fixture: ClusterFixture):
        self.fixture = fixture
        super().__init__(address, KubernetesHandler)


class KubernetesHandler(BaseHTTPRequestHandler):
    server: KubernetesHTTPServer

    LIST_ENDPOINTS = {
        "/api/v1/namespaces": ("v1", "NamespaceList"),
        "/api/v1/persistentvolumes": ("v1", "PersistentVolumeList"),
        "/api/v1/nodes": ("v1", "NodeList"),
        "/apis/rbac.authorization.k8s.io/v1/clusterrolebindings": (
            "rbac.authorization.k8s.io/v1",
            "ClusterRoleBindingList",
        ),
        "/apis/storage.k8s.io/v1/storageclasses": ("storage.k8s.io/v1", "StorageClassList"),
        "/apis/apiextensions.k8s.io/v1/customresourcedefinitions": (
            "apiextensions.k8s.io/v1",
            "CustomResourceDefinitionList",
        ),
        "/apis/admissionregistration.k8s.io/v1/validatingwebhookconfigurations": (
            "admissionregistration.k8s.io/v1",
            "ValidatingWebhookConfigurationList",
        ),
        "/apis/admissionregistration.k8s.io/v1/mutatingwebhookconfigurations": (
            "admissionregistration.k8s.io/v1",
            "MutatingWebhookConfigurationList",
        ),
    }
    ROLES_PATH = "/apis/rbac.authorization.k8s.io/v1/clusterroles"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def send_json(self, code: int, body: dict[str, Any]) -> None:
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def role_name(self, path: str) -> str | None:
        prefix = self.ROLES_PATH + "/"
        return unquote(path[len(prefix) :]) if path.startswith(prefix) else None

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        fixture = self.server.fixture

        if path == self.ROLES_PATH:
            with fixture.lock:
                if fixture.fail_next_cluster_role_lists:
                    fixture.fail_next_cluster_role_lists -= 1
                    fixture.cluster_role_list_statuses.append(503)
                    self.send_json(503, status_body(503, "ServiceUnavailable", "transient apiserver outage"))
                    return
                fixture.cluster_role_list_statuses.append(200)
                items = list(fixture.roles.values())
            self.send_json(
                200,
                {
                    "apiVersion": "rbac.authorization.k8s.io/v1",
                    "kind": "ClusterRoleList",
                    "metadata": {"resourceVersion": "1"},
                    "items": items,
                },
            )
            return

        role_name = self.role_name(path)
        if role_name is not None:
            with fixture.lock:
                role = fixture.roles.get(role_name)
            if role is None:
                self.send_json(404, status_body(404, "NotFound", f"ClusterRole {role_name} not found"))
            else:
                self.send_json(200, role)
            return

        if path == "/api/v1/namespaces/kube-system/configmaps/coredns":
            self.send_json(404, status_body(404, "NotFound", "CoreDNS is absent in this bare fixture"))
            return

        if path in self.LIST_ENDPOINTS:
            api_version, kind = self.LIST_ENDPOINTS[path]
            self.send_json(
                200,
                {
                    "apiVersion": api_version,
                    "kind": kind,
                    "metadata": {"resourceVersion": "1"},
                    "items": [],
                },
            )
            return

        self.send_json(404, status_body(404, "NotFound", f"unsupported path {path}"))

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path != self.ROLES_PATH:
            self.send_json(404, status_body(404, "NotFound", f"unsupported path {path}"))
            return

        fixture = self.server.fixture
        role = fixture.normalize_role(self.read_json())
        name = role["metadata"]["name"]
        with fixture.lock:
            fixture.roles[name] = role
            fixture.created_roles.append(name)
        self.send_json(201, role)

    def do_PUT(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        name = self.role_name(path)
        if name is None:
            self.send_json(404, status_body(404, "NotFound", f"unsupported path {path}"))
            return

        fixture = self.server.fixture
        role = fixture.normalize_role(self.read_json())
        assert role["metadata"]["name"] == name
        with fixture.lock:
            if name not in fixture.roles:
                self.send_json(404, status_body(404, "NotFound", f"ClusterRole {name} not found"))
                return
            fixture.roles[name] = role
            fixture.replaced_roles.append(name)
        self.send_json(200, role)

    def do_DELETE(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        name = self.role_name(path)
        if name is None:
            self.send_json(404, status_body(404, "NotFound", f"unsupported path {path}"))
            return

        fixture = self.server.fixture
        with fixture.lock:
            existed = fixture.roles.pop(name, None) is not None
            if existed:
                fixture.deleted_roles.append(name)
        code = 200 if existed else 404
        reason = "Success" if existed else "NotFound"
        self.send_json(code, status_body(code, reason, f"deleted={existed}"))


def role(name: str, verbs: list[str]) -> client.V1ClusterRole:
    return client.V1ClusterRole(
        api_version="rbac.authorization.k8s.io/v1",
        kind="ClusterRole",
        metadata=client.V1ObjectMeta(name=name),
        rules=[client.V1PolicyRule(api_groups=[""], resources=["pods"], verbs=verbs)],
    )


def new_manager() -> ClusterStateManager:
    manager = ClusterStateManager(KubeCtlAdapter())
    manager.kubectl.core_v1 = manager.core_v1
    return manager


def role_names(api: client.RbacAuthorizationV1Api) -> set[str]:
    return {item.metadata.name for item in api.list_cluster_role().items}


def role_verbs(api: client.RbacAuthorizationV1Api, name: str) -> list[str]:
    current = api.read_cluster_role(name)
    return list(current.rules[0].verbs)


def main() -> None:
    fixture = ClusterFixture()
    server = KubernetesHTTPServer(("127.0.0.1", 0), fixture)
    server_thread = threading.Thread(target=server.serve_forever, name="fake-kube-apiserver", daemon=True)
    server_thread.start()

    configuration = client.Configuration()
    configuration.host = f"http://127.0.0.1:{server.server_address[1]}"
    configuration.verify_ssl = False
    configuration.debug = False
    client.Configuration.set_default(configuration)

    critical_role = "baseline-critical-reader"
    deleted_role = "baseline-must-be-restored"
    mutated_role = "baseline-must-not-be-escalated"

    try:
        with tempfile.TemporaryDirectory(prefix="cr3-repro-") as tmp:
            tmp_path = Path(tmp)

            # Positive control: the identical public save/load/reconcile flow is
            # safe when every baseline observation succeeds.
            control_writer = new_manager()
            control_writer.rbac_v1.create_cluster_role(role(critical_role, ["get"]))
            control_file = tmp_path / "complete-control.json"
            control_writer.save_baseline_state(control_file)
            control_reader = new_manager()
            control_loaded = control_reader.load_baseline_state(control_file)
            control_changes = control_reader.reconcile_to_baseline()
            control_present = critical_role in role_names(control_reader.rbac_v1)
            assert control_loaded
            assert control_present
            assert control_changes["cluster_roles_deleted"] == []

            # CR-3 trigger: the Kubernetes endpoint transiently returns a valid
            # HTTP 503. The manager's public save API catches the resulting
            # ApiException, persists an empty authoritative collection, and a
            # restarted manager accepts it.
            with fixture.lock:
                fixture.fail_next_cluster_role_lists = 1
            partial_writer = new_manager()
            partial_file = tmp_path / "partial.json"
            partial_writer.save_baseline_state(partial_file)
            serialized = json.loads(partial_file.read_text())
            partial_reader = new_manager()
            partial_loaded = partial_reader.load_baseline_state(partial_file)
            primary_changes = partial_reader.reconcile_to_baseline()
            present_after_reconcile = critical_role in role_names(partial_reader.rbac_v1)
            partial_reader.reconcile_to_baseline()
            present_after_second_reconcile = critical_role in role_names(partial_reader.rbac_v1)

            assert serialized["cluster_roles"] == []
            assert partial_loaded
            assert primary_changes["cluster_roles_deleted"] == [critical_role]
            assert not present_after_reconcile
            assert not present_after_second_reconcile

            # Exercise the other name-only reconciliation paths through normal
            # Kubernetes APIs: capture two objects successfully, delete one,
            # mutate the other's rules, then reconcile.
            complete_writer = new_manager()
            complete_writer.rbac_v1.create_cluster_role(role(deleted_role, ["get"]))
            complete_writer.rbac_v1.create_cluster_role(role(mutated_role, ["get"]))
            restoration_file = tmp_path / "complete-restoration.json"
            complete_writer.save_baseline_state(restoration_file)

            restoration_reader = new_manager()
            restoration_loaded = restoration_reader.load_baseline_state(restoration_file)
            restoration_reader.rbac_v1.delete_cluster_role(deleted_role)
            restoration_reader.rbac_v1.replace_cluster_role(mutated_role, role(mutated_role, ["delete"]))
            posts_before_reconcile = len(fixture.created_roles)
            restoration_changes = restoration_reader.reconcile_to_baseline()
            names_after_restoration = role_names(restoration_reader.rbac_v1)
            verbs_after_restoration = role_verbs(restoration_reader.rbac_v1, mutated_role)
            restoration_reader.reconcile_to_baseline()
            names_after_second_restoration = role_names(restoration_reader.rbac_v1)
            verbs_after_second_restoration = role_verbs(restoration_reader.rbac_v1, mutated_role)
            posts_after_reconcile = len(fixture.created_roles)

            assert restoration_loaded
            assert restoration_changes["cluster_roles_deleted"] == []
            assert deleted_role not in names_after_restoration
            assert deleted_role not in names_after_second_restoration
            assert verbs_after_restoration == ["delete"]
            assert verbs_after_second_restoration == ["delete"]
            assert posts_after_reconcile == posts_before_reconcile

            print(f"SOURCE_FILE={SOURCE_FILE}")
            print("ESCALATION_LEVEL=0 (public save/load/reconcile APIs; no SUT patch or internal-state injection)")
            print(
                "REAL_API_SEQUENCE=create ClusterRole -> save baseline while list returns HTTP 503 "
                "-> restart/load -> reconcile"
            )
            print(f"CONTROL_COMPLETE_CAPTURE_ROLE_PRESENT={control_present}")
            print(f"CLUSTER_ROLE_LIST_HTTP_STATUSES={fixture.cluster_role_list_statuses}")
            print(f"PARTIAL_SNAPSHOT_CLUSTER_ROLES={serialized['cluster_roles']}")
            print(f"PARTIAL_SNAPSHOT_LOAD_ACCEPTED={partial_loaded}")
            print(f"RECONCILE_DELETED={primary_changes['cluster_roles_deleted']}")
            print(f"ROLE_PRESENT_AFTER_RECONCILE={present_after_reconcile}")
            print(f"ROLE_PRESENT_AFTER_SECOND_RECONCILE={present_after_second_reconcile}")
            print(f"DELETED_BASELINE_ROLE_RECREATED={deleted_role in names_after_restoration}")
            print(f"MUTATED_BASELINE_ROLE_VERBS_AFTER_RECONCILE={verbs_after_restoration}")
            print(f"RECONCILE_CREATE_CALLS={posts_after_reconcile - posts_before_reconcile}")
            print("RESULT=BUG TRIGGERED: a transient partial baseline was persisted and caused permanent deletion")
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=5)


if __name__ == "__main__":
    main()

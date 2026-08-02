#!/usr/bin/env python3
"""MC-3 reproduction: a persisted cluster-A baseline is trusted on cluster B.

Escalation:
  Level 0: probe for a real kubectl-backed runtime.
  Level 1: record why timing assistance cannot supply an absent runtime.
  Level 2: inject the reachable MCReplaceCluster precondition through faithful
           Kubernetes client adapters, while exercising the real production
           save/load/reconcile methods without changing their logic.

The injected state is admissible counterexample State 8, reached from State 7
MCCrash. The test itself creates the old file through save_baseline_state; it
does not hand-build an inconsistent ClusterBaseline object or JSON document.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import types
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace


REPRO_DIR = Path(__file__).resolve().parent
WORKTREE = Path(
    os.environ.get(
        "SREGYM_WORKTREE",
        REPRO_DIR.parent / "confirmation" / "MC-3" / "worktree",
    )
).resolve()
sys.path.insert(0, str(WORKTREE))


class ApiException(Exception):
    def __init__(self, status: int | None = None):
        super().__init__(f"Kubernetes API status {status}")
        self.status = status


# Provide only the Kubernetes dependency surface used by the production module.
# Every returned value below is a valid shape a Kubernetes Python client can
# return; the production ClusterStateManager implementation remains unmodified.
kubernetes_package = types.ModuleType("kubernetes")
kubernetes_package.__path__ = []
client_module = types.ModuleType("kubernetes.client")
rest_module = types.ModuleType("kubernetes.client.rest")
rest_module.ApiException = ApiException
kubernetes_package.client = client_module
sys.modules["kubernetes"] = kubernetes_package
sys.modules["kubernetes.client"] = client_module
sys.modules["kubernetes.client.rest"] = rest_module

# ClusterStateManager imports KubeCtl only for its public adapter type. Avoid
# importing the command runner and its unrelated optional dependencies.
kubectl_module = types.ModuleType("sregym.service.kubectl")
kubectl_module.KubeCtl = object
sys.modules["sregym.service.kubectl"] = kubectl_module


@dataclass
class Cluster:
    name: str
    namespaces: set[str]
    cluster_roles: set[str]
    cluster_role_bindings: set[str]
    coredns: dict[str, str]
    namespace_payloads: dict[str, str] = field(default_factory=dict)
    persistent_volumes: set[str] = field(default_factory=set)
    storage_classes: set[str] = field(default_factory=set)
    crds: set[str] = field(default_factory=set)
    validating_webhooks: set[str] = field(default_factory=set)
    mutating_webhooks: set[str] = field(default_factory=set)


active_cluster: Cluster | None = None


def _active() -> Cluster:
    assert active_cluster is not None
    return active_cluster


def _named_items(names: set[str]) -> SimpleNamespace:
    return SimpleNamespace(
        items=[
            SimpleNamespace(metadata=SimpleNamespace(name=name))
            for name in sorted(names)
        ]
    )


class CoreV1Api:
    def __init__(self, cluster: Cluster):
        self.cluster = cluster

    def list_namespace(self) -> SimpleNamespace:
        return _named_items(self.cluster.namespaces)

    def list_persistent_volume(self) -> SimpleNamespace:
        return _named_items(self.cluster.persistent_volumes)

    def delete_persistent_volume(self, name: str) -> None:
        self.cluster.persistent_volumes.discard(name)

    def list_node(self) -> SimpleNamespace:
        return SimpleNamespace(items=[])

    def read_namespaced_config_map(
        self, name: str, namespace: str
    ) -> SimpleNamespace:
        assert (name, namespace) == ("coredns", "kube-system")
        return SimpleNamespace(data=dict(self.cluster.coredns))

    def replace_namespaced_config_map(
        self, name: str, namespace: str, body: SimpleNamespace
    ) -> None:
        assert (name, namespace) == ("coredns", "kube-system")
        self.cluster.coredns = dict(body.data)

    def patch_node(self, name: str, body: dict) -> None:
        raise AssertionError(f"unexpected node patch for {name}: {body}")


class RbacAuthorizationV1Api:
    def __init__(self, cluster: Cluster):
        self.cluster = cluster

    def list_cluster_role(self) -> SimpleNamespace:
        return _named_items(self.cluster.cluster_roles)

    def list_cluster_role_binding(self) -> SimpleNamespace:
        return _named_items(self.cluster.cluster_role_bindings)

    def delete_cluster_role(self, name: str) -> None:
        self.cluster.cluster_roles.discard(name)

    def delete_cluster_role_binding(self, name: str) -> None:
        self.cluster.cluster_role_bindings.discard(name)


class StorageV1Api:
    def __init__(self, cluster: Cluster):
        self.cluster = cluster

    def list_storage_class(self) -> SimpleNamespace:
        return _named_items(self.cluster.storage_classes)

    def delete_storage_class(self, name: str) -> None:
        self.cluster.storage_classes.discard(name)


class ApiextensionsV1Api:
    def __init__(self, cluster: Cluster):
        self.cluster = cluster

    def list_custom_resource_definition(self) -> SimpleNamespace:
        return _named_items(self.cluster.crds)

    def delete_custom_resource_definition(self, name: str) -> None:
        self.cluster.crds.discard(name)


class AdmissionregistrationV1Api:
    def __init__(self, cluster: Cluster):
        self.cluster = cluster

    def list_validating_webhook_configuration(self) -> SimpleNamespace:
        return _named_items(self.cluster.validating_webhooks)

    def list_mutating_webhook_configuration(self) -> SimpleNamespace:
        return _named_items(self.cluster.mutating_webhooks)

    def delete_validating_webhook_configuration(self, name: str) -> None:
        self.cluster.validating_webhooks.discard(name)

    def delete_mutating_webhook_configuration(self, name: str) -> None:
        self.cluster.mutating_webhooks.discard(name)


class CustomObjectsApi:
    def __init__(self) -> None:
        self.cluster = _active()


client_module.CoreV1Api = lambda: CoreV1Api(_active())
client_module.RbacAuthorizationV1Api = lambda: RbacAuthorizationV1Api(_active())
client_module.StorageV1Api = lambda: StorageV1Api(_active())
client_module.ApiextensionsV1Api = lambda: ApiextensionsV1Api(_active())
client_module.AdmissionregistrationV1Api = (
    lambda: AdmissionregistrationV1Api(_active())
)
client_module.CustomObjectsApi = CustomObjectsApi
client_module.V1Taint = lambda **kwargs: SimpleNamespace(**kwargs)


class KubeCtlAdapter:
    """Faithful side-effect adapter for the production KubeCtl calls used here."""

    def __init__(self, cluster: Cluster):
        self.cluster = cluster
        self.deleted_namespaces: list[str] = []
        self.commands: list[str] = []

    def delete_namespace(self, namespace: str) -> None:
        self.deleted_namespaces.append(namespace)
        self.cluster.namespaces.discard(namespace)
        # Kubernetes namespace deletion removes its namespaced payloads.
        self.cluster.namespace_payloads.pop(namespace, None)

    def gc_orphan_localpv_dirs(self) -> dict[str, int]:
        return {}

    def exec_command(self, command: str) -> str:
        self.commands.append(command)
        return ""


from sregym.paths import CLUSTER_BASELINE_STATE_FILE
from sregym.service.cluster_state import ClusterStateManager


def _snapshot(cluster: Cluster) -> dict:
    return {
        "namespaces": sorted(cluster.namespaces),
        "cluster_roles": sorted(cluster.cluster_roles),
        "cluster_role_bindings": sorted(cluster.cluster_role_bindings),
        "coredns": cluster.coredns,
        "namespace_payloads": cluster.namespace_payloads,
    }


def main() -> None:
    global active_cluster

    print(f"SOURCE_MODULE={Path(sys.modules[ClusterStateManager.__module__].__file__).resolve()}")
    print(f"CONFIGURED_BASELINE_PATH={CLUSTER_BASELINE_STATE_FILE}")

    kubectl = shutil.which("kubectl")
    if kubectl is None:
        print(
            "LEVEL_0=NOT_TRIGGERED: kubectl is absent; no live Kubernetes "
            "public API is available for a black-box cluster replacement"
        )
    else:
        raise AssertionError(
            "This deterministic Level-2 test expects the recorded runner "
            "preflight with no live kubectl"
        )

    print(
        "LEVEL_1=NOT_TRIGGERED: timing assistance cannot create the missing "
        "Kubernetes runtime, so Level 0's environment limit remains"
    )
    print(
        "LEVEL_2=START: real save_baseline_state -> admissible MCCrash/MCReplaceCluster "
        "precondition -> real load_baseline_state -> real reconcile_to_baseline"
    )
    print(
        "COUNTEREXAMPLE_SEQUENCE=State 7 MCCrash -> State 8 MCReplaceCluster "
        "(clusterGen 1, persistedBaselineGen 0) -> State 9 restart -> "
        "State 10 MCStartProblem -> State 11 old baseline authoritative"
    )

    cluster_a = Cluster(
        name="cluster-a",
        namespaces={"default", "kube-system", "cluster-a-tenant"},
        cluster_roles={"cluster-a-platform-controller"},
        cluster_role_bindings={"cluster-a-platform-controller-binding"},
        coredns={"Corefile": "cluster-a.example"},
        namespace_payloads={"cluster-a-tenant": "cluster-a-data"},
    )
    cluster_b = Cluster(
        name="cluster-b",
        namespaces={"default", "kube-system", "replacement-tenant"},
        cluster_roles={"replacement-platform-controller"},
        cluster_role_bindings={"replacement-platform-controller-binding"},
        coredns={"Corefile": "cluster-b.example"},
        namespace_payloads={"replacement-tenant": "legitimate-cluster-b-data"},
    )

    with tempfile.TemporaryDirectory(prefix="mc3-baseline-") as temp_dir:
        baseline_path = Path(temp_dir) / CLUSTER_BASELINE_STATE_FILE.name

        # Public API capture on cluster A: no hand-authored baseline precondition.
        active_cluster = cluster_a
        manager_a = ClusterStateManager(KubeCtlAdapter(cluster_a))
        manager_a.save_baseline_state(baseline_path)
        persisted = json.loads(baseline_path.read_text())
        provenance_fields = {
            "cluster_id",
            "cluster_identity",
            "generation",
            "schema_version",
            "complete",
        }
        assert provenance_fields.isdisjoint(persisted)
        print(f"PERSISTED_KEYS={','.join(sorted(persisted))}")
        print("PERSISTED_PROVENANCE=none")

        # State 7 crash discards process memory; State 8 replaces the live cluster
        # while preserving the same user's home-directory cache file.
        del manager_a
        active_cluster = cluster_b
        kubectl_b = KubeCtlAdapter(cluster_b)
        manager_b = ClusterStateManager(kubectl_b)

        before = _snapshot(cluster_b)
        loaded = manager_b.load_baseline_state(baseline_path)
        print(f"LOAD_ACCEPTED={loaded}")
        print(f"CLUSTER_B_BEFORE={json.dumps(before, sort_keys=True)}")
        assert loaded is True
        assert manager_b.baseline is not None
        assert "replacement-tenant" not in manager_b.baseline.namespaces

        first_changes = manager_b.reconcile_to_baseline()
        after_first = _snapshot(cluster_b)
        print(
            "FIRST_RECONCILE_CHANGES="
            f"{json.dumps(first_changes, sort_keys=True)}"
        )
        print(f"CLUSTER_B_AFTER_FIRST={json.dumps(after_first, sort_keys=True)}")

        assert first_changes["namespaces_deleted"] == ["replacement-tenant"]
        assert first_changes["cluster_roles_deleted"] == [
            "replacement-platform-controller"
        ]
        assert first_changes["cluster_role_bindings_deleted"] == [
            "replacement-platform-controller-binding"
        ]
        assert first_changes["coredns_reset"] is True
        assert "replacement-tenant" not in cluster_b.namespaces
        assert "replacement-tenant" not in cluster_b.namespace_payloads
        assert "replacement-platform-controller" not in cluster_b.cluster_roles
        assert (
            "replacement-platform-controller-binding"
            not in cluster_b.cluster_role_bindings
        )
        assert cluster_b.coredns == {"Corefile": "cluster-a.example"}

        # A second production reconciliation has no restore path for resources
        # deleted by the first; it proves the bad result is not a transient
        # snapshot repaired by the system under test.
        second_changes = manager_b.reconcile_to_baseline()
        after_second = _snapshot(cluster_b)
        print(
            "SECOND_RECONCILE_CHANGES="
            f"{json.dumps(second_changes, sort_keys=True)}"
        )
        print(f"CLUSTER_B_AFTER_SECOND={json.dumps(after_second, sort_keys=True)}")
        assert after_second == after_first
        assert second_changes["namespaces_deleted"] == []
        assert second_changes["cluster_roles_deleted"] == []
        assert second_changes["cluster_role_bindings_deleted"] == []
        assert second_changes["coredns_reset"] is False

        # Negative control: when the same production serializer captures cluster
        # B and that matching file is loaded, reconciliation preserves B.
        control_cluster_b = Cluster(
            name="cluster-b-control",
            namespaces={"default", "kube-system", "replacement-tenant"},
            cluster_roles={"replacement-platform-controller"},
            cluster_role_bindings={"replacement-platform-controller-binding"},
            coredns={"Corefile": "cluster-b.example"},
            namespace_payloads={
                "replacement-tenant": "legitimate-cluster-b-data"
            },
        )
        control_path = Path(temp_dir) / "matching-cluster-b-baseline.json"
        active_cluster = control_cluster_b
        control_capture = ClusterStateManager(KubeCtlAdapter(control_cluster_b))
        control_capture.save_baseline_state(control_path)
        del control_capture

        control_manager = ClusterStateManager(KubeCtlAdapter(control_cluster_b))
        assert control_manager.load_baseline_state(control_path) is True
        control_changes = control_manager.reconcile_to_baseline()
        control_after = _snapshot(control_cluster_b)
        print(
            "MATCHED_BASELINE_CONTROL_CHANGES="
            f"{json.dumps(control_changes, sort_keys=True)}"
        )
        print(
            "MATCHED_BASELINE_CONTROL_AFTER="
            f"{json.dumps(control_after, sort_keys=True)}"
        )
        assert control_changes["namespaces_deleted"] == []
        assert control_changes["cluster_roles_deleted"] == []
        assert control_changes["cluster_role_bindings_deleted"] == []
        assert control_changes["coredns_reset"] is False
        assert control_after == _snapshot(
            Cluster(
                name="expected-cluster-b",
                namespaces={"default", "kube-system", "replacement-tenant"},
                cluster_roles={"replacement-platform-controller"},
                cluster_role_bindings={
                    "replacement-platform-controller-binding"
                },
                coredns={"Corefile": "cluster-b.example"},
                namespace_payloads={
                    "replacement-tenant": "legitimate-cluster-b-data"
                },
            )
        )

    print(
        "REAL_CONSUMERS=sregym/service/cluster_state.py:227-374 -> "
        "sregym/service/kubectl.py:498-503"
    )
    print(
        "PERMANENCE=confirmed: a second production reconciliation neither "
        "recreates the namespace/RBAC nor restores cluster B's CoreDNS value"
    )
    print(
        "BUG_TRIGGERED: parseable cluster-A baseline caused deletion of "
        "legitimate cluster-B namespace/RBAC and overwrote cluster-B CoreDNS"
    )
    print("LEVEL_3=NOT_ATTEMPTED: Level 2 reproduced without source modification")


if __name__ == "__main__":
    main()

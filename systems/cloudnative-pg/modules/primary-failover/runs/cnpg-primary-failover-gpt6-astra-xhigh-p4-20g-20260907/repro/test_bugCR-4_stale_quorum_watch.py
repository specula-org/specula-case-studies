#!/usr/bin/env python3
"""Level-1 reproduction for CR-4 against a real CloudNativePG cluster.

The only timing assistance is a reverse proxy that withholds events from the
operator's already-established FailoverQuorum watch.  It forwards all API
requests and every other watch unchanged, and never creates or edits an API
object.  PostgreSQL, the instance managers, and the Kubernetes API continue to
run normally while that watch is delayed.

Requirements: docker, kind, kubectl, openssl, and network access if the three
container images are not already local.  Set CR4_KEEP_CLUSTER=1 to retain the
ephemeral cluster after the assertion.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time


CLUSTER = "cr4-quorum-evidence"
CONTEXT = f"kind-{CLUSTER}"
NAMESPACE = "cr4-repro"
DB_CLUSTER = "cr4"
CONTROL = f"{CLUSTER}-control-plane"
PROXY_CONTAINER = "cr4-watch-proxy"
OPERATOR_CONTAINER = "cr4-external-operator"
OPERATOR_IMAGE = "ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0"
POSTGRES_IMAGE = "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie"
PROXY_IMAGE = "python:3.13-alpine"
OUTPUT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_REPO = OUTPUT_ROOT / "confirmation" / "CR-4" / "worktree"
OPERATOR_MANIFEST = SOURCE_REPO / "releases" / "cnpg-1.30.0.yaml"
KEEP_CLUSTER = os.environ.get("CR4_KEEP_CLUSTER") == "1"


KIND_CONFIG = """\
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
"""


DATABASE_MANIFEST = f"""\
apiVersion: v1
kind: Namespace
metadata:
  name: {NAMESPACE}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {DB_CLUSTER}
  namespace: {NAMESPACE}
spec:
  instances: 3
  imageName: {POSTGRES_IMAGE}
  affinity:
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
  postgresql:
    synchronous:
      method: any
      number: 2
      dataDurability: required
      failoverQuorum: true
  storage:
    size: 1Gi
"""


PROXY_SOURCE = r'''#!/usr/bin/env python3
"""Forward Kubernetes traffic while optionally delaying one real watch."""

import http.client
import json
import os
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 6443
LISTEN_PORT = 18080
state_lock = threading.Lock()
freeze_failover_quorum = False

def frozen():
    with state_lock:
        return freeze_failover_quorum

def set_frozen(value):
    global freeze_failover_quorum
    with state_lock:
        freeze_failover_quorum = value

tls = ssl.create_default_context()
tls.check_hostname = False
tls.verify_mode = ssl.CERT_NONE
tls.load_cert_chain("/certs/client.crt", "/certs/client.key")

HOP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}

class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("PROXY " + (fmt % args), flush=True)

    def control(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/__control/freeze":
            set_frozen(True)
        elif parsed.path == "/__control/unfreeze":
            set_frozen(False)
        elif parsed.path != "/__control/status":
            return False
        payload = json.dumps({"freezeFailoverQuorum": frozen()}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()
        print("CONTROL freezeFailoverQuorum=" + str(frozen()).lower(), flush=True)
        return True

    def do_GET(self):
        if not self.control():
            self.forward()

    def do_POST(self):
        if not self.control():
            self.forward()

    def do_PUT(self):
        self.forward()

    def do_PATCH(self):
        self.forward()

    def do_DELETE(self):
        self.forward()

    def forward(self):
        parsed = urlsplit(self.path)
        is_watch = parse_qs(parsed.query).get("watch", ["false"])[0].lower() in {"1", "true"}
        is_fq = "/failoverquorums" in parsed.path
        raw_len = self.headers.get("Content-Length")
        body = self.rfile.read(int(raw_len)) if raw_len else None
        headers = {
            key: value for key, value in self.headers.items()
            if key.lower() not in HOP_HEADERS | {"host", "accept-encoding", "content-length"}
        }
        if body is not None:
            headers["Content-Length"] = str(len(body))
        headers["Accept-Encoding"] = "identity"
        if is_watch:
            headers["Accept"] = "application/json"

        conn = http.client.HTTPSConnection(UPSTREAM_HOST, UPSTREAM_PORT, context=tls, timeout=600)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            response = conn.getresponse()
            if is_watch:
                self.send_response(response.status, response.reason)
                for key, value in response.getheaders():
                    if key.lower() not in HOP_HEADERS | {"content-length", "date", "server"}:
                        self.send_header(key, value)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                while True:
                    line = response.readline()
                    if not line:
                        break
                    if is_fq:
                        try:
                            event = json.loads(line)
                            obj = event.get("object", {})
                            status = obj.get("status", {})
                            marker = (
                                f"type={event.get('type')} "
                                f"rv={obj.get('metadata', {}).get('resourceVersion')} "
                                f"primary={status.get('primary')} "
                                f"number={status.get('standbyNumber')}"
                            )
                        except Exception:
                            marker = "unparsed"
                        if frozen():
                            print("FQ_DROP " + marker, flush=True)
                            continue
                        print("FQ_FORWARD " + marker, flush=True)
                    self.wfile.write(f"{len(line):X}\r\n".encode() + line + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
                return

            payload = response.read()
            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                if key.lower() not in HOP_HEADERS | {"content-length", "date", "server"}:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            print(f"PROXY_ERROR method={self.command} path={self.path} error={exc!r}", flush=True)
            try:
                self.send_error(502, str(exc))
            except Exception:
                pass
        finally:
            conn.close()

server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), ProxyHandler)
print(f"READY listen={LISTEN_PORT} upstream={UPSTREAM_HOST}:{UPSTREAM_PORT}", flush=True)
server.serve_forever()
'''


class Failure(RuntimeError):
    pass


def command(
    argv: list[str],
    *,
    input_text: str | None = None,
    timeout: int = 180,
    check: bool = True,
) -> str:
    try:
        result = subprocess.run(
            argv,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise Failure(f"timed out after {timeout}s: {' '.join(argv)}") from exc
    if check and result.returncode != 0:
        raise Failure(
            f"command failed ({result.returncode}): {' '.join(argv)}\n{result.stdout}"
        )
    return result.stdout.strip()


def kubectl(*args: str, input_text: str | None = None, timeout: int = 180) -> str:
    return command(
        ["kubectl", "--context", CONTEXT, *args],
        input_text=input_text,
        timeout=timeout,
    )


def kube_json(*args: str) -> dict:
    return json.loads(kubectl(*args, "-o", "json"))


def wait_for(description: str, predicate, timeout: int = 300, interval: float = 2.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except (Failure, json.JSONDecodeError, KeyError, IndexError):
            pass
        time.sleep(interval)
    raise Failure(f"timeout waiting for {description}; last observation: {last!r}")


def remove_test_environment() -> None:
    for name in (OPERATOR_CONTAINER, PROXY_CONTAINER):
        command(["docker", "rm", "-f", name], timeout=30, check=False)
    command(["kind", "delete", "cluster", "--name", CLUSTER], timeout=180, check=False)


def ensure_image(image: str) -> None:
    if command(["docker", "image", "inspect", image], timeout=30, check=False) == "":
        command(["docker", "pull", image], timeout=600)


def node_for_pod(pod: str) -> str:
    return kubectl(
        "-n", NAMESPACE, "get", "pod", pod,
        "-o", "jsonpath={.spec.nodeName}",
    )


def cluster_status() -> dict:
    return kube_json("-n", NAMESPACE, "get", "cluster", DB_CLUSTER).get("status", {})


def fq_status() -> dict:
    return kube_json("-n", NAMESPACE, "get", "failoverquorum", DB_CLUSTER).get("status", {})


def psql(pod: str, sql: str) -> str:
    return kubectl(
        "-n", NAMESPACE, "exec", pod, "-c", "postgres", "--",
        "psql", "-v", "ON_ERROR_STOP=1", "-Atqc", sql,
        timeout=90,
    )


def docker_logs(container: str) -> str:
    return command(["docker", "logs", container], timeout=30, check=False)


def last_matching_line(text: str, *needles: str) -> str:
    matches = [line for line in text.splitlines() if all(needle in line for needle in needles)]
    if not matches:
        raise Failure(f"no line contains all of {needles!r}")
    return matches[-1]


def start_external_operator(temp: Path) -> None:
    admin_conf = temp / "admin.conf"
    command(["docker", "cp", f"{CONTROL}:/etc/kubernetes/admin.conf", str(admin_conf)])
    config_text = admin_conf.read_text()
    cert_match = re.search(r"client-certificate-data:\s*(\S+)", config_text)
    key_match = re.search(r"client-key-data:\s*(\S+)", config_text)
    if not cert_match or not key_match:
        raise Failure("could not extract the kind administrator client certificate")

    cert_dir = temp / "proxy-certs"
    cert_dir.mkdir()
    (cert_dir / "client.crt").write_bytes(base64.b64decode(cert_match.group(1)))
    (cert_dir / "client.key").write_bytes(base64.b64decode(key_match.group(1)))
    proxy_path = temp / "watch_proxy.py"
    proxy_path.write_text(PROXY_SOURCE)

    kubeconfig_path = temp / "proxy-kubeconfig.yaml"
    kubeconfig_path.write_text(textwrap.dedent("""\
        apiVersion: v1
        kind: Config
        clusters:
          - name: proxied
            cluster:
              server: http://127.0.0.1:18080
        contexts:
          - name: proxied
            context:
              cluster: proxied
              user: local-proxy
        current-context: proxied
        users:
          - name: local-proxy
            user: {}
        """))

    webhook_dir = temp / "webhook"
    webhook_dir.mkdir()
    command([
        "openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
        "-keyout", str(webhook_dir / "tls.key"),
        "-out", str(webhook_dir / "tls.crt"),
        "-subj", "/CN=localhost", "-days", "1",
    ], timeout=60)
    # Outside a Pod there is no kubelet secret-volume projector.  Seed the
    # dedicated mount with the exact serving secret that the normal operator
    # already created; the operator verifies byte-for-byte equality at start.
    webhook_secret = kube_json(
        "-n", "cnpg-system", "get", "secret", "cnpg-webhook-cert",
    )
    for name, payload in webhook_secret.get("data", {}).items():
        (webhook_dir / name).write_bytes(base64.b64decode(payload))
    # The operator's PKI setup refreshes these files from its Kubernetes
    # secrets before starting the controllers.
    webhook_dir.chmod(0o777)
    for mounted_secret in webhook_dir.iterdir():
        mounted_secret.chmod(0o666)

    command([
        "docker", "run", "-d", "--name", PROXY_CONTAINER,
        "--network", f"container:{CONTROL}",
        "-v", f"{proxy_path}:/proxy.py:ro",
        "-v", f"{cert_dir}:/certs:ro",
        PROXY_IMAGE, "python", "/proxy.py",
    ])
    wait_for(
        "the timing proxy",
        lambda: "READY listen=18080" in docker_logs(PROXY_CONTAINER),
        timeout=60,
        interval=1,
    )

    env = [
        "-e", "MANAGE_WEBHOOK_CONFIGURATIONS=false",
        "-e", "KUBECONFIG=/kubeconfig",
        "-e", "OPERATOR_NAMESPACE=cnpg-system",
        "-e", f"OPERATOR_IMAGE_NAME={OPERATOR_IMAGE}",
        "-e", f"POSTGRES_IMAGE_NAME={POSTGRES_IMAGE}",
        "-e", "MONITORING_QUERIES_CONFIGMAP=cnpg-default-monitoring",
    ]
    command([
        "docker", "run", "-d", "--name", OPERATOR_CONTAINER,
        "--network", f"container:{CONTROL}",
        *env,
        "-v", f"{kubeconfig_path}:/kubeconfig:ro",
        "-v", f"{webhook_dir}:/run/secrets/cnpg.io/webhook",
        OPERATOR_IMAGE,
        "controller", "--leader-elect=false",
        "--metrics-bind-address=127.0.0.1:18081",
        "--webhook-port=19443", "--max-concurrent-reconciles=1",
    ])
    wait_for(
        "the external operator controllers",
        lambda: (
            command(
                ["docker", "inspect", "-f", "{{.State.Running}}", OPERATOR_CONTAINER],
                timeout=10,
                check=False,
            ) == "true"
            and "Starting workers" in docker_logs(OPERATOR_CONTAINER)
        ),
        timeout=90,
        interval=1,
    )
    logs = docker_logs(OPERATOR_CONTAINER)
    if any(marker in logs for marker in (
        "error loading config file", "unable to start manager", "unable to setup PKI",
    )):
        raise Failure("external operator failed to start:\n" + logs[-4000:])


def main() -> None:
    for executable in ("docker", "kind", "kubectl", "openssl"):
        if shutil.which(executable) is None:
            raise Failure(f"missing required executable: {executable}")
    if not OPERATOR_MANIFEST.is_file():
        raise Failure(f"missing operator manifest: {OPERATOR_MANIFEST}")

    print("CR-4 level=1: Kubernetes watch delivery delay only", flush=True)
    print(f"source_head={command(['git', '-C', str(SOURCE_REPO), 'rev-parse', 'HEAD'])}", flush=True)
    remove_test_environment()

    ensure_image(OPERATOR_IMAGE)
    ensure_image(POSTGRES_IMAGE)
    ensure_image(PROXY_IMAGE)

    with tempfile.TemporaryDirectory(prefix="cr4-repro-") as temp_name:
        temp = Path(temp_name)
        kind_config = temp / "kind.yaml"
        kind_config.write_text(KIND_CONFIG)
        command([
            "kind", "create", "cluster", "--name", CLUSTER,
            "--config", str(kind_config), "--wait", "180s",
        ], timeout=300)
        kubectl("apply", "--server-side", "-f", str(OPERATOR_MANIFEST), timeout=180)
        kubectl(
            "-n", "cnpg-system", "patch", "deployment", "cnpg-controller-manager",
            "--type=merge", "-p", json.dumps({
                "spec": {"template": {"spec": {
                    "nodeSelector": {"kubernetes.io/hostname": CONTROL},
                    "tolerations": [{
                        "key": "node-role.kubernetes.io/control-plane",
                        "operator": "Exists",
                        "effect": "NoSchedule",
                    }],
                }}},
            }),
        )
        kubectl(
            "-n", "cnpg-system", "rollout", "status",
            "deployment/cnpg-controller-manager", "--timeout=180s",
            timeout=210,
        )
        wait_for(
            "the operator admission webhook",
            lambda: (
                output if "cluster.postgresql.cnpg.io/cr4" in (
                    output := command(
                        ["kubectl", "--context", CONTEXT, "apply", "-f", "-"],
                        input_text=DATABASE_MANIFEST,
                        timeout=45,
                        check=False,
                    )
                ) else False
            ),
            timeout=180,
            interval=3,
        )

        wait_for(
            "three ready database instances",
            lambda: cluster_status().get("readyInstances") == 3,
            timeout=420,
            interval=3,
        )
        initial = fq_status()
        if initial.get("standbyNumber") != 2 or initial.get("primary") != "cr4-1":
            raise Failure(f"unexpected initial FailoverQuorum: {initial}")
        psql("cr4-1", "create table cr4_probe(id text primary key)")
        wait_for(
            "probe table on the future stale replica",
            lambda: psql("cr4-3", "select to_regclass('cr4_probe') is not null") == "t",
            timeout=90,
        )
        print(
            "initial_quorum=" + json.dumps({
                "primary": initial.get("primary"),
                "standbyNumber": initial.get("standbyNumber"),
                "standbyNames": initial.get("standbyNames"),
            }, sort_keys=True),
            flush=True,
        )

        # Keep the central controller alive on the control plane while the two
        # database nodes used for each simulated failure are stopped.
        kubectl(
            "-n", "cnpg-system", "scale", "deployment/cnpg-controller-manager",
            "--replicas=0",
        )
        webhooks = kube_json("get", "mutatingwebhookconfigurations").get("items", [])
        webhooks += kube_json("get", "validatingwebhookconfigurations").get("items", [])
        for webhook in webhooks:
            name = webhook["metadata"]["name"]
            if "cnpg" in name:
                kind = webhook["kind"].lower()
                kubectl("delete", kind, name, "--ignore-not-found=true")
        start_external_operator(temp)

        primary_node = node_for_pod("cr4-1")
        ack_node = node_for_pod("cr4-2")
        stale_node = node_for_pod("cr4-3")
        if len({primary_node, ack_node, stale_node}) != 3:
            raise Failure("pod anti-affinity did not place the instances on separate nodes")

        # First move normally to W=1.  The FailoverQuorum informer is lazy and
        # has not been needed by the healthy-cluster reconcile yet.
        kubectl(
            "-n", NAMESPACE, "patch", "cluster", DB_CLUSTER,
            "--type=merge", "-p", json.dumps({
                "spec": {"postgresql": {"synchronous": {
                    "method": "any", "number": 1,
                    "dataDurability": "required", "failoverQuorum": True,
                }}},
            }),
        )
        wait_for(
            "the priming W=1 status",
            lambda: fq_status().get("standbyNumber") == 1,
            timeout=180,
        )
        wait_for(
            "the priming W=1 PostgreSQL runtime",
            lambda: "ANY 1" in psql("cr4-1", "show synchronous_standby_names"),
            timeout=180,
        )

        # Force the real controller to read W=1 once.  With only cr4-3
        # available, equality correctly denies failover (R=1, W=1, N=2).
        command(["docker", "stop", "-t", "0", primary_node, ack_node], timeout=60)
        kubectl(
            "-n", NAMESPACE, "delete", "pod", "cr4-1", "cr4-2",
            "--force", "--grace-period=0", "--wait=false",
        )
        wait_for(
            "the operator's safe W=1 denial",
            lambda: (
                '"isStronglyConsistent":false' in docker_logs(OPERATOR_CONTAINER)
                and "FQ_FORWARD" in docker_logs(PROXY_CONTAINER)
                and "number=1" in docker_logs(PROXY_CONTAINER)
            ),
            timeout=180,
            interval=2,
        )
        denied = last_matching_line(
            docker_logs(OPERATOR_CONTAINER),
            '"isStronglyConsistent":false', '"writeSetCardinality":1',
        )
        print("priming_denial=" + denied, flush=True)

        command(["docker", "start", primary_node, ack_node], timeout=60)
        wait_for(
            "all Kubernetes nodes to recover",
            lambda: all(
                item.get("status") == "True"
                for node in kube_json("get", "nodes").get("items", [])
                for item in node.get("status", {}).get("conditions", [])
                if item.get("type") == "Ready"
            ),
            timeout=240,
            interval=3,
        )
        wait_for(
            "three ready instances after priming",
            lambda: cluster_status().get("readyInstances") == 3,
            timeout=420,
            interval=3,
        )

        # Deliver a genuine newer W=2 observation to the established watch.
        kubectl(
            "-n", NAMESPACE, "patch", "cluster", DB_CLUSTER,
            "--type=merge", "-p", json.dumps({
                "spec": {"postgresql": {"synchronous": {
                    "method": "any", "number": 2,
                    "dataDurability": "required", "failoverQuorum": True,
                }}},
            }),
        )
        wait_for(
            "the real W=2 status to be forwarded after recovery",
            lambda: (
                fq_status().get("standbyNumber") == 2
                and "FQ_FORWARD" in docker_logs(PROXY_CONTAINER)
                and "number=2" in docker_logs(PROXY_CONTAINER)
            ),
            timeout=180,
        )
        wait_for(
            "PostgreSQL to apply the delivered W=2 epoch",
            lambda: "ANY 2" in psql("cr4-1", "show synchronous_standby_names"),
            timeout=180,
        )

        control = command([
            "docker", "exec", PROXY_CONTAINER, "python", "-c",
            "import urllib.request; print(urllib.request.urlopen("
            "'http://127.0.0.1:18080/__control/freeze').read().decode())",
        ])
        if '"freezeFailoverQuorum": true' not in control:
            raise Failure(f"watch did not freeze: {control}")

        # This is a normal Cluster API update.  Instance managers apply W=1
        # and publish the reset/new status to the real API while the old W=2
        # event remains in the central controller's delayed cache.
        kubectl(
            "-n", NAMESPACE, "patch", "cluster", DB_CLUSTER,
            "--type=merge", "-p", json.dumps({
                "spec": {"postgresql": {"synchronous": {
                    "method": "any", "number": 1,
                    "dataDurability": "required", "failoverQuorum": True,
                }}},
            }),
        )
        wait_for(
            "the live FailoverQuorum API to publish W=1",
            lambda: fq_status().get("standbyNumber") == 1,
            timeout=180,
        )
        runtime = wait_for(
            "PostgreSQL to apply W=1",
            lambda: (
                value if "ANY 1" in (value := psql("cr4-1", "show synchronous_standby_names"))
                else False
            ),
            timeout=180,
        )
        wait_for(
            "the proxy to withhold the real W=1 event",
            lambda: (
                "FQ_DROP" in docker_logs(PROXY_CONTAINER)
                and "number=1" in docker_logs(PROXY_CONTAINER)
            ),
            timeout=60,
        )
        live = fq_status()
        proxy_logs = docker_logs(PROXY_CONTAINER)
        forwarded = last_matching_line(proxy_logs, "FQ_FORWARD", "number=2")
        dropped = last_matching_line(proxy_logs, "FQ_DROP", "number=1")
        print(f"runtime_synchronous_standby_names={runtime}", flush=True)
        print(
            "live_api_quorum=" + json.dumps({
                "primary": live.get("primary"),
                "standbyNumber": live.get("standbyNumber"),
                "standbyNames": live.get("standbyNames"),
            }, sort_keys=True),
            flush=True,
        )
        print("operator_cache_event=" + forwarded, flush=True)
        print("delayed_real_event=" + dropped, flush=True)

        # Pause cr4-3 before the transaction so only cr4-2 can acknowledge it.
        command(["docker", "pause", stale_node], timeout=30)
        wait_for(
            "the paused stale replica to leave pg_stat_replication",
            lambda: psql(
                "cr4-1",
                "select count(*) from pg_stat_replication where application_name='cr4-3'",
            ) == "0",
            timeout=90,
            interval=2,
        )
        psql("cr4-1", "insert into cr4_probe values ('acknowledged-under-w1')")
        primary_count = psql(
            "cr4-1", "select count(*) from cr4_probe where id='acknowledged-under-w1'",
        )
        ack_count = psql(
            "cr4-2", "select count(*) from cr4_probe where id='acknowledged-under-w1'",
        )
        replication = psql(
            "cr4-1",
            "select application_name || ':state=' || state || ':sync=' || sync_state "
            "|| ':flush=' || flush_lsn from pg_stat_replication order by application_name",
        )
        if primary_count != "1" or ack_count != "1" or "cr4-3" in replication:
            raise Failure(
                "transaction precondition failed: "
                f"primary={primary_count}, ack={ack_count}, replication={replication}"
            )
        print("commit_returned=true", flush=True)
        print(f"primary_has_row={primary_count}", flush=True)
        print(f"ack_replica_has_row={ack_count}", flush=True)
        print(f"replication_at_commit={replication}", flush=True)

        # Lose the primary and sole acknowledger, then make only the stale
        # replica available.  No object/status is injected at this step.
        primary_node = node_for_pod("cr4-1")
        ack_node = node_for_pod("cr4-2")
        command(["docker", "stop", "-t", "0", primary_node, ack_node], timeout=60)
        command(["docker", "unpause", stale_node], timeout=30)
        kubectl(
            "-n", NAMESPACE, "delete", "pod", "cr4-1", "cr4-2",
            "--force", "--grace-period=0", "--wait=false",
        )

        wait_for(
            "automatic promotion of the stale replica",
            lambda: (
                cluster_status().get("currentPrimary") == "cr4-3"
                and cluster_status().get("targetPrimary") == "cr4-3"
            ),
            timeout=300,
            interval=2,
        )
        wait_for(
            "the promoted PostgreSQL server",
            lambda: psql("cr4-3", "select pg_is_in_recovery()") == "f",
            timeout=180,
            interval=2,
        )
        promoted_count = psql(
            "cr4-3", "select count(*) from cr4_probe where id='acknowledged-under-w1'",
        )
        operator_logs = docker_logs(OPERATOR_CONTAINER)
        quorum_result = last_matching_line(
            operator_logs,
            '"isStronglyConsistent":true', '"writeSetCardinality":2',
            '"readSet":["cr4-3"]',
        )
        failover = last_matching_line(operator_logs, '"msg":"Failing over"', '"newPrimary":"cr4-3"')
        status = cluster_status()
        print("promotion_quorum_decision=" + quorum_result, flush=True)
        print("promotion_action=" + failover, flush=True)
        print(
            f"promoted_current={status.get('currentPrimary')} "
            f"target={status.get('targetPrimary')} in_recovery=false",
            flush=True,
        )
        print(f"promoted_has_acknowledged_row={promoted_count}", flush=True)
        if promoted_count != "0":
            raise Failure("the supposedly stale replica contains the acknowledged row")
        print(
            "RESULT: CR-4 REPRODUCED - a committed W=1 row was absent after "
            "promotion authorized with delayed W=2 evidence",
            flush=True,
        )


if __name__ == "__main__":
    exit_code = 0
    try:
        main()
    except Exception as exc:
        exit_code = 1
        print(f"RESULT: TEST FAILED: {exc}", file=sys.stderr, flush=True)
    finally:
        if KEEP_CLUSTER:
            print(f"cleanup=deferred cluster={CLUSTER}", flush=True)
        else:
            remove_test_environment()
            print(f"cleanup=complete cluster={CLUSTER}", flush=True)
    raise SystemExit(exit_code)

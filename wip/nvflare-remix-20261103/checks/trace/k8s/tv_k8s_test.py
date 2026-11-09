"""v11 block E group-level trace harness (JobCP_C under k8sJob).

Runs the real K8sJobHandle (terminate / wait / terminal-state release) against a
fake Kubernetes API, as upstream tests/unit_test/app_opt/job_launcher/
k8s_launcher_test.py does, together with the real WorkspaceTransferManager
(add_job, publish_results handler, remove_job) on a stub cell whose file
download writes a real results zip. Events go to $TV_K8S_OUT/<scenario>.json:
  env  sp (CHECK/DEPLOY/START from SP) | cjexit | abort
  obs  launch l | pubstart l | pubdone l | exit l | deletefail l
"""
import io
import json
import os
import sys
import zipfile
from types import ModuleType
from unittest.mock import MagicMock

OUT = os.environ.get("TV_K8S_OUT", "/tmp/tv_k8s")


class _FakeApiException(Exception):
    def __init__(self, status=None, reason=None, http_resp=None):
        self.status = status
        self.reason = reason


def _install_fake_kubernetes():
    k8s, client, config, rest, api, core = (ModuleType(n) for n in (
        "kubernetes", "kubernetes.client", "kubernetes.config", "kubernetes.client.rest",
        "kubernetes.client.api", "kubernetes.client.api.core_v1_api"))
    rest.ApiException = _FakeApiException
    client.Configuration = MagicMock()
    client.rest, client.api = rest, api
    core.CoreV1Api = MagicMock
    api.core_v1_api = core
    k8s.config, k8s.client = config, client
    for name, mod in {"kubernetes": k8s, "kubernetes.config": config, "kubernetes.client": client,
                      "kubernetes.client.rest": rest, "kubernetes.client.api": api,
                      "kubernetes.client.api.core_v1_api": core}.items():
        sys.modules[name] = mod


_install_fake_kubernetes()
from nvflare.app_opt.job_launcher import workspace_cell_transfer as wct  # noqa: E402
from nvflare.app_opt.job_launcher.k8s_launcher import JobState, K8sJobHandle, PodPhase  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.cellnet.utils import new_cell_message  # noqa: E402


class _StubCell:
    def __init__(self):
        self.cbs = {}

    def get_fqcn(self):
        return "site-1"

    def register_request_cb(self, channel, topic, cb):
        self.cbs[topic] = cb


def _job_config():
    return {"name": "job-1", "image": "nvflare/nvflare:test", "container_name": "c", "command": "x",
            "volume_mount_list": [], "volume_list": [], "module_args": {}, "set_list": [], "resources": {}}


def _results_zip(job_id, dest):
    path = os.path.join(dest, "results.zip")
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(f"{job_id}/app/result.txt", "ok")
    return path


def _pod(phase):
    pod = MagicMock()
    pod.status.phase = phase
    pod.status.container_statuses = []
    pod.status.conditions = []
    pod.metadata.uid = "uid-1"
    return pod


def _run(scn, delete_fails, tmp_path, monkeypatch):
    ev = []
    tr = lambda name, **kw: ev.append(dict(ev=name, **kw))
    job_id = "job-1"
    cell = _StubCell()
    mgr = wct.WorkspaceTransferManager(cell)
    monkeypatch.setattr(wct, "download_file", lambda **kw: (None, _results_zip(job_id, kw["location"])))
    monkeypatch.setattr(wct, "_validate_job_zip_members", lambda zf, jid: None)
    real_remove = mgr.remove_job

    def remove_job(jid):
        had = mgr._get_record(jid) is not None
        real_remove(jid)
        if had and state.get("in_publish"):
            tr("pubdone", l=1)

    mgr.remove_job = remove_job
    state = {}
    tr("sp")
    # launch_job: the workspace record and the Pod (the CP's start pipeline)
    token = mgr.add_job(job_id, str(tmp_path / "ws"))
    api = MagicMock()
    api.read_namespaced_pod.return_value = _pod(PodPhase.RUNNING.value)
    handle = K8sJobHandle(job_id, api, _job_config(), workspace_transfer=mgr, workspace_job_id=job_id)
    handle.job_id = job_id
    tr("launch", l=1)
    if not delete_fails:
        # the CJ publishes its results at shutdown; the handler authorizes, downloads,
        # extracts, then removes the record
        req = new_cell_message({MessageHeaderKey.ORIGIN: "site-1.job-1"},
                               {"job_id": job_id, "transfer_token": token, "ref_id": "r1"})
        tr("pubstart", l=1)
        state["in_publish"] = True
        reply = cell.cbs[wct.TOPIC_PUBLISH_RESULTS](req)
        state["in_publish"] = False
        assert reply.get_header(MessageHeaderKey.RETURN_CODE) == ReturnCode.OK, reply.payload
        tr("cjexit")
        api.read_namespaced_pod.return_value = _pod(PodPhase.SUCCEEDED.value)
        handle.wait()
        assert handle.terminal_state == JobState.SUCCEEDED
        tr("exit", l=1)
    else:
        tr("abort")
        api.delete_namespaced_pod.side_effect = _FakeApiException(status=500, reason="Internal")
        handle.terminate()
        assert handle.terminal_state == JobState.TERMINATED
        assert mgr._get_record(job_id) is None
        tr("deletefail", l=1)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, f"{scn}.json"), "w") as f:
        json.dump(ev, f, indent=1)
    return ev


def test_k8s_publish_and_exit(tmp_path, monkeypatch):
    ev = _run("k8s_ok", False, tmp_path, monkeypatch)
    assert [e["ev"] for e in ev] == ["sp", "launch", "pubstart", "pubdone", "cjexit", "exit"]


def test_k8s_delete_failure_releases(tmp_path, monkeypatch):
    ev = _run("k8s_deletefail", True, tmp_path, monkeypatch)
    assert ev[-1]["ev"] == "deletefail"

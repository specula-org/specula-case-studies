"""v10 Worker-group trace harness: run the real task-worker code path and log port events.

Real code: TaskWorkerExecutor, TaskSupervisor, FileTaskArtifactStore, the worker process
(task_worker_process -> run_worker -> Client API task runner), real Client API scripts.
Stand-in: the upstream test-only ProcessTaskLauncher for the Kubernetes backend, so the CP
task owner (K8sTaskService) and the Pod lifecycle are not observed (silent in the trace).
Environment events (input, abort, receipt, CJ launch) are driven here and logged as such.
Each scenario writes checks/trace/worker/traces/<name>.json. Pinned source c411a201.
"""
import hashlib
import json
import os
import threading
import time
from dataclasses import replace
from pathlib import Path

import pytest

from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, ReturnCode, TaskResultReceipt
from nvflare.apis.signal import Signal
from nvflare.apis.task_launcher_spec import TaskExecutionInterrupted
from nvflare.fuel.utils.config_service import ConfigService
from nvflare.private.defs import RequestHeader
from nvflare.private.fed.task_worker import supervisor as sup_mod
from nvflare.private.fed.task_worker.artifacts import FileTaskArtifactStore
from tests.task_execution_test_utils import _adapter
from tests.task_execution_test_utils import native_task as _native_task

native_task = _native_task
OUT = Path(os.environ["TV_WORKER_OUT"])

CKPT_SCRIPT = """
import os, sys, time
from pathlib import Path
import nvflare.client as flare
flare.init()
model = flare.receive()
MODE = "@MODE@"
if MODE == "crash":
    os._exit(3)
if MODE == "fail":
    raise RuntimeError("tv: script failure before send")
if MODE == "slow":
    time.sleep(30)
paths = flare.system_info()["task_checkpoint"]
previous = int(Path(paths["input"]).read_text()) if paths["input"] else 0
Path(paths["output"]).write_text(str(previous + 1))
flare.send(flare.FLModel(params=model.params, metrics={"previous": previous}))
"""


class Recorder:
    def __init__(self):
        self.events, self.ids, self.flags = [], {}, {}
        self.launch, self.lock = 1, threading.Lock()

    def ev(self, ev_name, **kw):
        with self.lock:
            self.events.append(dict(ev=ev_name, **kw))

    def bind(self, launch_id, l, server_attempt, a):
        wid = hashlib.sha256(json.dumps([launch_id, server_attempt]).encode()).hexdigest()
        self.ids[wid] = (l, a)

    def w(self, identity):
        return list(self.ids[identity.attempt_id])


@pytest.fixture
def rec(monkeypatch):
    r = Recorder()
    o_create = FileTaskArtifactStore.create_attempt
    o_release = FileTaskArtifactStore.release_payloads
    o_confirm = sup_mod.TaskSupervisor._confirm_settlement
    o_cancel = sup_mod.TaskSupervisor._cancel
    o_receipt = sup_mod.TaskSupervisor.record_receipt
    o_saved = sup_mod.TaskSupervisor.read_saved_result
    o_recover = sup_mod.TaskSupervisor.recover_checkpoint_result

    def create_attempt(self, identity):
        out = o_create(self, identity)
        r.ev("stage", w=r.w(identity))
        return out

    def release_payloads(self, identity):
        out = o_release(self, identity)
        r.ev("release", w=r.w(identity))
        return out

    def confirm(self, attempt, status):
        out = o_confirm(self, attempt, status)
        d = attempt.store.attempt_dir(attempt.identity)
        r.ev("settled", w=r.w(attempt.identity), completion=os.path.lexists(os.path.join(d, "completion.json")),
             failure=os.path.lexists(os.path.join(d, "failure.json")))
        r.flags["settled"] = True
        return out

    o_read = FileTaskArtifactStore.read_result

    def read_result(self, identity):
        out = o_read(self, identity)
        if r.flags.pop("settled", False):
            # supervisor.run read the settled attempt's result (after its abort check)
            r.ev("validated", w=r.w(identity))
        return out

    def cancel(self, attempt):
        r.ev("cancelReq", w=r.w(attempt.identity))
        return o_cancel(self, attempt)

    def receipt(self, identity, value):
        out = o_receipt(self, identity, value)
        r.ev("receiptRec", w=r.w(identity), receipt=value)
        return out

    def saved(self, identity):
        r.flags["reason"] = "saved"
        return o_saved(self, identity)

    def recover(self, *a, **k):
        out = o_recover(self, *a, **k)
        if out is not None:
            r.flags["reason"] = "recovered"
        return out

    monkeypatch.setattr(FileTaskArtifactStore, "create_attempt", create_attempt)
    monkeypatch.setattr(FileTaskArtifactStore, "release_payloads", release_payloads)
    monkeypatch.setattr(FileTaskArtifactStore, "read_result", read_result)
    monkeypatch.setattr(sup_mod.TaskSupervisor, "_confirm_settlement", confirm)
    monkeypatch.setattr(sup_mod.TaskSupervisor, "_cancel", cancel)
    monkeypatch.setattr(sup_mod.TaskSupervisor, "record_receipt", receipt)
    monkeypatch.setattr(sup_mod.TaskSupervisor, "read_saved_result", saved)
    monkeypatch.setattr(sup_mod.TaskSupervisor, "recover_checkpoint_result", recover)
    orig_get = ConfigService.get_str_var

    def get_str_var(name, *a, **k):
        if name == RequestHeader.CJ_LAUNCH_ID:
            return f"L{r.launch}"
        return orig_get(name, *a, **k)

    monkeypatch.setattr(ConfigService, "get_str_var", staticmethod(get_str_var))
    return r


class CJ:
    """One CJ launch: a TaskWorkerExecutor bound to launch l."""

    def __init__(self, rec, native_task, l, monkeypatch, mode="ok"):
        self.rec, self.l = rec, l
        root, custom, context, policy = native_task
        self.root, self.context = root, context
        rec.launch = l
        rec.ev("launch", l=l)
        orig_launch = policy.launcher.launch_task

        def k8s_status(status):
            # K8sTaskHandle._status (k8s_launcher.py:525-533): a nonzero exit is retryable;
            # the test launcher never sets it, so mirror the only implemented backend.
            return replace(status, retryable=status.exit_code not in (None, 0))

        def launch_task(request):
            handle = orig_launch(request)
            poll, wait = handle.poll, handle.wait_for_settlement
            handle.poll = lambda: k8s_status(poll())
            handle.wait_for_settlement = lambda timeout=None: k8s_status(wait(timeout=timeout))
            rec.ev("launched", l=l)
            return handle

        policy.launcher.launch_task = launch_task
        self.adapter, self.data = _adapter(custom, context, policy, script=CKPT_SCRIPT.replace("@MODE@", mode))
        self.gen = 0

    def manifest(self):
        files = sorted(self.root.rglob("*.checkpoint"))
        return files[0].read_bytes() if files else None

    def execute(self, a, signal=None, abort_first=False):
        self.gen += 1
        g = self.gen
        for k in range(1, 3):
            self.rec.bind(f"L{self.l}", self.l, f"attempt-{k}", k)
        self.context.set_prop(FLContextKey.TASK_ID, f"task-{a}", private=True, sticky=True)
        self.context.set_prop(FLContextKey.TASK_ATTEMPT_ID, f"attempt-{a}", private=True, sticky=True)
        signal = signal or Signal()
        if abort_first:
            self.rec.ev("abort", l=self.l)
            signal.trigger(True)
        self.rec.ev("input", l=self.l, gen=g, a=a)
        self.rec.flags.clear()
        self.rec.flags["reason"] = "fresh"
        before = self.manifest()
        try:
            reply = self.adapter.execute("train", self.data, self.context, signal)
            rc = reply.get_return_code(ReturnCode.OK)
            if rc == ReturnCode.OK:
                kind, reason = "result", self.rec.flags["reason"]
            elif rc == ReturnCode.TASK_ABORTED:
                kind, reason = "aborted", "abort"
            else:
                kind, reason = "error", str(rc)
        except TaskExecutionInterrupted:
            kind, reason = "interrupted", "crash"
        except RuntimeError as e:
            m = str(e)
            kind = "error"
            reason = ("workerFail" if " failed:" in m else "alreadyOwned" if "already owned" in m
                      else "missingSaved" if "no retained" in m else m[:60])
            if "checkpoint commit was cancelled" in m:
                # client_runner.py:446-452 turns it into TASK_ABORTED (abort_signal is set)
                kind, reason = "aborted", "commitGuard"
        self.rec.ev("out", l=self.l, gen=g, kind=kind, reason=reason, ckpt=self.manifest() != before)
        self.reply_ok = kind == "result"
        self.reply = reply if kind == "result" else None
        return g

    def receipt(self, g, body):
        self.rec.ev("receipt", l=self.l, gen=g, body=body)
        self.context.set_prop(FLContextKey.TASK_NAME, "train", private=True, sticky=True)
        self.context.set_prop(FLContextKey.TASK_RESULT, self.reply, private=True, sticky=False)
        self.context.set_prop(FLContextKey.TASK_RESULT_RECEIPT, body, private=True, sticky=False)
        self.adapter.handle_event(EventType.AFTER_SEND_TASK_RESULT, self.context)

    def end(self):
        self.adapter.handle_event(EventType.END_RUN, self.context)


def save(name, rec):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.json").write_text(json.dumps(rec.events, indent=1))
    print(name, json.dumps(rec.events))


def test_fresh_receipt(native_task, rec, monkeypatch):
    cj = CJ(rec, native_task, 1, monkeypatch)
    g = cj.execute(1)
    cj.receipt(g, TaskResultReceipt.RECEIVED)
    cj.end()
    save("fresh_receipt", rec)


def test_resend(native_task, rec, monkeypatch):
    cj = CJ(rec, native_task, 1, monkeypatch)
    cj.execute(1)
    cj.execute(1)
    cj.execute(2)
    g = cj.execute(1)
    cj.receipt(g, TaskResultReceipt.RECEIVED)
    cj.end()
    save("resend", rec)


def test_recovery(native_task, rec, monkeypatch):
    cj1 = CJ(rec, native_task, 1, monkeypatch)
    cj1.execute(1)
    # CJ 1 is lost after committing (no receipt); CP replaces it with launch 2.
    cj1.adapter.supervisor._stopping = True  # the dead CJ takes no further step
    cj2 = CJ(rec, native_task, 2, monkeypatch)
    g = cj2.execute(1)
    cj2.receipt(g, TaskResultReceipt.RECEIVED)
    cj2.end()
    save("recovery", rec)


def test_worker_fail(native_task, rec, monkeypatch):
    cj = CJ(rec, native_task, 1, monkeypatch, mode="fail")
    cj.execute(1)
    cj.end()
    save("worker_fail", rec)


def test_worker_crash(native_task, rec, monkeypatch):
    cj = CJ(rec, native_task, 1, monkeypatch, mode="crash")
    cj.execute(1)
    cj.end()
    save("worker_crash", rec)


def test_abort_running(native_task, rec, monkeypatch):
    cj = CJ(rec, native_task, 1, monkeypatch, mode="slow")
    signal = Signal()

    def later():
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not any(e["ev"] == "launched" for e in rec.events):
            time.sleep(0.05)
        time.sleep(1.0)
        rec.ev("abort", l=1)
        signal.trigger(True)

    t = threading.Thread(target=later)
    t.start()
    cj.execute(1, signal=signal)
    t.join()
    cj.end()
    save("abort_running", rec)


def test_abort_before_commit(native_task, rec, monkeypatch):
    cj = CJ(rec, native_task, 1, monkeypatch)
    signal = Signal()
    o_confirm = sup_mod.TaskSupervisor._confirm_settlement

    def confirm(self, attempt, status):
        out = o_confirm(self, attempt, status)
        rec.ev("abort", l=1)
        signal.trigger(True)
        return out

    monkeypatch.setattr(sup_mod.TaskSupervisor, "_confirm_settlement", confirm)
    cj.execute(1, signal=signal)
    cj.end()
    save("abort_before_commit", rec)


def test_abort_first(native_task, rec, monkeypatch):
    cj = CJ(rec, native_task, 1, monkeypatch)
    cj.execute(1, abort_first=True)
    cj.end()
    save("abort_first", rec)

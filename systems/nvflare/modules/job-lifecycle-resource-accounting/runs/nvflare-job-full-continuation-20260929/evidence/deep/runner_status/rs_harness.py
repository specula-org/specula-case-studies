#!/usr/bin/env python3
"""Phase-3 runner/status verification harness (extends a snapshot copy of evidence/harness/lifecycle_harness.py).

REAL product code exercised (pinned checkout, unmodified):
  JobRunner.run / _start_run / _job_complete_process / fail_run / stop_run / mark_run_aborted / except handler,
  DefaultJobScheduler.schedule_job / _do_schedule_job / _try_job / handle_event,
  SimpleJobDefManager + FilesystemStorage (real files in a temp dir),
  JobCommandModule.abort_job / delete_job (admin handlers),
  FederatedServer.process_job_failure (called unbound with a minimal `self` that only provides client_manager /
  engine / logger, i.e. the cell handler body is the real code),
  JobMetaValidator.validate (real submit-time validation on a real zip).

STUBS (network / process edges only; inherited from the base harness, see its docstring):
  FakeEngine RPC fan-out (resource check/cancel, START_JOB, ABORT), start_app_on_server (registers run_processes like
  ServerEngine._start_runner_process), sj_exit (mirrors ServerEngine.wait_for_complete bookkeeping), and the
  per-instance _deploy_job success stub.  abort_app_on_server -> sj_exit(rc=None): the real SJ returns normally after
  ServerRunner.abort() (server_runner.py:607-611, server_app_runner.py:52-94, mpm.run -> sys.exit(None) = 0).

REPRODUCTION CONTROLS (choose only WHEN a concurrent operation happens; product logic untouched):
  * `run_in_thread(...)`: a hook inside a stub/wrapper starts the real admin/cell handler in its own named thread and
    joins it, i.e. the concurrent operation lands exactly at that point of the runner thread.
  * wrappers around FilesystemStorage.list_objects / get_meta and SimpleJobDefManager.refresh_meta /
    save_workspace are call-through; they only trigger the hook at one chosen call.
FAULT INJECTION (only scenario N5, stated explicitly): one transient StorageException from set_status(RUNNING).
OBSERVATION: recording wrapper around set_status, event log, exception escaping JobRunner.run, thread liveness.
"""

import argparse
import io
import json
import logging
import os
import sys
import tempfile
import threading
import time
import traceback
import zipfile
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import base_harness_snapshot as bh  # noqa: E402  (snapshot copy of evidence/harness/lifecycle_harness.py)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.storage import StorageException  # noqa: E402
from nvflare.fuel.common.exit_codes import ProcessExitCode  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_meta_validator import JobMetaValidator  # noqa: E402

log = bh.log
SOURCE = bh.SOURCE


class _LogToHarness(logging.Handler):
    def emit(self, record):
        if record.levelno >= logging.WARNING or "Fail" in record.getMessage() or "not running" in record.getMessage():
            msg = record.getMessage()
            if record.exc_info:
                msg += " | EXC: " + "".join(traceback.format_exception_only(*record.exc_info[:2])).strip()
            log(f"LOG[{record.levelname}] {record.name}: {msg}")


def setup_logging():
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(_LogToHarness())


def run_in_thread(name, fn, *args, **kwargs):
    """Reproduction control: run a real handler in its own thread and wait for it (lands at this exact point)."""
    out = {}

    def target():
        try:
            out["result"] = fn(*args, **kwargs)
        except BaseException as e:  # observation only
            out["exception"] = f"{type(e).__name__}: {e}"
            log(f"{name} raised {out['exception']}")

    t = threading.Thread(target=target, name=name)
    t.start()
    t.join(timeout=30)
    return out


class _ClientManagerEdge:
    """Minimal client_manager surface used by FederatedServer.process_job_failure (fed_server.py:906-957)."""

    def __init__(self, engine):
        self._engine = engine

    def is_from_authorized_client(self, token):
        return token in self._engine.client_manager.clients

    @property
    def clients(self):
        return self._engine.client_manager.clients


def cell_report_outcome(engine, client_name, job_id, code, reason="?"):
    """Real FederatedServer.process_job_failure body, invoked as the cell handler thread would."""
    token = {c.name: t for t, c in engine.client_manager.clients.items()}[client_name]
    fake_self = SimpleNamespace(
        client_manager=_ClientManagerEdge(engine), engine=engine, logger=logging.getLogger("FederatedServer")
    )
    req = CellMessage(
        headers={MessageHeaderKey.ORIGIN: client_name, CellMessageHeaderKeys.TOKEN: token},
        payload={JobFailureMsgKey.JOB_ID: job_id, JobFailureMsgKey.CODE: code, JobFailureMsgKey.REASON: reason},
    )
    reply = FederatedServer.process_job_failure(fake_self, req)
    rc = reply.get_header(MessageHeaderKey.RETURN_CODE)
    log(f"CELL process_job_failure({client_name}, job={job_id[:8]}, code={code}) -> rc={rc}")
    return rc


def admin_abort_t(engine, job_id):
    return run_in_thread("ADMIN-abort_job", bh.admin_abort, engine, job_id).get("result")


def admin_delete_t(engine, job_id, snapshot_job=None):
    def _do():
        job = snapshot_job
        if job is None:
            with engine.new_context() as fl_ctx:
                job = engine.job_manager.get_job(job_id, fl_ctx)
        conn = bh.FakeConn(engine, {JobCommandModule.JOB_ID: job_id, JobCommandModule.JOB: job})
        JobCommandModule().delete_job(conn, ["delete_job", job_id])
        log(f"ADMIN delete_job({job_id[:8]}) -> {conn.out}")
        return conn.out

    return run_in_thread("ADMIN-delete_job", _do).get("result")


def submit_meta(engine, name, **extra):
    meta = {
        JobMetaKey.JOB_NAME.value: name,
        JobMetaKey.DEPLOY_MAP.value: {"app": ["server", "site-1", "site-2"]},
        JobMetaKey.MIN_CLIENTS.value: 1,
        JobMetaKey.RESOURCE_SPEC.value: {},
    }
    meta.update(extra)
    with engine.new_context() as fl_ctx:
        meta = engine.job_manager.create(meta, b"PK-not-used-by-stubbed-deploy", fl_ctx)
    log(f"submitted {name} job_id={meta[JobMetaKey.JOB_ID.value]}")
    time.sleep(0.01)  # distinct submit_time ordering
    return meta[JobMetaKey.JOB_ID.value]


def new_engine(root, max_jobs=1, n_clients=2):
    clients = [Client(f"site-{i}", f"tok-site-{i}") for i in range(1, n_clients + 1)]
    engine = bh.FakeEngine(root, clients)
    engine.scheduler.max_jobs = max_jobs
    bh.stub_deploy(engine)
    return engine


def common_tail(engine, history, report):
    engine.job_runner.ask_to_stop = True
    report["status_history"] = history
    report["events"] = [(e, (d or {}).get("job_id", "")[:8]) for e, d in engine.events]
    report["scheduled_jobs_slots"] = [j[:8] for j in engine.scheduler.scheduled_jobs]
    report["running_jobs"] = [j[:8] for j in engine.job_runner.running_jobs]
    report["exception_run_processes_left"] = [j[:8] for j in engine.exception_run_processes]
    report["sj_started"] = [j[:8] for j in engine.sj_started]
    report["sj_aborted"] = [j[:8] for j in engine.sj_aborted]
    report["cancel_calls"] = len(engine.cancelled)
    return report


def completion_thread_alive():
    for t in threading.enumerate():
        if getattr(t, "_target", None) is not None and getattr(t._target, "__name__", "") == "_job_complete_process":
            return t.is_alive()
    # Thread objects drop _target after run() returns; absence means it has exited.
    return False


# ----------------------------------------------------------------------------------------------------------------------
def scenario(name, root):
    report = {"scenario": name}

    if name == "N1_scan_delete":
        # An admin deletes a queued (SUBMITTED) job; the delete lands after the runner's 1 s scan listed the job
        # directory (FilesystemStorage.list_objects) and before _scan reads that job's meta (job_def_manager.py:527).
        engine = new_engine(root)
        history = bh.install_observers(engine)
        j_del = submit_meta(engine, "queued-job-user-deletes")
        j_later = submit_meta(engine, "later-eligible-job")
        real_list = engine.storage.list_objects
        fired = {}

        def list_objects_ctl(path, without_tag=None):
            res = real_list(path, without_tag=without_tag)
            if without_tag == "scheduled" and not fired and threading.current_thread().name == "JobRunner.run":
                fired["delete"] = admin_delete_t(engine, j_del)
            return res

        engine.storage.list_objects = list_objects_ctl
        t, res = bh.start_runner(engine)
        bh.wait_until(lambda: not t.is_alive(), 10)
        time.sleep(4.0)
        report["delete_reply"] = fired.get("delete")
        report["runner_thread_alive"] = t.is_alive()
        report["runner_exception"] = res["exception"]
        report["later_job_status_after_4s"] = bh.store_status(engine, j_later)
        report["later_job_ever_started"] = j_later in engine.sj_started
        return common_tail(engine, history, report)

    if name == "N1c_delete_control":
        # Control: the same delete when it does not overlap the scan -> no effect on the runner.
        engine = new_engine(root)
        history = bh.install_observers(engine)
        engine.scheduler.max_jobs = 0  # keep jobs queued; the scan still runs every second
        j_del = submit_meta(engine, "queued-job-user-deletes")
        j_later = submit_meta(engine, "later-eligible-job")
        t, res = bh.start_runner(engine)
        time.sleep(2.5)
        report["delete_reply"] = admin_delete_t(engine, j_del)
        engine.scheduler.max_jobs = 1
        ok = bh.wait_until(lambda: bh.store_status(engine, j_later) == RunStatus.RUNNING.value, 10)
        report["runner_thread_alive"] = t.is_alive()
        report["later_job_running"] = ok
        return common_tail(engine, history, report)

    if name == "N2a_cant_schedule_overwrites_abort":
        # Job X exhausted max_schedule_count (ordinary NO_RESOURCE retries); while the same scheduling pass waits on
        # another candidate's resource check, the user aborts X (status still SUBMITTED -> FINISHED_ABORTED).
        # schedule_job then blindly writes FINISHED_CANT_SCHEDULE (job_scheduler.py:308).
        engine = new_engine(root)
        history = bh.install_observers(engine)
        engine.scheduler.max_schedule_count = 1
        state = {"x": None, "y": None, "abort": None}

        def check(job, resource_reqs, fl_ctx):
            engine._hook("check_client_resources", job=job)
            return {s: (False, "not enough resource") for s in resource_reqs}

        engine.check_client_resources = check

        def during_y_check(job):
            if job.job_id == state["y"] and state["abort"] is None:
                state["abort"] = admin_abort_t(engine, state["x"])
                log(f"store status of X right after admin abort: {bh.store_status(engine, state['x'])}")

        engine.hooks["check_client_resources"] = during_y_check
        state["x"] = submit_meta(engine, "job-X")
        t, res = bh.start_runner(engine)
        bh.wait_until(
            lambda: (bh.store_status(engine, state["x"]) == RunStatus.SUBMITTED.value)
            and any(h[2] == state["x"][:8] for h in history) is False
            and engine.job_manager.get_job(state["x"], engine.new_context()).meta.get("schedule_count", 0) >= 1,
            10,
        )
        state["y"] = submit_meta(engine, "job-Y")
        bh.wait_until(lambda: str(bh.store_status(engine, state["x"])).startswith("FINISHED"), 10)
        time.sleep(1.5)
        report["admin_abort_reply"] = state["abort"]
        report["final_X"] = bh.store_status(engine, state["x"])
        report["runner_thread_alive"] = t.is_alive()
        return common_tail(engine, history, report)

    if name == "N2b_refresh_resurrects_abort":
        # Job X fails a scheduling attempt (NO_RESOURCE). schedule_job persists the schedule history with
        # refresh_meta -> update_meta -> FilesystemStorage.update_meta (unlocked read-modify-write of the whole meta).
        # The user's abort of the still-SUBMITTED job lands between that read and that write.
        engine = new_engine(root)
        history = bh.install_observers(engine)
        engine.scheduler.min_schedule_interval = 0.5
        state = {"x": None, "abort": None, "resources_ok": False}

        def check(job, resource_reqs, fl_ctx):
            ok = state["resources_ok"]
            return {s: (ok, f"tok-{job.job_id[:8]}-{s}" if ok else "not enough resource") for s in resource_reqs}

        engine.check_client_resources = check
        tl = threading.local()
        real_refresh = engine.job_manager.refresh_meta
        real_get_meta = engine.storage.get_meta

        def refresh_ctl(job, meta_keys, fl_ctx):
            tl.in_refresh = job.job_id
            try:
                return real_refresh(job, meta_keys, fl_ctx)
            finally:
                tl.in_refresh = None

        def get_meta_ctl(uri):
            meta = real_get_meta(uri)
            jid = getattr(tl, "in_refresh", None)
            if jid and uri.endswith(jid) and state["abort"] is None:
                log(f"refresh_meta RMW read status={meta.get('status')}; admin abort lands now")
                state["abort"] = admin_abort_t(engine, jid)
                log(f"store status right after admin abort: {bh.store_status(engine, jid)}")
                state["resources_ok"] = True  # resources free up later (e.g. another site's job ended)
            return meta

        engine.job_manager.refresh_meta = refresh_ctl
        engine.storage.get_meta = get_meta_ctl
        state["x"] = submit_meta(engine, "job-X-user-aborts-while-queued")
        t, res = bh.start_runner(engine)
        bh.wait_until(lambda: state["abort"] is not None, 10)
        time.sleep(0.2)
        report["status_after_refresh_write"] = bh.store_status(engine, state["x"])
        ran = bh.wait_until(lambda: bh.store_status(engine, state["x"]) == RunStatus.RUNNING.value, 15)
        report["admin_abort_reply"] = state["abort"]
        report["aborted_job_reached_RUNNING"] = ran
        report["sj_launched_for_aborted_job"] = state["x"] in engine.sj_started
        if ran:
            bh.finish_normally(engine, state["x"])
            bh.wait_until(lambda: str(bh.store_status(engine, state["x"])).startswith("FINISHED"), 10)
        report["final_X"] = bh.store_status(engine, state["x"])
        return common_tail(engine, history, report)

    if name in ("N3_failrun_during_start", "N3c_failrun_after_start"):
        # A client's CJ fails right after launch and its CP reports REPORT_JOB_FAILURE(EXCEPTION) through the real
        # FederatedServer.process_job_failure while the runner is still inside _start_run (N3) or just after the job
        # entered running_jobs (N3c control).
        engine = new_engine(root)
        history = bh.install_observers(engine)
        j1 = submit_meta(engine, "job1")
        out = {}

        if name == "N3_failrun_during_start":

            def during_start(job):
                out["rc"] = run_in_thread(
                    "CELL-process_job_failure",
                    cell_report_outcome,
                    engine,
                    "site-1",
                    job.job_id,
                    ProcessExitCode.EXCEPTION,
                    "exception",
                ).get("result")
                out["pending_after"] = sorted(engine.job_runner._pending_client_outcomes.get(job.job_id, {"<popped>"}))
                out["exception_entry"] = engine.exception_run_processes.get(job.job_id, {}).get("process_return_code")

            engine.hooks["start_client_job"] = during_start
            t, res = bh.start_runner(engine)
        else:
            t, res = bh.start_runner(engine)
            bh.wait_until(lambda: j1 in engine.job_runner.running_jobs, 10)
            out["rc"] = run_in_thread(
                "CELL-process_job_failure",
                cell_report_outcome,
                engine,
                "site-1",
                j1,
                ProcessExitCode.EXCEPTION,
                "exception",
            ).get("result")
        bh.wait_until(lambda: str(bh.store_status(engine, j1)).startswith("FINISHED"), 10)
        time.sleep(2.5)
        report["cell_reply_rc"] = out.get("rc")
        report["pending_right_after_fail_run"] = out.get("pending_after")
        report["final"] = bh.store_status(engine, j1)
        report["runner_thread_alive"] = t.is_alive()
        return common_tail(engine, history, report)

    if name in ("N4_unsafe_during_start", "N4c_unsafe_after_start"):
        # site-1's CJ is rejected by component authorization (mpm rc UNSAFE_COMPONENT=102) right after launch; its CP
        # reports it via the real process_job_failure -> JobRunner.stop_run. site-2's CJ then ends because of the
        # ABORT sent by _stop_run and reports rc 0 (normal exit of an aborted CJ).
        engine = new_engine(root)
        history = bh.install_observers(engine)
        j1 = submit_meta(engine, "job1")
        out = {}

        def report_unsafe(jid):
            out["unsafe_rc"] = run_in_thread(
                "CELL-process_job_failure",
                cell_report_outcome,
                engine,
                "site-1",
                jid,
                ProcessExitCode.UNSAFE_COMPONENT,
                "unsafe component",
            ).get("result")
            out["run_aborted_flag"] = getattr(engine.job_runner.running_jobs.get(jid), "run_aborted", "<not in running_jobs>")

        if name == "N4_unsafe_during_start":
            engine.hooks["start_client_job"] = lambda job: report_unsafe(job.job_id)
            t, res = bh.start_runner(engine)
            bh.wait_until(lambda: j1 in engine.job_runner.running_jobs, 10)
        else:
            t, res = bh.start_runner(engine)
            bh.wait_until(lambda: j1 in engine.job_runner.running_jobs, 10)
            time.sleep(0.3)
            report_unsafe(j1)
        time.sleep(1.5)
        report["status_while_waiting_for_site2"] = bh.store_status(engine, j1)
        report["site2_report_rc"] = run_in_thread(
            "CELL-process_job_failure-2", cell_report_outcome, engine, "site-2", j1, 0, None
        ).get("result")
        bh.wait_until(lambda: str(bh.store_status(engine, j1)).startswith("FINISHED"), 10)
        time.sleep(1.0)
        report["unsafe_report_rc"] = out.get("unsafe_rc")
        report["run_aborted_flag_after_unsafe_report"] = out.get("run_aborted_flag")
        report["final"] = bh.store_status(engine, j1)
        return common_tail(engine, history, report)

    if name in ("N6_min_clients_null", "N6s_min_clients_string"):
        # A job whose meta.json has "min_clients": null (or "2") passes the real submit-time JobMetaValidator, then
        # DefaultJobScheduler._try_job raises TypeError on every pass; later eligible jobs are never reached.
        bad_value = None if name == "N6_min_clients_null" else "2"
        zbuf = io.BytesIO()
        jn = "badjob"
        meta_json = {
            "name": jn,
            "deploy_map": {"app": ["server", "site-1", "site-2"]},
            "min_clients": bad_value,
            "resource_spec": {},
        }
        with zipfile.ZipFile(zbuf, "w") as z:
            for d in (f"{jn}/", f"{jn}/app/", f"{jn}/app/config/"):
                z.writestr(d, "")  # explicit directory entries, as produced by zipping a job folder
            z.writestr(f"{jn}/meta.json", json.dumps(meta_json))
            z.writestr(f"{jn}/app/config/config_fed_server.json", json.dumps({"format_version": 2, "workflows": []}))
            z.writestr(f"{jn}/app/config/config_fed_client.json", json.dumps({"format_version": 2, "executors": []}))
        valid, err, vmeta = JobMetaValidator().validate(jn, zbuf.getvalue())
        report["validator_result"] = [valid, err, {"min_clients": vmeta.get("min_clients", "<absent>")}]
        log(f"JobMetaValidator.validate -> valid={valid} err={err!r} min_clients={vmeta.get('min_clients')!r}")
        if not valid:
            raise SystemExit("validator rejected the job; scenario precondition not met")

        engine = new_engine(root)
        history = bh.install_observers(engine)
        checks = []
        real_check = engine.check_client_resources

        def check(job, resource_reqs, fl_ctx):
            checks.append(job.meta.get(JobMetaKey.JOB_NAME.value))
            return real_check(job, resource_reqs, fl_ctx)

        engine.check_client_resources = check
        # submit the validated meta through the real job manager (as submit_job does after validation)
        vmeta[JobMetaKey.JOB_NAME.value] = "bad-min-clients"
        with engine.new_context() as fl_ctx:
            j_bad = engine.job_manager.create(dict(vmeta), zbuf.getvalue(), fl_ctx)[JobMetaKey.JOB_ID.value]
        time.sleep(0.01)
        j_good = submit_meta(engine, "later-good-job")
        t, res = bh.start_runner(engine)
        time.sleep(6.0)
        report["runner_thread_alive"] = t.is_alive()
        report["bad_job_status"] = bh.store_status(engine, j_bad)
        report["bad_job_schedule_count"] = engine.job_manager.get_job(j_bad, engine.new_context()).meta.get(
            "schedule_count"
        )
        report["good_job_status_after_6s"] = bh.store_status(engine, j_good)
        report["resource_reservations_by_job"] = {n: checks.count(n) for n in set(checks)}
        return common_tail(engine, history, report)

    if name == "N5_cmp_blind_del":
        # FAULT INJECTION: one transient StorageException from set_status(RUNNING) (job_runner.py:711) while the
        # completion thread is finalizing the same job (its SJ already exited). The runner's except path removes the
        # job from running_jobs (:715-717); the completion thread then executes `del self.running_jobs[job_id]` (:532).
        engine = new_engine(root)
        history = []
        real_set_status = engine.job_manager.set_status
        cmp_in_save = threading.Event()
        runner_except_done = threading.Event()
        state = {"injected": False}

        def set_status_ctl(jid, status, fl_ctx):
            if status == RunStatus.RUNNING and not state["injected"]:
                state["injected"] = True
                cmp_in_save.wait(10)
                history.append((threading.current_thread().name, jid[:8], "RUNNING RAISED (injected)"))
                log("FAULT INJECTION: set_status(RUNNING) raises StorageException")
                raise StorageException("injected transient write failure")
            real_set_status(jid, status, fl_ctx)
            history.append((threading.current_thread().name, jid[:8], status.value))
            log(f"set_status({jid[:8]}, {status.value}) OK")
            if status == RunStatus.FAILED_TO_RUN:
                runner_except_done.set()

        engine.job_manager.set_status = set_status_ctl
        real_save_ws = engine.job_manager.save_workspace

        def save_ws_ctl(jid, data, fl_ctx):
            cmp_in_save.set()
            runner_except_done.wait(10)  # completion thread is still archiving when the runner's except path runs
            return real_save_ws(jid, data, fl_ctx)

        engine.job_manager.save_workspace = save_ws_ctl
        j1 = submit_meta(engine, "job1")

        def sj_crash_and_make_ws(job):
            os.makedirs(os.path.join(root, "ws", job.job_id), exist_ok=True)  # run dir exists -> archival happens
            with open(os.path.join(root, "ws", job.job_id, "log.txt"), "w") as f:
                f.write("x")
            engine.sj_exit(job.job_id, return_code=ProcessExitCode.EXCEPTION)

        engine.hooks["start_client_job"] = sj_crash_and_make_ws
        t, res = bh.start_runner(engine)
        bh.wait_until(lambda: runner_except_done.is_set(), 10)
        time.sleep(3.0)
        report["completion_thread_alive"] = completion_thread_alive()
        report["final_j1"] = bh.store_status(engine, j1)
        # a later eligible job
        j2 = submit_meta(engine, "job2-later")
        bh.wait_until(lambda: bh.store_status(engine, j2) == RunStatus.RUNNING.value, 10)
        bh.finish_normally(engine, j2)
        time.sleep(4.0)
        report["j2_status_4s_after_its_SJ_exit"] = bh.store_status(engine, j2)
        report["runner_thread_alive"] = t.is_alive()
        return common_tail(engine, history, report)

    if name == "K2v_delete_during_start":
        # K2 variant: delete_job authorized on a SUBMITTED snapshot executes while the runner is inside _start_run
        # (store status DISPATCHED). Shows the extra consequence: JOB_STARTED without JOB_ABORTED/COMPLETED.
        engine = new_engine(root)
        history = bh.install_observers(engine)
        j1 = submit_meta(engine, "job1")
        with engine.new_context() as fl_ctx:
            snapshot = engine.job_manager.get_job(j1, fl_ctx)  # authorize_job_id-time read (SUBMITTED)
        out = {}
        engine.hooks["start_client_job"] = lambda job: out.setdefault("del", admin_delete_t(engine, j1, snapshot))
        t, res = bh.start_runner(engine)
        bh.wait_until(lambda: not t.is_alive(), 10)
        time.sleep(1.5)
        report["delete_reply"] = out.get("del")
        report["runner_thread_alive"] = t.is_alive()
        report["runner_exception"] = res["exception"]
        return common_tail(engine, history, report)

    raise SystemExit(f"unknown scenario {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    setup_logging()
    import nvflare

    assert os.path.realpath(nvflare.__file__).startswith(SOURCE), nvflare.__file__
    log(f"nvflare imported from {nvflare.__file__}")
    root = tempfile.mkdtemp(prefix=f"nvf-rs-{a.scenario}-")
    rep = scenario(a.scenario, root)
    log("REPORT " + json.dumps(rep, indent=2, default=str))
    with open(a.out, "w") as f:
        f.write("\n".join(bh.LOG) + "\n")
    time.sleep(0.3)
    os._exit(0)


if __name__ == "__main__":
    main()

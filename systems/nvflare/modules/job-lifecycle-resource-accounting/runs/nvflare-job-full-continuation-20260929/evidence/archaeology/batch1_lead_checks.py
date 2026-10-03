# Batch-1 archaeology: in-memory checks of HEAD leads (no product code modified).
# Run from the pinned source root:  cd <source> && python3 <this file> [L1|L2|L3|L8|L9|all]
# Real product code exercised: JobMetaValidator.validate, job_from_meta, DefaultJobScheduler.schedule_job,
# JobRunner.run/_start_run/fail_run/stop_all_runs, JobCommandModule.abort_job/delete_job.
# Stubbed: job store, engine, deploy/start RPCs (only what the exercised methods touch).
import copy
import importlib.util
import io
import json
import sys
import threading
import time
import zipfile
from unittest.mock import Mock

import nvflare.private.fed.server.job_runner as jr
from nvflare.apis.client import Client
from nvflare.apis.fl_constant import SystemComponents
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus, job_from_meta
from nvflare.apis.job_scheduler_spec import DispatchInfo
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.fuel.common.exit_codes import ProcessExitCode
from nvflare.private.admin_defs import Message
from nvflare.private.fed.server.job_cmds import JobCommandModule
from nvflare.private.fed.server.job_meta_validator import JobMetaValidator
from nvflare.private.fed.server.job_runner import JobRunner


class _HS:
    pass


jr.HotState = _HS  # only satisfies the isinstance(server_state, HotState) gate in JobRunner.run


class Store:
    """Mimics SimpleJobDefManager semantics used here: get_job -> None when missing; writes raise when missing."""

    def __init__(self):
        self.meta, self.history = {}, []

    def get_job(self, jid, fl_ctx=None):
        m = self.meta.get(jid)
        return job_from_meta(copy.deepcopy(m)) if m else None

    def set_status(self, jid, st, fl_ctx):
        if jid not in self.meta:
            raise RuntimeError(f"StorageException: object {jid} does not exist")
        self.meta[jid]["status"] = st.value
        self.history.append((jid, st.value))

    def update_meta(self, jid, meta, fl_ctx):
        self.meta[jid].update(meta)

    def delete(self, jid, fl_ctx):
        del self.meta[jid]

    def get_jobs_to_schedule(self, fl_ctx):
        jobs = [job_from_meta(copy.deepcopy(m)) for m in self.meta.values() if m["status"] == "SUBMITTED"]
        return sorted(jobs, key=lambda j: j.meta.get("submit_time", 0.0))


class Engine:
    def __init__(self, store=None):
        self.store, self.run_processes, self.exception_run_processes = store, {}, {}
        self.lock = threading.Lock()
        self.server = type("S", (), {})()
        self.server.server_state = _HS()
        self.client_manager = type("CM", (), {"clients": {}})()
        self.job_def_manager = store
        self.ctx_mgr = FLContextManager(
            engine=self, identity_name="server", job_id="", public_stickers={}, private_stickers={}
        )
        self.clients = {"t1": Client("site-1", "t1"), "t2": Client("site-2", "t2")}

    def get_clients(self):
        return ["site-1"]

    def get_component(self, cid):
        return self.store if cid == SystemComponents.JOB_MANAGER else None

    def new_context(self):
        return self.ctx_mgr.new_context()

    def remove_exception_process(self, jid):
        pass


class Conn:
    def __init__(self, engine, job_id, job=None):
        self.app_ctx, self.job_id, self.job, self.out = engine, job_id, job, []

    def get_prop(self, k, default=None):
        return {"job_id": self.job_id, "job": self.job}.get(k, default)

    def append_string(self, s, meta=None):
        self.out.append(s)

    def append_success(self, s, meta=None):
        pass

    def append_error(self, s, meta=None):
        self.out.append("ERR " + s)


def _dispatch(job):
    job.meta.setdefault(JobMetaKey.SCHEDULE_COUNT.value, 1)
    job.meta.setdefault(JobMetaKey.LAST_SCHEDULE_TIME.value, 0)
    job.meta.setdefault(JobMetaKey.SCHEDULE_HISTORY.value, [])
    return {"server": DispatchInfo("app", {}, None), "site-1": DispatchInfo("app", {}, "tok")}


def check_l1():
    """min_clients null / numeric string: accepted by validator, breaks the scheduling pass."""
    for v in (None, "2"):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr("j/", "")
            zf.writestr("j/meta.json", json.dumps({"name": "j", "deploy_map": {"app": ["server", "site0", "site1"]}, "min_clients": v}))
            zf.writestr("j/app/", "")
            zf.writestr("j/app/config/", "")
            zf.writestr("j/app/config/config_fed_server.json", "{}")
            zf.writestr("j/app/config/config_fed_client.json", "{}")
        ok, err, meta = JobMetaValidator().validate("j", buf.getvalue())
        print(f"L1 validator input={v!r}: valid={ok} err={err!r} persisted min_clients={meta.get('min_clients')!r}")
    spec = importlib.util.spec_from_file_location("jst", "tests/unit_test/app_common/job_schedulers/job_scheduler_test.py")
    jst = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(jst)
    for v in (None, "2"):
        sites = [jst.Site(name=f"site{i}", resources=jst.create_resource(16, 8)) for i in range(2)]
        engine = jst.MockServerEngine(clients={s.name: s for s in sites})
        sched = DefaultJobScheduler(max_jobs=1, min_schedule_interval=0.0)
        jm = Mock()
        dm = {"app": ["server", "site0", "site1"]}
        bad = job_from_meta({"job_id": "bad", "deploy_map": dm, "resource_spec": {}, "min_clients": v, "submit_time": 1.0})
        good = job_from_meta({"job_id": "good", "deploy_map": dm, "resource_spec": {}, "min_clients": 1, "submit_time": 2.0})
        for attempt in range(2):
            with engine.new_context() as ctx:
                job, _ = sched.schedule_job(job_manager=jm, job_candidates=[bad, good], fl_ctx=ctx)
            cant = any(c.args[1] == RunStatus.FINISHED_CANT_SCHEDULE for c in jm.set_status.call_args_list)
            print(
                f"L1 min_clients={v!r} pass {attempt}: scheduled={job.job_id if job else None} "
                f"bad.schedule_count={bad.meta.get(JobMetaKey.SCHEDULE_COUNT.value)} CANT_SCHEDULE_set={cant}"
            )


def check_l2():
    """delete_job of the SUBMITTED job being scheduled kills JobRunner.run; later job never scheduled."""
    store = Store()
    for i, jid in enumerate(["job-A", "job-B"]):
        store.meta[jid] = {"job_id": jid, "status": "SUBMITTED", "deploy_map": {"app": ["server", "site-1"]}, "min_clients": 1, "submit_time": float(i)}
    eng = Engine(store)
    runner = JobRunner(workspace_root="/nonexistent")
    eng.job_runner = runner
    handed, del_out = [], []

    class Sched:
        def schedule_job(self, job_manager, job_candidates, fl_ctx):
            if not job_candidates:
                return None, None
            j = job_candidates[0]
            handed.append(j.job_id)
            if j.job_id == "job-A":  # delete while its client resource check is in flight
                c = Conn(eng, "job-A", store.get_job("job-A"))
                JobCommandModule().delete_job(c, ["delete_job", "job-A"])
                del_out.extend(c.out)
            return j, _dispatch(j)

    runner.scheduler = Sched()
    runner._deploy_job = lambda job, sites, fl_ctx: (job.job_id, [])
    runner._start_run = lambda job_id, job, client_sites, fl_ctx: eng.run_processes.setdefault(job_id, {})
    threading.Timer(4.0, lambda: setattr(runner, "ask_to_stop", True)).start()
    err = None
    try:
        with eng.new_context() as ctx:
            runner.run(ctx)
    except BaseException as e:
        err = e
    runner.ask_to_stop = True
    time.sleep(1.5)
    print(f"L2 delete reply: {del_out}")
    print(f"L2 JobRunner.run escaped with: {type(err).__name__}: {err}")
    print(f"L2 jobs handed out: {handed}; job-B status after 4 s: {store.meta['job-B']['status']}")


def check_l3():
    """stop_all_runs iterates the live run_processes view; a concurrent pop aborts the loop."""
    eng = Engine()
    eng.run_processes = {"j1": {}, "j2": {}, "j3": {}}
    runner = JobRunner(workspace_root="/nonexistent")
    stopped = []

    def fake_stop_run(job_id, fl_ctx):
        stopped.append(job_id)
        with eng.lock:  # what wait_for_complete / _remove_run_processes do on their own threads
            eng.run_processes.pop(job_id, None)
        return ""

    runner.stop_run = fake_stop_run
    try:
        with eng.new_context() as ctx:
            runner.stop_all_runs(ctx)
        print("L3 no error")
    except RuntimeError as e:
        print(f"L3 stop_all_runs raised: {e}; stopped={stopped}; not stopped={list(eng.run_processes)}; ask_to_stop={runner.ask_to_stop}")


def check_l8():
    """abort_job of a SUBMITTED/DISPATCHED job is overwritten by the runner; job runs anyway."""
    for where in ("deploy", "start"):
        store = Store()
        jid = "job-1"
        store.meta[jid] = {"job_id": jid, "status": "SUBMITTED", "deploy_map": {"app": ["server", "site-1"]}, "min_clients": 1}
        eng = Engine(store)
        runner = JobRunner(workspace_root="/nonexistent")
        eng.job_runner = runner
        started, msgs = [], []

        class Sched:
            def schedule_job(self, job_manager, job_candidates, fl_ctx):
                if job_candidates:
                    return job_candidates[0], _dispatch(job_candidates[0])
                return None, None

        def do_abort():
            c = Conn(eng, jid)
            JobCommandModule().abort_job(c, ["abort_job", jid])
            msgs.extend(c.out)

        def fake_deploy(job, sites, fl_ctx):
            if where == "deploy":
                do_abort()
            return job.job_id, []

        def fake_start(job_id, job, client_sites, fl_ctx):
            if where == "start":
                do_abort()
            started.append(job_id)
            eng.run_processes[job_id] = {}  # simulated live SJ
            threading.Timer(2.5, lambda: setattr(runner, "ask_to_stop", True)).start()

        runner.scheduler, runner._deploy_job, runner._start_run = Sched(), fake_deploy, fake_start
        with eng.new_context() as ctx:
            runner.run(ctx)
        ra = runner.running_jobs[jid].run_aborted if jid in runner.running_jobs else None
        print(f"L8 abort during {where}: reply={msgs} history={[s for _, s in store.history]} started={bool(started)} final={store.meta[jid]['status']} run_aborted={ra}")


def check_l9():
    """fail_run (client failure report) during _start_run -> KeyError in _start_run."""
    eng = Engine()

    class Reply:
        def __init__(self, name, body):
            self.client_name, self.reply = name, Message(topic="reply_start_job", body=body)

    runner = JobRunner(workspace_root="/nonexistent")
    eng.get_job_clients = lambda sites: dict(eng.clients)

    def start_app_on_server(fl_ctx, job=None, job_clients=None):
        eng.run_processes[job.job_id] = {"participants": job_clients}
        return ""

    def start_client_job(job, client_sites, fl_ctx):
        with eng.new_context() as c2:  # site-1 REPORT_JOB_FAILURE handled while site-2's START_JOB reply is pending
            runner.fail_run(job.job_id, ProcessExitCode.EXCEPTION, c2)
        return [Reply("site-1", "Start the client app..."), Reply("site-2", "Start the client app...")]

    eng.start_app_on_server, eng.start_client_job = start_app_on_server, start_client_job
    runner._stop_run = lambda job_id, fl_ctx: None
    job = Job(job_id="job-1", resource_spec={}, deploy_map={"app": ["server", "site-1", "site-2"]}, meta={}, min_sites=1)
    sites = {"site-1": DispatchInfo("app", {}, "t"), "site-2": DispatchInfo("app", {}, "t")}
    with eng.new_context() as ctx:
        try:
            runner._start_run("job-1", job, sites, ctx)
            print("L9 _start_run returned normally")
        except Exception as ex:
            print(f"L9 _start_run raised {type(ex).__name__}: {ex!r}; exception_run_processes has job: {'job-1' in eng.exception_run_processes}")


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    checks = {"L1": check_l1, "L2": check_l2, "L3": check_l3, "L8": check_l8, "L9": check_l9}
    for name, fn in checks.items():
        if which in ("all", name):
            fn()

"""T1-b under natural timing: an admin deletes a just-submitted job at a random moment.
Pinned source c411a201, read-only via sys.path.

Window: from the scheduling scan that lists the job (job_runner.py:703) to the DISPATCHED write
(734). In that whole span the job is still SUBMITTED, so the admin delete_job handler accepts it
(job_cmds.py:518 refuses only DISPATCHED/RUNNING). A delete inside it makes get_job return None
(job_def_manager.py:379-385) and `.meta` raise AttributeError in _check_job_status (827-829):
  - during schedule_job (client resource check RPC): at line 715, outside the try;
  - during _deploy_job: at line 727 inside the try, and again in the except branch at 793-795.
Either way the exception leaves run(): the scheduling loop ends and nothing is scheduled again.

Real code: JobRunner.run, DefaultJobScheduler (real resource-check flow), SimpleJobDefManager,
FilesystemStorage, JobCommandModule.delete_job (real status pre-check and delete).
Stubs: engine plumbing, client RPC latencies (check_client_resources, deploy round trip,
start_client_job), _deploy_job (a sleep of the deploy duration), the SJ (never exits).
No forcing: the admin's delete time is drawn independently of the runner's progress.

usage:
  t1b_natural.py measure                     real-code parts of the window (scan, job credentials)
  t1b_natural.py run <deploy_model> <delete_model> <n> [par]
  t1b_natural.py trial <deploy_model> <delete_model> <seed>
deploy models: fast (responsive clients, small job), slowclient (a client never answers DEPLOY ->
admin_timeout 10 s, fed_server.json default, admin/utils.py:92)
delete models: uniform14 (delete 0-14 s after submit), human (lognormal, median 8 s), script (0-2 s)
"""
import json, logging, math, os, random, shutil, subprocess, sys, tempfile, threading, time, types, uuid
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
logging.disable(logging.CRITICAL)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.abspath(os.path.join(HERE, "..", "..", ".tmp"))


def draw(deploy_model, delete_model, rng):
    rc = rng.uniform(0.02, 0.3)                              # check_resources round trip
    if deploy_model == "fast":
        dep = rng.uniform(0.3, 2.0)                          # app transfer + client unzip/verify + reply
    elif deploy_model == "slowclient":
        dep = 10.0                                           # waits admin_timeout for the silent client
    else:
        raise SystemExit(deploy_model)
    if delete_model == "uniform14":
        x = rng.uniform(0.0, 14.0)
    elif delete_model == "human":
        x = math.exp(rng.gauss(math.log(8.0), 0.6))
    elif delete_model == "script":
        x = rng.uniform(0.0, 2.0)
    else:
        raise SystemExit(delete_model)
    return rc, dep, x


class Conn:
    def __init__(self, engine, job_id, job):
        self.app_ctx, self.props, self.out = engine, {JobCommandModule.JOB_ID: job_id, JobCommandModule.JOB: job}, []

    def get_prop(self, k, default=None):
        return self.props.get(k, default)

    def set_prop(self, k, v):
        self.props[k] = v

    def append_error(self, msg, meta=None):
        self.out.append(("error", msg))

    def append_string(self, msg, meta=None):
        self.out.append(("string", msg))

    def append_success(self, msg, meta=None):
        self.out.append(("success", msg))


def trial(deploy_model, delete_model, seed):
    rng = random.Random(seed)
    rc, dep, x = draw(deploy_model, delete_model, rng)
    work = tempfile.mkdtemp(prefix="t1bn_", dir=TMP)
    os.chdir(work)
    store = FilesystemStorage(root_dir=os.path.join(work, "store"), uri_root="/")
    jm = SimpleJobDefManager(uri_root="jobs", job_store_id="job_store")
    sched = DefaultJobScheduler(max_jobs=1)
    eng = MagicMock(spec=ServerEngineSpec)
    clients = [Client("site-1", "tok-1"), Client("site-2", "tok-2")]
    comps = {"job_store": store, SystemComponents.JOB_MANAGER: jm, SystemComponents.JOB_SCHEDULER: sched}
    eng.get_component = comps.get
    eng.job_def_manager = jm
    eng.server = MagicMock()
    eng.server.server_state = HotState()
    eng.get_clients = lambda: list(clients)
    eng.client_manager = types.SimpleNamespace(clients={c.token: c for c in clients})
    eng.validate_targets = lambda names: ([c for c in clients if c.name in names], [])
    eng.get_job_clients = lambda sites: {c.token: c for c in clients if c.name in sites}
    eng.run_processes, eng.exception_run_processes, eng.lock = {}, {}, threading.Lock()
    mgr = FLContextManager(engine=eng, identity_name="server")
    eng.new_context = mgr.new_context
    marks = {}

    def check_client_resources(job, resource_reqs, fl_ctx):
        marks.setdefault("resource_check", time.monotonic())
        time.sleep(rc)
        return {s: (True, f"tok-{s}") for s in resource_reqs}
    eng.check_client_resources = check_client_resources
    eng.cancel_client_resources = lambda *a, **k: None

    def start_app_on_server(fl_ctx, job, job_clients, snapshot=None):
        eng.run_processes[job.job_id] = {RunProcessKey.PARTICIPANTS: job_clients}
        return ""
    eng.start_app_on_server = start_app_on_server
    ok = types.SimpleNamespace(body="OK", get_header=lambda *a, **k: "OK")
    eng.start_client_job = lambda job, sites, fl_ctx: [types.SimpleNamespace(client_name=s, reply=ok) for s in sites]

    runner = JobRunner(workspace_root=work)
    runner.scheduler = sched

    def deploy(job, sites, fl_ctx):
        marks.setdefault("deploy_start", time.monotonic())
        time.sleep(dep)
        return job.job_id, []
    runner._deploy_job = deploy
    real_gjts = jm.get_jobs_to_schedule

    def gjts(fl_ctx):                                       # timestamp only
        r = real_gjts(fl_ctx)
        if r and "listed" not in marks:
            marks["listed"] = time.monotonic()
        return r
    jm.get_jobs_to_schedule = gjts
    real_set_status = jm.set_status

    def set_status(jid, status, fl_ctx):                    # timestamp only
        real_set_status(jid, status, fl_ctx)
        marks.setdefault(str(RunStatus(status).value), time.monotonic())
    jm.set_status = set_status

    crashes = []
    threading.excepthook = lambda a: crashes.append((a.thread.name, a.exc_type.__name__, str(a.exc_value)[:90]))
    t = threading.Thread(target=runner.run, args=(mgr.new_context(),), name="job_runner", daemon=True)
    t.start()
    time.sleep(rng.uniform(0.0, 1.0))                       # arbitrary phase against the 1 s scan
    jid = str(uuid.uuid4())
    meta = {JobMetaKey.JOB_ID.value: jid, JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value,
            JobMetaKey.DEPLOY_MAP.value: {"app": ["@ALL"]}, JobMetaKey.MIN_CLIENTS.value: 1,
            JobMetaKey.RESOURCE_SPEC.value: {}, JobMetaKey.SCHEDULE_COUNT.value: 0}
    store.create_object(jm.job_uri(jid), b"job-data", meta, overwrite_existing=True)   # submit_job
    t_submit = time.monotonic()
    time.sleep(x)
    with mgr.new_context() as ctx:
        job = jm.get_job(jid, ctx)                         # the command's job pre-filter loads the job
    conn = Conn(eng, jid, job)
    t_del = time.monotonic()
    JobCommandModule().delete_job(conn, ["delete_job", jid])
    deleted = any(k == "success" for k, _ in conn.out)
    time.sleep(dep + 3.0)
    runner.ask_to_stop = True
    rel = lambda k: None if k not in marks else round(marks[k] - t_submit, 3)
    out = dict(deploy=deploy_model, delete=delete_model, seed=seed, delete_at=round(t_del - t_submit, 3),
               rc=round(rc, 3), deploy_s=round(dep, 3), listed=rel("listed"), deploy_start=rel("deploy_start"),
               dispatched=rel(RunStatus.DISPATCHED.value), delete_result=conn.out[-1][0] if conn.out else None,
               deleted=deleted, sched_alive=t.is_alive(), crashes=crashes)
    os.chdir(TMP)
    shutil.rmtree(work, ignore_errors=True)
    print(json.dumps(out), flush=True)


def run(deploy_model, delete_model, n, par):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    base, pending, running, res = random.randrange(1 << 30), list(range(n)), [], []
    while pending or running:
        while pending and len(running) < par:
            running.append(subprocess.Popen([sys.executable, "-B", __file__, "trial", deploy_model, delete_model,
                                             str(base + pending.pop(0))], stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, text=True, env=env, cwd=TMP))
        time.sleep(0.2)
        for pr in [r for r in running if r.poll() is not None]:
            running.remove(pr)
            lines = (pr.stdout.read() or "").strip().splitlines()
            if lines:
                res.append(json.loads(lines[-1]))
    dead = [r for r in res if not r["sched_alive"]]
    where = {}
    for r in dead:
        key = "during resource check (line 715, outside try)" if r["deploy_start"] is None else "during deploy (727/795)"
        where[key] = where.get(key, 0) + 1
    refused = sum(1 for r in res if r["delete_result"] == "error")
    safe = sum(1 for r in res if r["sched_alive"] and r["deleted"])
    print(f"deploy={deploy_model} delete={delete_model} trials={len(res)} scheduler_dead={len(dead)} {where} "
          f"delete_refused(job already DISPATCHED/RUNNING)={refused} deleted_before_pickup={safe}")
    if dead:
        xs = sorted(r["delete_at"] for r in dead)
        print(f"  killing delete times after submit: min={xs[0]:.2f}s max={xs[-1]:.2f}s")
    win = [(r["listed"], r["dispatched"]) for r in res if r["listed"] is not None and r["dispatched"] is not None]
    if win:
        lens = sorted(b - a for a, b in win)
        print(f"  measured window listing->DISPATCHED (jobs not deleted in it): n={len(lens)} "
              f"min={lens[0]:.2f}s median={lens[len(lens) // 2]:.2f}s max={lens[-1]:.2f}s; "
              f"pickup after submit median={sorted(a for a, _ in win)[len(win) // 2]:.2f}s")
    for r in dead[:1]:
        print("  example:", json.dumps(r))
    with open(os.path.join(TMP, f"t1bn_{deploy_model}_{delete_model}_{int(time.time())}.jsonl"), "w") as f:
        for r in res:
            f.write(json.dumps(r) + "\n")


def measure():
    import datetime
    from nvflare.lighter.utils import Identity, generate_cert, generate_keys, serialize_cert
    from nvflare.private.fed.utils.job_cert_utils import JobCertIssuer
    key, pub = generate_keys()                   # a job CA like the provisioned one (secure mode)
    ca = generate_cert(subject=Identity("jobca"), issuer=Identity("jobca"), signing_pri_key=key,
                       subject_pub_key=pub, valid_days=30, ca=True)
    issuer = JobCertIssuer(serialize_cert(ca), key)
    for n in (2, 8, 20):                         # _deploy_job issues one per site (job_runner.py:264) plus one for the SJ (289)
        owners = {f"site-{i}": f"site-{i}" for i in range(n)}
        ts = []
        for _ in range(3):
            t0 = time.perf_counter()
            issuer.issue_many(owners, "job1", 7)
            ts.append((time.perf_counter() - t0) * 1e3)
        print(f"JobCertIssuer.issue_many, {n} sites: " + ", ".join(f"{t:.0f}" for t in ts) + " ms")
    work = tempfile.mkdtemp(prefix="t1bn_measure_", dir=TMP)
    os.chdir(work)
    store = FilesystemStorage(root_dir=os.path.join(work, "store"), uri_root="/")
    jm = SimpleJobDefManager(uri_root="jobs", job_store_id="job_store")
    eng = MagicMock(spec=ServerEngineSpec)
    eng.get_component = {"job_store": store}.get
    ctx = FLContextManager(engine=eng, identity_name="server").new_context()
    for n in (20, 300):
        for _ in range(n - len(store.list_objects("jobs")) if os.path.isdir(os.path.join(work, "store", "jobs")) else n):
            jid = str(uuid.uuid4())
            store.create_object(jm.job_uri(jid), b"x", {JobMetaKey.JOB_ID.value: jid,
                                JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value}, overwrite_existing=True)
        t0 = time.perf_counter()
        jm.get_jobs_to_schedule(ctx)
        print(f"get_jobs_to_schedule scan with {n} queued jobs: {(time.perf_counter() - t0) * 1e3:.1f} ms")
    os.chdir(TMP)
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    os.makedirs(TMP, exist_ok=True)
    if sys.argv[1] == "measure":
        measure()
    elif sys.argv[1] == "trial":
        trial(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    else:
        run(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]) if len(sys.argv) > 5 else 4)

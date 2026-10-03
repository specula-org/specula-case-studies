"""Trace scenarios for nvflare-job.  Each scenario builds a fresh environment of real product objects, drives it
through the stub process/network edges and returns the Env (its tracer holds the emitted events).

Scenario driving uses only: submitting jobs before the runner starts, admin commands through the real
JobCommandModule / ServerEngine, SJ/CJ process behaviour at the process edge, CellNet delivery policies (deliver /
hold / drop / fail), explicit expiry ticks, heartbeats, client crash + dead-client sweep, and tla_hooks gates that
pause a product thread at a named point (timing control only).
"""

import os
import threading
import time

from nvf_env import Env

SCENARIOS = {}
LAST_ENV = {}

C1, C2 = "site-1", "site-2"


def scenario(fn):
    SCENARIOS[fn.__name__] = fn
    return fn


# ----------------------------------------------------------------------------------------------- helpers
def build(root, out, cfg, jobs):
    env = Env(root, out, cfg)
    LAST_ENV["env"] = env
    env.register_clients()
    env.system_start()
    env.submit_jobs(jobs)
    env.start_tracing()
    return env


def ev(name, job=None, cl=None, pred=None):
    def p(e):
        if e["name"] != name:
            return False
        if job is not None and e.get("real_job") != job:
            return False
        if cl is not None and e.get("real_cl") != cl:
            return False
        if pred is not None and not pred(e):
            return False
        return True

    return p


def wait(env, pred, timeout=30.0, desc="", start=0):
    return env.tracer.wait_event(pred, timeout=timeout, start=start, desc=desc)


def wait_ev(env, name, job=None, cl=None, timeout=30.0, start=0, pred=None):
    return wait(env, ev(name, job, cl, pred), timeout=timeout, desc=f"{name} job={job} cl={cl}", start=start)


def wait_until(fn, timeout=30.0, desc="condition", step=0.02):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if fn():
            return True
        time.sleep(step)
    raise TimeoutError(f"timed out waiting for {desc}")


def state_of(env, e=None):
    if e is None:
        e = env.tracer.events[-1]
    return e["state"]


def job_state(env, jid):
    return env.tracer.snapshot_job(jid) if hasattr(env.tracer, "snapshot_job") else None


def wait_status(env, jid, status, timeout=30.0):
    jn = env.jname(jid)
    return wait(env, lambda e: e["state"]["jobs"][jn]["status"] == status, timeout=timeout,
                desc=f"{jn} status {status}")


def wait_started_on(env, jid, clients, timeout=30.0):
    for cl in clients:
        wait_ev(env, "CjNotifyStarted", job=jid, cl=cl, timeout=timeout)


def normal_finish(env, jid, clients, ee=False, rc=0):
    """SJ ends normally, then every participating CJ reports STOPPED and exits 0."""
    env.sj_finish(jid, execution_error=ee, rc=rc)
    wait_ev(env, "SpWaitForComplete", job=jid)
    for cl in clients:
        env.finish_client_job(cl, jid)
    wait_ev(env, "CmpRemove", job=jid, timeout=30.0)


class Gate:
    """Pause a product thread at a tla_hooks gate until the scenario releases it."""

    def __init__(self, env, point, match=None, once=True):
        self.env = env
        self.point = point
        self.match = match
        self.once = once
        self.reached = threading.Event()
        self.release_ev = threading.Event()
        self.info = None
        self.used = False
        env.tracer.gates[point] = self._cb

    def _cb(self, **info):
        if self.used and self.once:
            return
        if self.match is not None and not self.match(info):
            return
        self.used = True
        self.info = info
        self.reached.set()
        if not self.release_ev.wait(timeout=60.0):
            self.env.tracer._harness_error(f"gate {self.point} was never released")

    def wait_reached(self, timeout=30.0):
        if not self.reached.wait(timeout):
            raise TimeoutError(f"gate {self.point} not reached")

    def release(self):
        self.release_ev.set()
        self.env.tracer.gates.pop(self.point, None)


def ident_is(typ, job=None, cl=None, env=None):
    def p(i):
        if i.get("type") != typ:
            return False
        if job is not None and i.get("job") != env.jname(job):
            return False
        if cl is not None and i.get("cl") != env.cname(cl):
            return False
        return True

    return p


BASE = {
    "clients": [C1, C2],
    "units": [0, 1],
    "need": 1,
    "max_jobs": 1,
    "max_schedule_count": 10,
    "expiry": 3,
    "min_schedule_interval": 0.0,
    "client_outcome_wait_timeout": 900.0,
}


def cfg_with(**kw):
    c = dict(BASE)
    c.update(kw)
    return c


def job(name, sites=(C1, C2), min_sites=1, required=()):
    return {"name": name, "deploy_sites": list(sites), "min_sites": min_sites, "required": list(required)}


# ----------------------------------------------------------------------------------------------- scenarios
@scenario
def normal_two_jobs(root, out):
    """Two jobs, max_jobs=1: j1 and then j2 run to FINISHED:COMPLETED on both clients.  Includes periodic heartbeats
    and a CJ whose same-group descendants outlive the leader (CjGroupExit)."""
    env = build(root, out, cfg_with(scenario="normal_two_jobs"), [job("job1"), job("job2")])
    j1, j2 = env.job_ids
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    env.heartbeat(C1)
    env.heartbeat(C2)
    normal_finish(env, j1, [C1, C2])
    wait_ev(env, "RunnerSetRunning", job=j2, timeout=30.0)
    wait_started_on(env, j2, [C1, C2])
    env.heartbeat(C2)
    env.sj_finish(j2)
    wait_ev(env, "SpWaitForComplete", job=j2)
    env.finish_client_job(C1, j2)
    env.cj_notify_stopped(C2, j2)
    env.cj_exit(C2, j2, 0, descendants=True)
    wait_ev(env, "CpChildFinished", job=j2, cl=C2)
    env.cj_group_exit(C2, j2)
    wait_ev(env, "CmpRemove", job=j2)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count())
    return env


@scenario
def abort_running_and_queued(root, out):
    """Admin abort of a queued SUBMITTED job (store-only abort) and of a RUNNING job (stop_run: ABORT to clients and
    to the SJ, abort-cleanup thread, run_aborted latch -> FINISHED:ABORTED).  c2's CJ handles the ABORT but is slow to
    exit, so the client's _terminate_job kills it after its 10 s grace.  Finally the finished job is deleted."""
    env = build(root, out, cfg_with(scenario="abort_running_and_queued"), [job("job1"), job("job2")])
    j1, j2 = env.job_ids
    env.cj_behavior[(C2, j1)] = {"auto_start": True, "on_abort": "stop_only"}
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    env.admin_abort(j2)  # SUBMITTED -> FINISHED:ABORTED (AdminAbortBegin + AdminAbortWrite)
    wait_ev(env, "AdminAbortWrite", job=j2)
    env.admin_delete(j1)  # refused: the authorization snapshot says RUNNING
    wait_ev(env, "AdminDeleteExec", job=j1)
    env.admin_abort(j1)  # RUNNING -> stop_run
    wait_ev(env, "AdminMarkAborted", job=j1)
    wait_ev(env, "CmpRemove", job=j1, timeout=40.0)
    wait_ev(env, "CpTerminateJob", job=j1, cl=C1, timeout=30.0)
    wait_ev(env, "CpTerminateJob", job=j1, cl=C2, timeout=30.0)  # kill after the 10 s grace
    wait_ev(env, "CpChildFinished", job=j1, cl=C2, timeout=30.0)
    wait_ev(env, "SpRemoveRunProcesses", job=j1, timeout=30.0)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    n = env.tracer.count()
    env.admin_delete(j1)
    wait_ev(env, "AdminDeleteExec", job=j1, start=n)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def check_timeout_backoff_expiry(root, out):
    """j1 needs both sites (min_sites=2).  c2's CHECK is held (the runner times out), so the scheduler cancels c1's
    reservation and records NO_RESOURCE (schedule_count 1).  The held CHECK is then processed late: c2 reserves for a
    runner that no longer waits, and only expiry ticks reclaim it.  The retry is backed off (min_schedule_interval)
    and then succeeds; the job completes."""
    env = build(root, out, cfg_with(scenario="check_timeout_backoff_expiry", min_schedule_interval=2.5),
                [job("job1", min_sites=2)])
    (j1,) = env.job_ids
    env.net.set_policy(ident_is("CHECK", job=j1, cl=C2, env=env), "hold", once=True)
    env.start_runner()
    wait_ev(env, "RunnerCheckTimeout")
    wait_ev(env, "CpCancelResource", cl=C1)
    wait_ev(env, "RunnerRefreshWrite", job=j1)
    assert env.net.release(ident_is("CHECK", job=j1, cl=C2, env=env)) == 1
    wait_ev(env, "CpCheckResource", cl=C2)
    for _ in range(env.expiry):
        env.tick(C2)
    wait_until(lambda: not env.cps[C2].rm.reserved_resources, desc="c2 reservation expired")
    wait_ev(env, "RunnerBackoffSkip", job=j1, timeout=10.0)
    wait_ev(env, "RunnerSetRunning", job=j1, timeout=30.0)
    wait_started_on(env, j1, [C1, C2])
    normal_finish(env, j1, [C1, C2])
    return env


@scenario
def lossy_check_cant_schedule(root, out):
    """Every CHECK to c2 for j1 (min_sites=2) is lost (LoseMsg).  Each attempt times out, cancels c1's reservation and
    counts one try; after max_schedule_count tries j1 is blocked and set FINISHED:CAN_NOT_SCHEDULE.  The later job j2
    (min_sites=1) is still admitted and completes."""
    env = build(root, out, cfg_with(scenario="lossy_check_cant_schedule", max_schedule_count=2),
                [job("job1", min_sites=2), job("job2", min_sites=1)])
    j1, j2 = env.job_ids
    env.net.set_policy(ident_is("CHECK", job=j1, cl=C2, env=env), "drop")
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j2, timeout=30.0)
    wait_started_on(env, j2, [C1, C2])
    normal_finish(env, j2, [C1, C2])
    wait_ev(env, "RunnerSetCantSched", job=j1, timeout=30.0)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def start_failures(root, out):
    """Three jobs fail at different start stages: j1's SJ launcher raises (RunnerStartServerAppFail); j2's CJ launch
    fails on c1 (CpStartLaunchFail -> ERROR START reply -> whole job FAILED_TO_RUN, c2's CJ and the SJ are aborted);
    j3's deployment to its required site c1 fails (RunnerDeployJob failed=[c1]).  The dispatched reservations the
    runner never cancels are reclaimed by expiry ticks."""
    env = build(root, out, cfg_with(scenario="start_failures"),
                [job("job1"), job("job2"), job("job3", min_sites=1, required=(C1,))])
    j1, j2, j3 = env.job_ids
    env.sj_launch_fail[j1] = True
    env.cj_launch_fail[(C1, j2)] = True
    env.net.set_policy(lambda i: i.get("type") == "DEPLOY" and i.get("job") == env.jname(j3)
                       and i.get("cl") == env.cname(C1), "fail")
    env.start_runner()
    wait_ev(env, "RunnerExceptMeta", job=j1, timeout=30.0)
    wait_ev(env, "RunnerExceptMeta", job=j2, timeout=30.0)
    wait_ev(env, "SpRemoveRunProcesses", job=j2, timeout=30.0)
    wait_ev(env, "RunnerExceptMeta", job=j3, timeout=30.0)
    env.net.quiesce(5.0)
    for cl in (C1, C2):
        for _ in range(env.expiry):
            env.tick(cl)
    wait_until(lambda: all(not env.cps[c].rm.reserved_resources for c in (C1, C2)), desc="reservations expired")
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def client_failure_and_sj_crash(root, out):
    """j1: c1's CJ fails while STARTED (rc 1 -> EXCEPTION report) -> fail_run -> stop_run (clients + SJ aborted) ->
    FINISHED:EXECUTION_EXCEPTION.  j2: the SJ process crashes (no UPDATE_RUN_STATUS; exit code recorded) -> the
    completion thread aborts the clients -> FINISHED:EXECUTION_EXCEPTION."""
    env = build(root, out, cfg_with(scenario="client_failure_and_sj_crash"), [job("job1"), job("job2")])
    j1, j2 = env.job_ids
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    env.cj_exit(C1, j1, 1)
    wait_ev(env, "SpProcessJobFailure", job=j1, cl=C1)
    wait_ev(env, "CmpRemove", job=j1, timeout=40.0)
    wait_ev(env, "SpRemoveRunProcesses", job=j1, timeout=30.0)
    wait_ev(env, "RunnerSetRunning", job=j2, timeout=30.0)
    wait_started_on(env, j2, [C1, C2])
    env.sj_crash(j2)
    wait_ev(env, "CmpRemove", job=j2, timeout=40.0)
    wait_ev(env, "CpChildFinished", job=j2, cl=C1, timeout=30.0)
    wait_ev(env, "CpChildFinished", job=j2, cl=C2, timeout=30.0)
    env.net.quiesce(5.0)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def client_crash_sweep(root, out):
    """c2's client parent crashes while j1 runs (its CJ dies with it).  The dead-client sweeper removes the session and
    resolves c2's pending outcome; the job completes from c1's outcome."""
    env = build(root, out, cfg_with(scenario="client_crash_sweep"), [job("job1")])
    (j1,) = env.job_ids
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    env.heartbeat(C1)
    env.heartbeat(C2)
    env.net.quiesce(5.0)
    env.client_crash(C2)
    env.sweep_dead_client(C2)
    wait_ev(env, "SweepEnd")
    env.sj_finish(j1)
    wait_ev(env, "SpWaitForComplete", job=j1)
    env.finish_client_job(C1, j1)
    wait_ev(env, "CmpRemove", job=j1, timeout=30.0)
    env.heartbeat(C1)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def outcome_deadline_hb_cleanup(root, out):
    """c1's CJ never reports its outcome: the completion thread finalizes after client_outcome_wait_timeout
    (CmpOutcomeDeadline).  c1 still runs the job, so its next heartbeat gets it aborted (heartbeat cleanup)."""
    env = build(root, out, cfg_with(scenario="outcome_deadline_hb_cleanup", client_outcome_wait_timeout=2.0),
                [job("job1")])
    (j1,) = env.job_ids
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    env.sj_finish(j1)
    wait_ev(env, "SpWaitForComplete", job=j1)
    env.finish_client_job(C2, j1)
    wait_ev(env, "CmpOutcomeDeadline", job=j1, timeout=30.0)
    wait_ev(env, "CmpRemove", job=j1, timeout=30.0)
    env.heartbeat(C1)
    wait_ev(env, "CpChildFinished", job=j1, cl=C1, timeout=30.0)
    wait_ev(env, "CpTerminateJob", job=j1, cl=C1, timeout=30.0)
    env.net.quiesce(5.0)
    env.heartbeat(C1)
    return env


@scenario
def disable_client_outcome_wait(root, out):
    """An admin disables c2 while j1 runs: its session is dropped without resolving its pending outcome and its later
    report is rejected, so the job is finalized only by the outcome deadline."""
    env = build(root, out, cfg_with(scenario="disable_client_outcome_wait", client_outcome_wait_timeout=2.0),
                [job("job1")])
    (j1,) = env.job_ids
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    env.admin_disable(C2)
    wait_ev(env, "AdminDisable", cl=C2)
    env.sj_finish(j1)
    wait_ev(env, "SpWaitForComplete", job=j1)
    env.finish_client_job(C1, j1)
    env.finish_client_job(C2, j1)
    wait_ev(env, "CmpOutcomeDeadline", job=j1, timeout=30.0)
    wait_ev(env, "CmpRemove", job=j1, timeout=30.0)
    env.net.quiesce(5.0)
    env.heartbeat(C1)
    return env


@scenario
def delete_held_job_kills_runner(root, out):
    """An admin deletes j1 after the scheduler selected it (its SUBMITTED re-check is outside run()'s try): the runner
    thread dies and the later job j2 is never scheduled.  The dispatched reservations expire."""
    env = build(root, out, cfg_with(scenario="delete_held_job_kills_runner"), [job("job1"), job("job2")])
    j1, j2 = env.job_ids
    g = Gate(env, "runner.before_check_submitted", match=lambda info: info.get("job") == j1)
    env.start_runner()
    g.wait_reached()
    env.admin_delete(j1)
    g.release()
    wait_ev(env, "RunnerCheckSubmitted", job=j1)
    wait_until(lambda: not env.runner_thread.is_alive(), desc="runner thread dead")
    for cl in (C1, C2):
        for _ in range(env.expiry):
            env.tick(cl)
    wait_until(lambda: all(not env.cps[c].rm.reserved_resources for c in (C1, C2)), desc="reservations expired")
    env.heartbeat(C1)
    return env


@scenario
def delete_during_scan(root, out):
    """An admin deletes a SUBMITTED job between the runner's listing and its meta reads: get_meta raises outside run()'s
    try and the runner thread dies (RunnerScanReadDeleted)."""
    env = build(root, out, cfg_with(scenario="delete_during_scan"), [job("job1"), job("job2")])
    j1, j2 = env.job_ids
    g = Gate(env, "runner.after_scan_list")
    env.start_runner()
    g.wait_reached()
    env.admin_delete(j1)
    g.release()
    wait_ev(env, "RunnerScanReadDeleted")
    wait_until(lambda: not env.runner_thread.is_alive(), desc="runner thread dead")
    env.heartbeat(C2)
    return env


@scenario
def abort_during_deploy(root, out):
    """An admin aborts j1 (still SUBMITTED) while the runner deploys it: the abort is acknowledged, then overwritten by
    set_status(DISPATCHED); the job runs and completes (seed F1)."""
    env = build(root, out, cfg_with(scenario="abort_during_deploy"), [job("job1")])
    (j1,) = env.job_ids
    g = Gate(env, "runner.after_deploy", match=lambda info: info.get("job") == j1)
    env.start_runner()
    g.wait_reached()
    env.admin_abort(j1)
    wait_ev(env, "AdminAbortWrite", job=j1)
    g.release()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    normal_finish(env, j1, [C1, C2])
    return env


@scenario
def failrun_during_start(root, out):
    """c1's CJ fails while STARTING (rc 1 -> INFRASTRUCTURE_ERROR report) after START replied but before the runner
    processed the replies: fail_run pops the pending outcomes and _start_run then raises KeyError, so the job ends
    FINISHED:FAILED_TO_RUN (seed F5)."""
    env = build(root, out, cfg_with(scenario="failrun_during_start"), [job("job1")])
    (j1,) = env.job_ids
    env.cj_behavior[(C1, j1)] = {"auto_start": False, "on_abort": "stop_exit"}
    g = Gate(env, "runner.after_start_client_job", match=lambda info: info.get("job") == j1)
    env.start_runner()
    g.wait_reached()
    env.cj_exit(C1, j1, 1)
    wait_ev(env, "SpProcessJobFailure", job=j1, cl=C1)
    # let fail_run's stop_run settle first (clients aborted, SJ exited and popped): the runner's own _stop_run then
    # finds no run process, so no duplicate ABORT is in flight (see failrun_during_start_dup_abort)
    wait_ev(env, "CpAbortApp", job=j1, cl=C2, timeout=30.0)
    wait_ev(env, "SpWaitForComplete", job=j1, timeout=30.0)
    wait_ev(env, "SpRemoveRunProcesses", job=j1, timeout=30.0)
    g.release()
    wait_ev(env, "RunnerExceptMeta", job=j1, timeout=30.0)
    wait_ev(env, "CpChildFinished", job=j1, cl=C2, timeout=30.0)
    env.net.quiesce(5.0)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def failrun_during_start_dup_abort(root, out):
    """Seed F5 with both stop paths overlapping: fail_run's ABORTs to c2 and to the SJ are delayed, so when the runner's
    exception handler calls _stop_run again the SJ is still registered and a second, identical ABORT is sent to c2 and
    to the SJ.  Both copies are delivered and processed."""
    env = build(root, out, cfg_with(scenario="failrun_during_start_dup_abort"), [job("job1")])
    (j1,) = env.job_ids
    env.cj_behavior[(C1, j1)] = {"auto_start": False, "on_abort": "stop_exit"}
    env.net.set_policy(ident_is("ABORT", job=j1, cl=C2, env=env), "hold", once=True)
    env.net.set_policy(ident_is("SJABORT", job=j1, env=env), "hold", once=True)
    g = Gate(env, "runner.after_start_client_job", match=lambda info: info.get("job") == j1)
    env.start_runner()
    g.wait_reached()
    env.cj_exit(C1, j1, 1)
    wait_ev(env, "SpProcessJobFailure", job=j1, cl=C1)
    g.release()
    wait_ev(env, "RunnerExceptStop", job=j1, timeout=30.0)
    wait_until(lambda: len(env.net.held) >= 2, timeout=10.0, desc="first ABORTs held")
    env.net.release(lambda i: True)
    wait_ev(env, "RunnerExceptMeta", job=j1, timeout=30.0)
    wait_ev(env, "CpChildFinished", job=j1, cl=C2, timeout=30.0)
    env.net.quiesce(5.0)
    wait_until(lambda: sum(1 for e in env.tracer.events if e["name"] == "SpRemoveRunProcesses") >= 2,
               timeout=30.0, desc="abort cleanups done")
    env.net.quiesce(5.0)
    return env


@scenario
def refresh_rmw_revert(root, out):
    """The scheduler's refresh of a NO_RESOURCE job is an unlocked read-modify-write: an admin abort between its read
    and write is reverted to SUBMITTED, and the job is scheduled and runs anyway (seed F16)."""
    env = build(root, out, cfg_with(scenario="refresh_rmw_revert"), [job("job1", min_sites=2)])
    (j1,) = env.job_ids
    env.net.set_policy(ident_is("CHECK", job=j1, cl=C2, env=env), "drop", once=True)
    g = Gate(env, "rmw.between", match=lambda info: j1 in str(info.get("uri")))
    env.start_runner()
    g.wait_reached()
    env.admin_abort(j1)
    wait_ev(env, "AdminAbortWrite", job=j1)
    g.release()
    wait_ev(env, "RunnerRefreshWrite", job=j1)
    wait_ev(env, "RunnerSetRunning", job=j1, timeout=30.0)
    wait_started_on(env, j1, [C1, C2])
    normal_finish(env, j1, [C1, C2])
    return env


@scenario
def running_after_terminal(root, out):
    """The SJ crashes right after the runner inserted j1 into running_jobs but before it wrote RUNNING: the completion
    thread publishes FINISHED:EXECUTION_EXCEPTION and removes the job, then the runner overwrites the terminal status
    with RUNNING (seed F3)."""
    env = build(root, out, cfg_with(scenario="running_after_terminal"), [job("job1")])
    (j1,) = env.job_ids
    g = Gate(env, "runner.before_set_running", match=lambda info: info.get("job") == j1)
    env.start_runner()
    g.wait_reached()
    wait_started_on(env, j1, [C1, C2])
    env.sj_crash(j1)
    wait_ev(env, "CmpRemove", job=j1, timeout=30.0)
    g.release()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_ev(env, "CpChildFinished", job=j1, cl=C1, timeout=30.0)
    wait_ev(env, "CpChildFinished", job=j1, cl=C2, timeout=30.0)
    env.net.quiesce(5.0)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def start_timeout_late_start(root, out):
    """c2's START is held: the runner's non-strict reply check ignores the timeout and runs the job with c1 only.  The
    held START is processed late (c2 allocates and launches a CJ nobody waits for); after the job completes, c2's
    heartbeat gets that CJ aborted."""
    env = build(root, out, cfg_with(scenario="start_timeout_late_start"), [job("job1")])
    (j1,) = env.job_ids
    env.net.set_policy(ident_is("START", job=j1, cl=C2, env=env), "hold", once=True)
    env.start_runner()
    wait_ev(env, "RunnerStartTimeout", job=j1)
    wait_ev(env, "RunnerSetRunning", job=j1)
    assert env.net.release(ident_is("START", job=j1, cl=C2, env=env)) == 1
    wait_started_on(env, j1, [C1, C2])
    env.sj_finish(j1)
    wait_ev(env, "SpWaitForComplete", job=j1)
    env.finish_client_job(C1, j1)
    wait_ev(env, "CmpRemove", job=j1, timeout=30.0)
    env.heartbeat(C2)
    wait_ev(env, "CpChildFinished", job=j1, cl=C2, timeout=30.0)
    env.net.quiesce(5.0)
    env.heartbeat(C2)
    return env


@scenario
def concurrent_jobs_contention(root, out):
    """One unit per client and max_jobs=2: j1 (c1 only) and j2 (c2 only) run concurrently; j3 (both sites, min 1) finds
    no free unit until j1 ends, then is dispatched to c1 alone (c2 answers not-enough) and runs there."""
    env = build(root, out, cfg_with(scenario="concurrent_jobs_contention", units=[0], max_jobs=2),
                [job("job1", sites=(C1,)), job("job2", sites=(C2,)), job("job3", min_sites=1)])
    j1, j2, j3 = env.job_ids
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_ev(env, "RunnerSetRunning", job=j2, timeout=30.0)
    wait_started_on(env, j1, [C1])
    wait_started_on(env, j2, [C2])
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    normal_finish(env, j1, [C1])
    wait_ev(env, "RunnerSetRunning", job=j3, timeout=30.0)
    wait_started_on(env, j3, [C1])
    normal_finish(env, j2, [C2])
    normal_finish(env, j3, [C1])
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def expiry_before_start(root, out):
    """j1's reservation on c1 expires while the runner is still deploying (slow deploy): START on c1 finds no reserved
    resources and replies with an error, so the whole job ends FINISHED:FAILED_TO_RUN and c2's CJ and the SJ are
    aborted.  No unit is lost or double-owned."""
    env = build(root, out, cfg_with(scenario="expiry_before_start"), [job("job1")])
    (j1,) = env.job_ids
    g = Gate(env, "runner.after_deploy", match=lambda info: info.get("job") == j1)
    env.start_runner()
    g.wait_reached()
    for _ in range(env.expiry):
        env.tick(C1)
    g.release()
    wait_ev(env, "RunnerExceptMeta", job=j1, timeout=30.0)
    wait_ev(env, "CpChildFinished", job=j1, cl=C2, timeout=30.0)
    wait_ev(env, "SpRemoveRunProcesses", job=j1, timeout=30.0)
    env.net.quiesce(5.0)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def disable_between_schedule_and_deploy(root, out):
    """c2 is disabled after the scheduler reserved on it but before deployment: the deployer rejects the whole job
    ("unknown clients") although min_sites=1 would be met by c1.  The later job j2 is scheduled on c1 alone and
    completes; the orphaned reservations expire."""
    env = build(root, out, cfg_with(scenario="disable_between_schedule_and_deploy"), [job("job1"), job("job2")])
    j1, j2 = env.job_ids
    g = Gate(env, "runner.before_check_submitted", match=lambda info: info.get("job") == j1)
    env.start_runner()
    g.wait_reached()
    env.admin_disable(C2)
    g.release()
    wait_ev(env, "RunnerExceptMeta", job=j1, timeout=30.0)
    wait_ev(env, "RunnerSetRunning", job=j2, timeout=30.0)
    wait_started_on(env, j2, [C1])
    normal_finish(env, j2, [C1])
    for cl in (C1, C2):
        for _ in range(env.expiry):
            env.tick(cl)
    wait_until(lambda: all(not env.cps[c].rm.reserved_resources for c in (C1, C2)), desc="reservations expired")
    env.heartbeat(C1)
    return env


@scenario
def abort_before_checks(root, out):
    """Admin aborts land right before the runner's status re-checks: j1 before the SUBMITTED re-check (skipped), j2
    before the DISPATCHED re-check (deployed but never started).  Both stay FINISHED:ABORTED; the runner never cancels
    their reservations, which only expiry reclaims."""
    env = build(root, out, cfg_with(scenario="abort_before_checks"), [job("job1"), job("job2")])
    j1, j2 = env.job_ids
    g1 = Gate(env, "runner.before_check_submitted", match=lambda info: info.get("job") == j1)
    g2 = Gate(env, "runner.before_check_dispatched", match=lambda info: info.get("job") == j2)
    env.start_runner()
    g1.wait_reached()
    env.admin_abort(j1)
    wait_ev(env, "AdminAbortWrite", job=j1)
    g1.release()
    wait_ev(env, "RunnerCheckSubmitted", job=j1)
    g2.wait_reached()
    env.admin_abort(j2)
    wait_ev(env, "AdminAbortWrite", job=j2)
    g2.release()
    wait_ev(env, "RunnerCheckDispatched", job=j2)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    for cl in (C1, C2):
        for _ in range(env.expiry):
            env.tick(cl)
    wait_until(lambda: all(not env.cps[c].rm.reserved_resources for c in (C1, C2)), desc="reservations expired")
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def lost_report_heartbeat(root, out):
    """Everything succeeds, but c2's best-effort terminal report is lost.  c2's next heartbeat no longer lists the job,
    so the server resolves the missing outcome with fail_run(INFRASTRUCTURE_ERROR) and publishes FINISHED:ABNORMAL."""
    env = build(root, out, cfg_with(scenario="lost_report_heartbeat"), [job("job1")])
    (j1,) = env.job_ids
    env.net.set_policy(ident_is("REPORT", job=j1, cl=C2, env=env), "drop", once=True)
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    env.sj_finish(j1)
    wait_ev(env, "SpWaitForComplete", job=j1)
    env.finish_client_job(C1, j1)
    env.finish_client_job(C2, j1)
    wait_ev(env, "LoseMsg")
    wait_ev(env, "SpProcessJobFailure", job=j1, cl=C1)
    env.heartbeat(C2)
    wait_ev(env, "CmpRemove", job=j1, timeout=30.0)
    env.heartbeat(C1)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def unsupported_app_missing(root, out):
    """OPT-IN, outside the supported envelope (Trace.cfg EnableUnsupported = FALSE rejects it by design): c1's deployed
    app directory disappears before START, ClientEngine.start_app returns an error string after allocation and the
    allocation is never freed (seed F9)."""
    import shutil

    env = build(root, out, cfg_with(scenario="unsupported_app_missing"), [job("job1")])
    (j1,) = env.job_ids
    g = Gate(env, "runner.after_deploy", match=lambda info: info.get("job") == j1)
    env.start_runner()
    g.wait_reached()
    shutil.rmtree(os.path.join(env.cps[C1].ws, j1, "app_" + C1))
    g.release()
    wait_ev(env, "RunnerExceptMeta", job=j1, timeout=30.0)
    wait_ev(env, "CpChildFinished", job=j1, cl=C2, timeout=30.0)
    env.net.quiesce(5.0)
    wait_ev(env, "RunnerScanRead", start=env.tracer.count(), timeout=10.0)
    return env


@scenario
def double_abort_terminate(root, out):
    """c1's CJ handles the admin ABORT but is slow to exit.  The server finalizes the job (FINISHED:ABORTED) while the
    CJ is still registered, so c1's next heartbeat aborts it again: the CP now runs two _terminate_job threads for the
    same job.  The first kills the CJ after its 10 s grace, the second then returns early."""
    env = build(root, out, cfg_with(scenario="double_abort_terminate"), [job("job1")])
    (j1,) = env.job_ids
    env.cj_behavior[(C1, j1)] = {"auto_start": True, "on_abort": "stop_only"}
    env.start_runner()
    wait_ev(env, "RunnerSetRunning", job=j1)
    wait_started_on(env, j1, [C1, C2])
    env.admin_abort(j1)
    wait_ev(env, "CjHandleAbort", job=j1, cl=C1, timeout=30.0)
    wait_ev(env, "CmpRemove", job=j1, timeout=30.0)
    env.heartbeat(C1)
    wait_ev(env, "CpAbortApp", job=j1, cl=C1, pred=lambda e: e["msg"]["flag"], timeout=30.0)
    wait_ev(env, "CpChildFinished", job=j1, cl=C1, timeout=30.0)
    wait_until(lambda: sum(1 for e in env.tracer.events
                           if e["name"] == "CpTerminateJob" and e.get("real_cl") == C1) >= 2,
               timeout=30.0, desc="both terminate threads done")
    env.net.quiesce(5.0)
    env.heartbeat(C1)
    return env


# ----------------------------------------------------------------------------------------------- randomized mix
def _alive_cjs(env, jid):
    return [cl for cl in env.client_names if env.cj_state(cl, jid) == "Alive"]


def _reg_status(env, cl, jid):
    reg = env.cps[cl].executor.run_processes.get(jid)
    return None if reg is None else reg.get("_status")


def _drain(env, rnd, deadline=60.0):
    """Let every job reach a quiescent end: deliver held messages, end SJs/CJs cooperatively, expire reservations."""
    end = time.monotonic() + deadline
    env.net.release(lambda i: True)
    while time.monotonic() < end:
        busy = False
        for jid in env.job_ids:
            if env.sj_state(jid) == "Running":
                busy = True
                if all(_reg_status(env, cl, jid) in (None, 2, 3) for cl in _alive_cjs(env, jid)):
                    env.sj_finish(jid)
            for cl in _alive_cjs(env, jid):
                busy = True
                st = _reg_status(env, cl, jid)
                if st == 1:
                    env.cj_notify_started(cl, jid)
                elif st in (2, 3) and env.sj_state(jid) != "Running":
                    env.finish_client_job(cl, jid)
        for cl in env.client_names:
            if env.cps[cl].rm.reserved_resources:
                busy = True
                env.tick(cl)
        env.net.release(lambda i: True)
        # also wait for jobs that are still queued or being started (they end COMPLETED/CAN_NOT_SCHEDULE/...)
        pending_jobs = [j for j in env.job_ids
                        if (env.read_meta(j) or {}).get("status") in ("SUBMITTED", "DISPATCHED", "RUNNING")]
        if not busy and not pending_jobs and not env.runner.running_jobs and env.net.quiesce(0.5):
            break
        for cl in env.client_names:
            if rnd.random() < 0.3:
                env.heartbeat(cl)
        time.sleep(0.3)
    env.net.quiesce(5.0)


def _random_mix(root, out, seed, duration=12.0):
    import random

    rnd = random.Random(seed)
    jobs = []
    for i in range(4):
        sites = rnd.choice([(C1, C2), (C1, C2), (C1,), (C2,)])
        min_sites = rnd.randint(1, len(sites))
        required = tuple(s for s in sites if rnd.random() < 0.2)
        jobs.append(job(f"job{i + 1}", sites=sites, min_sites=min_sites, required=required))
    cfg = cfg_with(scenario=f"random_mix_s{seed}", max_jobs=2, max_schedule_count=6, client_outcome_wait_timeout=3.0)
    env = build(root, out, cfg, jobs)
    ids = env.job_ids
    for jid in ids:
        for cl in (C1, C2):
            env.cj_behavior[(cl, jid)] = {
                "auto_start": rnd.random() < 0.85,
                "on_abort": rnd.choice(["stop_exit", "stop_exit", "stop_exit", "stop_only"]),
            }
        if rnd.random() < 0.3:
            env.net.set_policy(ident_is("CHECK", job=jid, cl=rnd.choice([C1, C2]), env=env),
                               rnd.choice(["hold", "drop"]), once=True)
        if rnd.random() < 0.15:
            env.net.set_policy(ident_is("START", job=jid, cl=rnd.choice([C1, C2]), env=env), "hold", once=True)
        if rnd.random() < 0.15:
            env.net.set_policy(ident_is("REPORT", job=jid, cl=rnd.choice([C1, C2]), env=env), "drop", once=True)
        if rnd.random() < 0.1:
            env.net.set_policy(ident_is("RUNSTATUS", job=jid, env=env), "drop", once=True)
    env.start_runner()
    t_end = time.monotonic() + duration
    while time.monotonic() < t_end:
        time.sleep(rnd.uniform(0.05, 0.35))
        running = [j for j in ids if env.sj_state(j) == "Running"]
        r = rnd.random()
        if r < 0.30 and running:
            jid = rnd.choice(running)
            alive = _alive_cjs(env, jid)
            k = rnd.random()
            if k < 0.55:
                if all(_reg_status(env, cl, jid) in (2, 3) for cl in alive):
                    env.sj_finish(jid)
                    for cl in alive:
                        if rnd.random() < 0.8:
                            env.finish_client_job(cl, jid)
            elif k < 0.70:
                env.sj_finish(jid, execution_error=True, rc=1)
            elif k < 0.80:
                env.sj_crash(jid)
            elif alive:
                env.cj_exit(rnd.choice(alive), jid, 1)
        elif r < 0.40:
            for jid in ids:
                for cl in _alive_cjs(env, jid):
                    st = _reg_status(env, cl, jid)
                    if st == 1 and rnd.random() < 0.5:
                        env.cj_notify_started(cl, jid)
                    elif st in (2, 3) and env.sj_state(jid) != "Running" and rnd.random() < 0.5:
                        env.finish_client_job(cl, jid)
        elif r < 0.50:
            env.admin_abort(rnd.choice(ids))
        elif r < 0.55:
            terminal = [j for j in ids if (env.read_meta(j) or {}).get("status", "").startswith("FINISHED")]
            if terminal:
                env.admin_delete(rnd.choice(terminal))
        elif r < 0.70:
            env.heartbeat(rnd.choice(env.client_names))
        elif r < 0.80:
            cl = rnd.choice(env.client_names)
            if env.cps[cl].rm.reserved_resources:
                env.tick(cl)
        elif r < 0.90 and env.net.held:
            if rnd.random() < 0.7:
                env.net.release(lambda i: rnd.random() < 0.5)
            else:
                env.net.drop_held(lambda i: i.get("type") in env.MODELED_TYPES and rnd.random() < 0.5)
    _drain(env, rnd)
    return env


for _seed in range(1, 41):  # random_mix_s1..s6 are in the default run.sh set; more seeds can be run on demand
    def _mk(seed):
        def fn(root, out):
            return _random_mix(root, out, seed)

        fn.__name__ = f"random_mix_s{seed}"
        fn.__doc__ = f"Seeded random mix of overlapping operations and ordinary faults (seed {seed}); see _random_mix."
        return fn

    scenario(_mk(_seed))

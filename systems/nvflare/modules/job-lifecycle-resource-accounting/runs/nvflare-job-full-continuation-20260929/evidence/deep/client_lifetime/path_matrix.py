#!/usr/bin/env python3
"""Path matrix: for each CP path from CHECK_RESOURCE to process exit, count reserve / cancel / expire / allocate /
free events (by unit identity) and check: (i) every allocated unit is returned exactly once, (ii) no unit is
duplicated in the pool, (iii) free never happens while the job's leader process is alive, and record whether a
same-process-group descendant is alive at free time.

Observation hooks only: CountingLRM subclasses the real ListResourceManager and records calls before delegating to
the real implementation (_deallocate caller identified via the call stack). Everything else as in cp_harness.py.
"""
import argparse
import inspect
import json
import os
import signal
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cp_harness as H  # noqa: E402

from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.app_common.resource_consumers.list_resource_consumer import ListResourceConsumer  # noqa: E402
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager  # noqa: E402
from nvflare.private.fed.client.client_status import ClientStatus  # noqa: E402

POOL = [0, 1, 2, 3]


class CountingLRM(ListResourceManager):
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.events = []
        self.pid_of_token = {}  # filled by the harness when the child record appears
        self.gc_of_token = {}

    def check_resources(self, resource_requirement, fl_ctx):
        ok, tok = super().check_resources(resource_requirement, fl_ctx)
        self.events.append({"t": H.ts(), "ev": "reserve", "ok": ok, "tok": tok[:8] if tok else tok})
        return ok, tok

    def cancel_resources(self, resource_requirement, token, fl_ctx):
        self.events.append({"t": H.ts(), "ev": "cancel_call", "tok": (token or "")[:8]})
        return super().cancel_resources(resource_requirement, token, fl_ctx)

    def allocate_resources(self, resource_requirement, token, fl_ctx):
        try:
            res = super().allocate_resources(resource_requirement, token, fl_ctx)
        except Exception as e:
            self.events.append({"t": H.ts(), "ev": "allocate_raised", "tok": (token or "")[:8], "err": str(e)[:60]})
            raise
        self.events.append({"t": H.ts(), "ev": "allocate", "tok": (token or "")[:8], "units": res.get("gpu", [])})
        return res

    def free_resources(self, resources, token, fl_ctx):
        pid = self.pid_of_token.get(token)
        gc = self.gc_of_token.get(token)
        self.events.append(
            {
                "t": H.ts(),
                "ev": "free",
                "tok": (token or "")[:8],
                "units": resources.get("gpu", []),
                "leader_alive_at_free": (H.alive(pid) if pid else None),
                "grandchild_alive_at_free": (H.alive(gc) if gc else None),
                "caller": inspect.stack()[1].function,
            }
        )
        return super().free_resources(resources, token, fl_ctx)

    def _deallocate(self, resources):
        caller = inspect.stack()[1].function
        if caller == "_check_expired":
            self.events.append({"t": H.ts(), "ev": "expire_dealloc", "units": resources.get("gpu", [])})
        elif caller == "cancel_resources":
            self.events.append({"t": H.ts(), "ev": "cancel_dealloc", "units": resources.get("gpu", [])})
        return super()._deallocate(resources)


def summarize(rm, name):
    ev = rm.events
    alloc_units = [u for e in ev if e["ev"] == "allocate" for u in e["units"]]
    freed_units = [u for e in ev if e["ev"] == "free" for u in e["units"]]
    pool = list(rm.resources["gpu"])
    reserved_units = [u for (r, _t) in rm.reserved_resources.values() for u in r.get("gpu", [])]
    return {
        "path": name,
        "n_reserve": sum(1 for e in ev if e["ev"] == "reserve" and e["ok"]),
        "n_cancel_dealloc": sum(1 for e in ev if e["ev"] == "cancel_dealloc"),
        "n_expire_dealloc": sum(1 for e in ev if e["ev"] == "expire_dealloc"),
        "n_allocate": sum(1 for e in ev if e["ev"] == "allocate"),
        "n_allocate_raised": sum(1 for e in ev if e["ev"] == "allocate_raised"),
        "n_free": sum(1 for e in ev if e["ev"] == "free"),
        "allocated_units": alloc_units,
        "freed_units": freed_units,
        "every_alloc_freed_exactly_once": sorted(alloc_units) == sorted(freed_units),
        "pool_end": sorted(pool),
        "still_reserved_units": reserved_units,
        "pool_has_duplicates": len(pool) != len(set(pool)),
        "lost_units": sorted(set(POOL) - set(pool) - set(reserved_units)),
        "free_while_leader_alive": any(e.get("leader_alive_at_free") for e in ev if e["ev"] == "free"),
        "free_while_same_pgid_descendant_alive": any(e.get("grandchild_alive_at_free") for e in ev if e["ev"] == "free"),
        "events": ev,
    }


def new_env(prefix, child_secs=30.0, grandchild_secs=0.0, expiration=300, consumer=None, extra=()):
    ws = tempfile.mkdtemp(prefix=prefix)
    rm = CountingLRM({"gpu": list(POOL)}, expiration_period=expiration)
    launcher = H.StubCmdLauncher(ws, child_secs=child_secs, grandchild_secs=grandchild_secs)
    ce = H.make_engine(ws, rm, consumer if consumer is not None else ListResourceConsumer(), [launcher, *extra])
    ce.fire_event(EventType.SYSTEM_START, ce.new_context())
    return ws, rm, launcher, ce


def track_child(ws, rm, jid, tok, wait=10.0):
    child = H.read_child(ws, jid, wait=wait)
    if child:
        rm.pid_of_token[tok] = child["pid"]
        if child.get("grandchild_pid"):
            rm.gc_of_token[tok] = child["grandchild_pid"]
            H.SPAWNED.append(child["grandchild_pid"])
    return child


def end(ce, rm, name, results, extra=None):
    H.wait_until(lambda: not H.registered(ce), timeout=25)
    s = summarize(rm, name)
    s["registered_end"] = H.registered(ce)
    s["reports"] = [r["payload"] for r in ce.client.reports]
    if extra:
        s.update(extra)
    ce.fire_event(EventType.SYSTEM_END, ce.new_context())
    results.append(s)


def meta_for(jid, units=1):
    return {"job_id": jid, "resource_spec": {"site-1": {"gpu": units}}}


# ---------------------------------------------------------------- paths
def p01_success(results):
    ws, rm, _, ce = new_env("pm01-", child_secs=1.0)
    m = meta_for("j01")
    H.deploy(ws, m)
    ok, tok = H.check(ce, "j01", {"gpu": 1})
    reply = H.start(ce, m, {"gpu": 1}, tok)
    track_child(ws, rm, "j01", tok)
    H.notify(ce, "j01", ClientStatus.STARTED)
    time.sleep(0.2)
    H.notify(ce, "j01", ClientStatus.STOPPED)
    end(ce, rm, "P01 success (CJ exits rc0)", results, {"start_reply": reply})


def p02_allocate_failure_after_expiry(results):
    ws, rm, _, ce = new_env("pm02-", expiration=1)
    m = meta_for("j02")
    H.deploy(ws, m)
    ok, tok = H.check(ce, "j02", {"gpu": 1})
    time.sleep(2.5)
    reply = H.start(ce, m, {"gpu": 1}, tok)
    end(ce, rm, "P02 allocate failure (reservation expired before START_JOB)", results, {"start_reply": reply})


def p03_consume_failure(results):
    """Consumer raises after allocate (supported extension point: custom _Consumer in resource_consumer_map)."""
    from nvflare.app_common.resource_consumers.list_resource_consumer import _Consumer

    class RaisingConsumer(_Consumer):
        def consume(self, resources):
            raise RuntimeError("device not usable")

    consumer = ListResourceConsumer()
    consumer.resource_consumer_map["gpu"] = RaisingConsumer()
    ws, rm, _, ce = new_env("pm03-", consumer=consumer)
    m = meta_for("j03")
    H.deploy(ws, m)
    ok, tok = H.check(ce, "j03", {"gpu": 1})
    reply = H.start(ce, m, {"gpu": 1}, tok)
    end(ce, rm, "P03 consume failure (consumer raises after allocate)", results, {"start_reply": reply})


def p04_launch_failure(results):
    ws, rm, launcher, ce = new_env("pm04-")
    launcher.get_command = lambda job_meta, fl_ctx: "/nonexistent/nvflare-cj-binary --x"
    m = meta_for("j04")
    H.deploy(ws, m)
    ok, tok = H.check(ce, "j04", {"gpu": 1})
    reply = H.start(ce, m, {"gpu": 1}, tok)
    end(ce, rm, "P04 launch failure (spawn raises)", results, {"start_reply": reply})


def p05_start_app_raises_prereg(results):
    ws, rm, _, ce = new_env("pm05-")
    m = meta_for("j05")
    H.deploy(ws, {"job_id": "j05", "resource_spec": {"site-1": {"gpu": 2}}})  # deployed meta differs
    ok, tok = H.check(ce, "j05", {"gpu": 1})
    reply = H.start(ce, m, {"gpu": 1}, tok)
    end(ce, rm, "P05 start_app raises before registration (meta mismatch)", results, {"start_reply": reply})


def p05b_start_app_returns_error_string(results):
    ws, rm, _, ce = new_env("pm05b-")
    m = meta_for("j05b")  # not deployed -> "Client app does not exist" string (K5, known)
    ok, tok = H.check(ce, "j05b", {"gpu": 1})
    reply = H.start(ce, m, {"gpu": 1}, tok)
    end(ce, rm, "P05b start_app returns error string (K5 known)", results, {"start_reply": reply})


def p06_abort_starting_pending(results):
    ws, rm, launcher, ce = new_env("pm06-")
    m = meta_for("j06")
    H.deploy(ws, m)
    ok, tok = H.check(ce, "j06", {"gpu": 1})
    reached, release = launcher.arm_launch_gate("j06")
    res = {}
    th = threading.Thread(target=lambda: res.setdefault("r", H.start(ce, m, {"gpu": 1}, tok)), daemon=True)
    th.start()
    reached.wait(10)
    ab = H.abort(ce, "j06")
    release.set()
    th.join(20)
    end(ce, rm, "P06 abort while STARTING (before handle attach)", results, {"start_reply": res.get("r"), "abort": ab})


def _started_job(prefix, jid, child_secs=60.0, grandchild_secs=0.0):
    ws, rm, launcher, ce = new_env(prefix, child_secs=child_secs, grandchild_secs=grandchild_secs)
    m = meta_for(jid)
    H.deploy(ws, m)
    ok, tok = H.check(ce, jid, {"gpu": 1})
    reply = H.start(ce, m, {"gpu": 1}, tok)
    track_child(ws, rm, jid, tok)
    return ws, rm, launcher, ce, tok, reply


def p07_abort_started(results):
    ws, rm, _, ce, tok, reply = _started_job("pm07-", "j07")
    H.notify(ce, "j07", ClientStatus.STARTED)
    t = H.ts()
    ab = H.abort(ce, "j07")  # CJ stub ignores the ABORT message -> terminate after <= 10 s
    end(ce, rm, "P07 admin ABORT while STARTED (CJ ignores abort msg)", results,
        {"start_reply": reply, "abort": ab, "abort_call_secs": round(H.ts() - t, 2)})


def p08_abort_stopped(results):
    ws, rm, _, ce, tok, reply = _started_job("pm08-", "j08")
    H.notify(ce, "j08", ClientStatus.STARTED)
    H.notify(ce, "j08", ClientStatus.STOPPED)  # runner returned, process still alive
    t = H.ts()
    ab = H.abort(ce, "j08")
    end(ce, rm, "P08 ABORT while STOPPED-but-alive", results,
        {"start_reply": reply, "abort": ab, "abort_call_secs": round(H.ts() - t, 2)})


def p09_heartbeat_cleanup_started(results):
    ws, rm, _, ce, tok, reply = _started_job("pm09-", "j09")
    H.notify(ce, "j09", ClientStatus.STARTED)
    t = H.ts()
    ab = ce.abort_app("j09", heartbeat_cleanup=True)
    end(ce, rm, "P09 heartbeat-cleanup abort while STARTED", results,
        {"start_reply": reply, "abort": ab, "abort_call_secs": round(H.ts() - t, 2)})


def p10_duplicate_start_same_token(results):
    ws, rm, _, ce, tok, reply = _started_job("pm10-", "j10")
    m = meta_for("j10")
    reply2 = H.start(ce, m, {"gpu": 1}, tok)
    ce.abort_app("j10", heartbeat_cleanup=True)
    end(ce, rm, "P10 duplicate START_JOB, same token, while STARTING", results,
        {"start_reply": reply, "start_reply_2": reply2})


def p11_duplicate_start_fresh_token(results):
    ws, rm, _, ce, tok, reply = _started_job("pm11-", "j11")
    m = meta_for("j11")
    ok2, tok2 = H.check(ce, "j11", {"gpu": 1})
    reply2 = H.start(ce, m, {"gpu": 1}, tok2)
    H.notify(ce, "j11", ClientStatus.STARTED)
    ok3, tok3 = H.check(ce, "j11", {"gpu": 1})
    reply3 = H.start(ce, m, {"gpu": 1}, tok3)  # STARTED -> "already started" string (K5 known)
    ce.abort_app("j11", heartbeat_cleanup=True)
    end(ce, rm, "P11 duplicate START_JOB fresh token (STARTING -> raise; STARTED -> K5 string)", results,
        {"start_reply": reply, "start_reply_2_while_starting": reply2, "start_reply_3_while_started": reply3})


def p12_concurrent_duplicate_abort(results):
    ws, rm, _, ce, tok, reply = _started_job("pm12-", "j12")
    H.notify(ce, "j12", ClientStatus.STARTED)
    outs = []
    ths = [threading.Thread(target=lambda: outs.append(H.abort(ce, "j12"))) for _ in range(2)]
    ths.append(threading.Thread(target=lambda: outs.append(ce.abort_app("j12", heartbeat_cleanup=True))))
    for th in ths:
        th.start()
    for th in ths:
        th.join(30)
    end(ce, rm, "P12 two admin ABORTs + heartbeat cleanup concurrently (STARTED)", results,
        {"start_reply": reply, "abort_replies": outs})


def p13_leader_exit_descendant_alive(results):
    ws, rm, _, ce, tok, reply = _started_job("pm13-", "j13", child_secs=1.0, grandchild_secs=8.0)
    H.notify(ce, "j13", ClientStatus.STARTED)
    H.notify(ce, "j13", ClientStatus.STOPPED)
    end(ce, rm, "P13 CJ leader exits normally, same-pgid descendant alive (K8 known)", results, {"start_reply": reply})


def p14_abort_started_leader_exits_descendant_alive(results):
    ws, rm, _, ce, tok, reply = _started_job("pm14-", "j14", child_secs=2.0, grandchild_secs=12.0)
    H.notify(ce, "j14", ClientStatus.STARTED)
    ab = H.abort(ce, "j14")  # leader exits (2 s) within the 10 s grace -> _terminate_job returns early, no killpg
    child_gc = rm.gc_of_token.get(tok)
    extra = {"start_reply": reply, "abort": ab, "grandchild_alive_after_abort_returned": H.alive(child_gc)}
    end(ce, rm, "P14 ABORT while STARTED, leader exits in grace, descendant survives (K8 variant)", results, extra)


def p15_cancel_and_expiry(results):
    ws, rm, _, ce = new_env("pm15-", expiration=1)
    ok1, tok1 = H.check(ce, "j15a", {"gpu": 1})
    ok2, tok2 = H.check(ce, "j15b", {"gpu": 1})
    H.cancel = getattr(H, "cancel", None)
    from nvflare.private.admin_defs import Message
    from nvflare.private.defs import TrainingTopic
    from nvflare.private.fed.client.scheduler_cmds import CancelResourceProcessor
    from nvflare.private.scheduler_constants import ShareableHeader

    req = Message(topic=TrainingTopic.CANCEL_RESOURCE, body={"gpu": 1})
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, tok1)
    CancelResourceProcessor().process(req, ce)
    time.sleep(2.5)  # tok2 expires
    CancelResourceProcessor().process(req, ce)  # duplicate cancel of tok1
    end(ce, rm, "P15 cancel + expiry + duplicate cancel (no allocate)", results)


PATHS = [
    p01_success,
    p02_allocate_failure_after_expiry,
    p03_consume_failure,
    p04_launch_failure,
    p05_start_app_raises_prereg,
    p05b_start_app_returns_error_string,
    p06_abort_starting_pending,
    p07_abort_started,
    p08_abort_stopped,
    p09_heartbeat_cleanup_started,
    p10_duplicate_start_same_token,
    p11_duplicate_start_fresh_token,
    p12_concurrent_duplicate_abort,
    p13_leader_exit_descendant_alive,
    p14_abort_started_leader_exits_descendant_alive,
    p15_cancel_and_expiry,
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", nargs="*")
    a = ap.parse_args()
    results = []
    threads = []
    for fn in PATHS:
        if a.only and fn.__name__ not in a.only:
            continue

        def run(fn=fn):
            try:
                fn(results)
            except Exception as e:
                results.append({"path": fn.__name__, "error": f"{type(e).__name__}: {e}", "tb": traceback.format_exc()})

        th = threading.Thread(target=run, name=fn.__name__)
        th.start()
        threads.append(th)
        if fn in (p03_consume_failure,):
            th.join()  # patches process-global gpu_utils edge / os.environ
    for th in threads:
        th.join(120)
    time.sleep(0.5)
    for pid in H.SPAWNED:
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except Exception:
            pass
    results.sort(key=lambda r: r.get("path", ""))
    table = [
        {k: r.get(k) for k in (
            "path", "n_reserve", "n_cancel_dealloc", "n_expire_dealloc", "n_allocate", "n_allocate_raised", "n_free",
            "every_alloc_freed_exactly_once", "pool_has_duplicates", "lost_units", "still_reserved_units",
            "free_while_leader_alive", "free_while_same_pgid_descendant_alive", "error")}
        for r in results
    ]
    out = {"table": table, "details": results}
    txt = json.dumps(out, indent=1, default=str)
    with open(a.out, "w") as f:
        f.write(txt + "\n")
    print(json.dumps(table, indent=1, default=str))
    os._exit(0)


if __name__ == "__main__":
    main()

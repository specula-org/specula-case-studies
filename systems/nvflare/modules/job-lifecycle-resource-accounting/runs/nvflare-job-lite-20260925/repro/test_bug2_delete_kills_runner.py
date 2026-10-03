"""Reproduction for candidate MC-2: deleting a queued (SUBMITTED) job while the JobRunner is deploying it
terminates the JobRunner scheduling thread; every later job then stays SUBMITTED forever.

Level 0 (black-box): real POC, public FLARE admin API only (submit_job, delete_job, get_job_meta, list_jobs).
The delete is timed by an externally observable signal: the job's server-side run directory appears
(JobRunner is inside _deploy_job; the job-store status is still SUBMITTED, so delete_job is permitted by
job_cmds.py:516). No product code or configuration is modified.

Bug criterion: delete_job succeeds, the server process stays up with both clients connected, but a job
submitted afterwards is never scheduled (remains SUBMITTED for the whole observation window, while a normal
job is picked up in < 2 s — see test_sanity.py), and the server log shows the JobRunner exception.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, log_offset, log_since, server_log, server_run_dir, session, status  # noqa
from probe_job import make_probe_job  # noqa


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--observe", type=float, default=90.0)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    sess, sess2 = session(), session()
    rec = {}
    log_off = log_offset(server_log())
    console = os.path.join(os.path.dirname(server_log()), "poc_console.log")
    console_off = log_offset(console)

    job_a = make_probe_job(os.path.join(R, "jobs", "delete-a"), name="delete-a", num_rounds=2, sleep_time=1.0)
    t0 = time.time()
    a_id = sess.submit_job(job_a)
    rec["job_a"] = a_id
    trig = None
    while time.time() - t0 < 20:
        if os.path.isdir(server_run_dir(a_id)):
            trig = round(time.time() - t0, 3)
            break
        time.sleep(0.002)
    rec["t_server_run_dir"] = trig
    rec["status_a_before_delete"] = status(sess2, a_id)
    try:
        rec["delete_reply"] = sess2.delete_job(a_id)
    except Exception as e:
        rec["delete_reply"] = f"<delete error {type(e).__name__}: {e}>"
    rec["t_delete"] = round(time.time() - t0, 3)
    time.sleep(5)

    # a later, eligible job
    job_b = make_probe_job(os.path.join(R, "jobs", "delete-b"), name="delete-b", num_rounds=1, sleep_time=1.0)
    tb = time.time()
    b_id = sess.submit_job(job_b)
    rec["job_b"] = b_id
    trace = []
    while time.time() - tb < a.observe:
        st = status(sess, b_id)
        if not trace or trace[-1][1] != st:
            trace.append((round(time.time() - tb, 2), st))
        if st and st != "SUBMITTED":
            break
        time.sleep(1.0)
    rec["job_b_status_trace"] = trace
    rec["job_b_final"] = status(sess, b_id)
    try:
        clients = sess.get_system_info().client_info
        rec["connected_clients"] = sorted(c.name for c in clients)
    except Exception as e:
        rec["connected_clients"] = f"<error {e}>"
    new_log = log_since(server_log(), log_off)
    new_console = log_since(console, console_off)
    rec["server_log_excerpt"] = [l for l in new_log.splitlines()
                                 if a_id in l or "Traceback" in l or "Exception" in l or "Error" in l][:20]
    rec["console_excerpt"] = [l for l in new_console.splitlines()
                              if "Traceback" in l or "Error" in l or "Exception" in l or "job_runner" in l
                              or "File " in l][:40]
    rec["BUG"] = bool(isinstance(rec["delete_reply"], dict) and rec["job_b_final"] == "SUBMITTED")
    print(json.dumps(rec, indent=1))
    if a.out:
        with open(a.out, "w") as f:
            json.dump(rec, f, indent=1)
    sess.close()
    sess2.close()
    return 0 if rec["BUG"] else 1


if __name__ == "__main__":
    sys.exit(main())

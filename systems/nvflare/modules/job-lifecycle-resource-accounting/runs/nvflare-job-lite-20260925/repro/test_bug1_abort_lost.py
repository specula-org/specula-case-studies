"""Reproduction for candidate MC-1: an admin abort_job acknowledged as "Aborted the job ... before running it."
is lost — the JobRunner overwrites FINISHED:ABORTED with DISPATCHED/RUNNING and starts the job anyway.

Level 0 (black-box): real POC (server + 2 client parents as OS processes), public FLARE admin API only.
The abort is timed by externally observable signals only:
  --when deploy     : the server-side run directory of the job appears (the runner is inside _deploy_job;
                      the job-store status is still SUBMITTED), then abort_job is sent.
  --when dispatched : the job-store status reads DISPATCHED (runner inside _start_run), then abort_job is sent.
No product code or configuration is modified.

Bug criterion (per attempt): abort_job returned "Aborted the job <id> before running it." and afterwards the
job-store status left FINISHED:ABORTED (DISPATCHED/RUNNING/FINISHED:COMPLETED) and/or an SJ/CJ process for the
job was running after the acknowledgement.
"""
import argparse
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, grep_file, server_log, server_run_dir, session, sj_processes, status  # noqa
from probe_job import make_probe_job  # noqa


def attempt(poll_sess, abort_sess, idx, when, pad_mb, sleep_time, rounds, observe_s):
    name = f"abort-{when}-{idx}"
    job_dir = make_probe_job(os.path.join(R, "jobs", name), name=name, num_rounds=rounds, sleep_time=sleep_time,
                             pad_mb=pad_mb)
    t0 = time.time()
    job_id = poll_sess.submit_job(job_dir)
    rec = {"attempt": idx, "when": when, "job_id": job_id, "pad_mb": pad_mb}
    # wait for the trigger point
    trig = None
    deadline = t0 + 20
    while time.time() < deadline:
        if when == "deploy":
            if os.path.isdir(server_run_dir(job_id)):
                trig = "server_run_dir"
                break
            time.sleep(0.002)
        else:
            st = status(poll_sess, job_id)
            if st == "DISPATCHED":
                trig = "status=DISPATCHED"
                break
            if st and st != "SUBMITTED":
                trig = f"missed(status={st})"
                break
    rec["trigger"] = trig
    rec["t_trigger"] = round(time.time() - t0, 3)
    procs_at_ack = None
    try:
        reply = abort_sess.abort_job(job_id)
    except Exception as e:
        reply = f"<abort error {type(e).__name__}: {e}>"
    t_ack = time.time()
    rec["abort_reply"] = reply
    rec["t_ack"] = round(t_ack - t0, 3)
    procs_at_ack = sj_processes(job_id)
    rec["procs_at_ack"] = procs_at_ack
    # observe after the acknowledgement
    seen = []
    max_sj, max_cj = len(procs_at_ack["sj"]), len(procs_at_ack["cj"])
    new_after_ack = False
    end = time.time() + observe_s
    while time.time() < end:
        st = status(poll_sess, job_id)
        if not seen or seen[-1][1] != st:
            seen.append((round(time.time() - t0, 2), st))
        p = sj_processes(job_id)
        if set(p["sj"]) - set(procs_at_ack["sj"]) or set(p["cj"]) - set(procs_at_ack["cj"]):
            new_after_ack = True
        max_sj, max_cj = max(max_sj, len(p["sj"])), max(max_cj, len(p["cj"]))
        if st and st.startswith("FINISHED") and st != "FINISHED:ABORTED" and not p["sj"] and not p["cj"]:
            break
        time.sleep(0.1)
    rec["status_trace"] = seen
    rec["final_status"] = status(poll_sess, job_id)
    rec["sj_cj_started_after_ack"] = new_after_ack
    rec["max_sj_procs"] = max_sj
    rec["max_cj_procs"] = max_cj
    rec["server_log"] = [l for l in grep_file(server_log(), job_id)
                         if "won't be" in l or "started to run" in l or "Aborted" in l or "abort" in l.lower()
                         or "Finished running" in l or "status changed" in l][:12]
    acked_before_running = isinstance(reply, str) and "before running it" in reply
    left_aborted = any(s not in ("FINISHED:ABORTED", "SUBMITTED") for _, s in seen if not s.startswith("<"))
    ran = new_after_ack or max_sj > 0 or max_cj > 0
    rec["BUG"] = bool(acked_before_running and (left_aborted or ran))
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--when", choices=["deploy", "dispatched"], default="deploy")
    ap.add_argument("--attempts", type=int, default=5)
    ap.add_argument("--pad-mb", type=int, default=0)
    ap.add_argument("--sleep-time", type=float, default=2.0)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--observe", type=float, default=40.0)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    poll_sess, abort_sess = session(), session()
    results = []
    for i in range(a.attempts):
        rec = attempt(poll_sess, abort_sess, i, a.when, a.pad_mb, a.sleep_time, a.rounds, a.observe)
        results.append(rec)
        print(json.dumps(rec, indent=1), flush=True)
        time.sleep(2)
    n_bug = sum(r["BUG"] for r in results)
    print(f"SUMMARY when={a.when} attempts={len(results)} bug_triggered={n_bug}")
    if a.out:
        with open(a.out, "w") as f:
            json.dump(results, f, indent=1)
    poll_sess.close()
    abort_sess.close()
    return 0 if n_bug else 1


if __name__ == "__main__":
    sys.exit(main())

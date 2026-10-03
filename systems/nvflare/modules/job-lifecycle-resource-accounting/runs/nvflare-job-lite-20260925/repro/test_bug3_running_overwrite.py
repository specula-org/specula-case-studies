"""Reproduction for candidate MC-4a: the JobRunner's unconditional set_status(RUNNING) (job_runner.py:711) can
overwrite a terminal status already published by the completion loop for a job whose SJ ended quickly.

Level 0: normal source; Level 3: the server runs from repro/l3_src (repro/l3_src.patch adds an env-controlled
sleep between job_runner.py:710 and 711, SPECULA_DELAY_BEFORE_RUNNING; logic unchanged).

Job kinds (supported job content, no product change):
  --kind sjfail     : server config names a class outside the site's class allow-list -> the SJ exits with a
                      config/unsafe-component failure right after launch.
  --kind zerorounds : ScatterAndGather with num_rounds=0 -> the SJ finishes normally almost immediately.

Bug criterion: the job reaches a terminal status (published by the completion loop) and afterwards the store
status becomes RUNNING again and stays RUNNING while no SJ/CJ process exists; abort_job then reports that the
job is not running and delete_job refuses to delete it.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, grep_file, server_log, session, sj_processes, status  # noqa
from probe_job import make_probe_job  # noqa


def make_job(kind, idx):
    name = f"overwrite-{kind}-{idx}"
    d = make_probe_job(os.path.join(R, "jobs", name), name=name, num_rounds=0 if kind == "zerorounds" else 2,
                       sleep_time=1.0)
    if kind == "sjfail":
        p = os.path.join(d, "app", "config", "config_fed_server.json")
        cfg = json.load(open(p))
        cfg["components"].append({"id": "bogus", "path": "nvflare.app_common.np.np_model_persistor.NoSuchClass",
                                  "args": {}})
        json.dump(cfg, open(p, "w"), indent=2)
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", choices=["sjfail", "zerorounds"], default="sjfail")
    ap.add_argument("--attempts", type=int, default=1)
    ap.add_argument("--observe", type=float, default=40.0)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    sess = session()
    results = []
    for i in range(a.attempts):
        t0 = time.time()
        job_id = sess.submit_job(make_job(a.kind, i))
        trace, max_procs = [], 0
        while time.time() - t0 < a.observe:
            st = status(sess, job_id)
            if not trace or trace[-1][1] != st:
                trace.append((round(time.time() - t0, 2), st))
            p = sj_processes(job_id)
            max_procs = max(max_procs, len(p["sj"]) + len(p["cj"]))
            time.sleep(0.1)
        procs_end = sj_processes(job_id)
        rec = {"job_id": job_id, "kind": a.kind, "status_trace": trace, "final_status": status(sess, job_id),
               "procs_at_end": procs_end, "max_procs_seen": max_procs,
               "server_delay_env": os.environ.get("SPECULA_DELAY_BEFORE_RUNNING")}
        try:
            rec["abort_reply"] = sess.abort_job(job_id)
        except Exception as e:
            rec["abort_reply"] = f"<abort error {type(e).__name__}: {e}>"
        try:
            rec["delete_reply"] = sess.delete_job(job_id)
        except Exception as e:
            rec["delete_reply"] = f"<delete error {type(e).__name__}: {e}>"
        rec["status_after_abort_delete"] = status(sess, job_id)
        rec["server_log"] = [l[:220] for l in grep_file(server_log(), job_id)
                             if "RUNNING" in l or "Finished" in l or "status" in l.lower() or "fail" in l.lower()][:12]
        terminal_then_running = False
        seen_terminal = False
        for _, st in trace:
            if st and st.startswith("FINISHED"):
                seen_terminal = True
            elif seen_terminal and st == "RUNNING":
                terminal_then_running = True
        rec["BUG"] = bool(terminal_then_running and rec["final_status"] == "RUNNING"
                          and not procs_end["sj"] and not procs_end["cj"])
        results.append(rec)
        print(json.dumps(rec, indent=1), flush=True)
    print(f"SUMMARY kind={a.kind} attempts={len(results)} bug_triggered={sum(r['BUG'] for r in results)}")
    if a.out:
        json.dump(results, open(a.out, "w"), indent=1)
    sess.close()


if __name__ == "__main__":
    main()

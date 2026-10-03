"""MC-2 variant (a): deleting queued jobs that the JobRunner is NOT working on can still end the scheduling
thread, because JobRunner.run -> job_manager.get_jobs_to_schedule (job_runner.py:650, outside the try) lists the
job-store objects and then reads each meta (job_def_manager.py:517-531); a job deleted in between makes
FilesystemStorage.get_meta raise StorageException (filesystem_storage.py:326-327).

Level 0, public API only: one long-running job holds the (virtual) GPU on both sites so that N queued GPU jobs
stay SUBMITTED (they are rejected with NO_RESOURCE and remain in the scan); the admin then deletes the queued
jobs (an allowed operation: status SUBMITTED). Afterwards an eligible job is submitted.

Bug criterion: the server console shows the JobRunner thread exception from _scan/get_meta and the eligible job
submitted after the long-running job finished is never scheduled.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, log_offset, log_since, server_log, session, status  # noqa
from probe_job import make_probe_job  # noqa

GPU = {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 1}
SPEC = {"site-1": dict(GPU), "site-2": dict(GPU)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queued", type=int, default=150)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    sess = session()
    console = os.path.join(os.path.dirname(server_log()), "poc_console.log")
    off = log_offset(console)
    rec = {}
    long_job = sess.submit_job(make_probe_job(os.path.join(R, "jobs", "scan-long"), name="scan-long", num_rounds=8,
                                              sleep_time=8.0, resource_spec=SPEC))
    t0 = time.time()
    while status(sess, long_job) != "RUNNING" and time.time() - t0 < 60:
        time.sleep(0.5)
    rec["long_job"] = long_job
    qdir = make_probe_job(os.path.join(R, "jobs", "scan-queued"), name="scan-queued", num_rounds=1, sleep_time=1.0,
                          resource_spec=SPEC)
    queued = [sess.submit_job(qdir) for _ in range(a.queued)]
    rec["queued_submitted"] = len(queued)
    time.sleep(3)
    crash_at = None
    deleted = 0
    t_del = time.time()
    for q in queued:
        try:
            sess.delete_job(q)
            deleted += 1
        except Exception as e:
            rec.setdefault("delete_errors", []).append(f"{q}: {type(e).__name__}: {e}"[:200])
        if crash_at is None and "_start_job_runner" in log_since(console, off):
            crash_at = deleted
    rec["deleted"] = deleted
    rec["delete_seconds"] = round(time.time() - t_del, 1)
    time.sleep(2)
    text = log_since(console, off)
    rec["runner_thread_exception"] = "_start_job_runner" in text
    rec["crash_after_n_deletes"] = crash_at
    rec["console_excerpt"] = [l for l in text.splitlines() if "Traceback" in l or "Error" in l or "Exception" in l
                              or "job_runner.py" in l or "job_def_manager.py" in l or "filesystem_storage.py" in l][:30]
    # wait for the long job, then submit an eligible job
    t1 = time.time()
    while not (status(sess, long_job) or "").startswith("FINISHED") and time.time() - t1 < 180:
        time.sleep(2)
    rec["long_job_final"] = status(sess, long_job)
    z = sess.submit_job(make_probe_job(os.path.join(R, "jobs", "scan-after"), name="scan-after", num_rounds=1,
                                       sleep_time=1.0))
    tz = time.time()
    while status(sess, z) == "SUBMITTED" and time.time() - tz < 60:
        time.sleep(1)
    rec["eligible_job"] = z
    rec["eligible_job_status_after_60s"] = status(sess, z)
    rec["BUG"] = bool(rec["runner_thread_exception"] and rec["eligible_job_status_after_60s"] == "SUBMITTED")
    print(json.dumps(rec, indent=1))
    if a.out:
        json.dump(rec, open(a.out, "w"), indent=1)
    sess.close()
    return 0 if rec["BUG"] else 1


if __name__ == "__main__":
    sys.exit(main())

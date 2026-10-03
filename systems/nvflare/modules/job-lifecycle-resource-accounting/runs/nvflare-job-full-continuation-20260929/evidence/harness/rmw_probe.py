#!/usr/bin/env python3
"""Probe F16: FilesystemStorage.update_meta is get_meta -> merge -> _write with no lock (filesystem_storage.py:251-275).
Real code: DefaultJobScheduler.schedule_job NO_RESOURCE path -> SimpleJobDefManager.refresh_meta -> update_meta, the
real JobCommandModule.abort_job handler, FilesystemStorage. Reproduction control (timing only): the module-level
filesystem_storage._write is wrapped so that the scheduler thread's first meta write pauses until the admin abort has
completed; the write itself is then performed unchanged. This models the admin thread being scheduled between the
scheduler thread's read and write inside update_meta."""
import os, sys, threading, time, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lifecycle_harness as H
from nvflare.apis.client import Client
from nvflare.apis.job_def import JobMetaKey
import nvflare.app_common.storages.filesystem_storage as fs

root = __import__("tempfile").mkdtemp(prefix="nvf-rmw-")
eng = H.FakeEngine(root, [Client("site-1", "tok-site-1"), Client("site-2", "tok-site-2")])
j = H.submit(eng, "queued-job")
eng.check_client_resources = lambda job, reqs, ctx: {s: (False, "") for s in reqs}   # site says: not enough -> NO_RESOURCE
abort_done = threading.Event(); paused = {"n": 0}
real_write = fs._write
def controlled_write(path, content):
    if threading.current_thread().name == "scheduler" and path.endswith("meta") and paused["n"] == 0:
        paused["n"] += 1
        H.log("reproduction control: scheduler thread read meta, pausing before its write")
        abort_done.wait(5.0)
    return real_write(path, content)
fs._write = controlled_write

def scheduler_pass():
    with eng.new_context() as ctx:
        jobs = eng.job_manager.get_jobs_to_schedule(ctx)
        eng.scheduler.schedule_job(job_manager=eng.job_manager, job_candidates=jobs, fl_ctx=ctx)
t = threading.Thread(target=scheduler_pass, name="scheduler"); t.start()
while paused["n"] == 0 and t.is_alive(): time.sleep(0.01)
reply = H.admin_abort(eng, j)
H.log(f"status right after admin abort: {H.store_status(eng, j)}")
abort_done.set(); t.join()
final = H.store_status(eng, j)
with eng.new_context() as ctx:
    again = [x.job_id for x in eng.job_manager.get_jobs_to_schedule(ctx)]
out = {"admin_reply": reply, "final_status": final, "aborted_job_still_schedulable": j in again}
print(json.dumps(out, indent=2)); open("logs/rmw_probe.json", "w").write(json.dumps(out, indent=2))
os._exit(0)

"""Sanity: a probe job runs to FINISHED:COMPLETED on the POC (baseline for the reproduction tests)."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, session, status, wait_status  # noqa
from probe_job import make_probe_job  # noqa

sess = session()
job_dir = make_probe_job(os.path.join(R, "jobs", "sanity"), name="sanity", num_rounds=2, sleep_time=1.0)
t0 = time.time()
job_id = sess.submit_job(job_dir)
print("submitted", job_id)
seen = []
while time.time() - t0 < 180:
    st = status(sess, job_id)
    if not seen or seen[-1] != st:
        seen.append(st)
        print(f"{time.time()-t0:6.2f}s status={st}", flush=True)
    if st and st.startswith("FINISHED"):
        break
    time.sleep(0.2)
print("final", status(sess, job_id))
sess.close()

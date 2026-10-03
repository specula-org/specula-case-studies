"""Reproduction for T-1 / Scenario S3 (Q4): after an ordinary deployment failure, the JobRunner never cancels the
client resource reservations made for the failed job; they are held until the resource manager's expiry
(provisioned default expiration_period=300 s) and a later eligible job is rejected as "not enough resources".

Level 0: real POC, public admin API only. Site configuration uses supported options only:
  - site-1/site-2 local/resources.json: GPUResourceManager(num_of_gpus=1, mem_per_gpu_in_GiB=1,
    expiration_period=300, ignore_host=True)  (default manager type; one externally-managed GPU unit)
  - site-2 local/privacy.json: offers only the "public" privacy scope.
Job X requests 1 GPU per site with privacy scope "research" -> site-2 rejects the deployment
(app_deployer.py:40-42), min_clients=2 -> FINISHED:FAILED_TO_RUN (job_runner.py:269-282, 713-731).
Job Y requests the same resources with the default scope and is otherwise eligible.

Observed: report_resources shows the reservations of job X still held after X failed; Y is repeatedly
rejected ("not enough sites have enough resources") and consumes scheduling attempts until the reservations
expire.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, session, status  # noqa
from probe_job import make_probe_job  # noqa

GPU = {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 1}
SPEC = {"site-1": dict(GPU), "site-2": dict(GPU)}


def job(name, scope=None):
    d = make_probe_job(os.path.join(R, "jobs", name), name=name, num_rounds=1, sleep_time=1.0, resource_spec=SPEC)
    if scope:
        p = os.path.join(d, "meta.json")
        m = json.load(open(p))
        m["scope"] = scope
        json.dump(m, open(p, "w"), indent=2)
    return d


def resources(sess):
    try:
        return sess.report_resources("client", ["site-1", "site-2"])
    except Exception as e:
        return {"error": str(e)}


def wait_terminal(sess, job_id, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = status(sess, job_id)
        if st and st.startswith("FINISHED"):
            return st, round(time.time() - t0, 1)
        time.sleep(1)
    return status(sess, job_id), round(time.time() - t0, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--observe", type=float, default=840.0)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    sess = session()
    rec = {"resources_initial": resources(sess)}

    # Control: an eligible job is scheduled promptly and its allocation is released at CJ exit.
    y0 = sess.submit_job(job("leftover-control"))
    st, dt = wait_terminal(sess, y0, 120)
    rec["control"] = {"job_id": y0, "final": st, "seconds": dt,
                      "schedule_count": sess.get_job_meta(y0).get("schedule_count")}
    time.sleep(3)
    rec["resources_after_control"] = resources(sess)

    # Ordinary failure: deployment rejected by site-2's privacy policy.
    tx = time.time()
    x = sess.submit_job(job("leftover-x", scope="research"))
    st, dt = wait_terminal(sess, x, 120)
    mx = sess.get_job_meta(x)
    rec["failed_job"] = {"job_id": x, "final": st, "seconds": dt, "deploy_detail": mx.get("job_deploy_detail")}
    rec["resources_after_failure"] = resources(sess)

    # A later eligible job.
    ty = time.time()
    y = sess.submit_job(job("leftover-y"))
    samples = []
    running_at = None
    while time.time() - ty < a.observe:
        st = status(sess, y)
        if st != "SUBMITTED":
            running_at = round(time.time() - ty, 1)
            break
        if not samples or time.time() - samples[-1]["t"] - ty > 30:
            m = sess.get_job_meta(y)
            samples.append({"t": round(time.time() - ty, 1), "status": st,
                            "schedule_count": m.get("schedule_count"),
                            "last_history": (m.get("schedule_history") or [None])[-1],
                            "resources": resources(sess)})
        time.sleep(2)
    my = sess.get_job_meta(y)
    rec["later_job"] = {"job_id": y, "left_SUBMITTED_after_s": running_at,
                        "seconds_since_failed_job_submit": round(time.time() - tx, 1),
                        "schedule_count": my.get("schedule_count"),
                        "schedule_history": my.get("schedule_history"), "samples": samples}
    st, dt = wait_terminal(sess, y, 120)
    rec["later_job"]["final"] = st
    rec["BUG"] = bool(rec["control"]["final"] == "FINISHED:COMPLETED"
                      and (running_at is None or running_at > 60)
                      and "reserved_resources': {}" not in str(rec["resources_after_failure"].get("site-1", "")))
    print(json.dumps(rec, indent=1))
    if a.out:
        json.dump(rec, open(a.out, "w"), indent=1)
    sess.close()
    return 0 if rec["BUG"] else 1


if __name__ == "__main__":
    sys.exit(main())

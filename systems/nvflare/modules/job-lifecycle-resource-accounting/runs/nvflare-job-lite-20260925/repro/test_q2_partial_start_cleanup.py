"""Q2 negative-evidence check (Scenario S3/S5): START_JOB succeeds on site-1 but fails on site-2 (its configured
GPUResourceConsumer raises on this GPU-less host). Expected by the model: job FAILED_TO_RUN, site-1's CJ is
aborted and both sites' allocations are released (no leak, no zombie CJ). Level 0, supported configuration."""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, session, status, sj_processes, grep_file, server_log  # noqa
from probe_job import make_probe_job  # noqa

SPEC = {"site-1": {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 1}, "site-2": {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 1}}
s = session()
res = lambda: s.report_resources("client", ["site-1", "site-2"])
rec = {"resources_before": res()}
j = s.submit_job(make_probe_job(os.path.join(R, "jobs", "partial-start"), name="partial-start", num_rounds=3,
                                sleep_time=5.0, resource_spec=SPEC))
t0 = time.time(); trace = []; procs = []
while time.time() - t0 < 40:
    st = status(s, j)
    if not trace or trace[-1][1] != st:
        trace.append((round(time.time() - t0, 2), st))
    p = sj_processes(j)
    procs.append((round(time.time() - t0, 1), len(p["sj"]), len(p["cj"])))
    time.sleep(0.5)
rec.update(job_id=j, status_trace=trace, final=status(s, j), deploy_detail=s.get_job_meta(j).get("job_deploy_detail"),
           max_cj=max(c for _, _, c in procs), procs_end=sj_processes(j), resources_after=res(),
           server_log=[l[:300] for l in grep_file(server_log(), j) if "ERROR" in l or "Failed" in l][:4])
rec["LEAK_OR_ZOMBIE"] = ("reserved_resources': {}" not in str(rec["resources_after"]) or "'memory': 0" in str(rec["resources_after"])
                         or bool(rec["procs_end"]["cj"]) or bool(rec["procs_end"]["sj"]))
print(json.dumps(rec, indent=1))
json.dump(rec, open(os.path.join(R, "logs", "q2_partial_start_L0_run1.json"), "w"), indent=1)
s.close()

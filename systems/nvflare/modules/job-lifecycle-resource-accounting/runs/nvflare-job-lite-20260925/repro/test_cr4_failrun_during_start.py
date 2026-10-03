"""CR-4: fail_run (job_runner.py:813-852) pops _pending_client_outcomes[job]; if a client's terminal failure report
arrives while _start_run is still collecting START replies, the later
`self._pending_client_outcomes[job_id].intersection_update(...)` (job_runner.py:359-360) raises KeyError and the job
goes through the runner's generic except path. Job: client config names a class outside the site allow-list, so
each CJ fails at startup and reports its failure. Level 0 = unmodified; Level 3 = repro/l3_src with
SPECULA_DELAY_AFTER_START_CLIENTS (timing only). Records final status, processes and server log lines."""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, session, status, sj_processes, grep_file, server_log  # noqa
from probe_job import make_probe_job  # noqa
tag = sys.argv[1] if len(sys.argv) > 1 else "L0"
d = make_probe_job(os.path.join(R, "jobs", f"cr4-{tag}"), name=f"cr4-{tag}", num_rounds=2, sleep_time=2.0)
p = os.path.join(d, "app", "config", "config_fed_client.json")
cfg = json.load(open(p))
cfg["components"].append({"id": "bogus", "path": "nvflare.app_common.np.np_trainer.NoSuchClass", "args": {}})
json.dump(cfg, open(p, "w"), indent=2)
s = session()
j = s.submit_job(d)
t0 = time.time(); trace = []
while time.time() - t0 < 60:
    st = status(s, j)
    if not trace or trace[-1][1] != st:
        trace.append((round(time.time() - t0, 2), st))
    if st and st.startswith("FINISHED") and not any(sj_processes(j).values()):
        break
    time.sleep(0.3)
rec = {"job_id": j, "tag": tag, "status_trace": trace, "final": status(s, j), "procs_end": sj_processes(j),
       "delay_env": os.environ.get("SPECULA_DELAY_AFTER_START_CLIENTS"),
       "server_log": [l[:260] for l in grep_file(server_log(), j)
                      if "Fail" in l or "KeyError" in l or "fail" in l or "Finished" in l or "status" in l.lower()][:10]}
print(json.dumps(rec, indent=1))
json.dump(rec, open(os.path.join(R, "logs", f"cr4_failrun_during_start_{tag}.json"), "w"), indent=1)
s.close()

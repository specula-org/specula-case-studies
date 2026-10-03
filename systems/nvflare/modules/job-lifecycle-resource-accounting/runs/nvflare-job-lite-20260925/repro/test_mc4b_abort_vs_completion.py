"""Candidate MC-4b: stop_run (job_runner.py:798-800) signals the SJ/CJs first (_stop_run) and sets run_aborted only
afterwards (mark_run_aborted). If the aborted SJ exits and the completion loop classifies the job in between, an
admin-aborted run is published with a non-ABORTED status.
Level 0: unmodified source. Level 3: repro/l3_src with SPECULA_DELAY_BEFORE_MARK_ABORTED (timing only).
Observation: abort a RUNNING job via the admin API, record the reply, the final status and the processes."""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flare_util import R, session, status, sj_processes, grep_file, server_log  # noqa
from probe_job import make_probe_job  # noqa
tag = sys.argv[1] if len(sys.argv) > 1 else "L0"
s = session()
j = s.submit_job(make_probe_job(os.path.join(R, "jobs", f"abortrun-{tag}"), name=f"abortrun-{tag}", num_rounds=6,
                                sleep_time=5.0))
t0 = time.time()
while status(s, j) != "RUNNING" and time.time() - t0 < 60:
    time.sleep(0.2)
time.sleep(6)   # let the run make progress
p_before = sj_processes(j)
ta = time.time()
try:
    reply = s.abort_job(j)
except Exception as e:
    reply = f"<abort error {type(e).__name__}: {e}>"
t_reply = round(time.time() - ta, 2)
trace = []
while time.time() - ta < 60:
    st = status(s, j)
    if not trace or trace[-1][1] != st:
        trace.append((round(time.time() - ta, 2), st))
    if st and st.startswith("FINISHED") and not any(sj_processes(j).values()):
        break
    time.sleep(0.3)
rec = {"job_id": j, "tag": tag, "procs_before_abort": p_before, "abort_reply": reply, "abort_reply_after_s": t_reply,
       "status_trace_after_abort": trace, "final": status(s, j), "procs_end": sj_processes(j),
       "delay_env": os.environ.get("SPECULA_DELAY_BEFORE_MARK_ABORTED"),
       "server_log": [l[:230] for l in grep_file(server_log(), j) if "abort" in l.lower() or "Finished" in l
                      or "status" in l.lower()][:10]}
rec["MISCLASSIFIED"] = bool(p_before["sj"] and rec["final"] != "FINISHED:ABORTED")
print(json.dumps(rec, indent=1))
json.dump(rec, open(os.path.join(R, "logs", f"mc4b_abort_vs_completion_{tag}.json"), "w"), indent=1)
s.close()

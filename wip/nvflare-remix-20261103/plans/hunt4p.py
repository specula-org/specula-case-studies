# Parallel share of hunt4's BFS tail (job/task families), renamed *_p so they never
# collide with the main driver's files; the main driver is stopped before it
# reaches the originals.
import runpy, pathlib
H = runpy.run_path(str(pathlib.Path(__file__).with_name("hunt4.py")))
take = ["h4B_job_s1l2a1_k1", "h4B_job_s1l1a2_k1", "h4R_job_s1l1a1_k2",
        "h4B_task_s1l2a1_k1", "h4B_task_s1l1a2_k1", "h4R_task_s1l1a1_k2"]
PLAN = []
for p in H["PLAN"]:
    if p["name"] in take:
        q = dict(p); q["name"] = p["name"] + "_p"; PLAN.append(q)

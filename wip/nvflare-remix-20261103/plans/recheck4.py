import runpy, pathlib
P = runpy.run_path(str(pathlib.Path(__file__).with_name("hunt4.py")))["PLAN"]
want = {"h4S_restart_fam_s1l2a2_t20", "h4S_restart_fam_s1l2a2_t200", "h4S_net_allF_s2l2a2_t20", "h4S_job_fam_s2l1a2_t20", "h4S_restart_allF_s2l1a2_t200", "h4S_restart_fam_s2l1a2_t200", "h4S_job_allF_s2l2a2_t20", "h4S_task_fam_s2l2a2_t20"}
PLAN = []
for p in P:
    if p["name"] in want:
        q = dict(p); q["name"] = "rc4_" + p["name"]; q["timeout"] = 120; q["workers"] = 4
        PLAN.append(q)

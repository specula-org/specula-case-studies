import runpy
P = runpy.run_path(__file__.replace("smoke4.py", "hunt4.py"))["PLAN"]
pick = {}
for p in P:
    pick.setdefault(p["track"], p)
PLAN0 = None
PLAN = []
for t, p in pick.items():
    q = dict(p); q["name"] = "sm4_" + p["name"]; q["timeout"] = 45; q["workers"] = 2; q["heap"] = "6g"
    PLAN.append(q)

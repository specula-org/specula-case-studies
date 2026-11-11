import runpy
_c = runpy.run_path(__file__.replace("pilot.py", "calib.py"))
DEPS = _c["DEPS"]; FILTERS = {}
CONFIGS = {"fedavg": dict(_c["CONFIGS"]["fedavg"], points=["cjCrash", "storeError", "spCrash", "cpCrash", "abort", "deleteJob"]),
           "k8s": dict(_c["CONFIGS"]["k8s"], points=["cpCrash"]),
           "multijobcp": dict(_c["CONFIGS"]["multijobcp"], points=["cjCrash"]),
           "fedavg2": dict(_c["CONFIGS"]["fedavg2"], points=["deadClient", "regIterRace"])}

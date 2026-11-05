import runpy, pathlib
H = runpy.run_path(str(pathlib.Path(__file__).with_name("hunt4.py")))
PLAN = [H["sim"]("sm_send_net_allF", "net", H["grain"]("net", True), 2, 1, 2, 20, timeout=90, workers=4, track="T"),
        H["sim"]("sm_send_all_allF", "all", H["grain"]("all", True), 2, 1, 2, 0, timeout=90, workers=4, track="T", throttle=False)]

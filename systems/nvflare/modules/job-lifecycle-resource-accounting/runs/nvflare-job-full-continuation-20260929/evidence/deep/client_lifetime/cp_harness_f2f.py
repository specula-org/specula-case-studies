#!/usr/bin/env python3
"""F2f: a START_JOB that fails after consume() (launch failure) leaves CUDA_VISIBLE_DEVICES pointing at the units it
just freed; the next job with an empty allocation inherits that binding (Q4: failed operation's remaining state
affects a later job). Default config classes (GPUResourceManager + GPUResourceConsumer), GPU edge stubbed."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cp_harness as H  # noqa: E402

from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.app_common.resource_consumers.gpu_resource_consumer import GPUResourceConsumer  # noqa: E402
from nvflare.app_common.resource_managers.gpu_resource_manager import GPUResourceManager  # noqa: E402
from nvflare.utils.job_launcher_utils import get_resource_manager_spec  # noqa: E402

out = sys.argv[1]
r = {}
H._patch_gpu_edge()
os.environ.pop("CUDA_VISIBLE_DEVICES", None)
ws = tempfile.mkdtemp(prefix="nvf-cl-f2f-")
rm = GPUResourceManager(num_of_gpus=2, mem_per_gpu_in_GiB=16, expiration_period=300, ignore_host=True)
launcher = H.StubCmdLauncher(ws, child_secs=5.0)
ce = H.make_engine(ws, rm, GPUResourceConsumer(), extra_components=[launcher])
ce.fire_event(EventType.SYSTEM_START, ce.new_context())
r["cp_env_initial"] = os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>")

# job A: GPU job whose launch fails (e.g. spawn error) -> allocation freed by StartJobProcessor
meta_a = {"job_id": "job-A", "resource_spec": {"site-1": {"num_of_gpus": 2, "mem_per_gpu_in_GiB": 16}}}
spec_a = get_resource_manager_spec(meta_a, "site-1")
H.deploy(ws, meta_a)
ok, tok = H.check(ce, "job-A", spec_a)
orig_get_command = launcher.get_command
launcher.get_command = lambda job_meta, fl_ctx: "/nonexistent/cj --x"
r["job_A_start_reply"] = H.start(ce, meta_a, spec_a, tok)
launcher.get_command = orig_get_command
r["after_A_failed"] = {"rm": H.rm_state(rm), "cp_env": os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>")}

# job C: GPU job that now owns GPU 0 (legitimately)
meta_c = {"job_id": "job-C", "resource_spec": {"site-1": {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 16}}}
spec_c = get_resource_manager_spec(meta_c, "site-1")
H.deploy(ws, meta_c)
ok, tok = H.check(ce, "job-C", spec_c)
r["job_C_start_reply"] = H.start(ce, meta_c, spec_c, tok)
cc = H.read_child(ws, "job-C")
# job B: no GPU requirement -> {} -> consume skipped
meta_b = {"job_id": "job-B", "resource_spec": {}}
spec_b = get_resource_manager_spec(meta_b, "site-1")
H.deploy(ws, meta_b)
ok, tok = H.check(ce, "job-B", spec_b)
r["job_B_rm_spec"] = spec_b
r["job_B_start_reply"] = H.start(ce, meta_b, spec_b, tok)
cb = H.read_child(ws, "job-B")
r["child_env"] = {"job-C": cc and cc["CUDA_VISIBLE_DEVICES"], "job-B": cb and cb["CUDA_VISIBLE_DEVICES"]}
r["rm_while_C_and_B_run"] = H.rm_state(rm)
for jid in ("job-C", "job-B"):
    ce.abort_app(jid, heartbeat_cleanup=True)
H.wait_until(lambda: not H.registered(ce), timeout=20)
r["rm_after_cleanup"] = H.rm_state(rm)
ce.fire_event(EventType.SYSTEM_END, ce.new_context())
with open(out, "w") as f:
    json.dump(r, f, indent=2, default=str)
print(json.dumps(r, indent=2, default=str))
sys.stdout.flush()
os._exit(0)

#!/usr/bin/env python3
"""Probe L9 (validator-accepted min_clients string/null starves later jobs) and L1 (GPU float memory drift).
Real code: JobMetaValidator._validate_min_clients, DefaultJobScheduler.schedule_job via lifecycle_harness FakeEngine
(real JobRunner/SimpleJobDefManager/FilesystemStorage), GPUResourceManager(ignore_host=True)."""
import os, sys, time, json, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lifecycle_harness as H
from nvflare.apis.client import Client
from nvflare.apis.job_def import JobMetaKey
from nvflare.private.fed.server.job_meta_validator import JobMetaValidator
from nvflare.app_common.resource_managers.gpu_resource_manager import GPUResourceManager

out = {}
# ---- L9 ----
for bad in ("2", None):
    v = JobMetaValidator()
    try:
        v._validate_min_clients("bad-job", {JobMetaKey.MIN_CLIENTS.value: bad}, {"site-1", "site-2"})
        out[f"L9_validator_accepts_min_clients={bad!r}"] = True
    except Exception as e:
        out[f"L9_validator_accepts_min_clients={bad!r}"] = f"rejected: {e}"
    root = tempfile.mkdtemp(prefix="nvf-L9-")
    eng = H.FakeEngine(root, [Client("site-1", "tok-site-1"), Client("site-2", "tok-site-2")])
    H.stub_deploy(eng)
    hist = H.install_observers(eng)
    meta = {JobMetaKey.JOB_NAME.value: "bad", JobMetaKey.DEPLOY_MAP.value: {"app": ["server", "site-1", "site-2"]},
            JobMetaKey.MIN_CLIENTS.value: bad, JobMetaKey.RESOURCE_SPEC.value: {}}
    with eng.new_context() as ctx:
        jbad = eng.job_manager.create(meta, b"x", ctx)[JobMetaKey.JOB_ID.value]
    time.sleep(0.05)
    jgood = H.submit(eng, "good-later-job")
    t, res = H.start_runner(eng)
    time.sleep(6.0)
    eng.job_runner.ask_to_stop = True
    with eng.new_context() as ctx:
        badjob = eng.job_manager.get_job(jbad, ctx)
    out[f"L9[{bad!r}]_bad_status"] = H.store_status(eng, jbad)
    out[f"L9[{bad!r}]_bad_schedule_count"] = badjob.meta.get(JobMetaKey.SCHEDULE_COUNT.value, 0)
    out[f"L9[{bad!r}]_later_valid_job_status_after_6s"] = H.store_status(eng, jgood)
    out[f"L9[{bad!r}]_later_valid_job_ever_started"] = jgood in eng.sj_started
    out[f"L9[{bad!r}]_runner_alive"] = t.is_alive()
# ---- L1 ----
rm = GPUResourceManager(num_of_gpus=1, mem_per_gpu_in_GiB=1, expiration_period=30, ignore_host=True)
toks = []
for m in (0.1, 0.2):
    ok, tok = rm.check_resources({"num_of_gpus": 1, "mem_per_gpu_in_GiB": m}, None)
    toks.append((m, tok, rm.allocate_resources({"num_of_gpus": 1, "mem_per_gpu_in_GiB": m}, tok, None)))
for m, tok, alloc in reversed(toks):
    rm.free_resources(alloc, tok, None)
out["L1_gpu0_memory_after_all_freed"] = rm.resources[0].memory
ok, _ = rm.check_resources({"num_of_gpus": 1, "mem_per_gpu_in_GiB": 1}, None)
out["L1_full_gpu_job_admitted_after_all_freed"] = ok
print(json.dumps(out, indent=2, default=str))
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "l9_l1_probe.json"), "w").write(json.dumps(out, indent=2, default=str))
os._exit(0)

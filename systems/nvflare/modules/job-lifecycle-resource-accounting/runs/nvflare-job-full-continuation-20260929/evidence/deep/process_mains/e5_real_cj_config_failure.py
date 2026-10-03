# E5: run the REAL CJ main (python -m nvflare.private.fed.app.client.worker_process) through the
# REAL default launcher primitive (spawn_process -> ProcessHandle) against a POC-provisioned site-1
# kit, with a job whose client config fails before the CJ checks in (STARTING):
#   variant "unsafe": executor class not in the site class_allow_list (enforce mode)  -> ComponentNotAuthorized
#   variant "config": allow-listed class with an invalid constructor argument          -> ConfigError
# Then feed the real handle into the real JobExecutor._wait_child_process_finish (CP status STARTING)
# and the reported code into the real FederatedServer.process_job_failure + JobRunner classification.
# No product code is modified; the CP cell and the server are replaced by mocks/fakes.
import json
import os
import shutil
import sys
import uuid
from unittest.mock import MagicMock

from nvflare.apis.fl_constant import FLMetaKey, RunProcessKey
from nvflare.app_common.job_launcher.process_launcher import ProcessHandle
from nvflare.fuel.f3.cellnet.defs import ReturnCode
from nvflare.private.defs import JobFailureMsgKey
from nvflare.private.fed.client.client_executor import _ABORT_REQUESTED_KEY, JobExecutor
from nvflare.private.fed.client.client_status import ClientStatus
from nvflare.utils.process_utils import spawn_process

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from e1_exit_code_chain import server_side_status  # noqa: E402

SITE_WS = os.path.join(HERE, "poc_ws", "example_project", "prod_00", "site-1")

CONFIGS = {
    "unsafe": {
        "format_version": 2,
        "executors": [{"tasks": ["train"], "executor": {"path": "my_custom_pkg.UnlistedExecutor", "args": {}}}],
        "task_result_filters": [],
        "task_data_filters": [],
        "components": [],
    },
    "config": {
        "format_version": 2,
        "executors": [
            {
                "tasks": ["train"],
                "executor": {"path": "nvflare.app_common.np.np_trainer.NPTrainer", "args": {"no_such_arg": 1}},
            }
        ],
        "task_result_filters": [],
        "task_data_filters": [],
        "components": [],
    },
}


def make_job(variant):
    job_id = str(uuid.uuid4())
    run_dir = os.path.join(SITE_WS, job_id)
    cfg_dir = os.path.join(run_dir, "app_site-1", "config")
    os.makedirs(cfg_dir)
    with open(os.path.join(cfg_dir, "config_fed_client.json"), "w") as f:
        json.dump(CONFIGS[variant], f)
    with open(os.path.join(run_dir, "meta.json"), "w") as f:
        json.dump({"job_id": job_id, "name": f"e5-{variant}", "resource_spec": {}}, f)
    return job_id, run_dir


def launch_cj(job_id):
    argv = [
        sys.executable,
        "-m",
        "nvflare.private.fed.app.client.worker_process",
        "-m",
        SITE_WS,
        "-w",
        os.path.join(SITE_WS, "startup"),
        "-n",
        job_id,
        "-c",
        "site-1",
        "-p",
        "tcp://127.0.0.1:9",
        "-g",
        "localhost:8002",
        "-scheme",
        "http",
        "-s",
        "fed_client.json",
        "-t",
        "tok",
        "-ts",
        "sig",
        "-d",
        "ssid",
        "--set",
        "secure_train=true",
        "uid=site-1",
        "org=nvidia",
        "config_folder=config",
        "print_conf=True",
    ]
    env = os.environ.copy()
    adapter = spawn_process(argv, env)  # posix_spawn(setsid=True), exactly like ProcessJobLauncher.launch_job
    return ProcessHandle(process_adapter=adapter), adapter


def main():
    results = []
    for variant in ("unsafe", "config"):
        job_id, run_dir = make_job(variant)
        try:
            handle, adapter = launch_cj(job_id)
            handle.wait()
            raw = adapter.poll()
            rc_file = os.path.join(run_dir, FLMetaKey.PROCESS_RC_FILE)
            rc_content = open(rc_file).read() if os.path.exists(rc_file) else None
            client = MagicMock()
            client.client_name = "site-1"
            client.send_request_before_shutdown.return_value.get_header.return_value = ReturnCode.OK
            je = JobExecutor(client=client, startup="startup")
            je.run_processes = {
                job_id: {
                    RunProcessKey.JOB_HANDLE: handle,
                    RunProcessKey.STATUS: ClientStatus.STARTING,
                    _ABORT_REQUESTED_KEY: False,
                }
            }
            rm = MagicMock()
            je._wait_child_process_finish(client, job_id, {"gpu": [0]}, "tok", rm, SITE_WS, MagicMock())
            payload = client.send_request_before_shutdown.call_args.kwargs["request"].payload
            reported = payload[JobFailureMsgKey.CODE]
            status = server_side_status(reported)
            log_file = os.path.join(run_dir, "log.txt")
            evidence = ""
            if os.path.exists(log_file):
                with open(log_file) as f:
                    lines = [x.strip() for x in f if "not authorized" in x or "ConfigError" in x or "MPM" in x]
                evidence = " | ".join(lines[-3:])[:600]
            results.append((variant, raw, rc_content, reported, payload[JobFailureMsgKey.REASON], status, evidence))
        finally:
            shutil.rmtree(run_dir, ignore_errors=True)
    print("variant raw_exit rc_file reported reason -> server_terminal_status")
    for r in results:
        print(f"{r[0]:7} {r[1]!s:8} {r[2]!s:7} {r[3]!s:8} {r[4]!s:22} -> {r[5]}")
        print(f"   CJ log evidence: {r[6]}")


if __name__ == "__main__":
    main()

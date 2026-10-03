#!/usr/bin/env python3
"""CR-4 reproduction: validator-accepted malformed job metadata stalls scheduling.

This is a focused executable test.  It uses a real public job ZIP, the real
JobMetaValidator, SimpleJobDefManager, FilesystemStorage, job_from_meta, and
DefaultJobScheduler.  The server engine below only supplies the normal scheduler
environment: connected clients and resource-check/cancel replies.
"""

import io
import json
import logging
import os
import sys
import tempfile
import time
import traceback
import zipfile
from collections import Counter

SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-4/worktree"
)

sys.path.insert(0, SOURCE)

import nvflare  # noqa: E402
from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContext, FLContextManager  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.private.fed.server.job_meta_validator import JobMetaValidator  # noqa: E402
from nvflare.widgets.widget import Widget  # noqa: E402


assert os.path.realpath(nvflare.__file__).startswith(SOURCE), nvflare.__file__


class ReproEngine(ServerEngineSpec):
    def __init__(self, storage, site_names):
        self.storage = storage
        self.job_def_manager = None
        self.components = {
            "job_store": storage,
            SystemComponents.JOB_STORE if hasattr(SystemComponents, "JOB_STORE") else "job_store": storage,
        }
        self.clients = [Client(name=name, token=f"token-{name}") for name in site_names]
        self.fl_ctx_mgr = FLContextManager(
            engine=self,
            identity_name="server",
            job_id="cr4-repro",
            public_stickers={},
            private_stickers={},
        )
        self.check_calls = []
        self.cancel_calls = []
        self.reservations = []
        self._seq = 0

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        return None

    def validate_targets(self, target_names: list[str]) -> tuple[list, list[str]]:
        known = {client.name: client for client in self.clients}
        valid = [known[name] for name in target_names if name in known]
        invalid = [name for name in target_names if name not in known]
        return valid, invalid

    def get_clients(self) -> list[Client]:
        return list(self.clients)

    def sync_clients_from_main_process(self):
        return None

    def update_job_run_status(self):
        return None

    def new_context(self) -> FLContext:
        return self.fl_ctx_mgr.new_context()

    def get_workspace(self) -> Workspace:
        return None

    def add_component(self, component_id: str, component):
        self.components[component_id] = component

    def get_component(self, component_id: str) -> object:
        return self.components.get(component_id)

    def register_aux_message_handler(self, topic: str, message_handle_func):
        return None

    def send_aux_request(
        self,
        targets: [],
        topic: str,
        request: Shareable,
        timeout: float,
        fl_ctx: FLContext,
        optional=False,
        secure=False,
    ) -> dict:
        return {}

    def multicast_aux_requests(
        self,
        topic: str,
        target_requests: dict[str, Shareable],
        timeout: float,
        fl_ctx: FLContext,
        optional: bool = False,
        secure: bool = False,
    ) -> dict:
        return {}

    def get_widget(self, widget_id: str) -> Widget:
        return None

    def persist_components(self, fl_ctx: FLContext, completed: bool):
        return None

    def restore_components(self, snapshot, fl_ctx: FLContext):
        return None

    def start_client_job(self, job, client_sites, fl_ctx: FLContext):
        return []

    def check_client_resources(
        self, job: Job, resource_reqs: dict[str, dict], fl_ctx: FLContext
    ) -> dict[str, tuple[bool, str | None]]:
        self.check_calls.append({"job_id": job.job_id, "sites": sorted(resource_reqs)})
        result = {}
        for site_name in sorted(resource_reqs):
            self._seq += 1
            token = f"reservation-{self._seq}-{job.job_id}-{site_name}"
            self.reservations.append((job.job_id, site_name, token))
            result[site_name] = (True, token)
        return result

    def cancel_client_resources(
        self, resource_check_results: dict[str, tuple[bool, str]], resource_reqs: dict[str, dict], fl_ctx: FLContext
    ):
        self.cancel_calls.append({"results": resource_check_results, "reqs": resource_reqs})

    def get_client_name_from_token(self, token: str) -> str:
        for client in self.clients:
            if client.token == token:
                return client.name
        return ""


def job_zip(job_name, meta):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for path in (f"{job_name}/", f"{job_name}/app/", f"{job_name}/app/config/"):
            zf.writestr(path, "")
        zf.writestr(f"{job_name}/meta.json", json.dumps(meta))
        zf.writestr(f"{job_name}/app/config/config_fed_server.json", json.dumps({"format_version": 2}))
        zf.writestr(f"{job_name}/app/config/config_fed_client.json", json.dumps({"format_version": 2}))
    return buf.getvalue()


def base_meta(job_name, **overrides):
    meta = {
        "name": job_name,
        "deploy_map": {"app": ["server", "site-1", "site-2"]},
        "min_clients": 1,
        "resource_spec": {},
    }
    meta.update(overrides)
    return meta


def validated_meta_from_zip(job_name, meta):
    data = job_zip(job_name, meta)
    valid, error, validated = JobMetaValidator().validate(job_name, data)
    print(
        f"validator {job_name}: valid={valid} error={error!r} "
        f"min_clients={validated.get('min_clients', '<absent>')!r} "
        f"resource_spec={validated.get('resource_spec', '<absent>')!r}"
    )
    if not valid:
        raise AssertionError(f"validator unexpectedly rejected {job_name}: {error}")
    return validated, data


def create_validated_job(job_manager, engine, job_id, job_name, meta):
    validated, data = validated_meta_from_zip(job_name, meta)
    validated[JobMetaKey.JOB_ID.value] = job_id
    with engine.new_context() as fl_ctx:
        created = job_manager.create(validated, data, fl_ctx)
    time.sleep(0.01)
    return created[JobMetaKey.JOB_ID.value]


def status_and_count(job_manager, engine, job_id):
    with engine.new_context() as fl_ctx:
        job = job_manager.get_job(job_id, fl_ctx)
    if job is None:
        return None, None
    return job.meta.get(JobMetaKey.STATUS.value), job.meta.get(JobMetaKey.SCHEDULE_COUNT.value)


def run_schedule_passes(job_manager, scheduler, engine, passes):
    observations = []
    for pass_idx in range(passes):
        with engine.new_context() as fl_ctx:
            candidates = job_manager.get_jobs_to_schedule(fl_ctx)
        with engine.new_context() as fl_ctx:
            job, dispatch_info = scheduler.schedule_job(job_manager=job_manager, job_candidates=candidates, fl_ctx=fl_ctx)
        observations.append(
            {
                "pass": pass_idx,
                "candidates": [candidate.job_id for candidate in candidates],
                "scheduled": job.job_id if job else None,
                "dispatch_sites": sorted(dispatch_info) if dispatch_info else [],
            }
        )
    return observations


def new_env():
    tmp = tempfile.TemporaryDirectory(prefix="cr4-repro-")
    old_cwd = os.getcwd()
    os.chdir(tmp.name)
    storage = FilesystemStorage(root_dir=os.path.join(tmp.name, "store"), uri_root="/")
    engine = ReproEngine(storage=storage, site_names=["site-1", "site-2"])
    job_manager = SimpleJobDefManager(uri_root="jobs")
    engine.job_def_manager = job_manager
    scheduler = DefaultJobScheduler(max_jobs=1, min_schedule_interval=0.0, max_schedule_interval=0.0)
    return tmp, old_cwd, engine, job_manager, scheduler


def close_env(tmp, old_cwd):
    os.chdir(old_cwd)
    tmp.cleanup()


def exercise_bad_then_good(case_name, bad_meta, passes=3):
    tmp, old_cwd, engine, job_manager, scheduler = new_env()
    try:
        bad_id = create_validated_job(job_manager, engine, f"bad-{case_name}", f"bad_{case_name}", bad_meta)
        good_id = create_validated_job(job_manager, engine, f"good-after-{case_name}", f"good_{case_name}", base_meta("good"))
        observations = run_schedule_passes(job_manager, scheduler, engine, passes=passes)
        bad_status, bad_count = status_and_count(job_manager, engine, bad_id)
        good_status, good_count = status_and_count(job_manager, engine, good_id)
        checks_by_job = Counter(call["job_id"] for call in engine.check_calls)
        reservations_by_job = Counter(item[0] for item in engine.reservations)
        print(f"\nCASE {case_name}")
        print("observations=" + json.dumps(observations, sort_keys=True))
        print(
            "state="
            + json.dumps(
                {
                    "bad_status": bad_status,
                    "bad_schedule_count": bad_count,
                    "good_status": good_status,
                    "good_schedule_count": good_count,
                    "check_calls_by_job": dict(checks_by_job),
                    "reservations_by_job": dict(reservations_by_job),
                    "cancel_calls": len(engine.cancel_calls),
                    "uncancelled_tokens": len(engine.reservations),
                },
                sort_keys=True,
            )
        )
        if any(obs["scheduled"] for obs in observations):
            raise AssertionError(f"{case_name}: scheduler unexpectedly returned a job")
        if good_status != RunStatus.SUBMITTED.value:
            raise AssertionError(f"{case_name}: good job status changed to {good_status}")
        if bad_count not in (None, 0):
            raise AssertionError(f"{case_name}: malformed job was counted/backed off: {bad_count}")
        return {
            "case": case_name,
            "bad_id": bad_id,
            "good_id": good_id,
            "checks_by_job": checks_by_job,
            "reservations_by_job": reservations_by_job,
            "cancel_calls": len(engine.cancel_calls),
        }
    finally:
        close_env(tmp, old_cwd)


def exercise_good_only():
    tmp, old_cwd, engine, job_manager, scheduler = new_env()
    try:
        good_id = create_validated_job(job_manager, engine, "good-control", "good_control", base_meta("good"))
        observations = run_schedule_passes(job_manager, scheduler, engine, passes=1)
        print("\nCASE good_control")
        print("observations=" + json.dumps(observations, sort_keys=True))
        if observations[0]["scheduled"] != good_id:
            raise AssertionError(f"good control did not schedule: {observations}")
        return good_id
    finally:
        close_env(tmp, old_cwd)


def main():
    log_capture = io.StringIO()
    handler = logging.StreamHandler(log_capture)
    handler.setLevel(logging.ERROR)
    root_logger = logging.getLogger()
    old_level = root_logger.level
    root_logger.setLevel(logging.ERROR)
    root_logger.addHandler(handler)
    try:
        print(f"nvflare_import={nvflare.__file__}")
        good_id = exercise_good_only()
        null_result = exercise_bad_then_good(
            "null-min-clients",
            base_meta("bad_null", min_clients=None),
            passes=3,
        )
        string_result = exercise_bad_then_good(
            "string-min-clients",
            base_meta("bad_string", min_clients="2"),
            passes=2,
        )
        process_result = exercise_bad_then_good(
            "legacy-process-string",
            base_meta("bad_process", resource_spec={"site-1": {"process": "x"}}),
            passes=2,
        )

        if null_result["reservations_by_job"][null_result["bad_id"]] < 6:
            raise AssertionError("null min_clients did not accumulate per-site reservations across passes")
        if null_result["cancel_calls"] != 0:
            raise AssertionError("null min_clients reservations were unexpectedly cancelled")
        if string_result["checks_by_job"][string_result["bad_id"]] != 0:
            raise AssertionError("numeric-string min_clients should fail before resource checks")
        if process_result["checks_by_job"][process_result["bad_id"]] != 0:
            raise AssertionError("legacy process string should fail before resource checks")

        logs = log_capture.getvalue()
        interesting_logs = [
            line
            for line in logs.splitlines()
            if "TypeError" in line
            or "ValueError" in line
            or "error scheduling job" in line
            or "'<' not supported" in line
            or "dictionary update sequence" in line
        ]
        print("\nLOG_EXCERPT")
        for line in interesting_logs[:40]:
            print(line)

        print(
            "\nRESULT: PASS CR-4 reproduced: malformed validated ZIP metadata blocks later valid jobs; "
            f"good control scheduled {good_id}."
        )
        return 0
    except Exception:
        print("\nRESULT: FAIL")
        traceback.print_exc()
        return 1
    finally:
        root_logger.removeHandler(handler)
        root_logger.setLevel(old_level)


if __name__ == "__main__":
    raise SystemExit(main())

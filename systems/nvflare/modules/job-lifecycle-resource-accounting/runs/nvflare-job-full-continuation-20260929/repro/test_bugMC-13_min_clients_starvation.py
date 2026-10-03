#!/usr/bin/env python3
"""Reproduce MC-13 against the pinned NVFlare source tree."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import time
import traceback
import zipfile
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace


SOURCE_ROOT = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/MC-13/worktree"
)
sys.path.insert(0, str(SOURCE_ROOT))

from nvflare.apis.fl_constant import JobConstants  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus, SERVER_SITE_NAME  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.storage import StorageException, StorageSpec  # noqa: E402
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler  # noqa: E402
from nvflare.private.fed.server.job_meta_validator import JobMetaValidator  # noqa: E402


CLIENT_SITE = "site-1"
APP_NAME = "app"
JOB_STORE_ID = "job_store"


class FakeFLContext:
    def __init__(self, engine):
        self._engine = engine
        self.props = {}

    def get_engine(self):
        return self._engine

    def set_prop(self, key, value, private=False, sticky=False):
        self.props[key] = value

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def get_identity_name(self, default=None):
        return default or SERVER_SITE_NAME


class FakeServerEngine(ServerEngineSpec):
    def __init__(self, store=None):
        self.clients = [SimpleNamespace(name=CLIENT_SITE)]
        self.resource_checks = []
        self.cancelled = []
        self.components = {}
        if store is not None:
            self.components[JOB_STORE_ID] = store

    def validate_targets(self, target_names):
        return target_names, []

    def fire_event(self, event_type, fl_ctx):
        return None

    def get_clients(self):
        return self.clients

    def sync_clients_from_main_process(self):
        return self.clients

    def update_job_run_status(self):
        return None

    @contextmanager
    def new_context(self):
        yield FakeFLContext(self)

    def get_workspace(self):
        return None

    def add_component(self, component_id, component):
        self.components[component_id] = component

    def get_component(self, component_id):
        return self.components.get(component_id)

    def register_aux_message_handler(self, topic, message_handle_func):
        return None

    def send_aux_request(self, targets, topic, request, timeout, fl_ctx, optional=False, secure=False):
        return {}

    def multicast_aux_requests(self, topic, target_requests, timeout, fl_ctx, optional=False, secure=False):
        return {}

    def get_widget(self, widget_id):
        return None

    def persist_components(self, fl_ctx, completed):
        return None

    def restore_components(self, snapshot, fl_ctx):
        return None

    def start_client_job(self, job, client_sites, fl_ctx):
        return None

    def check_client_resources(self, job, resource_reqs, fl_ctx):
        self.resource_checks.append((job.job_id, sorted(resource_reqs)))
        return {CLIENT_SITE: (True, f"token-{job.job_id}-{CLIENT_SITE}")}

    def cancel_client_resources(self, resource_check_results, resource_reqs, fl_ctx):
        self.cancelled.append((resource_check_results, resource_reqs))

    def get_client_name_from_token(self, token):
        return CLIENT_SITE


class InMemoryStorage(StorageSpec):
    def __init__(self):
        self.objects = {}
        self.update_meta_calls = []

    def create_object(self, uri: str, data, meta: dict, overwrite_existing: bool):
        if uri in self.objects and not overwrite_existing:
            raise StorageException(f"object already exists: {uri}")
        self.objects[uri] = {"data": data, "meta": dict(meta), "components": {}, "tags": {}}

    def clone_object(self, from_uri: str, to_uri: str, meta: dict, overwrite_existing: bool = False):
        if from_uri not in self.objects:
            raise StorageException(f"no such object: {from_uri}")
        if to_uri in self.objects and not overwrite_existing:
            raise StorageException(f"object already exists: {to_uri}")
        src = self.objects[from_uri]
        self.objects[to_uri] = {
            "data": src["data"],
            "meta": dict(meta),
            "components": dict(src["components"]),
            "tags": dict(src["tags"]),
        }

    def update_object(self, uri: str, data: bytes | str | list[str], component_name: str) -> str:
        if uri not in self.objects:
            raise StorageException(f"no such object: {uri}")
        self.objects[uri]["components"][component_name] = data
        return uri

    def update_meta(self, uri: str, meta: dict, replace: bool):
        if uri not in self.objects:
            raise StorageException(f"no such object: {uri}")
        self.update_meta_calls.append((uri, dict(meta), replace))
        if replace:
            self.objects[uri]["meta"] = dict(meta)
        else:
            self.objects[uri]["meta"].update(meta)

    def list_objects(self, path: str, without_tag=None) -> list[str]:
        uris = []
        for uri, obj in self.objects.items():
            if not uri.startswith(path):
                continue
            if without_tag and without_tag in obj["tags"]:
                continue
            uris.append(uri)
        return sorted(uris)

    def get_meta(self, uri: str) -> dict:
        obj = self.objects.get(uri)
        return dict(obj["meta"]) if obj else {}

    def list_components_of_object(self, uri: str) -> list[str]:
        if uri not in self.objects:
            raise StorageException(f"no such object: {uri}")
        return sorted(self.objects[uri]["components"])

    def get_data(self, uri: str, component_name: str = "data") -> bytes:
        obj = self.objects.get(uri)
        if not obj:
            return None
        if component_name == "data":
            return obj["data"]
        return obj["components"].get(component_name)

    def get_data_for_download(self, uri: str, component_name: str = "data", download_file: str | None = None):
        return self.get_data(uri, component_name)

    def get_detail(self, uri: str) -> tuple[dict, bytes]:
        return self.get_meta(uri), self.get_data(uri)

    def delete_object(self, uri: str):
        self.objects.pop(uri, None)

    def tag_object(self, uri: str, tag: str, data=None):
        if uri not in self.objects:
            raise StorageException(f"no such object: {uri}")
        self.objects[uri]["tags"][tag] = data


def make_job_zip(job_name: str, min_clients, job_id: str | None = None):
    meta = {
        JobMetaKey.DEPLOY_MAP.value: {APP_NAME: [SERVER_SITE_NAME, CLIENT_SITE]},
        JobMetaKey.MIN_CLIENTS.value: min_clients,
        JobMetaKey.RESOURCE_SPEC.value: {},
    }
    if job_id:
        meta[JobMetaKey.JOB_ID.value] = job_id
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as zf:
        zf.writestr(f"{job_name}/{APP_NAME}/config/", "")
        zf.writestr(f"{job_name}/{JobConstants.META_FILE}", json.dumps(meta))
        zf.writestr(f"{job_name}/{APP_NAME}/config/{JobConstants.SERVER_JOB_CONFIG}", "{}")
        zf.writestr(f"{job_name}/{APP_NAME}/config/{JobConstants.CLIENT_JOB_CONFIG}", "{}")
    return data.getvalue()


def validated_package(job_name: str, min_clients, job_id: str):
    job_data = make_job_zip(job_name, min_clients, job_id)
    valid, error, meta = JobMetaValidator().validate(job_name, job_data)
    if not valid:
        raise AssertionError(f"validator rejected {job_name}: {error}")
    return job_data, dict(meta)


def make_job_manager_runtime():
    temp_dir = tempfile.TemporaryDirectory(prefix="mc13-job-store-")
    store = InMemoryStorage()
    engine = FakeServerEngine(store)
    fl_ctx = FakeFLContext(engine)
    manager = SimpleJobDefManager(uri_root=str(Path(temp_dir.name) / "jobs"), job_store_id=JOB_STORE_ID)
    manager.log_debug = lambda *args, **kwargs: None
    return temp_dir, manager, engine, fl_ctx, store


def create_submitted_job(manager, fl_ctx, job_name: str, min_clients, job_id: str):
    job_data, meta = validated_package(job_name, min_clients, job_id)
    return manager.create(meta, job_data, fl_ctx)


def find_job(jobs, job_id: str):
    for job in jobs:
        if job.job_id == job_id:
            return job
    raise AssertionError(f"job {job_id} not found in {[job.job_id for job in jobs]}")


def make_scheduler():
    scheduler = DefaultJobScheduler(max_jobs=1, max_schedule_count=3, min_schedule_interval=0.0)
    scheduler.caught_exceptions = []
    scheduler.log_debug = lambda *args, **kwargs: None
    scheduler.log_info = lambda *args, **kwargs: None
    scheduler.log_error = lambda *args, **kwargs: None
    scheduler.fire_event = lambda *args, **kwargs: None

    def record_exception(*args, **kwargs):
        scheduler.caught_exceptions.append(traceback.format_exc())

    scheduler.log_exception = record_exception
    return scheduler


def stored_job(manager, fl_ctx, job_id: str):
    job = manager.get_job(job_id, fl_ctx)
    if job is None:
        raise AssertionError(f"stored job {job_id} not found")
    return job


def schedule_count(job):
    return job.meta.get(JobMetaKey.SCHEDULE_COUNT.value, 0)


def main():
    print("MC-13 reproduction: numeric-string min_clients can starve a later eligible job")
    print(f"source_root={SOURCE_ROOT}")

    string_data, string_meta = validated_package("bad_string_pkg", "1", "bad-oldest")
    good_data, good_meta = validated_package("good_pkg", 1, "good-later")
    print(
        "validator accepted numeric-string min_clients: "
        f"type={type(string_meta[JobMetaKey.MIN_CLIENTS.value]).__name__} "
        f"value={string_meta[JobMetaKey.MIN_CLIENTS.value]!r}"
    )

    trigger_tmp, trigger_manager, trigger_engine, trigger_ctx, trigger_store = make_job_manager_runtime()
    trigger_manager.create(dict(string_meta), string_data, trigger_ctx)
    time.sleep(0.01)
    trigger_manager.create(dict(good_meta), good_data, trigger_ctx)
    initial_candidates = trigger_manager.get_jobs_to_schedule(trigger_ctx)
    bad_oldest = find_job(initial_candidates, "bad-oldest")
    print(
        "job_def_manager/job_from_meta preserved min_sites: "
        f"type={type(bad_oldest.min_sites).__name__} value={bad_oldest.min_sites!r}"
    )
    print(f"submitted_jobs_from_manager={[job.job_id for job in initial_candidates]!r}")

    trigger_scheduler = make_scheduler()
    repeated_exception_types = []
    for attempt in (1, 2):
        jobs_to_schedule = trigger_manager.get_jobs_to_schedule(trigger_ctx)
        ready_job, dispatch_info = trigger_scheduler.schedule_job(
            trigger_manager, jobs_to_schedule, trigger_ctx
        )
        bad_stored = stored_job(trigger_manager, trigger_ctx, "bad-oldest")
        good_stored = stored_job(trigger_manager, trigger_ctx, "good-later")
        last_exception = trigger_scheduler.caught_exceptions[-1] if trigger_scheduler.caught_exceptions else ""
        repeated_exception_types.append("TypeError" if "TypeError" in last_exception else "missing")
        print(
            f"attempt={attempt} ready_job={getattr(ready_job, 'job_id', None)!r} "
            f"dispatch_info={dispatch_info!r} exceptions={len(trigger_scheduler.caught_exceptions)} "
            f"exception_type={repeated_exception_types[-1]} "
            f"resource_checks={trigger_engine.resource_checks!r} "
            f"store_meta_updates={trigger_store.update_meta_calls!r} "
            f"bad_schedule_count={schedule_count(bad_stored)} "
            f"good_schedule_count={schedule_count(good_stored)} "
            f"good_status={good_stored.meta[JobMetaKey.STATUS.value]!r}"
        )
        assert ready_job is None
        assert dispatch_info is None
        assert repeated_exception_types[-1] == "TypeError"
        assert len(trigger_scheduler.caught_exceptions) == attempt
        assert trigger_engine.resource_checks == []
        assert trigger_store.update_meta_calls == []
        assert schedule_count(bad_stored) == 0
        assert schedule_count(good_stored) == 0
        assert good_stored.meta[JobMetaKey.STATUS.value] == RunStatus.SUBMITTED.value

    int_data, int_meta = validated_package("bad_int_pkg", 1, "int-oldest")
    int_tmp, int_manager, int_engine, int_ctx, int_store = make_job_manager_runtime()
    int_manager.create(dict(int_meta), int_data, int_ctx)
    int_oldest = find_job(int_manager.get_jobs_to_schedule(int_ctx), "int-oldest")
    scheduler_int = make_scheduler()
    ready_int, dispatch_int = scheduler_int.schedule_job(int_manager, [int_oldest], int_ctx)
    print(
        "control_int_min_clients: "
        f"ready_job={getattr(ready_int, 'job_id', None)!r} "
        f"dispatch_sites={sorted(dispatch_int) if dispatch_int else None!r} "
        f"exceptions={len(scheduler_int.caught_exceptions)} "
        f"resource_checks={int_engine.resource_checks!r} "
        f"schedule_count={schedule_count(int_oldest)} "
        f"store_meta_updates={int_store.update_meta_calls!r}"
    )
    assert ready_int is int_oldest
    assert scheduler_int.caught_exceptions == []
    assert int_engine.resource_checks == [("int-oldest", [CLIENT_SITE])]

    good_alone_data, good_alone_meta = validated_package("good_alone_pkg", 1, "good-later-alone")
    good_tmp, good_manager, good_engine, good_ctx, _good_store = make_job_manager_runtime()
    good_manager.create(dict(good_alone_meta), good_alone_data, good_ctx)
    good_alone = find_job(good_manager.get_jobs_to_schedule(good_ctx), "good-later-alone")
    scheduler_good = make_scheduler()
    ready_good, dispatch_good = scheduler_good.schedule_job(good_manager, [good_alone], good_ctx)
    print(
        "control_later_job_without_bad_oldest: "
        f"ready_job={getattr(ready_good, 'job_id', None)!r} "
        f"dispatch_sites={sorted(dispatch_good) if dispatch_good else None!r} "
        f"exceptions={len(scheduler_good.caught_exceptions)} "
        f"resource_checks={good_engine.resource_checks!r} "
        f"schedule_count={schedule_count(good_alone)}"
    )
    assert ready_good is good_alone
    assert scheduler_good.caught_exceptions == []
    assert good_engine.resource_checks == [("good-later-alone", [CLIENT_SITE])]

    print("BUG_REPRODUCED: older accepted string min_clients job aborts each scheduler scan before later eligible job")

    trigger_tmp.cleanup()
    int_tmp.cleanup()
    good_tmp.cleanup()


if __name__ == "__main__":
    main()

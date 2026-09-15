# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by law or agreed in writing, software is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.
"""Read-only source probes. No model import, transition execution, or cleanup.

One local-host NDJSON stream, serialized by a thread mutex plus flock across
parent processes. Only whitelisted lifecycle values are recorded, never auth
credentials, command lines, job application data, or the whole environment.
"""
import collections
import enum
import fcntl
import inspect
import json
import os
import threading
import time

_lock = threading.RLock()
_seq = 0
_objects = {}
_seen_faults = set()
_last_tick = None
_local = threading.local()


def simple(value):
    if isinstance(value, enum.Enum):
        return value.value
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, (list, tuple, set, collections.deque)):
        return [simple(x) for x in value]
    if isinstance(value, dict):
        return {str(simple(k)): simple(v) for k, v in value.items()}
    if hasattr(value, "job_id"):
        return {"job_id": value.job_id, "meta": metadata(value.meta),
                "run_aborted": getattr(value, "run_aborted", False)}
    return {"type": type(value).__name__}


def metadata(meta):
    keys = {"job_id", "name", "status", "submit_time", "schedule_count",
            "last_schedule_time", "schedule_history", "min_sites", "required_sites"}
    return {str(simple(k)): simple(v) for k, v in meta.items() if simple(k) in keys}


def handles(mapping):
    from nvflare.apis.fl_constant import RunProcessKey
    result = {}
    for jid, row in list(mapping.items()):
        h = row.get(RunProcessKey.JOB_HANDLE)
        actual = getattr(h, "_job_handle", h)
        adapter = getattr(actual, "adapter", None)
        result[jid] = {
            "handle": "attached" if actual else "pending", "handle_id": id(h),
            "pid": getattr(adapter, "pid", None),
            "status": simple(row.get(RunProcessKey.STATUS)),
            "abort_requested": row.get("_abort_requested", False),
            "pending_abort": getattr(h, "_pending_heartbeat_cleanup", None),
        }
    return result


def context_values(local):
    from nvflare.apis.fl_constant import FLContextKey
    for key in ("fl_ctx", "ctx", "completion_ctx"):
        ctx = local.get(key)
        if ctx is not None and hasattr(ctx, "get_identity_name"):
            return {"site": ctx.get_identity_name(),
                    "context_job": ctx.get_prop(FLContextKey.CURRENT_JOB_ID)}
    return {}


def _probe_impl(name, local):
    global _seq, _last_tick
    path = os.environ.get("NVFLARE_LIFECYCLE_RAW")
    if not path:
        return
    start = time.monotonic_ns()
    # Capture caller locals without traversing arbitrary object graphs.
    chain = []
    frame = inspect.currentframe().f_back
    merged = {}
    for _ in range(14):
        if frame is None:
            break
        if "/nvflare/" in frame.f_code.co_filename and not frame.f_code.co_filename.endswith('_lifecycle_probe.py'):
            chain.append({"file": frame.f_code.co_filename.split("/nvflare/", 1)[1],
                          "line": frame.f_lineno, "function": frame.f_code.co_name})
            for k, v in frame.f_locals.items():
                merged.setdefault(k, v)
            obj = frame.f_locals.get("self")
            if obj is not None:
                _objects[type(obj).__name__] = obj
        frame = frame.f_back
    del frame
    merged.update(local)
    with _lock:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as out:
            fcntl.flock(out, fcntl.LOCK_EX)
            _seq += 1
            data = context_values(merged)
            if not data.get('site'):
                data['site'] = os.environ.get('NVFLARE_LIFECYCLE_SITE')
            for key in ("job_id", "jid", "job", "ready_job", "job_candidates", "failed_jobs",
                        "blocked_jobs", "result", "rc", "schedule_count", "required_interval",
                        "time_since_last_schedule", "num_sites_ok", "required_sites_not_enough_resource",
                        "sites_dispatch_info", "failed_clients", "abort_job", "active_client_sites",
                        "client_sites", "client_name", "event_type", "job_status", "job_run_status",
                        "reload_job", "return_code", "failure_reason", "heartbeat_cleanup",
                        "status", "pending", "unresolved", "allocated_resource", "allocated_resources",
                        "token", "resource_spec", "resource_requirement", "resources", "tokens_to_remove",
                        "is_resource_enough", "reserved_resources", "meta", "err"):
                if key in merged:
                    data[key] = metadata(merged[key]) if key == "meta" else simple(merged[key])
            for key in ('timeout_secs', 'client_token_to_name', 'server_failed', 'now', 'deadline', 'start', 'start_time'):
                if key in merged:
                    data[key] = simple(merged[key])
            if name in ('JobExecutorTerminateAfterGrace', 'ServerEngineTerminateAfterGrace'):
                data['observed_elapsed_s'] = time.time() - merged['start']
            if name == 'CellWaiterOpened':
                request = merged['request']
                admin_id = request.get_header('_specula_admin_id')
                if not admin_id:
                    return
                data['stream_waiter'] = {'id': merged['req_id'], 'admin_id': admin_id, 'target': merged['target']}
            if name == 'CellLateReplyDiscarded':
                data['stream_id'] = merged['req_id']
            if name == 'CoreWaiterOpened':
                data['core_waiters'] = [
                    {'id': merged['waiter'].id, 'admin_id': tm.message.get_header('_specula_admin_id'), 'target': target}
                    for target, tm in merged['target_msgs'].items()
                    if tm.message.get_header('_specula_admin_id')]
                if not data['core_waiters']:
                    return
            if name in ('CoreReplyAccepted', 'CoreLateReplyDiscarded'):
                payload=merged['message'].payload
                if not hasattr(payload,'body'):
                    return
                data['core_reply'] = {'id': merged['rid'], 'target': merged['req_destination'],
                                      'body': simple(payload.body)}
            for key in ("job_meta",):
                if isinstance(merged.get(key), dict):
                    data[key] = metadata(merged[key])
            if "new_env" in merged:
                data["copied_cuda"] = merged["new_env"].get("CUDA_VISIBLE_DEVICES", "")
            if name == "ListResourceConsumerConsume":
                data["cuda"] = os.environ.get("CUDA_VISIBLE_DEVICES", "")
            req = merged.get("req")
            if req is not None and hasattr(req, "get_header"):
                from nvflare.private.defs import RequestHeader
                from nvflare.private.scheduler_constants import ShareableHeader
                data["request"] = {"id": getattr(req, "id", None), "topic": req.topic,
                    "job": req.get_header(RequestHeader.JOB_ID),
                    "token": req.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN)}
            requests = merged.get("requests") or merged.get("client_deploy_requests")
            if isinstance(requests, dict) and name.startswith("Send"):
                from nvflare.private.defs import RequestHeader
                from nvflare.private.scheduler_constants import ShareableHeader
                data["requests"] = [{"client_token": k, "id": getattr(v, "id", None),
                    "topic": v.topic, "job": v.get_header(RequestHeader.JOB_ID),
                    "token": v.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN)} for k, v in requests.items()]
                engine = _objects.get('ServerEngine')
                if engine:
                    data['client_names'] = {k: v.name for k, v in engine.client_manager.clients.items()}
            r = merged.get("r")
            if r is not None and hasattr(r, "client_name"):
                from nvflare.private.defs import RequestHeader
                from nvflare.private.scheduler_constants import ShareableHeader
                data["reply"] = {"site": r.client_name, "job": r.request.get_header(RequestHeader.JOB_ID),
                    "request_id": getattr(r.request, "id", None), "topic": r.request.topic,
                    "present": r.reply is not None,
                    "body": simple(r.reply.body) if r.reply else None}
            obj = merged.get("self")
            # These maps are captured at explicitly instrumented lock boundaries.
            if hasattr(obj, "reserved_resources"):
                data["rm"] = {"free": simple(obj.resources), "reserved": simple(obj.reserved_resources)}
                if name == "AutoCleanResourceManagerTick":
                    now = time.monotonic_ns()
                    data["tick_elapsed_ns"] = now - (_last_tick or (now - int(obj._check_period * 1e9)))
                    _last_tick = now
            if type(obj).__name__ == "DefaultJobScheduler":
                data["scheduled_jobs"] = list(obj.scheduled_jobs)
            if type(obj).__name__ == "JobExecutor":
                data["client_processes"] = handles(obj.run_processes)
                data["site"] = obj.client.client_name
            if type(obj).__name__ == "ServerEngine":
                data["server_processes"] = handles(obj.run_processes)
            if type(obj).__name__ == "JobRunner":
                data["running_jobs"] = simple(obj.running_jobs)
                data["pending_outcomes"] = simple(obj._pending_client_outcomes)
                data["finished_states"] = {k: {"status": simple(v.status),
                    "archival_complete": v.workspace_archival_complete,
                    "save_started": v.workspace_save_started_at} for k, v in obj._finished_job_states.items()}
                data['server_processes'] = handles(merged.get('engine').run_processes) if merged.get('engine') else {}
            if type(obj).__name__ == 'ClientEngine':
                data['client_processes'] = handles(obj.client_executor.run_processes)
            adapter = merged.get("process_adapter")
            if adapter is not None:
                data["spawn_pid"] = adapter.pid
            data["parent_pid"] = os.getpid()
            row = {"tag": "trace", "ts": time.monotonic_ns(), "capture_start_ns": start,
                   "event": name, "pid": os.getpid(), "tid": threading.get_ident(),
                   "seq": _seq, "source": chain, "capture": data}
            out.write(json.dumps(row, separators=(",", ":")) + "\n")
            out.flush()
            fcntl.flock(out, fcntl.LOCK_UN)


def probe(name, local):
    # Probe failures invalidate evidence without changing production error
    # handling, returning a fabricated response, or repairing owned resources.
    try:
        _probe_impl(name, local)
    except Exception as error:
        path = os.environ.get('NVFLARE_LIFECYCLE_RAW')
        if path:
            with _lock, open(path + '.errors', 'a') as out:
                out.write(json.dumps({'event': name, 'error': repr(error), 'ts': time.monotonic_ns()})+'\n')


def fault(point, local):
    """Explicit, recorded local ordinary-runtime faults; no protocol replacement."""
    case = os.environ.get("NVFLARE_LIFECYCLE_SCENARIO", "")
    if point == 'bootstrap_wait':
        gate=os.environ.get('NVFLARE_LIFECYCLE_GATE')
        if gate:
            deadline=time.monotonic()+90
            while not os.path.exists(gate):
                if time.monotonic()>deadline:
                    raise TimeoutError('harness bootstrap gate was not released')
                time.sleep(0.05)
        return
    site = context_values(local).get("site")
    engine = local.get("engine")
    if engine is not None and hasattr(engine, "get_client_name"):
        site = engine.get_client_name()
    job = local.get("job") or local.get("ready_job")
    meta = getattr(job, "meta", None) or local.get("job_meta") or {}
    req = local.get("req")
    if req is not None:
        from nvflare.private.defs import RequestHeader
        meta = req.get_header(RequestHeader.JOB_META) or meta
    key = (point, meta.get("name"))
    if key in _seen_faults:
        return
    if case == "delayed_start" and point == "before_allocate" and site == "site-2":
        _seen_faults.add(key)
        probe("ControlledStartDelay", local)
        time.sleep(32)
    if case == 'delayed_start' and point == 'cancel_reply' and site == 'site-1':
        _seen_faults.add(key)
        probe('ControlledCancelReplyDelay', local)
        time.sleep(12)
    if case == "admission_exception" and point == "after_resource_results" and meta.get("name", "").endswith("-1"):
        _seen_faults.add(key)
        probe("ControlledAdmissionException", local)
        raise RuntimeError("controlled ordinary admission exception after resource replies")
    if case == 'admission_exception' and point == 'prepare_start' and site == 'site-2' and meta.get('name','').endswith('-2'):
        _seen_faults.add(key)
        probe('JobExecutorPrepareException', local)
        raise OSError('controlled ordinary startup preparation I/O failure')

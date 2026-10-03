# Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Specula NDJSON tracer for nvflare-job (Category A: one linear trace written under one process-wide lock).

The tracer is the backend of ``nvflare.fuel.utils.tla_hooks``.  Product hooks and harness stubs open *sections*;
the outermost section of a thread holds the trace lock ``T`` from its beginning (before the traced state change)
until its event line (with the post-state snapshot) has been written.  Therefore the NDJSON order is a valid
linearisation of the traced steps and every snapshot shows exactly the effects of the events before it.

Rules that keep the harness deadlock free and faithful:
  * ``T`` is always taken *before* any product lock and the snapshot never takes product locks (every writer of
    captured state runs inside a section, so the snapshot sees a quiescent state).
  * A thread never waits for an RPC reply while it holds ``T``: stub network sends made inside a section are queued
    in the thread's outbox, the sender sees an injected timeout (only used where the product ignores the reply),
    and the queued messages are delivered after the section's event line is written.
"""

import json
import os
import sys
import threading
import time
import traceback

from nvflare.apis.fl_constant import RunProcessKey
from nvflare.private.fed.client.client_executor import _ABORT_REQUESTED_KEY, _PendingJobHandle

STATUS_NAMES = {1: "STARTING", 2: "STARTED", 3: "STOPPED", 0: "NOT_STARTED", 4: "EXCEPTION"}


class _Frame:
    __slots__ = ("name", "fields", "top", "on_error", "error", "closed", "skip", "failed")

    def __init__(self, name, fields, top, on_error="emit"):
        self.name = name
        self.fields = dict(fields)
        self.top = top
        self.on_error = on_error
        self.error = None
        self.closed = False
        self.skip = False
        self.failed = False


class _TS(threading.local):
    def __init__(self):
        self.stack = []
        self.outbox = []
        self.notes = {}
        self.contexts = []


class _NullHandle:
    frame = None

    def __enter__(self):
        return self

    def __exit__(self, et, ev, tb):
        return False

    def cancel(self):
        pass

    def set(self, **fields):
        pass

    def rename(self, name):
        pass


_NULL = _NullHandle()


class _Handle:
    def __init__(self, tracer, name, fields, on_error):
        self.t = tracer
        self.name = name
        self.fields = fields
        self.on_error = on_error
        self.frame = None

    def __enter__(self):
        self.frame = self.t._begin(self.name, self.fields, self.on_error)
        return self

    def __exit__(self, et, ev, tb):
        self.t._exit_frame(self.frame, et, ev)
        return False

    def cancel(self):
        self.t._cancel_frame(self.frame)

    def set(self, **fields):
        if self.frame is not None and not self.frame.closed:
            self.frame.fields.update(fields)

    def rename(self, name):
        if self.frame is not None and not self.frame.closed:
            self.frame.name = name


class _Ctx:
    def __init__(self, ts, tag):
        self.ts = ts
        self.tag = tag

    def __enter__(self):
        self.ts.contexts.append(self.tag)
        return self

    def __exit__(self, et, ev, tb):
        if self.ts.contexts and self.ts.contexts[-1] == self.tag:
            self.ts.contexts.pop()
        elif self.tag in self.ts.contexts:
            self.ts.contexts.remove(self.tag)
        return False


class Tracer:
    def __init__(self, env, out_path, deadlock_timeout=120.0):
        self.env = env
        self.out_path = out_path
        self._fh = open(out_path, "w")
        self._T = threading.Lock()
        self._owner = None
        self._ts = _TS()
        self._seq = 0
        self._closed = False
        self._cv = threading.Condition()
        self.events = []  # emitted events (dicts), for scenario synchronisation
        self.deadlock_timeout = deadlock_timeout
        self.errors = []  # harness errors (snapshot failures, stray frames, ...)
        self.thread_deaths = []  # (thread name, exception repr) for threads that died with an exception
        self.gates = {}  # gate point -> callback(**info)
        # attempt ids (spec nextAtt): incremented at every RunnerTryNext that sends CHECK_RESOURCE
        self.att = 0
        self.current_check_att = 0
        # reservation token -> (att, real job id), recorded at CpCheckResource
        self.token_info = {}
        # harness side tables (instrumentation-spec 1.2): units between allocate and launch / held by the waiter
        self.starting = {}  # (client name, job id) -> list of units
        self.allocated = {}  # (client name, job id) -> list of units
        # observation state kept for deleted jobs / removed Job objects (see INSTRUMENTATION.md, "abstraction")
        self._last_count = {}
        self._last_tag = {}
        self._last_job_obj = {}
        self._orig_excepthook = threading.excepthook
        threading.excepthook = self._excepthook

    # ------------------------------------------------------------------ lock
    def holding(self) -> bool:
        return bool(self._ts.stack)

    def _acquire(self):
        t0 = time.monotonic()
        while not self._T.acquire(timeout=5.0):
            if time.monotonic() - t0 > self.deadlock_timeout:
                self._dump_deadlock()
                os._exit(3)
        self._owner = threading.current_thread()

    def _release(self):
        self._owner = None
        self._T.release()

    def _dump_deadlock(self):
        sys.stderr.write(f"\n!!! TRACE LOCK DEADLOCK SUSPECTED (owner={self._owner}) !!!\n")
        for tid, frame in sys._current_frames().items():
            name = next((t.name for t in threading.enumerate() if t.ident == tid), str(tid))
            sys.stderr.write(f"--- thread {name}\n{''.join(traceback.format_stack(frame))}\n")
        sys.stderr.flush()
        try:
            self._fh.write(json.dumps({"tag": "harness_error", "error": "trace lock deadlock"}) + "\n")
            self._fh.flush()
        except Exception:
            pass

    # ------------------------------------------------------------------ hook API
    def section(self, name, **fields):
        when = fields.pop("when", None)
        on_error = fields.pop("on_error", "emit")
        if when is not None and not self.in_context(when):
            return _NULL
        return _Handle(self, name, fields, on_error)

    def begin(self, name, **fields):
        on_error = fields.pop("on_error", "emit")
        self._begin(name, fields, on_error)

    def _normalize(self, name, fields):
        """Resolve hook arguments (product hooks pass only locals/objects, never derived attributes)."""
        env = self.env
        ex = fields.pop("executor", None)
        if ex is not None:
            fields["cl"] = env.client_name_of_executor(ex)
        eng = fields.get("engine")
        if eng is not None and "cl" not in fields:
            fields["cl"] = env.client_name_of_engine(eng)
        replies = fields.pop("replies", None)
        requests = fields.pop("requests", None)
        if replies is not None:
            timed_out = any(getattr(r, "reply", None) is None for r in replies)
            if requests is not None and len(replies) < len(requests):
                timed_out = True
            if timed_out and name in ("RunnerStartCollect", "RunnerCheckCollect"):
                name = name.replace("Collect", "Timeout")
        return name, fields

    def _begin(self, name, fields, on_error):
        ts = self._ts
        if name.startswith("@rmw."):
            name = self._rmw_name(name)
        name, fields = self._normalize(name, dict(fields))
        if ts.stack:
            frame = _Frame(name, fields, top=False, on_error=on_error)
            ts.stack.append(frame)
            return frame
        self._acquire()
        if self._closed:
            self._release()
            frame = _Frame(name, fields, top=False, on_error=on_error)
            frame.closed = True
            return frame
        frame = _Frame(name, fields, top=True, on_error=on_error)
        ts.stack.append(frame)
        try:
            self._on_open(frame)
        except Exception as e:  # never break the product thread
            self._harness_error(f"on_open({name}): {e!r}")
        return frame

    def end(self, name=None, **fields):
        ts = self._ts
        if not ts.stack:
            return
        top = ts.stack[-1]
        if name is not None and top.name != name:
            return
        top.fields.update(fields)
        self._pop_and_finish(top, emit=True)

    def end_open(self, **fields):
        ts = self._ts
        if not ts.stack:
            return
        outer = ts.stack[0]
        outer.fields.update(fields)
        outer.failed = True
        for f in ts.stack[1:]:
            f.closed = True
        del ts.stack[1:]
        self._pop_and_finish(outer, emit=True)

    def cancel(self, name=None):
        ts = self._ts
        if not ts.stack:
            return
        top = ts.stack[-1]
        if name is not None and top.name != name:
            return
        self._pop_and_finish(top, emit=False)

    def emit(self, name, **fields):
        ts = self._ts
        if not ts.stack:
            return
        outer = ts.stack[0]
        merged = dict(fields)
        self._write_event(name, merged, None, outer)

    def event(self, name, **fields):
        ts = self._ts
        if ts.stack:
            return  # absorbed into the open section
        frame = self._begin(name, fields, "emit")
        self._pop_and_finish(frame, emit=True)

    def rename(self, name, **fields):
        ts = self._ts
        if ts.stack:
            ts.stack[-1].name = name
            ts.stack[-1].fields.update(fields)

    def set_fields(self, **fields):
        ts = self._ts
        if ts.stack:
            ts.stack[-1].fields.update(fields)

    def gate(self, point, **info):
        cb = self.gates.get(point)
        if cb is None:
            return
        if self.holding():
            return  # shared code path reached inside another traced step: never pause while holding T
        cb(**info)

    def context(self, tag):
        return _Ctx(self._ts, tag)

    def in_context(self, tag) -> bool:
        ctxs = self._ts.contexts
        if tag == "rmw":
            return any(c.startswith("rmw:") for c in ctxs)
        return tag in ctxs

    def note(self, key, value):
        self._ts.notes[key] = value

    def take(self, key, default=None):
        return self._ts.notes.pop(key, default)

    def defer(self, fn):
        """Called by stubs: run fn after the current section releases T (or now if no section is open)."""
        ts = self._ts
        if ts.stack:
            ts.outbox.append(fn)
            return True
        return False

    # ------------------------------------------------------------------ frame handling
    def _rmw_name(self, name):
        prefix = next((c[4:] for c in reversed(self._ts.contexts) if c.startswith("rmw:")), "Rmw")
        return prefix + ("Read" if name == "@rmw.read" else "Write")

    def _exit_frame(self, frame, et, ev):
        if frame is None or frame.closed:
            return
        ts = self._ts
        if frame not in ts.stack:
            return
        # close frames left open above this one (should not happen)
        while ts.stack and ts.stack[-1] is not frame:
            stray = ts.stack.pop()
            stray.closed = True
            self._harness_error(f"stray open section {stray.name} inside {frame.name}")
        if et is not None and frame.top:
            if frame.on_error == "cancel":
                self._pop_and_finish(frame, emit=False)
                return
            frame.error = f"{et.__name__}: {ev}"
        self._pop_and_finish(frame, emit=True)

    def _cancel_frame(self, frame):
        if frame is None or frame.closed:
            return
        ts = self._ts
        if ts.stack and ts.stack[-1] is frame:
            self._pop_and_finish(frame, emit=False)

    def _pop_and_finish(self, frame, emit):
        ts = self._ts
        if ts.stack and ts.stack[-1] is frame:
            ts.stack.pop()
        frame.closed = True
        if not frame.top:
            return
        outbox = ts.outbox
        ts.outbox = []
        try:
            if emit and not frame.skip:
                self._write_event(frame.name, frame.fields, frame.error, frame)
        except Exception as e:
            self._harness_error(f"emit {frame.name}: {e!r}\n{traceback.format_exc()}")
        finally:
            self._release()
        for fn in outbox:
            try:
                fn()
            except Exception as e:
                self._harness_error(f"deferred delivery failed: {e!r}")

    def _excepthook(self, args):
        ts = self._ts
        if ts.stack:
            outer = ts.stack[0]
            outer.error = f"{type(args.exc_value).__name__}: {args.exc_value}"
            for f in ts.stack[1:]:
                f.closed = True
            del ts.stack[1:]
            self._pop_and_finish(outer, emit=True)
        self.thread_deaths.append((args.thread.name if args.thread else "?", repr(args.exc_value)))
        self._orig_excepthook(args)

    def close_thread_sections(self, err):
        """For harness thread wrappers: close sections left open by a thread that is terminating."""
        ts = self._ts
        if ts.stack:
            outer = ts.stack[0]
            outer.error = err
            for f in ts.stack[1:]:
                f.closed = True
            del ts.stack[1:]
            self._pop_and_finish(outer, emit=True)

    def _harness_error(self, msg):
        self.errors.append(msg)
        sys.stderr.write(f"[tracer] HARNESS ERROR: {msg}\n")

    # ------------------------------------------------------------------ special per-event handling
    def _on_open(self, frame):
        if frame.name == "CpTick":
            rm = frame.fields.get("rm")
            if rm is not None and not rm.reserved_resources:
                frame.skip = True  # an empty tick changes nothing; the spec's CpTick requires reservations

    def _client_of_engine(self, engine):
        return self.env.client_name_of_engine(engine)

    def _msg_identity(self, name, fields):
        env = self.env
        if name == "CpCheckResource":
            req = fields["msg"]
            cl = self._client_of_engine(fields.get("engine"))
            return {"type": "CHECK", "job": env.jname(req.get_header("job_id")), "cl": env.cname(cl),
                    "att": getattr(req, "_tla_att", -1), "ok": False, "code": 0, "flag": False}
        if name == "CpCancelResource":
            req = fields["msg"]
            cl = self._client_of_engine(fields.get("engine"))
            tok = req.get_header(env.RESERVE_TOKEN_HEADER)
            att, jid = self.token_info.get((cl, tok), (-1, None))
            return {"type": "CANCEL", "job": env.jname(jid), "cl": env.cname(cl), "att": att, "ok": False,
                    "code": 0, "flag": False}
        if name in ("CpStartAllocate", "CpStartAllocateAppMissing"):
            req = fields["msg"]
            cl = self._client_of_engine(fields.get("engine"))
            tok = req.get_header(env.RESERVE_TOKEN_HEADER)
            att, _ = self.token_info.get((cl, tok), (-1, None))
            return {"type": "START", "job": env.jname(req.get_header("job_id")), "cl": env.cname(cl), "att": att,
                    "ok": False, "code": 0, "flag": False}
        if name == "CpAbortApp":
            return {"type": "ABORT", "job": env.jname(fields.get("job")), "cl": env.cname(fields.get("cl")),
                    "att": 0, "ok": False, "code": 0, "flag": bool(fields.get("hb", False))}
        if name == "SpProcessJobFailure":
            req = fields["msg"]
            payload = req.payload if isinstance(req.payload, dict) else {}
            code = payload.get("code")
            return {"type": "REPORT", "job": env.jname(payload.get("job_id")),
                    "cl": env.cname(getattr(req, "_tla_from", None)), "att": 0, "ok": False,
                    "code": int(code) if code is not None else -1, "flag": False}
        if name == "SpUpdateRunStatus":
            req = fields["msg"]
            payload = req.payload if isinstance(req.payload, dict) else {}
            return {"type": "RUNSTATUS", "job": env.jname(req.get_header(env.CELL_JOB_ID_HEADER)), "cl": "None",
                    "att": 0, "ok": False, "code": 0, "flag": bool(payload.get("execution_error", False))}
        m = fields.get("msg")
        if isinstance(m, dict):
            return m
        return None

    def _update_side_tables(self, name, fields, frame):
        env = self.env
        if name == "RunnerTryNext" and fields.get("check"):
            self.att += 1
            self.current_check_att = self.att
        elif name == "CpCheckResource":
            cl = self._client_of_engine(fields.get("engine"))
            tok = fields.get("token")
            rm = env.cps[cl].rm
            if tok and tok in rm.reserved_resources:
                req = fields["msg"]
                self.token_info[(cl, tok)] = (getattr(req, "_tla_att", -1), req.get_header("job_id"))
        elif name == "CpStartAllocate":
            cl = self._client_of_engine(fields.get("engine"))
            jid = fields["msg"].get_header("job_id")
            units = fields.get("units")
            if units and fields.get("branch") != "already_started" and not (frame is not None and frame.failed):
                self.starting[(cl, jid)] = list(units.get("gpu", []))
        elif name == "CpStartRegister":
            if frame is not None and frame.failed:
                self.starting.pop((fields.get("cl"), fields.get("job")), None)
        elif name == "CpStartLaunch":
            key = (fields.get("cl"), fields.get("job"))
            self.starting.pop(key, None)
            units = fields.get("units")
            self.allocated[key] = list(units.get("gpu", [])) if units else []
        elif name == "CpStartLaunchFail":
            self.starting.pop((fields.get("cl"), fields.get("job")), None)
        elif name == "CpChildFinished":
            self.allocated.pop((fields.get("cl"), fields.get("job")), None)

    # ------------------------------------------------------------------ emission
    def _write_event(self, name, fields, error, frame):
        env = self.env
        self._update_side_tables(name, fields, frame)
        env.resource_observer.check_projection(name)
        evt = {"name": name}
        job = fields.get("job")
        cl = fields.get("cl")
        if job is None and fields.get("uri"):
            job = os.path.basename(str(fields["uri"]).rstrip("/"))  # RMW halves: the job whose meta is updated
        if name in ("CpCheckResource", "CpCancelResource", "CpStartAllocate", "CpStartAllocateAppMissing"):
            cl = self._client_of_engine(fields.get("engine"))
        if name == "CpTick":
            cl = env.client_name_of_rm(fields.get("rm"))
        evt["job"] = env.jname(job) if job is not None else "None"
        evt["cl"] = env.cname(cl) if cl is not None else "None"
        msg = self._msg_identity(name, fields)
        if msg is not None:
            evt["msg"] = msg
            if evt["job"] == "None" and msg.get("job") not in (None, "None"):
                evt["job"] = msg["job"]  # informational only (message actions are matched through msg)
                job = env.real_job(msg["job"])
            if evt["cl"] == "None" and msg.get("cl") not in (None, "None"):
                evt["cl"] = msg["cl"]
                cl = env.real_client(msg["cl"])
        arg = fields.get("arg")
        if arg is not None:
            evt["arg"] = env.map_arg(arg)
        evt["state"] = self.snapshot()
        self._seq += 1
        line = {"tag": "trace", "seq": self._seq, "ts": str(time.time_ns()), "thread": threading.current_thread().name,
                "event": evt}
        if error:
            line["error"] = error
        self._fh.write(json.dumps(line, separators=(",", ":")) + "\n")
        self._fh.flush()
        rec = dict(evt)
        rec["seq"] = self._seq
        rec["real_job"] = job
        rec["real_cl"] = cl
        with self._cv:
            self.events.append(rec)
            self._cv.notify_all()

    def write_config(self, cfg: dict):
        line = {"tag": "config", "ts": str(time.time_ns())}
        line.update(cfg)
        self._fh.write(json.dumps(line, separators=(",", ":")) + "\n")
        self._fh.flush()

    def close(self):
        # Freeze under the writer lock. A hook already waiting for the lock sees
        # _closed in _begin and cannot append after the report hashes the file.
        with self._T:
            self._closed = True
            self._fh.flush()
            self._fh.close()

    # ------------------------------------------------------------------ snapshot
    def _rec(self, d):
        env = self.env
        if d is None:
            return {"present": False, "finished": False, "exe_error": False, "rc": 0, "parts": []}
        parts = d.get(RunProcessKey.PARTICIPANTS) or {}
        names = sorted(env.cname(c.name) for c in list(parts.values()))
        rc = d.get(RunProcessKey.PROCESS_RETURN_CODE)
        return {
            "present": True,
            "finished": bool(d.get(RunProcessKey.PROCESS_FINISHED, False)),
            "exe_error": bool(d.get(RunProcessKey.PROCESS_EXE_ERROR, False)),
            "rc": 0 if rc is None else int(rc),
            "parts": names,
        }

    def snapshot(self) -> dict:
        env = self.env
        runner = env.runner
        running = dict(runner.running_jobs)
        pending = dict(runner._pending_client_outcomes)
        latched = dict(runner._finished_job_states)
        rps = dict(env.engine.run_processes)
        excs = dict(env.engine.exception_run_processes)
        tagged = []
        jobs = {}
        for jid in env.job_ids:
            jn = env.jname(jid)
            meta = env.read_meta(jid)
            if meta is None:
                status = "DELETED"
                count = self._last_count.get(jid, 0)
                tag = self._last_tag.get(jid, False)
            else:
                status = meta.get("status")
                count = int(meta.get("schedule_count", 0) or 0)
                tag = env.has_scheduled_tag(jid)
                self._last_count[jid] = count
                self._last_tag[jid] = tag
            if tag:
                tagged.append(jn)
            job_obj = running.get(jid)
            if job_obj is not None:
                self._last_job_obj[jid] = job_obj
            else:
                job_obj = self._last_job_obj.get(jid)
            run_aborted = bool(job_obj.run_aborted) if job_obj is not None else False
            pset = pending.get(jid)
            jobs[jn] = {
                "status": status,
                "schedule_count": count,
                "run_aborted": run_aborted,
                "pending": {
                    "present": pset is not None,
                    "set": sorted(env.cname(c) for c in list(pset)) if pset is not None else [],
                },
                "latched": latched[jid].status.value if jid in latched else "None",
                "run_process": self._rec(rps.get(jid)),
                "exception_process": self._rec(excs.get(jid)),
                "sj": env.sj_state(jid),
            }
        clients = {}
        for cl in env.client_names:
            cp = env.cps[cl]
            if not cp.alive:
                # Trace.tla checks only alive after CP death. Do not emit the
                # dead parent's frozen pools/registrations as unchecked state.
                clients[env.cname(cl)] = {"alive": False}
                continue
            free = [env.unit_name(u) for u in list(cp.rm.resources.get("gpu", []))]
            reserved = []
            for tok, (res, ttl) in list(cp.rm.reserved_resources.items()):
                att, jid = self.token_info.get((cl, tok), (-1, None))
                reserved.append(
                    {"att": att, "job": env.jname(jid), "units": [env.unit_name(u) for u in res.get("gpu", [])],
                     "ttl": ttl}
                )
            cjobs = {}
            regs = dict(cp.executor.run_processes)
            for jid in env.job_ids:
                reg = regs.get(jid)
                if reg is None:
                    registration = {"present": False, "st": "None", "attached": False, "abort_req": False}
                else:
                    handle = reg.get(RunProcessKey.JOB_HANDLE)
                    attached = True
                    if isinstance(handle, _PendingJobHandle):
                        attached = handle._job_handle is not None
                    registration = {
                        "present": True,
                        "st": STATUS_NAMES.get(reg.get(RunProcessKey.STATUS), str(reg.get(RunProcessKey.STATUS))),
                        "attached": attached,
                        "abort_req": bool(reg.get(_ABORT_REQUESTED_KEY, False)),
                    }
                st_units = self.starting.get((cl, jid))
                cjobs[env.jname(jid)] = {
                    "registration": registration,
                    "starting": {"present": st_units is not None,
                                 "units": [env.unit_name(u) for u in (st_units or [])]},
                    "allocated": [env.unit_name(u) for u in self.allocated.get((cl, jid), [])],
                    "cj": env.cj_state(cl, jid),
                }
            clients[env.cname(cl)] = {"alive": cp.alive, "free": free, "reserved": reserved, "jobs": cjobs}
        return {
            "tagged": sorted(tagged),
            "scheduled_jobs": sorted(env.jname(j) for j in list(env.scheduler.scheduled_jobs)),
            "running_jobs": sorted(env.jname(j) for j in running.keys()),
            "sessions": sorted(env.cname(c.name) for c in list(env.client_manager.clients.values())),
            "jobs": jobs,
            "clients": clients,
        }

    # ------------------------------------------------------------------ scenario helpers
    def wait_event(self, pred, timeout=30.0, start=0, desc=""):
        """Block until an emitted event (index >= start) satisfies pred; returns (index, event)."""
        deadline = time.monotonic() + timeout
        with self._cv:
            i = start
            while True:
                while i < len(self.events):
                    if pred(self.events[i]):
                        return i, self.events[i]
                    i += 1
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"timed out waiting for event {desc or pred}")
                self._cv.wait(timeout=min(remaining, 0.5))

    def count(self):
        with self._cv:
            return len(self.events)

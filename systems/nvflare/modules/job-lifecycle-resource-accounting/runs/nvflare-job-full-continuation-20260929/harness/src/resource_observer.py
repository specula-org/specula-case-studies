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
"""Observe actual allocation/free calls separately from model-event side tables."""

import copy
import sys
import threading
import time
from collections import Counter


class ResourceObserver:
    def __init__(self, env):
        self.env = env
        self.active = {}
        self.calls = []
        self.checks = 0
        self.mismatches = []

    def install(self, cp):
        for operation in ("allocate_resources", "free_resources"):
            original = getattr(cp.rm, operation)

            def observed(*args, _original=original, _operation=operation, **kwargs):
                caller = sys._getframe(1)
                entry = {"operation": _operation, "client": cp.name, "ts": time.time_ns(),
                         "thread": threading.current_thread().name,
                         "caller": f"{caller.f_code.co_filename}:{caller.f_lineno}",
                         "arguments": copy.deepcopy({k: v for k, v in kwargs.items() if k != "fl_ctx"}),
                         "free_before": list(cp.rm.resources["gpu"])}
                try:
                    result = _original(*args, **kwargs)
                except BaseException as exc:
                    entry["error"] = repr(exc)
                    raise
                else:
                    entry["return"] = copy.deepcopy(result)
                    key = (cp.name, kwargs["token"])
                    if _operation == "allocate_resources":
                        self.active[key] = list(result.get("gpu", []))
                    else:
                        self.active.pop(key, None)
                    return result
                finally:
                    entry["free_after"] = list(cp.rm.resources["gpu"])
                    self.calls.append(entry)

            setattr(cp.rm, operation, observed)

    def check_projection(self, event_name):
        tr = self.env.tracer
        for cl, cp in self.env.cps.items():
            if not cp.alive:
                continue  # CP crash intentionally freezes its waiter and local ownership.
            for jid in self.env.job_ids:
                actual = Counter()
                for (owner, token), units in self.active.items():
                    if owner == cl and tr.token_info.get((cl, token), (None, None))[1] == jid:
                        actual.update(units)
                projected = Counter(tr.starting.get((cl, jid), [])) + Counter(tr.allocated.get((cl, jid), []))
                self.checks += 1
                if actual != projected:
                    mismatch = {"after": event_name, "seq": tr._seq + 1, "client": cl, "job": jid,
                                "calls_outstanding": dict(actual), "projected": dict(projected)}
                    self.mismatches.append(mismatch)
                    tr._harness_error(f"allocation observation differs from event projection: {mismatch}")

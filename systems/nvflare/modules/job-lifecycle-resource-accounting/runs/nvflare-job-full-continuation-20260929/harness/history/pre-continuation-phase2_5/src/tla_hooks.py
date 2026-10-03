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
"""Specula TLA+ trace-validation observation hooks (harness-only; copied in by harness/apply.sh).

Every function here is a no-op unless a tracer has been installed with ``install()``.  Product code
calls these hooks at the instrumentation points listed in harness/INSTRUMENTATION.md.  The hooks never
change control flow, locking or return values of the product code; the only effects when a tracer is
installed are: (1) serialising traced steps under one process-wide trace lock, (2) appending one NDJSON
line per traced step and (3) optional reproduction gates that pause a thread at a named point.

Section model (implemented by the tracer):
  * ``section(name)`` / ``begin(name)`` .. ``end(name)`` delimit one traced atomic step.  The trace lock is
    taken at the beginning and the post-state snapshot is emitted at the end.  A section opened while the
    thread already holds an open section is absorbed into the outer one (no separate event).
  * ``end(name)`` / ``cancel(name)`` only act when ``name`` matches the innermost open section.
  * ``emit(name)`` writes an intermediate event inside the open section; ``event(name)`` is a section of
    its own (absorbed if a section is already open).
"""

_tracer = None


def install(tracer):
    global _tracer
    _tracer = tracer


def uninstall():
    global _tracer
    _tracer = None


def active() -> bool:
    return _tracer is not None


class _NullSection:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        return False

    def cancel(self):
        pass

    def set(self, **fields):
        pass

    def rename(self, name):
        pass


_NULL = _NullSection()


def section(name, **fields):
    t = _tracer
    if t is None:
        return _NULL
    return t.section(name, **fields)


def begin(name, **fields):
    t = _tracer
    if t is not None:
        t.begin(name, **fields)


def end(name=None, **fields):
    t = _tracer
    if t is not None:
        t.end(name, **fields)


def end_open(**fields):
    """Close (emit) whatever section is open on this thread, if any."""
    t = _tracer
    if t is not None:
        t.end_open(**fields)


def cancel(name=None):
    t = _tracer
    if t is not None:
        t.cancel(name)


def emit(name, **fields):
    t = _tracer
    if t is not None:
        t.emit(name, **fields)


def event(name, **fields):
    t = _tracer
    if t is not None:
        t.event(name, **fields)


def rename(name, **fields):
    t = _tracer
    if t is not None:
        t.rename(name, **fields)


def set_fields(**fields):
    t = _tracer
    if t is not None:
        t.set_fields(**fields)


def gate(point, **info):
    t = _tracer
    if t is not None:
        t.gate(point, **info)


def context(tag):
    t = _tracer
    if t is None:
        return _NULL
    return t.context(tag)


def in_context(tag) -> bool:
    t = _tracer
    if t is None:
        return False
    return t.in_context(tag)


def note(key, value):
    t = _tracer
    if t is not None:
        t.note(key, value)


def take(key, default=None):
    t = _tracer
    if t is None:
        return default
    return t.take(key, default)

#!/usr/bin/env python3
"""Atomic raw-event emitter shared by the warmreboot trace probes."""

import json
import os
import socket
import threading
import time
import uuid
from typing import Any, Dict, Optional

_lock = threading.Lock()
_sequence = 0
_process_instance = os.environ.get(
    "SPECULA_PROCESS_INSTANCE",
    f"{os.getpid()}-{time.time_ns()}-{uuid.uuid4().hex[:12]}",
)


def _next_sequence() -> int:
    global _sequence
    with _lock:
        _sequence += 1
        return _sequence


def emit(
    name: str,
    source: str,
    observed: Optional[Dict[str, Any]] = None,
    *,
    asic: Optional[str] = None,
    component: Optional[str] = None,
) -> None:
    """Send one complete JSON datagram; disabled unless the harness socket is set."""
    socket_path = os.environ.get("SPECULA_TRACE_SOCKET")
    if not socket_path:
        return

    event: Dict[str, Any] = {
        "name": name,
        "source": source,
        "process_instance": _process_instance,
        "local_seq": _next_sequence(),
        "monotonic_ns": time.monotonic_ns(),
        "observed": observed or {},
    }
    if asic:
        event["asic"] = asic
    if component:
        event["component"] = component

    payload = json.dumps(
        {"tag": "raw", "ts": time.time_ns(), "event": event},
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    if len(payload) > 60_000:
        raise ValueError(f"trace event {name} exceeds safe Unix datagram size")

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
            client.sendto(payload, socket_path)
    except OSError:
        if os.environ.get("SPECULA_TRACE_STRICT") == "1":
            raise

"""
TLA+ Trace Emission Module for SONiC Warm Reboot.

Thread-safe NDJSON writer. Each event line includes:
  - tag: "trace"
  - timestamp: ISO 8601 with microsecond precision
  - event: {name, component, state, detail}

Usage:
    from tla_trace import TraceWriter
    tw = TraceWriter("traces/scenario.ndjson")
    tw.emit("StartWarmReboot", "orchagent", {"phase": "Sanity"})
    tw.close()
"""

import json
import os
import threading
import time
from datetime import datetime, timezone


class TraceWriter:
    """Thread-safe NDJSON trace writer."""

    def __init__(self, filepath):
        self._filepath = filepath
        os.makedirs(os.path.dirname(filepath), exist_ok=True)
        self._file = open(filepath, "w")
        self._lock = threading.Lock()
        self._closed = False

    def emit(self, event_name, component, state, detail=None):
        """Write one NDJSON trace line.

        Args:
            event_name: TLA+ action name (e.g., "StartWarmReboot")
            component: Component ID (e.g., "orchagent", "syncd")
            state: Dict of state fields (phase, componentState, etc.)
            detail: Optional dict of action-specific fields (key, cacheState)
        """
        record = {
            "tag": "trace",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "event": {
                "name": event_name,
                "component": component,
                "state": state,
            },
        }
        if detail:
            record["event"]["detail"] = detail

        line = json.dumps(record, separators=(",", ":"))
        with self._lock:
            if not self._closed:
                self._file.write(line + "\n")
                self._file.flush()

    def emit_config(self, config):
        """Write a config line (tag=config) as the first line."""
        record = {
            "tag": "config",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "config": config,
        }
        line = json.dumps(record, separators=(",", ":"))
        with self._lock:
            if not self._closed:
                self._file.write(line + "\n")
                self._file.flush()

    def close(self):
        with self._lock:
            if not self._closed:
                self._file.close()
                self._closed = True

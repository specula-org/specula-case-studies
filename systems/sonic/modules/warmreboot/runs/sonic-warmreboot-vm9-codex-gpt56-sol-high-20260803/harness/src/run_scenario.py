#!/usr/bin/env python3
"""Run one real-code scenario while collecting atomic Unix datagrams."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
from typing import Any, Dict, List

from trace_reducer import enrich, write_ndjson


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not command:
        parser.error("scenario command is required")

    socket_path = os.path.join(tempfile.gettempdir(), f"specula-wr-{os.getpid()}.sock")
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    server.bind(socket_path)
    server.settimeout(0.1)
    events: List[Dict[str, Any]] = []
    stopping = threading.Event()

    def collect() -> None:
        while not stopping.is_set():
            try:
                payload = server.recv(65536)
            except socket.timeout:
                continue
            events.append(json.loads(payload.decode("utf-8")))

    collector = threading.Thread(target=collect, name="specula-collector", daemon=True)
    collector.start()
    env = os.environ.copy()
    env["SPECULA_TRACE_SOCKET"] = socket_path
    env["SPECULA_TRACE_STRICT"] = "1"

    completed = subprocess.run(command, env=env, check=False)
    time.sleep(0.2)
    stopping.set()
    collector.join(timeout=2)
    server.close()
    os.unlink(socket_path)

    write_ndjson(args.raw, events)
    if completed.returncode != 0:
        return completed.returncode
    write_ndjson(args.trace, enrich(events))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

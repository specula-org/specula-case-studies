#!/usr/bin/env python3
"""Measure guest CPUs before executing the unchanged regression fixture."""
from pathlib import Path
import stat
import sys

INIT = b'''#!/bin/busybox sh
set -eu
count=$(/bin/nproc_probe | { read online affinity; echo "$online"; })
printf 'WR_GUEST_NPROC %s\\n' "$count"
exec /fixture "$@"
'''

binary, busybox, probe, destination = map(Path, sys.argv[1:])
with destination.open("wb") as stream:
    for index, (name, payload, mode) in enumerate([
        ("bin", b"", stat.S_IFDIR | 0o755),
        ("bin/busybox", busybox.read_bytes(), stat.S_IFREG | 0o755),
        ("bin/nproc_probe", probe.read_bytes(), stat.S_IFREG | 0o755),
        ("init", INIT, stat.S_IFREG | 0o755),
        ("fixture", binary.read_bytes(), stat.S_IFREG | 0o755),
        ("TRAILER!!!", b"", 0),
    ], 1):
        name = name.encode() + b"\0"
        fields = [index, mode, 0, 0, 1, 0, len(payload), 0, 0, 0, 0, len(name), 0]
        header = b"070701" + b"".join(f"{v:08x}".encode() for v in fields)
        stream.write(header + name)
        stream.write(b"\0" * (-(len(header) + len(name)) % 4))
        stream.write(payload)
        stream.write(b"\0" * (-len(payload) % 4))

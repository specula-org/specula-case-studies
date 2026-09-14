#!/usr/bin/env python3
"""Restore only the exact files owned by this harness; preserve other changes."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parents[1]
SOURCE = Path("/home/ubuntu/nvflare-runs-20260913/source-fedavg")
HEAD = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"


def main():
    assert subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip() == HEAD
    owned = json.loads((HERE / "applied.json").read_text())
    restore = {}
    for name, expected in owned.items():
        path = SOURCE / name
        if name == "nvflare/_specula_trace.py":
            if path.exists():
                assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, f"Unowned edits: {name}"
                restore[name] = None
            continue
        original = subprocess.check_output(["git", "-C", str(SOURCE), "show", f"{HEAD}:{name}"])
        current = path.read_bytes()
        assert current == original or hashlib.sha256(current).hexdigest() == expected, f"Unowned edits: {name}"
        restore[name] = original
    # Validate every file before making any changes.
    for name, original in restore.items():
        if original is None:
            (SOURCE / name).unlink()
        else:
            (SOURCE / name).write_bytes(original)
    print("Removed only harness-owned source instrumentation; traces and reports retained.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Apply/reverse only the owned patch and copied files, protecting other edits."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

HARNESS = Path(__file__).resolve().parent
REVISION = "3ac0104a567092139534c9022205d02281a2da41"
FILES = {"tla_trace.rs": "tla_trace.rs", "specula_trace.rs": "tests/specula_trace.rs",
         "controller.rs": "tests/specula_harness/controller.rs",
         "scenarios.rs": "tests/specula_harness/scenarios.rs"}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    action, source_arg = sys.argv[1:]
    source = Path(source_arg).resolve()
    def git(*args, check=True):
        return subprocess.run(["git", "-C", str(source), *args], text=True,
                              capture_output=True, check=check)
    if git("rev-parse", "HEAD").stdout.strip() != REVISION:
        raise SystemExit("Source revision differs from pinned instrumentation revision")
    patch = str(HARNESS / "patches/instrumentation.patch")
    key = hashlib.sha256(str(source).encode()).hexdigest()[:16]
    manifest = HARNESS / "runtime" / f"applied-{key}.json"
    previous = json.loads(manifest.read_text()) if manifest.exists() else {}
    # Preflight all copies before any mutation; permit known previous copies.
    for name, relative in FILES.items():
        destination = source / relative
        for component in (destination, *destination.parents):
            if component == source:
                break
            if component.is_symlink():
                raise SystemExit(f"Refusing symlink target or parent: {component}")
        if destination.exists():
            if not destination.is_file():
                raise SystemExit(f"Preserving non-file target: {destination}")
            actual = digest(destination)
            expected = previous.get(relative, digest(HARNESS / "src" / name))
            if actual not in {expected, digest(HARNESS / "src" / name)}:
                raise SystemExit(f"Preserving edited target: {destination}")
    applied = git("apply", "--reverse", "--check", patch, check=False).returncode == 0
    if action == "apply":
        if not applied:
            git("apply", "--check", patch)
            git("apply", patch)
        for name, relative in FILES.items():
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(HARNESS / "src" / name, destination)
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps({relative: digest(source / relative) for relative in FILES.values()}, indent=2) + "\n")
        print(f"Instrumentation applied: {source}")
    elif action == "clean":
        if applied:
            git("apply", "--reverse", patch)
        else:
            git("apply", "--check", patch)  # already clean; unexpected edits fail closed
        for relative in FILES.values():
            (source / relative).unlink(missing_ok=True)
        directory = source / "tests/specula_harness"
        if directory.exists() and not any(directory.iterdir()):
            directory.rmdir()
        manifest.unlink(missing_ok=True)
        print(f"Owned instrumentation removed: {source}")
    else:
        raise SystemExit("Expected apply or clean")

if __name__ == "__main__":
    main()

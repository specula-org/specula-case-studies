#!/usr/bin/env python3
"""Record the source, test, boot artifact, and validator identities for a run."""

import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys

harness = Path(sys.argv[1]).resolve()
source = harness.parent.parent / "source"
changed = subprocess.check_output(
    ["git", "-C", str(source), "diff", "--name-only"], text=True
).splitlines()
paths = [source / name for name in changed]
paths += [source / "kernel/core/src/tla_trace.rs", source / "Cargo.lock"]
paths += list((harness / "src").glob("*.*"))
paths += list(harness.glob("*.sh"))
paths += list((harness / "patches").glob("*.patch"))
paths += list((harness.parent / "spec").glob("*.tla"))
paths += list((harness.parent / "spec").glob("Trace*.cfg"))
paths += list((harness / "config").glob("*.cfg"))
paths += [
    harness / "build/initramfs.cpio",
    harness / "build/initramfs/scenarios",
    harness / "build/initramfs/init",
    harness / "build/scenarios-linux",
    source / "target/osdk/asterinas/asterinas-osdk-bin.elf",
    source / "target/osdk/asterinas/bundle.toml",
]
manifest = {
    "recorded_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "source_commit": subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip(),
    "image": (harness / "logs/image.txt").read_text().strip(),
    "host_kernel": (harness / "logs/linux-version.txt").read_text().strip(),
    "guest_exit": int((harness / "logs/guest-exit.txt").read_text()),
    "sha256": {
        str(path.relative_to(harness.parent.parent)):
            hashlib.sha256(path.read_bytes()).hexdigest()
        for path in paths if path.is_file()
    },
}
(harness / "raw/run.json").write_text(json.dumps(manifest, indent=2) + "\n")

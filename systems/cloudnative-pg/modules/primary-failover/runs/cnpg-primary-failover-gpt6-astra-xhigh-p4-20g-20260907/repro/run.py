#!/usr/bin/env python3
"""Run the archived CR-4 test with isolated source and resource names."""

import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import uuid


REVISION = "d5f3426e161076322086b58c886cf8e7435f0e1b"
UPSTREAM = "https://github.com/cloudnative-pg/cloudnative-pg.git"


def command(arguments, timeout=180):
    return subprocess.run(arguments, check=True, timeout=timeout)


def interrupt_run(signum, frame):
    raise KeyboardInterrupt(f"interrupted by signal {signum}")


def load_test(source):
    script = Path(__file__).with_name("test_bugCR-4_stale_quorum_watch.py")
    spec = importlib.util.spec_from_file_location("archived_cr4", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    suffix = uuid.uuid4().hex[:12]
    module.CLUSTER = f"cnpg-cr4-{suffix}"
    module.CONTEXT = f"kind-{module.CLUSTER}"
    module.CONTROL = f"{module.CLUSTER}-control-plane"
    module.PROXY_CONTAINER = f"cnpg-cr4-proxy-{suffix}"
    module.OPERATOR_CONTAINER = f"cnpg-cr4-operator-{suffix}"
    module.SOURCE_REPO = source
    module.OPERATOR_MANIFEST = source / "releases" / "cnpg-1.30.0.yaml"
    module.KEEP_CLUSTER = False
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="create a disposable Kind cluster and run the fault test")
    parser.add_argument("--source-repo", type=Path, help="local Git repository containing the pinned source revision")
    arguments = parser.parse_args()
    if not arguments.execute:
        parser.print_help()
        return
    for executable in ("docker", "kind", "kubectl", "openssl", "git"):
        if shutil.which(executable) is None:
            parser.error(f"missing required executable: {executable}")
    command(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=30)
    source_origin = str(arguments.source_repo.resolve()) if arguments.source_repo else UPSTREAM
    signal.signal(signal.SIGTERM, interrupt_run)
    with tempfile.TemporaryDirectory(prefix="cnpg-cr4-source-") as temporary:
        scratch = Path(temporary)
        source = scratch / "source"
        command(["git", "init", "-q", str(source)])
        command(["git", "-C", str(source), "fetch", "-q", "--depth=1", source_origin, REVISION], timeout=600)
        command(["git", "-C", str(source), "checkout", "-q", "--detach", REVISION])
        module = load_test(source)
        previous_kubeconfig = os.environ.get("KUBECONFIG")
        os.environ["KUBECONFIG"] = str(scratch / "kubeconfig")
        print(f"test_cluster={module.CLUSTER}", flush=True)
        print(f"test_containers={module.PROXY_CONTAINER},{module.OPERATOR_CONTAINER}", flush=True)
        print(f"source_revision={REVISION}", flush=True)
        try:
            module.main()
        finally:
            try:
                module.remove_test_environment()
            finally:
                if previous_kubeconfig is None:
                    os.environ.pop("KUBECONFIG", None)
                else:
                    os.environ["KUBECONFIG"] = previous_kubeconfig


if __name__ == "__main__":
    main()

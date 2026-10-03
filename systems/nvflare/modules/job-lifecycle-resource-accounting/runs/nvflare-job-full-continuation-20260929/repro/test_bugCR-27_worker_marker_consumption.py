#!/usr/bin/env python3
"""Reproduce CR-27: client job-worker bootstrap consumes root lifecycle markers."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path


REPO = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-27/worktree"
)
sys.path.insert(0, str(REPO))

from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.private.fed.app.client.worker_process import remove_restart_file  # noqa: E402


def make_workspace(root: Path) -> Workspace:
    (root / "startup").mkdir()
    (root / "local").mkdir()
    return Workspace(str(root), "site-1")


def wrapper_decision(root: Path) -> str:
    """Execute the marker-consuming branches from provisioned sub_start.sh."""
    script = r'''
if [[ ! -f "$WORKSPACE/pid.fl" ]]; then
  echo START_NO_PID
  exit 0
fi
pid=`cat "$WORKSPACE/pid.fl"`
kill -0 ${pid} 2> /dev/null 1>&2
if [[ $? -ne 0 ]]; then
  if [[ -f "$WORKSPACE/shutdown.fl" ]]; then
    echo GRACEFUL_SHUTDOWN
    exit 0
  fi
  echo RESTART_DEAD_PROCESS
  exit 0
fi
if [[ -f "$WORKSPACE/shutdown.fl" ]]; then
  echo SHUTDOWN_LIVE_PROCESS
  exit 0
fi
if [[ -f "$WORKSPACE/restart.fl" ]]; then
  echo RESTART_LIVE_PROCESS
  exit 0
fi
echo KEEP_RUNNING
'''
    env = os.environ.copy()
    env["WORKSPACE"] = str(root)
    result = subprocess.run(["bash", "-c", script], check=True, capture_output=True, text=True, env=env)
    return result.stdout.strip()


def touch_marker(root: Path, name: str) -> None:
    marker = root / name
    marker.touch()
    assert marker.exists(), f"{name} was not created"


def run_shutdown_loss_case() -> None:
    with tempfile.TemporaryDirectory(prefix="cr27-shutdown-") as td:
        root = Path(td)
        workspace = make_workspace(root)
        dead_pid = 999999999
        try:
            os.kill(dead_pid, 0)
            raise RuntimeError(f"test picked live pid {dead_pid}")
        except ProcessLookupError:
            pass
        root.joinpath("pid.fl").write_text(f"{dead_pid}\n")

        touch_marker(root, "shutdown.fl")
        before = wrapper_decision(root)
        print(f"shutdown control before worker bootstrap: {before}")
        if before != "GRACEFUL_SHUTDOWN":
            raise AssertionError(f"expected GRACEFUL_SHUTDOWN before cleanup, got {before}")

        remove_restart_file(workspace)

        shutdown_exists = (root / "shutdown.fl").exists()
        after = wrapper_decision(root)
        print(f"shutdown marker exists after worker bootstrap cleanup: {shutdown_exists}")
        print(f"shutdown consumer decision after worker bootstrap: {after}")
        if shutdown_exists:
            raise AssertionError("worker bootstrap did not remove shutdown.fl")
        if after != "RESTART_DEAD_PROCESS":
            raise AssertionError(f"expected RESTART_DEAD_PROCESS after cleanup, got {after}")
        print("BUG_TRIGGERED shutdown.fl consumed; wrapper restarts instead of exiting")


def run_restart_loss_case() -> None:
    with tempfile.TemporaryDirectory(prefix="cr27-restart-") as td:
        root = Path(td)
        workspace = make_workspace(root)
        root.joinpath("pid.fl").write_text(f"{os.getpid()}\n")

        touch_marker(root, "restart.fl")
        before = wrapper_decision(root)
        print(f"restart control before worker bootstrap: {before}")
        if before != "RESTART_LIVE_PROCESS":
            raise AssertionError(f"expected RESTART_LIVE_PROCESS before cleanup, got {before}")

        remove_restart_file(workspace)

        restart_exists = (root / "restart.fl").exists()
        after = wrapper_decision(root)
        print(f"restart marker exists after worker bootstrap cleanup: {restart_exists}")
        print(f"restart consumer decision after worker bootstrap: {after}")
        if restart_exists:
            raise AssertionError("worker bootstrap did not remove restart.fl")
        if after != "KEEP_RUNNING":
            raise AssertionError(f"expected KEEP_RUNNING after cleanup, got {after}")
        print("RESTART_MARKER_CONSUMED live wrapper misses restart request")


def main() -> int:
    print("CR-27 reproduction: worker bootstrap cleanup vs shell lifecycle markers")
    print(f"source repo: {REPO}")
    run_shutdown_loss_case()
    run_restart_loss_case()
    print("RESULT: CR-27 reproduced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

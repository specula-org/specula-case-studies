#!/usr/bin/env python3
"""MC-3 reproduction driver for the SONiC SWSS DVS test environment.

The generated pytest case uses only normal operator/service interfaces: the
``config`` CLI, ``orchagent_restart_check``, and the supported SWSS warm-restart
stop/start helpers.  No application state is injected and no source is patched.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile


WORKTREE = Path(
    "/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/"
    "warmreboot/.specula-output/confirmation/MC-3/worktree"
)
TESTS_DIR = WORKTREE / "src/sonic-swss/tests"
IMAGE = "docker-sonic-vs:latest"


PYTEST_CASE = r'''
import time

from swsscommon import swsscommon


PORT = "Ethernet0"


def field(db_id, redis_sock, table_name, key, name):
    db = swsscommon.DBConnector(db_id, redis_sock, 0)
    table = swsscommon.Table(db, table_name)
    status, values = table.get(key)
    if not status:
        return None
    return dict(values).get(name)


def asic_admin(dvs):
    oid = dvs.asicdb.portnamemap[PORT]
    return field(
        swsscommon.ASIC_DB,
        dvs.redis_sock,
        "ASIC_STATE:SAI_OBJECT_TYPE_PORT",
        oid,
        "SAI_PORT_ATTR_ADMIN_STATE",
    )


def wait_value(read, expected, timeout=30):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = read()
        if last == expected:
            return last
        time.sleep(0.25)
    raise AssertionError("expected {!r}, last observed {!r}".format(expected, last))


def run_ok(dvs, command):
    rc, output = dvs.runcmd(command)
    assert rc == 0, "command failed: {} rc={} output={!r}".format(command, rc, output)
    return output.strip()


def test_mc3_config_update_after_consumer_freeze(dvs):
    # Level 0: establish a normal, observable baseline through the public CLI.
    run_ok(dvs, "config interface shutdown {}".format(PORT))
    wait_value(lambda: asic_admin(dvs), "false")
    print("LEVEL0_BASELINE port={} config=down asic=false".format(PORT))

    run_ok(dvs, "config warm_restart enable swss")
    try:
        freeze = run_ok(dvs, "/usr/bin/orchagent_restart_check -w 2000 -r 5")
        assert freeze == "RESTARTCHECK succeeded", freeze
        print("LEVEL0_FREEZE {}".format(freeze))

        # This is the ordinary operator API, issued only after freeze is acknowledged.
        run_ok(dvs, "config interface startup {}".format(PORT))
        config_admin = wait_value(
            lambda: field(swsscommon.CONFIG_DB, dvs.redis_sock, "PORT", PORT, "admin_status"),
            "up",
        )
        # PORT configuration is one of the tables PortsOrch consumes directly
        # from CONFIG_DB.  APPL_DB may therefore retain the pre-freeze value.
        app_admin = field(
            swsscommon.APPL_DB,
            dvs.redis_sock,
            "PORT_TABLE",
            PORT,
            "admin_status",
        )

        # Orchagent is frozen, so the real ASIC-facing consumer has not applied it yet.
        for _ in range(8):
            assert asic_admin(dvs) == "false"
            time.sleep(0.25)
        print(
            "PRE_RESTART_UPDATE config={} app={} asic={}".format(
                config_admin, app_admin, asic_admin(dvs)
            )
        )

        # Normal warm-restart lifecycle.  This asserts whether the queued update is
        # lost permanently or consumed by the downstream reconciliation mechanism.
        dvs.stop_swss()
        dvs.start_swss()
        post_restart = wait_value(lambda: asic_admin(dvs), "true", timeout=45)
        print("POST_RESTART_RECONCILIATION asic={}".format(post_restart))
        print("MASK_CONFIRMED queued post-freeze update was applied after SWSS restart")
    finally:
        # Leave the shared DVS fixture in its normal state for teardown.
        dvs.runcmd("config warm_restart disable swss")
        dvs.runcmd("config interface shutdown {}".format(PORT))
'''


def main() -> int:
    if os.geteuid() != 0:
        print("ERROR: run as root so the upstream DVS fixture can manage Docker", file=sys.stderr)
        return 2
    if not TESTS_DIR.is_dir():
        print("ERROR: missing sonic-swss tests directory: {}".format(TESTS_DIR), file=sys.stderr)
        return 2

    source = TESTS_DIR.parent / "orchagent/orchdaemon.cpp"
    text = source.read_text(encoding="utf-8")
    required = (
        "stop processing any new db data",
        "freezeAndHeartBeat(UINT_MAX, heartBeatInterval)",
    )
    if not all(marker in text for marker in required):
        print("ERROR: target checkout does not contain the audited freeze path", file=sys.stderr)
        return 2

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix="test_bugMC3_",
            suffix=".py",
            dir=TESTS_DIR,
            delete=False,
        ) as handle:
            handle.write(PYTEST_CASE)
            temporary = Path(handle.name)

        command = [
            sys.executable,
            "-m",
            "pytest",
            "-s",
            "-q",
            temporary.name,
            "--imgname={}".format(IMAGE),
        ]
        print("DVS_IMAGE={}".format(IMAGE))
        print("PYTEST_COMMAND={}".format(" ".join(command)))
        completed = subprocess.run(
            command,
            cwd=TESTS_DIR,
            text=True,
            timeout=15 * 60,
        )
        return completed.returncode
    except subprocess.TimeoutExpired:
        print("ERROR: DVS reproduction timed out after 900 seconds", file=sys.stderr)
        return 124
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())

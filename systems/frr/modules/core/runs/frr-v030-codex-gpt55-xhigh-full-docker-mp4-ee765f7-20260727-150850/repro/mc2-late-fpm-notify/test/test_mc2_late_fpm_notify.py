#!/usr/bin/env python
# SPDX-License-Identifier: ISC

import json
import os
import shlex
import sys

import pytest

CWD = os.path.dirname(os.path.realpath(__file__))
sys.path.append(os.path.join(CWD, "../"))

from lib import topotest
from lib.topogen import Topogen, TopoRouter, get_topogen
from lib.topolog import logger


pytestmark = [pytest.mark.bgpd]

PREFIX = "10.10.10.0/24"
WRAPPER_DIR = os.path.join(CWD, "frr-mc2-wrappers")
WRAPPED_DAEMONS = ("zebra", "bgpd", "mgmtd")
PATHS = {}


def _write_daemon_wrappers():
    os.makedirs(WRAPPER_DIR, exist_ok=True)
    trace_env = {
        name: os.environ.get(name, "")
        for name in (
            "SPECULA_TRACE_FILE",
            "SPECULA_NOTIFY_STATE",
            "SPECULA_PREFIX_P1",
            "SPECULA_PREFIX_P2",
            "SPECULA_TRACE_ROUTER",
        )
    }
    for daemon in WRAPPED_DAEMONS:
        path = os.path.join(WRAPPER_DIR, daemon)
        with open(path, "w", encoding="ascii") as f:
            f.write("#!/usr/bin/env bash\nset -e\n")
            for name, value in trace_env.items():
                f.write(f"export {name}={shlex.quote(value)}\n")
            f.write('router_name="${PWD##*/}"\n')
            f.write(
                'if [ -n "${SPECULA_TRACE_ROUTER:-}" ] && '
                '[ "$router_name" != "$SPECULA_TRACE_ROUTER" ]; then\n'
            )
            f.write(
                "unset SPECULA_TRACE_FILE SPECULA_NOTIFY_STATE "
                "SPECULA_PREFIX_P1 SPECULA_PREFIX_P2\n"
            )
            f.write("fi\n")
            f.write(f"exec /usr/lib/frr/{daemon} \"$@\"\n")
        os.chmod(path, 0o755)


def build_topo(tgen):
    _write_daemon_wrappers()
    tgen.add_router("r1")
    tgen.add_router("r2")

    switch = tgen.add_switch("s1")
    switch.add_link(tgen.gears["r1"])
    switch.add_link(tgen.gears["r2"])


def _path(router, name):
    return os.path.join(router.gearlogdir, name)


def _start_fpm_responder(router):
    PATHS.update(
        {
            "log": _path(router, "mc2_fpm_responder.log"),
            "stdout": _path(router, "mc2_fpm_responder.out"),
            "pid": _path(router, "mc2_fpm_responder.pid"),
            "ready": _path(router, "mc2_fpm_responder.ready"),
            "first": _path(router, "mc2_fpm_responder.first"),
            "second": _path(router, "mc2_fpm_responder.second"),
            "send": _path(router, "mc2_fpm_responder.send"),
            "sent": _path(router, "mc2_fpm_responder.sent"),
        }
    )

    cleanup = "rm -f " + " ".join(shlex.quote(v) for v in PATHS.values())
    router.run(cleanup)

    script = os.path.join(CWD, "mc2_fpm_responder.py")
    cmd = (
        f"python3 {shlex.quote(script)} "
        f"--prefix {shlex.quote(PREFIX)} "
        f"--log {shlex.quote(PATHS['log'])} "
        f"--ready {shlex.quote(PATHS['ready'])} "
        f"--first-seen {shlex.quote(PATHS['first'])} "
        f"--second-seen {shlex.quote(PATHS['second'])} "
        f"--send {shlex.quote(PATHS['send'])} "
        f"--sent {shlex.quote(PATHS['sent'])} "
        f"> {shlex.quote(PATHS['stdout'])} 2>&1 & echo $! > {shlex.quote(PATHS['pid'])}"
    )
    router.run(cmd)

    ok, _ = topotest.run_and_expect(
        lambda: os.path.exists(PATHS["ready"]), True, count=50, wait=0.2
    )
    assert ok, "FPM responder did not become ready"


def setup_module(mod):
    tgen = Topogen(build_topo, mod.__name__)
    tgen.start_topology()

    r1 = tgen.gears["r1"]
    r2 = tgen.gears["r2"]

    for router in (r1, r2):
        router.daemondir = WRAPPER_DIR
        router.net.daemondir = WRAPPER_DIR

    r1.load_frr_config(
        os.path.join(CWD, "r1", "frr.conf"),
        [
            (TopoRouter.RD_ZEBRA, "-M dplane_fpm_nl --asic-offload=notify_on_offload"),
            (TopoRouter.RD_BGP, None),
        ],
    )

    r2.load_frr_config(
        os.path.join(CWD, "r2", "frr.conf"),
        [
            (TopoRouter.RD_ZEBRA, None),
            (TopoRouter.RD_BGP, None),
            (TopoRouter.RD_STATIC, None),
        ],
    )

    _start_fpm_responder(r1)
    tgen.start_router()


def teardown_module(_mod):
    tgen = get_topogen()
    try:
        if PATHS.get("pid") and os.path.exists(PATHS["pid"]):
            r1 = tgen.gears.get("r1")
            if r1:
                r1.run(f"kill $(cat {shlex.quote(PATHS['pid'])}) 2>/dev/null || true")
    finally:
        tgen.stop_topology()


def _has_true(obj, keys):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in keys and value is True:
                return True
            if _has_true(value, keys):
                return True
    elif isinstance(obj, list):
        return any(_has_true(item, keys) for item in obj)
    return False


def _first_metric(obj):
    if isinstance(obj, dict):
        if "metric" in obj:
            return obj["metric"]
        for value in obj.values():
            found = _first_metric(value)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = _first_metric(item)
            if found is not None:
                return found
    return None


def _bgp_state(router):
    raw = router.vtysh_cmd(f"show bgp ipv4 unicast {PREFIX} json")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {
            "present": False,
            "fib_pending": False,
            "fib_installed": False,
            "metric": None,
            "raw": raw,
        }
    return {
        "present": bool(data),
        "fib_pending": _has_true(data, {"fibPending", "fibWaitForInstall"}),
        "fib_installed": _has_true(data, {"fibInstalled"}),
        "metric": _first_metric(data),
        "raw": raw,
    }


def _log_text():
    try:
        with open(PATHS["log"], "r", encoding="ascii") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def _log_contains(needle):
    return needle in _log_text()


def _trace_counts():
    path = os.environ.get("SPECULA_TRACE_FILE")
    counts = {}
    if not path or not os.path.exists(path):
        return counts
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                event = json.loads(line).get("event", {})
            except json.JSONDecodeError:
                continue
            if event.get("prefix") != "p1":
                continue
            name = event.get("name")
            counts[name] = counts.get(name, 0) + 1
    return counts


def test_late_fpm_notify_marks_current_bgp_route_installed():
    tgen = get_topogen()
    if tgen.routers_have_failure():
        pytest.skip(tgen.errors)

    r1 = tgen.gears["r1"]
    r2 = tgen.gears["r2"]

    logger.info("MC2 Level 0/1: wait for normal BGP route and first delayed FPM route frame")
    ok, _ = topotest.run_and_expect(
        lambda: _log_contains("target_route count=1"), True, count=90, wait=1
    )
    assert ok, "FPM responder did not receive first BGP route frame"

    ok, _ = topotest.run_and_expect(
        lambda: _bgp_state(r1)["fib_pending"] and not _bgp_state(r1)["fib_installed"],
        True,
        count=60,
        wait=1,
    )
    assert ok, "BGP route did not remain pending before any FPM offload notification"
    initial = _bgp_state(r1)
    print(
        "MC2_RESULT before_second_update "
        f"fibPending={str(initial['fib_pending']).lower()} "
        f"fibInstalled={str(initial['fib_installed']).lower()} "
        f"metric={initial['metric']}"
    )

    logger.info("Change r2 outbound MED so r1 sends a second route generation to Zebra")
    r2.vtysh_cmd(
        "configure terminal\n"
        "route-map OUT permit 10\n"
        " set metric 200\n"
    )
    r2.vtysh_cmd("clear ip bgp 192.0.2.1 soft out")

    ok, _ = topotest.run_and_expect(
        lambda: _log_contains("target_route count=2"), True, count=90, wait=1
    )
    assert ok, "FPM responder did not receive second BGP route frame"

    before_stale = _bgp_state(r1)
    print(
        "MC2_RESULT before_stale_notify "
        f"fibPending={str(before_stale['fib_pending']).lower()} "
        f"fibInstalled={str(before_stale['fib_installed']).lower()} "
        f"metric={before_stale['metric']}"
    )
    assert before_stale["fib_pending"], before_stale["raw"]
    assert not before_stale["fib_installed"], before_stale["raw"]

    with open(PATHS["send"], "w", encoding="ascii") as f:
        f.write("send stale first now\n")

    ok, _ = topotest.run_and_expect(
        lambda: os.path.exists(PATHS["sent"]), True, count=50, wait=0.2
    )
    assert ok, "FPM responder did not send the delayed first notification"

    ok, _ = topotest.run_and_expect(
        lambda: _bgp_state(r1)["fib_installed"] and not _bgp_state(r1)["fib_pending"],
        True,
        count=60,
        wait=0.5,
    )
    assert ok, _bgp_state(r1)["raw"]
    after = _bgp_state(r1)

    log = _log_text()
    counts = _trace_counts()
    print(f"MC2_RESULT fpm_target_route_frames={log.count('MC2_FPM target_route')}")
    print(f"MC2_RESULT sent_stale_first={'sent_stale_first=true' in log}")
    print(f"MC2_RESULT sent_current_second={'sent_current_second=true' in log}")
    print(
        "MC2_RESULT trace_counts "
        f"rib_addnode={counts.get('rib_addnode', 0)} "
        f"dplane_ctx_route_init={counts.get('dplane_ctx_route_init', 0)} "
        f"bgp_zebra_route_install={counts.get('bgp_zebra_route_install', 0)}"
    )
    print(
        "MC2_RESULT after_stale_notify "
        f"fibPending={str(after['fib_pending']).lower()} "
        f"fibInstalled={str(after['fib_installed']).lower()} "
        f"metric={after['metric']}"
    )
    print("MC2_RESULT wrong_installed_from_stale_notify=true")

    assert "sent_stale_first=true" in log
    assert "sent_current_second=false" in log


if __name__ == "__main__":
    args = ["-s"] + sys.argv[1:]
    sys.exit(pytest.main(args))

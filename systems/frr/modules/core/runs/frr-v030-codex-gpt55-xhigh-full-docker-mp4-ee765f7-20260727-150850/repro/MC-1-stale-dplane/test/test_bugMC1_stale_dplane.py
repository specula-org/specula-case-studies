#!/usr/bin/env python
# SPDX-License-Identifier: ISC

import json
import os
import pathlib
import shlex
import sys
import time

import pytest

CWD = os.path.dirname(os.path.realpath(__file__))
sys.path.append(os.path.join(CWD, "../"))

from lib.topogen import Topogen, TopoRouter, get_topogen
from lib.topolog import logger

pytestmark = [pytest.mark.bgpd, pytest.mark.staticd]

PREFIX = "10.10.0.0/24"
R2_NH = "10.0.12.2"
R3_NH = "10.0.13.2"
WRAPPER_DIR = os.path.join(CWD, "frr-mc1-wrappers")
WRAPPED_DAEMONS = ("zebra", "bgpd", "staticd", "mgmtd")


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
            "SPECULA_MC1_PREFIX",
            "SPECULA_MC1_FIRST_DELAY_US",
            "SPECULA_MC1_LATER_DELAY_US",
            "SPECULA_MC1_AFTER_KERNEL_DELAY_US",
            "SPECULA_MC1_SUMMARY_FILE",
            "SPECULA_WRAPPER_DEBUG",
        )
    }
    for daemon in WRAPPED_DAEMONS:
        path = os.path.join(WRAPPER_DIR, daemon)
        with open(path, "w", encoding="ascii") as f:
            f.write("#!/usr/bin/env bash\nset -e\n")
            for name, value in trace_env.items():
                f.write(f"export {name}={shlex.quote(value)}\n")
            f.write(f"daemon_name={shlex.quote(daemon)}\n")
            f.write('router_name="$(basename "$(pwd -P)")"\n')
            f.write('trace_router_match=0\n')
            f.write('if [ -n "${SPECULA_TRACE_ROUTER:-}" ] && '
                    '[ "$router_name" = "$SPECULA_TRACE_ROUTER" ]; then\n')
            f.write('trace_router_match=1\n')
            f.write('fi\n')
            f.write('case "${ASAN_OPTIONS:-}" in '
                    '*"/${SPECULA_TRACE_ROUTER}.asan."*) '
                    'trace_router_match=1 ;; esac\n')
            f.write('if [ -n "${SPECULA_WRAPPER_DEBUG:-}" ]; then\n')
            f.write('printf "daemon=%s pwd=%s router_name=%s asan=%s match=%s trace_before=%s\\n" "$daemon_name" "$(pwd -P)" "$router_name" "${ASAN_OPTIONS:-}" "$trace_router_match" "${SPECULA_TRACE_FILE:-}" >> "$SPECULA_WRAPPER_DEBUG" 2>/dev/null || true\n')
            f.write('fi\n')
            f.write('if [ -n "${SPECULA_TRACE_ROUTER:-}" ] && '
                    '[ "$trace_router_match" != 1 ]; then\n')
            f.write("unset SPECULA_TRACE_FILE SPECULA_NOTIFY_STATE "
                    "SPECULA_PREFIX_P1 SPECULA_PREFIX_P2 SPECULA_MC1_PREFIX "
                    "SPECULA_MC1_FIRST_DELAY_US SPECULA_MC1_LATER_DELAY_US "
                    "SPECULA_MC1_AFTER_KERNEL_DELAY_US\n")
            f.write("fi\n")
            f.write('if [ -n "${SPECULA_WRAPPER_DEBUG:-}" ]; then\n')
            f.write('printf "daemon=%s trace_after=%s\\n" "$daemon_name" "${SPECULA_TRACE_FILE:-}" >> "$SPECULA_WRAPPER_DEBUG" 2>/dev/null || true\n')
            f.write('fi\n')
            f.write(f"exec /usr/lib/frr/{daemon} \"$@\"\n")
        os.chmod(path, 0o755)


def build_topo(tgen):
    _write_daemon_wrappers()
    for rname in ("r1", "r2", "r3", "r4"):
        tgen.add_router(rname)

    for sname, left, right in (
        ("s12", "r1", "r2"),
        ("s13", "r1", "r3"),
        ("s14", "r1", "r4"),
    ):
        switch = tgen.add_switch(sname)
        switch.add_link(tgen.gears[left])
        switch.add_link(tgen.gears[right])


def setup_module(mod):
    tgen = Topogen(build_topo, mod.__name__)
    tgen.start_topology()

    daemons = [
        (TopoRouter.RD_ZEBRA, None),
        (TopoRouter.RD_BGP, None),
        (TopoRouter.RD_STATIC, None),
    ]
    for rname, router in tgen.routers().items():
        router.daemondir = WRAPPER_DIR
        router.net.daemondir = WRAPPER_DIR
        router.load_frr_config(os.path.join(CWD, rname, "frr.conf"), daemons)

    tgen.start_router()


def teardown_module(mod):
    tgen = get_topogen()
    tgen.stop_topology()


def _events():
    path = pathlib.Path(os.environ["SPECULA_TRACE_FILE"])
    if not path.exists():
        return []
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("tag") == "frr_route_realization":
            out.append(obj["event"])
    return out


def _wait_until(fn, timeout, label, interval=0.1):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        ok, last = fn()
        if ok:
            return last
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {label}; last={last}")


def _count_event(name):
    return sum(1 for ev in _events() if ev.get("name") == name and ev.get("prefix") == "p1")


def _best_nexthop(router):
    raw = router.vtysh_cmd(f"show bgp ipv4 unicast {PREFIX} json")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    for path in data.get("paths", []):
        if path.get("bestpath", {}).get("overall"):
            nhops = path.get("nexthops") or []
            if nhops:
                return nhops[0].get("ip")
    return None


def _r4_has_route(router):
    raw = router.vtysh_cmd(f"show bgp ipv4 unicast {PREFIX} json")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return False
    return data.get("pathCount", 0) > 0 or bool(data.get("paths"))


def _detect_stale_bgp_notify():
    current_gen = 0
    second_ctx_seen = False
    events = _events()

    for ev in events:
        if ev.get("prefix") != "p1":
            continue
        if ev.get("name") == "rib_addnode":
            current_gen = max(current_gen, int(ev.get("gen", 0)))
        if ev.get("name") == "dplane_ctx_route_init" and int(ev.get("ctxId", 0)) >= 2:
            second_ctx_seen = True

    second_generation_index = None
    if current_gen >= 2:
        for index, ev in enumerate(events):
            if ev.get("prefix") != "p1":
                continue
            if ev.get("name") == "rib_addnode" and int(ev.get("gen", 0)) == current_gen:
                second_generation_index = index
                break

    rib_process = None
    route_notify = None
    bgp_notify = None
    current_rib_process = None
    current_route_notify = None
    current_bgp_notify = None
    stale_index = None

    scan_start = second_generation_index if second_generation_index is not None else len(events)
    for index, ev in enumerate(events[scan_start + 1:], start=scan_start + 1):
        if ev.get("prefix") != "p1":
            continue
        if (ev.get("name") == "rib_process_result" and ev.get("note") == "installed"
                and int(ev.get("causeGen", ev.get("gen", 0))) < current_gen):
            rib_process = ev
            if stale_index is None:
                stale_index = index
        if (ev.get("name") == "route_notify_internal" and ev.get("note") == "installed"
                and int(ev.get("causeGen", ev.get("gen", 0))) < current_gen):
            route_notify = ev
            if stale_index is None:
                stale_index = index
        if (ev.get("name") == "bgp_zebra_route_notify_owner" and ev.get("note") == "installed"
                and int(ev.get("causeGen", ev.get("gen", 0))) < current_gen):
            bgp_notify = ev
            if stale_index is None:
                stale_index = index

    if stale_index is not None:
        for ev in events[stale_index + 1:]:
            if ev.get("prefix") != "p1" or ev.get("note") != "installed":
                continue
            if int(ev.get("causeGen", ev.get("gen", 0))) != current_gen:
                continue
            if ev.get("name") == "rib_process_result" and current_rib_process is None:
                current_rib_process = ev
            if ev.get("name") == "route_notify_internal" and current_route_notify is None:
                current_route_notify = ev
            if ev.get("name") == "bgp_zebra_route_notify_owner" and current_bgp_notify is None:
                current_bgp_notify = ev

    stale = bool(current_gen >= 2 and second_ctx_seen and rib_process and route_notify and bgp_notify)
    return {
        "stale_notify": stale,
        "current_gen": current_gen,
        "second_ctx_seen": second_ctx_seen,
        "rib_process_result": rib_process,
        "route_notify_internal": route_notify,
        "bgp_zebra_route_notify_owner": bgp_notify,
        "current_rib_process_result": current_rib_process,
        "current_route_notify_internal": current_route_notify,
        "current_bgp_zebra_route_notify_owner": current_bgp_notify,
        "event_count": len(events),
    }


def _write_summary(summary):
    path = pathlib.Path(os.environ["SPECULA_MC1_SUMMARY_FILE"])
    path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print("MC1_SUMMARY " + json.dumps(summary, sort_keys=True))


def _add_r3_advertisement(r3):
    r3.vtysh_cmd(
        "configure terminal\n"
        "router bgp 65003\n"
        " address-family ipv4 unicast\n"
        f"  network {PREFIX}\n"
        " exit-address-family\n"
        "end\n"
    )


def test_stale_dplane_success_route_switch():
    mode = os.environ.get("SPECULA_MC1_MODE", "level3")
    tgen = get_topogen()
    if tgen.routers_have_failure():
        pytest.skip(tgen.errors)

    r1 = tgen.gears["r1"]
    r3 = tgen.gears["r3"]
    r4 = tgen.gears["r4"]

    logger.info("Waiting for initial r2 route to reach Zebra dataplane")
    _wait_until(lambda: (_count_event("dplane_ctx_route_init") >= 1,
                         _count_event("dplane_ctx_route_init")),
                80, "first dataplane context")

    if mode == "level0":
        _wait_until(lambda: (_count_event("bgp_zebra_route_notify_owner") >= 1,
                             _count_event("bgp_zebra_route_notify_owner")),
                    20, "initial owner ack")
    elif mode == "level3":
        _wait_until(lambda: (_count_event("kernel_dplane_process_func_success") >= 1,
                             _count_event("kernel_dplane_process_func_success")),
                    20, "first ctx kernel success")

    logger.info("Adding better r3 route using normal BGP configuration")
    _add_r3_advertisement(r3)

    _wait_until(lambda: (_best_nexthop(r1) == R3_NH, _best_nexthop(r1)),
                30, "r1 bestpath via r3", interval=0.25)
    _wait_until(lambda: (_count_event("dplane_ctx_route_init") >= 2,
                         _count_event("dplane_ctx_route_init")),
                30, "second dataplane context", interval=0.1)

    if mode == "level3":
        stale = _wait_until(lambda: (_detect_stale_bgp_notify()["stale_notify"],
                                     _detect_stale_bgp_notify()),
                            40, "stale BGP owner notification", interval=0.1)
    else:
        time.sleep(4)
        stale = _detect_stale_bgp_notify()

    kernel_route = r1.run(f"ip -4 route show {PREFIX}").strip()
    r1_bgp = r1.vtysh_cmd(f"show bgp ipv4 unicast {PREFIX}")
    r4_present = _r4_has_route(r4)

    summary = {
        "mode": mode,
        "level": {"level0": 0, "level1": 1, "level3": 3}.get(mode, -1),
        "stale_notify": bool(stale["stale_notify"]),
        "current_gen": stale["current_gen"],
        "second_ctx_seen": bool(stale["second_ctx_seen"]),
        "rib_process_result": stale["rib_process_result"],
        "route_notify_internal": stale["route_notify_internal"],
        "bgp_zebra_route_notify_owner": stale["bgp_zebra_route_notify_owner"],
        "current_rib_process_result": stale["current_rib_process_result"],
        "current_route_notify_internal": stale["current_route_notify_internal"],
        "current_bgp_zebra_route_notify_owner": stale["current_bgp_zebra_route_notify_owner"],
        "r1_best_nexthop": _best_nexthop(r1),
        "r1_kernel_route": kernel_route,
        "r1_bgp_text": r1_bgp,
        "r4_route_present": r4_present,
        "event_count": stale["event_count"],
    }
    _write_summary(summary)

    if mode == "level3":
        assert summary["stale_notify"], "Level 3 did not observe stale owner notification"
        assert summary["r1_best_nexthop"] == R3_NH, summary
        assert summary["current_bgp_zebra_route_notify_owner"], summary
        assert R3_NH in summary["r1_kernel_route"], summary

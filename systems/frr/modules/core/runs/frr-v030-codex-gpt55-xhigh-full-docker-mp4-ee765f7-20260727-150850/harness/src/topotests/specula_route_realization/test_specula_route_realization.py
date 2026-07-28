#!/usr/bin/env python
# SPDX-License-Identifier: ISC

import functools
import os
import shlex
import sys

import pytest

CWD = os.path.dirname(os.path.realpath(__file__))
sys.path.append(os.path.join(CWD, "../"))

from lib import topotest
from lib.topogen import Topogen, TopoRouter, get_topogen
from lib.topolog import logger

pytestmark = [pytest.mark.bgpd, pytest.mark.staticd]

WRAPPER_DIR = os.path.join(CWD, "frr-specula-wrappers")
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
        )
    }
    for daemon in WRAPPED_DAEMONS:
        path = os.path.join(WRAPPER_DIR, daemon)
        with open(path, "w", encoding="ascii") as f:
            f.write("#!/usr/bin/env bash\nset -e\n")
            for name, value in trace_env.items():
                f.write(f"export {name}={shlex.quote(value)}\n")
            f.write('router_name="${PWD##*/}"\n')
            f.write('if [ -n "${SPECULA_TRACE_ROUTER:-}" ] && '
                    '[ "$router_name" != "$SPECULA_TRACE_ROUTER" ]; then\n')
            f.write("unset SPECULA_TRACE_FILE SPECULA_NOTIFY_STATE "
                    "SPECULA_PREFIX_P1 SPECULA_PREFIX_P2\n")
            f.write("fi\n")
            f.write(f"exec /usr/lib/frr/{daemon} \"$@\"\n")
        os.chmod(path, 0o755)


def build_topo(tgen):
    _write_daemon_wrappers()
    for rname in ("r1", "r2"):
        tgen.add_router(rname)

    switch = tgen.add_switch("s1")
    switch.add_link(tgen.gears["r1"])
    switch.add_link(tgen.gears["r2"])


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


def _assert_route(router, command, expected, message, count=30):
    test_func = functools.partial(topotest.router_json_cmp, router, command, expected)
    _, result = topotest.run_and_expect(test_func, None, count=count, wait=1)
    assert result is None, message


def test_static_route_realization():
    tgen = get_topogen()
    if tgen.routers_have_failure():
        pytest.skip(tgen.errors)

    r1 = tgen.gears["r1"]
    logger.info("Install a static blackhole route on r1")
    r1.vtysh_cmd(
        "configure terminal\n"
        "ip route 198.51.100.0/24 blackhole\n"
    )

    _assert_route(
        r1,
        "show ip route 198.51.100.0/24 json",
        {"198.51.100.0/24": [{"protocol": "static"}]},
        "static route 198.51.100.0/24 was not realized in zebra",
    )


def test_bgp_suppress_fib_route_realization():
    tgen = get_topogen()
    if tgen.routers_have_failure():
        pytest.skip(tgen.errors)

    r1 = tgen.gears["r1"]
    logger.info("Wait for r1 to install 10.0.0.0/24 via BGP")
    _assert_route(
        r1,
        "show ip route 10.0.0.0/24 json",
        {"10.0.0.0/24": [{"protocol": "bgp"}]},
        "BGP route 10.0.0.0/24 was not realized in zebra",
        count=45,
    )


if __name__ == "__main__":
    args = ["-s"] + sys.argv[1:]
    sys.exit(pytest.main(args))

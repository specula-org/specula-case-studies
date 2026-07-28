#!/usr/bin/env bash
set -euo pipefail

SPECULA_OUTPUT_DIR="/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output"
SRC="/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/confirmation/MC-1/worktree"
IMAGE="${IMAGE:-ncp/frr-replay:ubuntu22-topotest}"
RUN_DIR="$SPECULA_OUTPUT_DIR/repro/MC-1-stale-dplane"
TMP_SRC="$RUN_DIR/src"
PERSIST_DIR="${PERSIST_DIR:-$RUN_DIR/persist}"
TRACE_DIR="$RUN_DIR/traces"
TOPODIR="$TMP_SRC/tests/topotests/specula_mc1_stale_dplane"
GIT_LIST="$SPECULA_OUTPUT_DIR/git-ls-files"

echo "MC-1 stale dataplane success reproduction"
echo "source=$SRC"
echo "run_dir=$RUN_DIR"
echo "image=$IMAGE"

rm -rf "$TMP_SRC"
mkdir -p "$RUN_DIR" "$TRACE_DIR" "$PERSIST_DIR"
chmod 0777 "$RUN_DIR" "$TRACE_DIR"
rsync -a --delete --exclude='.git' "$SRC"/ "$TMP_SRC"/

python3 - "$TMP_SRC/zebra/zebra_dplane.c" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

include_anchor = """#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

"""
if "#include <unistd.h>\n" not in text:
    text = text.replace(include_anchor, include_anchor + "#include <unistd.h>\n\n", 1)

helper_anchor = """static void kernel_dplane_process_tc_qdisc_read(struct zebra_dplane_provider *prov,
\t\t\t\t\t\tstruct zebra_dplane_ctx *ctx)
{
\tkernel_read_tc_qdisc(ctx);
\tdplane_provider_enqueue_out_ctx(prov, ctx);
}

"""
helper = r'''static unsigned long specula_mc1_get_delay_us(const char *name)
{
	const char *value = getenv(name);
	char *endp = NULL;
	unsigned long delay;

	if (!value || !value[0])
		return 0;

	delay = strtoul(value, &endp, 10);
	if (endp == value || *endp != '\0')
		return 0;

	return delay;
}

static void specula_mc1_delay_route_ctx(struct zebra_dplane_ctx *ctx)
{
	static uint32_t matched_route_ctxs;
	const struct prefix *p;
	const char *target;
	enum dplane_op_e op;
	char buf[PREFIX2STR_BUFFER];
	unsigned long delay;

	target = getenv("SPECULA_MC1_PREFIX");
	if (!target || !target[0])
		return;

	op = dplane_ctx_get_op(ctx);
	if (op != DPLANE_OP_ROUTE_INSTALL && op != DPLANE_OP_ROUTE_UPDATE)
		return;

	p = dplane_ctx_get_dest(ctx);
	if (!p)
		return;

	prefix2str(p, buf, sizeof(buf));
	if (strcmp(buf, target) != 0)
		return;

	matched_route_ctxs++;
	delay = matched_route_ctxs == 1
			? specula_mc1_get_delay_us("SPECULA_MC1_FIRST_DELAY_US")
			: specula_mc1_get_delay_us("SPECULA_MC1_LATER_DELAY_US");
	if (delay > 0)
		usleep(delay);
}

static void specula_mc1_delay_after_kernel_result(struct zebra_dplane_ctx *ctx)
{
	const struct prefix *p;
	const char *target;
	enum dplane_op_e op;
	char buf[PREFIX2STR_BUFFER];
	unsigned long delay;

	target = getenv("SPECULA_MC1_PREFIX");
	if (!target || !target[0])
		return;

	op = dplane_ctx_get_op(ctx);
	if (op != DPLANE_OP_ROUTE_INSTALL && op != DPLANE_OP_ROUTE_UPDATE)
		return;

	p = dplane_ctx_get_dest(ctx);
	if (!p)
		return;

	prefix2str(p, buf, sizeof(buf));
	if (strcmp(buf, target) != 0)
		return;

	delay = specula_mc1_get_delay_us("SPECULA_MC1_AFTER_KERNEL_DELAY_US");
	if (delay > 0)
		usleep(delay);
}

'''
if "specula_mc1_delay_route_ctx" not in text:
    if helper_anchor not in text:
        raise SystemExit("helper insertion anchor not found")
    text = text.replace(helper_anchor, helper_anchor + helper, 1)

call_anchor = """\t\tctx = dplane_provider_dequeue_in_ctx(prov);
\t\tif (ctx == NULL)
\t\t\tbreak;
\t\tif (IS_ZEBRA_DEBUG_DPLANE_DETAIL)
"""
call_repl = """\t\tctx = dplane_provider_dequeue_in_ctx(prov);
\t\tif (ctx == NULL)
\t\t\tbreak;
\t\tspecula_mc1_delay_route_ctx(ctx);
\t\tif (IS_ZEBRA_DEBUG_DPLANE_DETAIL)
"""
if "specula_mc1_delay_route_ctx(ctx);" not in text:
    if call_anchor not in text:
        raise SystemExit("call insertion anchor not found")
    text = text.replace(call_anchor, call_repl, 1)

after_kernel_anchor = """\t\tspecula_trace_kernel_result(
\t\t\tctx, specula_dplane_status(dplane_ctx_get_status(ctx)),
\t\t\tdplane_ctx_get_status(ctx) == ZEBRA_DPLANE_REQUEST_SUCCESS,
\t\t\tfalse);

\t\tdplane_provider_enqueue_out_ctx(prov, ctx);
"""
after_kernel_repl = """\t\tspecula_trace_kernel_result(
\t\t\tctx, specula_dplane_status(dplane_ctx_get_status(ctx)),
\t\t\tdplane_ctx_get_status(ctx) == ZEBRA_DPLANE_REQUEST_SUCCESS,
\t\t\tfalse);
\t\tspecula_mc1_delay_after_kernel_result(ctx);

\t\tdplane_provider_enqueue_out_ctx(prov, ctx);
"""
if "specula_mc1_delay_after_kernel_result(ctx);" not in text:
    if after_kernel_anchor not in text:
        raise SystemExit("after-kernel delay insertion anchor not found")
    text = text.replace(after_kernel_anchor, after_kernel_repl, 1)

path.write_text(text, encoding="utf-8")
PY

mkdir -p "$TOPODIR"/r1 "$TOPODIR"/r2 "$TOPODIR"/r3 "$TOPODIR"/r4

cat > "$TOPODIR/__init__.py" <<'PY'
"""MC-1 stale dataplane result topotest."""
PY

cat > "$TOPODIR/r1/frr.conf" <<'EOF'
!
log file /tmp/r1-frr.log debugging
debug zebra dplane detailed
debug bgp zebra
zebra dplane limit 1
!
interface r1-eth0
 ip address 10.0.12.1/30
!
interface r1-eth1
 ip address 10.0.13.1/30
!
interface r1-eth2
 ip address 10.0.14.1/30
!
ip forwarding
!
route-map PREFER_R3 permit 10
 set local-preference 200
!
router bgp 65001
 no bgp ebgp-requires-policy
 bgp suppress-fib-pending 0
 neighbor 10.0.12.2 remote-as 65002
 neighbor 10.0.13.2 remote-as 65003
 neighbor 10.0.14.2 remote-as 65004
 address-family ipv4 unicast
  neighbor 10.0.12.2 activate
  neighbor 10.0.13.2 activate
  neighbor 10.0.13.2 route-map PREFER_R3 in
  neighbor 10.0.14.2 activate
 exit-address-family
!
EOF

cat > "$TOPODIR/r2/frr.conf" <<'EOF'
!
interface r2-eth0
 ip address 10.0.12.2/30
!
ip forwarding
ip route 10.10.0.0/24 blackhole
!
router bgp 65002
 no bgp ebgp-requires-policy
 neighbor 10.0.12.1 remote-as 65001
 address-family ipv4 unicast
  network 10.10.0.0/24
  neighbor 10.0.12.1 activate
 exit-address-family
!
EOF

cat > "$TOPODIR/r3/frr.conf" <<'EOF'
!
interface r3-eth0
 ip address 10.0.13.2/30
!
ip forwarding
ip route 10.10.0.0/24 blackhole
!
router bgp 65003
 no bgp ebgp-requires-policy
 neighbor 10.0.13.1 remote-as 65001
 address-family ipv4 unicast
  neighbor 10.0.13.1 activate
 exit-address-family
!
EOF

cat > "$TOPODIR/r4/frr.conf" <<'EOF'
!
interface r4-eth0
 ip address 10.0.14.2/30
!
ip forwarding
!
router bgp 65004
 no bgp ebgp-requires-policy
 neighbor 10.0.14.1 remote-as 65001
 address-family ipv4 unicast
  neighbor 10.0.14.1 activate
 exit-address-family
!
EOF

cat > "$TOPODIR/test_bugMC1_stale_dplane.py" <<'PY'
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
PY

cat > "$RUN_DIR/run_inside.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

cd /root/persist/frr-build/tests/topotests
export TOPOTESTS_CHECK_MEMLEAK=/tmp/memleak_
export TOPOTESTS_CHECK_STDERR=Yes
export PYTHONUNBUFFERED=1
mkdir -p /tmp/repro/MC-1-stale-dplane/traces
chmod 0777 /tmp/repro/MC-1-stale-dplane /tmp/repro/MC-1-stale-dplane/traces

run_mode() {
	local mode="$1"
	local first_delay="$2"
	local later_delay="$3"
	local after_kernel_delay="$4"
	local trace="/tmp/repro/MC-1-stale-dplane/traces/${mode}.ndjson"
	local notify="/tmp/repro/MC-1-stale-dplane/traces/${mode}.notify"
	local summary="/tmp/repro/MC-1-stale-dplane/summary-${mode}.json"
	local debug="/tmp/repro/MC-1-stale-dplane/wrapper-debug-${mode}.log"
	local rc=0

	echo "==== MC-1 ${mode} ===="
	rm -f "$trace" "$notify" "$summary" "$debug"
	rm -rf /tmp/topotests/specula_mc1_stale_dplane.test_bugMC1_stale_dplane
	export SPECULA_MC1_MODE="$mode"
	export SPECULA_TRACE_FILE="$trace"
	export SPECULA_NOTIFY_STATE="$notify"
	export SPECULA_PREFIX_P1="10.10.0.0/24"
	export SPECULA_PREFIX_P2="10.10.0.0/8"
	export SPECULA_TRACE_ROUTER="r1"
	export SPECULA_MC1_PREFIX="10.10.0.0/24"
	export SPECULA_MC1_FIRST_DELAY_US="$first_delay"
	export SPECULA_MC1_LATER_DELAY_US="$later_delay"
	export SPECULA_MC1_AFTER_KERNEL_DELAY_US="$after_kernel_delay"
	export SPECULA_MC1_SUMMARY_FILE="$summary"
	export SPECULA_WRAPPER_DEBUG="$debug"
	export TOPOTEST_CLEAN=1

	pytest -s \
		--junitxml "/tmp/repro/MC-1-stale-dplane/topotests-${mode}.xml" \
		"specula_mc1_stale_dplane/test_bugMC1_stale_dplane.py::test_stale_dplane_success_route_switch" || rc=$?

	if [ ! -s "$summary" ]; then
		echo "${mode}: summary missing at $summary"
		return 1
	fi
	return "$rc"
}

overall=0
run_mode level0 0 0 0 || overall=$?
run_mode level1 0 0 0 || {
	rc=$?
	if [ "$overall" -eq 0 ]; then overall="$rc"; fi
}
run_mode level3 0 12000000 3000000 || {
	rc=$?
	if [ "$overall" -eq 0 ]; then overall="$rc"; fi
}
exit "$overall"
SH
chmod +x "$RUN_DIR/run_inside.sh"

(cd "$SRC" && git ls-files -z --cached --others --exclude-standard) > "$GIT_LIST"
printf '%s\0' \
	"tests/topotests/specula_mc1_stale_dplane/__init__.py" \
	"tests/topotests/specula_mc1_stale_dplane/r1/frr.conf" \
	"tests/topotests/specula_mc1_stale_dplane/r2/frr.conf" \
	"tests/topotests/specula_mc1_stale_dplane/r3/frr.conf" \
	"tests/topotests/specula_mc1_stale_dplane/r4/frr.conf" \
	"tests/topotests/specula_mc1_stale_dplane/test_bugMC1_stale_dplane.py" \
	>> "$GIT_LIST"

rm -f "$RUN_DIR/docker-run.log"
set +e
docker run --rm --privileged --network=none \
	-v "$SPECULA_OUTPUT_DIR:/tmp" \
	-v "$TMP_SRC:/root/host-frr:ro" \
	-v "$PERSIST_DIR:/root/persist" \
	-e TOPOTEST_CLEAN=0 \
	-e TOPOTEST_VERBOSE="${TOPOTEST_VERBOSE:-0}" \
	-e TOPOTEST_DOC=0 \
	-e TOPOTEST_SANITIZER="${TOPOTEST_SANITIZER:-0}" \
	"$IMAGE" \
	/bin/bash /tmp/repro/MC-1-stale-dplane/run_inside.sh \
	2>&1 | tee "$RUN_DIR/docker-run.log"
rc=${PIPESTATUS[0]}
set -e

python3 - "$RUN_DIR" "$rc" <<'PY'
import json
import pathlib
import sys

run_dir = pathlib.Path(sys.argv[1])
rc = int(sys.argv[2])
print("==== MC-1 reproduction summary ====")
print(f"docker_exit={rc}")
any_missing = False
level3_triggered = False
for mode in ("level0", "level1", "level3"):
    path = run_dir / f"summary-{mode}.json"
    if not path.exists():
        print(f"{mode}: summary missing")
        any_missing = True
        continue
    data = json.loads(path.read_text())
    print(
        f"{mode}: stale_notify={data.get('stale_notify')} "
        f"current_gen={data.get('current_gen')} "
        f"second_ctx_seen={data.get('second_ctx_seen')} "
        f"r1_best_nexthop={data.get('r1_best_nexthop')} "
        f"r1_kernel_route={data.get('r1_kernel_route')!r} "
        f"r4_route_present={data.get('r4_route_present')}"
    )
    ev = data.get("bgp_zebra_route_notify_owner")
    if ev:
        print(
            f"{mode}: bgp_notify ctxId={ev.get('ctxId')} "
            f"causeGen={ev.get('causeGen')} note={ev.get('note')}"
        )
    current_ev = data.get("current_bgp_zebra_route_notify_owner")
    if current_ev:
        print(
            f"{mode}: current_bgp_notify ctxId={current_ev.get('ctxId')} "
            f"causeGen={current_ev.get('causeGen')} note={current_ev.get('note')}"
        )
    rp = data.get("rib_process_result")
    if rp:
        print(
            f"{mode}: rib_process_result ctxId={rp.get('ctxId')} "
            f"gen={rp.get('gen')} causeGen={rp.get('causeGen')} "
            f"seq={rp.get('seq')} note={rp.get('note')}"
        )
    if mode == "level3" and data.get("stale_notify"):
        level3_triggered = True

if rc != 0 or any_missing or not level3_triggered:
    sys.exit(1)
PY

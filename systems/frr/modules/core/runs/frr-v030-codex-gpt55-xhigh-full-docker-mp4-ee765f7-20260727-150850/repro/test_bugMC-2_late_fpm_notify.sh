#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output"
FRR_SRC="$ROOT/confirmation/MC-2/worktree"
IMAGE="${IMAGE:-ncp/frr-replay:ubuntu22-topotest}"
OUT_DIR="$ROOT/repro/mc2-late-fpm-notify"
PERSIST_DIR="${PERSIST_DIR:-$OUT_DIR/persist}"
TEST_DIR="$FRR_SRC/tests/topotests/specula_mc2_late_fpm_notify"

mkdir -p "$OUT_DIR" "$PERSIST_DIR" "$TEST_DIR/r1" "$TEST_DIR/r2"
chmod 0777 "$OUT_DIR"

cat > "$TEST_DIR/mc2_fpm_responder.py" <<'PY'
#!/usr/bin/env python3
import argparse
import ipaddress
import os
import socket
import struct
import time

AF_INET = 2
FPM_MSG_TYPE_NETLINK = 1
NLM_F_REQUEST = 1
RTM_NEWROUTE = 24
RTA_DST = 1
RTA_TABLE = 15
RTPROT_BGP = 186
RTM_F_OFFLOAD = 0x4000
NLMSG_HDRLEN = 16
RTMSG_LEN = 12


def align4(value):
    return (value + 3) & ~3


def recv_exact(sock, size):
    chunks = []
    remaining = size
    while remaining:
        data = sock.recv(remaining)
        if not data:
            return None
        chunks.append(data)
        remaining -= len(data)
    return b"".join(chunks)


class Responder:
    def __init__(self, args):
        self.target = ipaddress.ip_network(args.prefix)
        self.log_path = args.log
        self.ready_path = args.ready
        self.first_seen_path = args.first_seen
        self.second_seen_path = args.second_seen
        self.send_path = args.send
        self.sent_path = args.sent
        self.first_frame = None
        self.target_frames = 0

    def log(self, message):
        with open(self.log_path, "a", encoding="ascii") as f:
            f.write(message + "\n")
            f.flush()

    def marker(self, path, text):
        with open(path, "w", encoding="ascii") as f:
            f.write(text + "\n")

    def parse_target_infos(self, frame):
        payload = frame[4:]
        infos = []
        offset = 0

        while offset + NLMSG_HDRLEN <= len(payload):
            try:
                nlmsg_len, nlmsg_type, nlmsg_flags, nlmsg_seq, _ = struct.unpack_from(
                    "=IHHII", payload, offset
                )
            except struct.error:
                break

            if nlmsg_len < NLMSG_HDRLEN + RTMSG_LEN:
                break
            end = offset + nlmsg_len
            if end > len(payload):
                break

            if nlmsg_type == RTM_NEWROUTE:
                rtm_offset = offset + NLMSG_HDRLEN
                try:
                    (
                        family,
                        dst_len,
                        _src_len,
                        _tos,
                        table,
                        proto,
                        _scope,
                        route_type,
                        rtm_flags,
                    ) = struct.unpack_from("=BBBBBBBBI", payload, rtm_offset)
                except struct.error:
                    break

                dst = None
                table_attr = None
                attr_offset = offset + align4(NLMSG_HDRLEN + RTMSG_LEN)
                while attr_offset + 4 <= end:
                    try:
                        rta_len, rta_type = struct.unpack_from("=HH", payload, attr_offset)
                    except struct.error:
                        break
                    if rta_len < 4 or attr_offset + rta_len > end:
                        break
                    data = payload[attr_offset + 4 : attr_offset + rta_len]
                    if rta_type == RTA_DST and family == AF_INET and len(data) >= 4:
                        dst = str(ipaddress.IPv4Address(data[:4]))
                    elif rta_type == RTA_TABLE and len(data) >= 4:
                        table_attr = struct.unpack_from("=I", data, 0)[0]
                    attr_offset += align4(rta_len)

                if (
                    family == AF_INET
                    and proto == RTPROT_BGP
                    and dst == str(self.target.network_address)
                    and dst_len == self.target.prefixlen
                ):
                    infos.append(
                        {
                            "rtm_flags_off": 4 + rtm_offset + 8,
                            "nlmsg_flags": nlmsg_flags,
                            "nlmsg_seq": nlmsg_seq,
                            "route_type": route_type,
                            "table": table_attr if table_attr is not None else table,
                            "rtm_flags": rtm_flags,
                        }
                    )

            offset += align4(nlmsg_len)

        return infos

    def offload_frame(self, frame, infos):
        out = bytearray(frame)
        for info in infos:
            off = info["rtm_flags_off"]
            flags = struct.unpack_from("=I", out, off)[0]
            struct.pack_into("=I", out, off, flags | RTM_F_OFFLOAD)
        return bytes(out)

    def wait_for_send_marker(self):
        for _ in range(300):
            if os.path.exists(self.send_path):
                return True
            time.sleep(0.1)
        return False

    def run(self):
        for path in (
            self.ready_path,
            self.first_seen_path,
            self.second_seen_path,
            self.send_path,
            self.sent_path,
            self.log_path,
        ):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", 2620))
            srv.listen(1)
            self.marker(self.ready_path, "ready")
            self.log("MC2_FPM ready")

            conn, addr = srv.accept()
            with conn:
                self.log(f"MC2_FPM accepted addr={addr}")
                while True:
                    hdr = recv_exact(conn, 4)
                    if hdr is None:
                        self.log("MC2_FPM connection_closed")
                        return
                    version, msg_type, msg_len = struct.unpack("!BBH", hdr)
                    if msg_len < 4:
                        self.log(f"MC2_FPM bad_len len={msg_len}")
                        return
                    payload = recv_exact(conn, msg_len - 4)
                    if payload is None:
                        self.log("MC2_FPM payload_closed")
                        return

                    frame = hdr + payload
                    if version != 1 or msg_type != FPM_MSG_TYPE_NETLINK:
                        continue

                    infos = self.parse_target_infos(frame)
                    if not infos:
                        continue

                    self.target_frames += 1
                    info = infos[0]
                    self.log(
                        "MC2_FPM target_route "
                        f"count={self.target_frames} prefix={self.target} "
                        f"nlmsg_flags=0x{info['nlmsg_flags']:x} "
                        f"rtm_flags=0x{info['rtm_flags']:x} "
                        f"seq={info['nlmsg_seq']} table={info['table']}"
                    )

                    if not (info["nlmsg_flags"] & NLM_F_REQUEST):
                        self.log("MC2_FPM target_route_missing_request_flag")

                    if self.target_frames == 1:
                        self.first_frame = self.offload_frame(frame, infos)
                        self.marker(self.first_seen_path, "first_seen")
                        self.log("MC2_FPM stored_first_without_reply=true")
                    elif self.target_frames == 2:
                        self.marker(self.second_seen_path, "second_seen")
                        self.log("MC2_FPM stored_second_without_reply=true")
                        if not self.wait_for_send_marker():
                            self.log("MC2_FPM send_marker_timeout=true")
                            return
                        conn.sendall(self.first_frame)
                        self.marker(self.sent_path, "sent_stale_first")
                        self.log("MC2_FPM sent_stale_first=true")
                        self.log("MC2_FPM sent_current_second=false")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--first-seen", required=True)
    parser.add_argument("--second-seen", required=True)
    parser.add_argument("--send", required=True)
    parser.add_argument("--sent", required=True)
    args = parser.parse_args()
    Responder(args).run()


if __name__ == "__main__":
    main()
PY
chmod +x "$TEST_DIR/mc2_fpm_responder.py"

cat > "$TEST_DIR/test_mc2_late_fpm_notify.py" <<'PY'
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
WRAPPED_DAEMONS = ("zebra", "bgpd", "mgmtd", "staticd")
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
PY

cat > "$TEST_DIR/r1/frr.conf" <<'EOF'
!
fpm address 127.0.0.1
!
interface r1-eth0
 ip address 192.0.2.1/30
!
ip forwarding
!
router bgp 65001
 no bgp ebgp-requires-policy
 bgp suppress-fib-pending
 neighbor 192.0.2.2 remote-as 65002
 address-family ipv4 unicast
  neighbor 192.0.2.2 activate
 exit-address-family
!
EOF

cat > "$TEST_DIR/r2/frr.conf" <<'EOF'
!
interface r2-eth0
 ip address 192.0.2.2/30
!
ip forwarding
!
ip route 10.10.10.0/24 blackhole
!
router bgp 65002
 no bgp ebgp-requires-policy
 neighbor 192.0.2.1 remote-as 65001
 address-family ipv4 unicast
  network 10.10.10.0/24
  neighbor 192.0.2.1 activate
  neighbor 192.0.2.1 route-map OUT out
 exit-address-family
!
ip prefix-list TARGET seq 5 permit 10.10.10.0/24
!
route-map OUT permit 10
 match ip address prefix-list TARGET
 set metric 100
!
EOF

printf 'MC2 reproduction: source=%s\n' "$FRR_SRC"
printf 'MC2 reproduction: image=%s\n' "$IMAGE"
printf 'MC2 ladder: Level 0 observes normal BGP route pending without offload notification; Level 1 controls only FPM notification timing and sends a late first offload notify after the second route generation.\n'

rm -f "$OUT_DIR/output.log" "$OUT_DIR/mc2_trace.ndjson" "$OUT_DIR/mc2_notify.sidecar" "$OUT_DIR/topotests.xml"
(cd "$FRR_SRC" && git ls-files -z --cached --others --exclude-standard) > "$ROOT/git-ls-files"

timeout 30m docker run --rm --privileged --network=none \
	-v "$ROOT:/tmp" \
	-v "$FRR_SRC:/root/host-frr:ro" \
	-v "$PERSIST_DIR:/root/persist" \
	-e TOPOTEST_CLEAN=1 \
	-e TOPOTEST_VERBOSE=0 \
	-e TOPOTEST_DOC=0 \
	-e TOPOTEST_SANITIZER=0 \
	-e SPECULA_TRACE_FILE=/tmp/repro/mc2-late-fpm-notify/mc2_trace.ndjson \
	-e SPECULA_NOTIFY_STATE=/tmp/repro/mc2-late-fpm-notify/mc2_notify.sidecar \
	-e SPECULA_PREFIX_P1=10.10.10.0/24 \
	-e SPECULA_PREFIX_P2=203.0.113.0/24 \
	-e SPECULA_TRACE_ROUTER=r1 \
	"$IMAGE" \
	/bin/bash -lc 'cd /root/persist/frr-build/tests/topotests && pytest -s --junitxml /tmp/repro/mc2-late-fpm-notify/topotests.xml specula_mc2_late_fpm_notify/test_mc2_late_fpm_notify.py::test_late_fpm_notify_marks_current_bgp_route_installed' \
	| tee "$OUT_DIR/output.log"

grep -q 'MC2_RESULT fpm_target_route_frames=2' "$OUT_DIR/output.log"
grep -q 'MC2_RESULT sent_stale_first=True' "$OUT_DIR/output.log"
grep -q 'MC2_RESULT sent_current_second=False' "$OUT_DIR/output.log"
grep -q 'MC2_RESULT before_stale_notify fibPending=true fibInstalled=false' "$OUT_DIR/output.log"
grep -q 'MC2_RESULT after_stale_notify fibPending=false fibInstalled=true' "$OUT_DIR/output.log"
grep -q 'MC2_RESULT wrong_installed_from_stale_notify=true' "$OUT_DIR/output.log"

printf 'MC2 reproduction: PASS\n'

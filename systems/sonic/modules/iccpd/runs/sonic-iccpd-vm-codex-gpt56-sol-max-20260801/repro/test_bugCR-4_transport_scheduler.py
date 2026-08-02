#!/usr/bin/env python3
"""Level-0 black-box reproduction for CR-4.

The test builds clean git HEAD out of tree, starts the real iccpd binary in an
isolated user/network/mount namespace, and talks only to normal TCP and control
interfaces.  It does not patch the source, call internal functions, or inject
in-memory state.
"""

from __future__ import annotations

import os
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path


WORKTREE = Path(
    os.environ.get(
        "CR4_WORKTREE",
        "/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/"
        "iccpd/.specula-output/confirmation/CR-4/worktree",
    )
)
SYNC_ADDR = ("127.0.0.6", 2626)
LOCAL_ADDR = "127.0.0.3"
PEER_ADDR = "127.0.0.2"
ICCP_PORT = 8888
SESSION_TIMEOUT = 3  # Public schema permits keepalive=1, timeout=3.


def out(message: str) -> None:
    print(message, flush=True)


def run_checked(
    argv: list[str],
    *,
    cwd: Path | None = None,
    timeout: float = 60,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    if result.returncode != 0:
        tail = result.stdout[-4000:]
        raise RuntimeError(f"command failed ({result.returncode}): {argv!r}\n{tail}")
    return result


def enter_isolated_namespace() -> None:
    if os.environ.get("CR4_IN_NAMESPACE") == "1":
        return
    unshare = shutil.which("unshare")
    if not unshare:
        raise RuntimeError("unshare is required for the isolated black-box run")
    env = os.environ.copy()
    env["CR4_IN_NAMESPACE"] = "1"
    os.execvpe(
        unshare,
        [
            unshare,
            "--user",
            "--map-root-user",
            "--net",
            "--mount",
            sys.executable,
            str(Path(__file__).resolve()),
        ],
        env,
    )


def prepare_namespace() -> None:
    run_checked(["ip", "link", "set", "lo", "up"], timeout=5)
    run_checked(["mount", "--make-rprivate", "/"], timeout=5)
    # Isolate iccpd.pid and mclagdctl.sock from the host.
    run_checked(["mount", "-t", "tmpfs", "tmpfs", "/var/run"], timeout=5)


def build_clean_head(build_root: Path) -> tuple[Path, Path, str]:
    sha = run_checked(
        ["git", "-C", str(WORKTREE), "rev-parse", "HEAD"], timeout=10
    ).stdout.strip()
    archive = build_root / "iccpd-head.tar"
    run_checked(
        [
            "git",
            "-C",
            str(WORKTREE),
            "archive",
            "--format=tar",
            f"--output={archive}",
            "HEAD",
            "src/iccpd",
        ],
        timeout=30,
    )
    run_checked(["tar", "-xf", str(archive), "-C", str(build_root)], timeout=30)
    source_dir = build_root / "src/iccpd"
    run_checked(["autoreconf", "-if"], cwd=source_dir, timeout=90)
    build_env = os.environ.copy()
    build_env["CFLAGS"] = "-O0 -g"
    run_checked(["./configure"], cwd=source_dir, timeout=90, env=build_env)
    run_checked(["make", "-j2"], cwd=source_dir, timeout=120)
    daemon = source_dir / "src/iccpd"
    ctl = source_dir / "src/mclagdctl/mclagdctl"
    if not daemon.is_file() or not ctl.is_file():
        raise RuntimeError("clean build did not produce iccpd and mclagdctl")
    return daemon, ctl, sha


def c_string(value: str, size: int) -> bytes:
    encoded = value.encode() + b"\0"
    if len(encoded) > size:
        raise ValueError(value)
    return encoded.ljust(size, b"\0")


def domain_config_message() -> bytes:
    # Native layout from msg_format.h. sizeof(mclag_domain_cfg_info) == 80.
    domain = struct.pack(
        "<iiii16s16s20s6s2xi",
        1,  # MCLAG_CFG_OPER_ADD
        1,  # domain_id
        1,  # keepalive_time
        SESSION_TIMEOUT,
        c_string(LOCAL_ADDR, 16),
        c_string(PEER_ADDR, 16),
        b"\0" * 20,
        b"\x02\x00\x00\x00\x00\x01",
        0x1B,  # SRC_ADDR | PEER_ADDR | KEEPALIVE | SESSION_TIMEOUT
    )
    assert len(domain) == 80
    # Native IccpSyncdHDr: version=1, CFG_MCLAG_DOMAIN=2, total length.
    return struct.pack("<BBH", 1, 2, 4 + len(domain)) + domain


def unsupported_app_frame(message_id: int) -> bytes:
    # A complete ICC RG APP DATA message.  The unknown parameter type 0x20 has
    # its U-bit set, so this is a structurally valid extensibility input.
    icc_rg_id = struct.pack("!HHI", 0x0005, 4, 1)
    unknown_parameter = struct.pack("!HH", 0x8020, 0)
    body = icc_rg_id + unknown_parameter
    frame = struct.pack("!HHI", 0x0703, 4 + len(body), message_id) + body
    assert len(frame) == 20
    return frame


def make_listener() -> socket.socket:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(SYNC_ADDR)
    listener.listen()
    return listener


def drain_socket(sock: socket.socket) -> tuple[int, bool]:
    total = 0
    closed = False
    old_timeout = sock.gettimeout()
    sock.setblocking(False)
    try:
        while True:
            try:
                chunk = sock.recv(65536)
            except BlockingIOError:
                break
            if not chunk:
                closed = True
                break
            total += len(chunk)
    finally:
        sock.settimeout(old_timeout)
    return total, closed


def wait_for_eof(sock: socket.socket, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        _, closed = drain_socket(sock)
        if closed:
            return True
        time.sleep(0.05)
    return drain_socket(sock)[1]


def process_wchan(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/wchan").read_text().strip()
    except OSError as exc:
        return f"unavailable:{exc.errno}"


class IccpdRun:
    def __init__(self, daemon: Path, *, configure_domain: bool):
        self.listener = make_listener()
        self.listener.settimeout(8)
        self.proc = subprocess.Popen(
            [str(daemon), "-c"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        self.sync_conn, _ = self.listener.accept()
        if configure_domain:
            self.sync_conn.sendall(domain_config_message())
            # Service-readiness wait; no timing hook or SUT delay is used.
            time.sleep(0.6)

    def raw_peer(self) -> socket.socket:
        peer = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        peer.settimeout(2)
        peer.bind((PEER_ADDR, 0))
        peer.connect((LOCAL_ADDR, ICCP_PORT))
        return peer

    def accepted_peer(self) -> tuple[socket.socket, bytes]:
        deadline = time.monotonic() + 5
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            peer: socket.socket | None = None
            try:
                peer = self.raw_peer()
                data = peer.recv(4096)
                if data:
                    return peer, data
                peer.close()
            except (OSError, socket.timeout) as exc:
                last_error = exc
                if peer is not None:
                    peer.close()
            time.sleep(0.1)
        raise RuntimeError(f"configured peer was not accepted: {last_error}")

    def terminate(self) -> None:
        try:
            self.sync_conn.close()
        except OSError:
            pass
        try:
            self.listener.close()
        except OSError:
            pass
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(timeout=2)


def reproduce_partial_header(daemon: Path) -> None:
    run = IccpdRun(daemon, configure_domain=True)
    peer: socket.socket | None = None
    try:
        peer, capability = run.accepted_peer()
        frame = unsupported_app_frame(1)
        peer.sendall(frame[:1])
        time.sleep(0.25)
        os.kill(run.proc.pid, signal.SIGUSR1)
        time.sleep(SESSION_TIMEOUT + 1.2)
        alive = run.proc.poll() is None
        peer_open = not drain_socket(peer)[1]
        wchan = process_wchan(run.proc.pid) if alive else "exited"
        out(
            "partial_header: sent=1/8-header-bytes "
            f"capability_rx={len(capability)}B queued_SIGUSR1=yes"
        )
        out(
            f"partial_header: alive_after_{SESSION_TIMEOUT + 1.2:.1f}s={alive} "
            f"peer_open={peer_open} wchan={wchan}"
        )
        if not alive or not peer_open:
            raise AssertionError("partial header did not hold the real scheduler")

        # Releasing the normal TCP read lets the already-queued control request run.
        peer.close()
        peer = None
        try:
            rc = run.proc.wait(timeout=3)
            released = rc == 0
        except subprocess.TimeoutExpired:
            released = False
            rc = None
        out(f"partial_header: exited_after_peer_release={released} rc={rc}")
        if not released:
            raise AssertionError("queued warm-reboot request did not run after release")
    finally:
        if peer is not None:
            peer.close()
        run.terminate()


def reproduce_partial_body(daemon: Path) -> None:
    run = IccpdRun(daemon, configure_domain=True)
    peer: socket.socket | None = None
    try:
        peer, capability = run.accepted_peer()
        frame = unsupported_app_frame(2)
        peer.sendall(frame[:9])  # complete 8-byte header plus 1/12 body bytes
        time.sleep(0.25)
        os.kill(run.proc.pid, signal.SIGUSR1)
        observed = SESSION_TIMEOUT + 2.3
        time.sleep(observed)
        alive = run.proc.poll() is None
        peer_open = not drain_socket(peer)[1]
        wchan = process_wchan(run.proc.pid) if alive else "exited"
        out(
            "partial_body: sent=8-byte-header+1/12-body-bytes "
            f"session_timeout={SESSION_TIMEOUT}s capability_rx={len(capability)}B"
        )
        out(
            f"partial_body: alive_after_{observed:.1f}s={alive} "
            f"peer_open={peer_open} queued_SIGUSR1=yes wchan={wchan}"
        )
        if not alive or not peer_open:
            raise AssertionError("partial body did not stall scheduler past timeout")
    finally:
        if peer is not None:
            peer.close()
        run.terminate()


def reproduce_nonprogress_traffic(daemon: Path, ctl: Path) -> None:
    run = IccpdRun(daemon, configure_domain=True)
    peer: socket.socket | None = None
    second: socket.socket | None = None
    third: socket.socket | None = None
    try:
        peer, capability = run.accepted_peer()
        start = time.monotonic()
        sent = 0
        while time.monotonic() - start < 6.2:
            peer.sendall(unsupported_app_frame(100 + sent))
            sent += 1
            time.sleep(0.7)
            drain_socket(peer)

        peer_open = not drain_socket(peer)[1]
        elapsed = time.monotonic() - start
        status = run_checked(
            [str(ctl), "-i", "1", "dump", "state"], timeout=4
        ).stdout
        status_lines = [
            line
            for line in status.splitlines()
            if line.startswith("The MCLAG's keepalive")
            or line.startswith("MCLAG info sync")
            or line.startswith("sesssion Timeout")
        ]
        out(
            f"nonprogress_app: frame_hex={unsupported_app_frame(100).hex()} "
            f"sent={sent} elapsed={elapsed:.1f}s peer_open={peer_open}"
        )
        for line in status_lines:
            out(f"nonprogress_app: mclagdctl: {line}")
        if not peer_open:
            raise AssertionError("unsupported complete frames did not preserve socket")
        if "The MCLAG's keepalive is: ERROR" not in status:
            raise AssertionError("ICCP unexpectedly reached operational state")
        if "MCLAG info sync is: incomplete" not in status:
            raise AssertionError("mLACP unexpectedly made synchronization progress")

        # A replacement peer reaches the real accept path but is rejected because
        # the non-progressing CSM still owns a positive socket descriptor.
        second = run.raw_peer()
        second_rejected = wait_for_eof(second, 1.5)
        out(f"nonprogress_app: replacement_while_traffic_rejected={second_rejected}")
        if not second_rejected:
            raise AssertionError("replacement peer was not excluded by stale session")
        second.close()
        second = None

        # Once the trigger ceases, the ordinary heartbeat timeout eventually
        # removes the first connection; this is recovery after trigger removal,
        # not a mechanism that masks harm while traffic continues.
        first_closed = wait_for_eof(peer, 6)
        out(f"nonprogress_app: first_closed_after_traffic_stopped={first_closed}")
        if not first_closed:
            raise AssertionError("session did not expire after traffic stopped")
        peer.close()
        peer = None

        third, new_capability = run.accepted_peer()
        accepted_after_timeout = bool(new_capability)
        out(
            "nonprogress_app: replacement_after_timeout_accepted="
            f"{accepted_after_timeout} capability_rx={len(new_capability)}B"
        )
        if not accepted_after_timeout:
            raise AssertionError("replacement peer was not accepted after timeout")
    finally:
        for sock in (peer, second, third):
            if sock is not None:
                sock.close()
        run.terminate()


def reproduce_syncd_eof(daemon: Path) -> None:
    run = IccpdRun(daemon, configure_domain=False)
    replacement: socket.socket | None = None
    try:
        run.listener.close()
        run.sync_conn.close()  # normal mclagsyncd EOF/process-restart condition
        replacement = make_listener()
        replacement.settimeout(2)
        accepted = False
        start = time.monotonic()
        try:
            conn, _ = replacement.accept()
            accepted = True
            conn.close()
        except socket.timeout:
            pass
        elapsed = time.monotonic() - start
        alive = run.proc.poll() is None
        out(
            f"syncd_eof: initial_connection=accepted replacement_accepts={int(accepted)} "
            f"after={elapsed:.1f}s daemon_alive={alive}"
        )
        if accepted or not alive:
            raise AssertionError("mclagsyncd EOF did not leave reconnect suppressed")
    finally:
        if replacement is not None:
            replacement.close()
        run.terminate()


def main() -> int:
    enter_isolated_namespace()
    prepare_namespace()
    if not WORKTREE.is_dir():
        raise RuntimeError(f"worktree not found: {WORKTREE}")

    prepared_config = WORKTREE / "src/iccpd/config.log"
    prepared_trace = (
        prepared_config.is_file()
        and "-DICCPD_TLA_TRACE" in prepared_config.read_text(errors="replace")
    )
    out("CR-4 Level 0 black-box reproduction")
    out(
        f"preflight: prepared_binary={WORKTREE / 'src/iccpd/src/iccpd'} "
        f"trace_instrumented={str(prepared_trace).lower()} reused=no"
    )

    with tempfile.TemporaryDirectory(prefix="cr4-clean-head-") as temp_dir:
        daemon, ctl, sha = build_clean_head(Path(temp_dir))
        out(f"preflight: clean_source_sha={sha}")
        out("preflight: build=autoreconf -if; ./configure CFLAGS='-O0 -g'; make -j2")
        out(f"preflight: clean_binary={daemon}")

        reproduce_partial_header(daemon)
        reproduce_partial_body(daemon)
        reproduce_nonprogress_traffic(daemon, ctl)
        reproduce_syncd_eof(daemon)

    out("RESULT: BUG TRIGGERED (4/4 Level 0 black-box scenarios)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # Keep real diagnostic output in the captured run.
        out(f"RESULT: TEST ERROR: {type(exc).__name__}: {exc}")
        traceback.print_exc()
        raise SystemExit(2)

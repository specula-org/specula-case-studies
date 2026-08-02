#!/usr/bin/env python3
"""Reproduce MC-3 with two real iccpd instances and real mclagsyncd.

The test creates two isolated SONiC-like nodes, configures an ICCP domain and
virtual MLAG PortChannels through CONFIG_DB, and waits for MLACP Exchange.  It
pauses node A's genuine mclagsyncd, uses normal peer link changes to fill the
bounded sidecar TCP window, and waits for iccpd's own TX_ERROR counter before
flapping the untouched target through Linux RTM_NEWLINK notifications.  It
then crashes/restarts the sidecar and checks iccpd state plus the real
mclagsyncd ProducerStateTable output in APPL_DB.

No iccpd source is patched and no protocol message or internal state is
injected.  Linux dummy/veth links, Redis CONFIG_DB writes, process timing, and
normal netlink link operations are the only trigger inputs.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from typing import Iterable, Optional


TEST_FILE = pathlib.Path(__file__).resolve()
SPECULA_OUTPUT = TEST_FILE.parent.parent
WORKTREE = pathlib.Path(
    os.environ.get(
        "MC3_WORKTREE",
        SPECULA_OUTPUT / "confirmation" / "MC-3" / "worktree",
    )
).resolve()
ICCPD = WORKTREE / "src" / "iccpd" / "src" / "iccpd"
MCLAGDCTL = WORKTREE / "src" / "iccpd" / "src" / "mclagdctl" / "mclagdctl"
PINNED_SWSS = "b20a59691baca9ff6e4fbe46a7cd8223a3419117"
TARGET_LAG = "PortChannel100"
PRIMER_LAGS = tuple(f"PortChannel{number}" for number in range(200, 206))
SWSS_COMMON_LUA = pathlib.Path(
    os.environ.get("MC3_SWSS_COMMON_LUA", "/users/Pial/dependencies/sonic-swss-common/common")
).resolve()


def run(
    argv: Iterable[str],
    *,
    check: bool = True,
    timeout: float = 20,
    env: Optional[dict[str, str]] = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(argv),
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        env=env,
    )


def require_program(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"required program is missing: {name}")


def build_real_mclagsyncd() -> pathlib.Path:
    override = os.environ.get("MC3_MCLAGSYNCD")
    if override:
        binary = pathlib.Path(override).resolve()
        if not binary.is_file():
            raise RuntimeError(f"MC3_MCLAGSYNCD does not exist: {binary}")
        return binary

    cached_source = pathlib.Path("/tmp/mc3-sonic-swss.vYzWP0")
    source = cached_source if (cached_source / "mclagsyncd/mclaglink.cpp").is_file() else None
    if source is None:
        source = pathlib.Path(tempfile.mkdtemp(prefix="mc3-sonic-swss."))
        run(
            [
                "git",
                "clone",
                "--quiet",
                "--filter=blob:none",
                "--no-checkout",
                "https://github.com/sonic-net/sonic-swss.git",
                str(source),
            ],
            timeout=120,
        )
        run(["git", "-C", str(source), "checkout", "--quiet", PINNED_SWSS], timeout=120)

    binary = source / "mclagsyncd.mc3-real"
    inputs = [source / "mclagsyncd/mclagsyncd.cpp", source / "mclagsyncd/mclaglink.cpp"]
    if binary.is_file() and binary.stat().st_mtime >= max(p.stat().st_mtime for p in inputs):
        return binary

    compile_cmd = [
        "g++",
        "-std=c++17",
        "-O0",
        "-g",
        '-DCFG_MCLAG_UNIQUE_IP_TABLE_NAME="MCLAG_UNIQUE_IP"',
        '-DCFG_DEVICE_METADATA_TABLE_NAME="DEVICE_METADATA"',
        "-I.",
        "-I/usr/local/include/swss",
        "-I/usr/include/libnl3",
        "mclagsyncd/mclagsyncd.cpp",
        "mclagsyncd/mclaglink.cpp",
        "-o",
        str(binary),
        "-L/usr/local/lib",
        "-Wl,-rpath,/usr/local/lib",
        "-lswsscommon",
        "-lhiredis",
        "-lzmq",
        "-lnl-3",
        "-lnl-route-3",
        "-lpthread",
    ]
    proc = subprocess.run(
        compile_cmd,
        cwd=source,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
    if proc.returncode:
        raise RuntimeError(f"mclagsyncd build failed:\n{proc.stdout}")
    return binary


def enter_outer_namespace(mclagsyncd: pathlib.Path) -> None:
    if os.environ.get("MC3_OUTER_NS") == "1":
        return
    env = os.environ.copy()
    env["MC3_OUTER_NS"] = "1"
    env["MC3_MCLAGSYNCD"] = str(mclagsyncd)
    os.execvpe(
        "unshare",
        [
            "unshare",
            "--user",
            "--map-root-user",
            "--net",
            "--mount",
            "--",
            sys.executable,
            str(TEST_FILE),
        ],
        env,
    )


@dataclass
class Node:
    name: str
    address: str
    peer: str
    mac: str
    temp: pathlib.Path
    keeper: Optional[subprocess.Popen[str]] = None
    processes: list[subprocess.Popen[str]] = field(default_factory=list)

    @property
    def pid(self) -> int:
        if self.keeper is None:
            raise RuntimeError("namespace keeper has not started")
        return self.keeper.pid

    def ns_argv(self, argv: Iterable[str]) -> list[str]:
        return ["nsenter", "-t", str(self.pid), "-n", "-m", "--", *argv]

    def command(
        self,
        argv: Iterable[str],
        *,
        check: bool = True,
        timeout: float = 20,
    ) -> subprocess.CompletedProcess[str]:
        return run(self.ns_argv(argv), check=check, timeout=timeout)

    def start_namespace(self) -> None:
        ready = self.temp / f"{self.name}.ready"
        script = (
            "mount --make-rprivate /; "
            "mount -t tmpfs -o mode=755 tmpfs /var/run; "
            "mount -t tmpfs -o mode=755 tmpfs /usr/share; "
            "mkdir -p /usr/share/swss; "
            f"mount --bind {SWSS_COMMON_LUA} /usr/share/swss; "
            "mkdir -p /var/run/redis/sonic-db /var/run/iccpd; "
            "ip link set lo up; "
            f"touch {ready}; "
            "exec sleep 300"
        )
        self.keeper = subprocess.Popen(
            ["unshare", "--net", "--mount", "--", "bash", "-ceu", script],
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not ready.exists():
            if self.keeper.poll() is not None:
                raise RuntimeError(f"{self.name}: namespace keeper exited")
            time.sleep(0.05)
        if not ready.exists():
            raise RuntimeError(f"{self.name}: namespace setup timed out")

    def configure_links(self, veth: str) -> None:
        # Bound the sidecar TCP receive window so Level-1 timing assistance can
        # reach the same ordinary EAGAIN path quickly instead of requiring
        # minutes of link churn.  This is per-network-namespace kernel state.
        self.command(
            ["sysctl", "-q", "-w", "net.ipv4.tcp_rmem=4096 4096 4096"]
        )
        self.command(
            ["sysctl", "-q", "-w", "net.ipv4.tcp_wmem=4096 4096 4096"]
        )
        self.command(["ip", "link", "set", veth, "name", "Ethernet0"])
        self.command(["ip", "addr", "add", f"{self.address}/24", "dev", "Ethernet0"])
        self.command(["ip", "link", "set", "Ethernet0", "up"])
        for link in ("PortChannel1", TARGET_LAG, *PRIMER_LAGS):
            self.command(["ip", "link", "add", link, "type", "dummy"])
            self.command(["ip", "link", "set", link, "up"])

    def setup_redis(self) -> None:
        config = {
            "INSTANCES": {
                "redis": {
                    "hostname": "127.0.0.1",
                    "port": 6379,
                    "unix_socket_path": "/var/run/redis/redis.sock",
                    "persistence_for_warm_boot": "no",
                }
            },
            "DATABASES": {
                "APPL_DB": {"id": 0, "separator": ":", "instance": "redis"},
                "ASIC_DB": {"id": 1, "separator": ":", "instance": "redis"},
                "COUNTERS_DB": {"id": 2, "separator": ":", "instance": "redis"},
                "CONFIG_DB": {"id": 4, "separator": "|", "instance": "redis"},
                "FLEX_COUNTER_DB": {"id": 5, "separator": "|", "instance": "redis"},
                "STATE_DB": {"id": 6, "separator": "|", "instance": "redis"},
            },
        }
        payload = json.dumps(config, separators=(",", ":"))
        self.command(
            [
                sys.executable,
                "-c",
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])",
                "/var/run/redis/sonic-db/database_config.json",
                payload,
            ]
        )
        log = (self.temp / f"{self.name}.redis.log").open("w")
        proc = subprocess.Popen(
            self.ns_argv(
                [
                    "redis-server",
                    "--bind",
                    "127.0.0.1",
                    "--port",
                    "6379",
                    "--unixsocket",
                    "/var/run/redis/redis.sock",
                    "--unixsocketperm",
                    "777",
                    "--save",
                    "",
                    "--appendonly",
                    "no",
                ]
            ),
            text=True,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        self.processes.append(proc)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            ping = self.command(
                ["redis-cli", "-s", "/var/run/redis/redis.sock", "PING"],
                check=False,
            )
            if "PONG" in ping.stdout:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"{self.name}: Redis did not start")

        redis = ["redis-cli", "-s", "/var/run/redis/redis.sock", "-n", "4"]
        self.command(redis + ["HSET", "DEVICE_METADATA|localhost", "mac", self.mac])
        self.command(
            redis
            + [
                "HSET",
                "MCLAG_DOMAIN|1",
                "source_ip",
                self.address,
                "peer_ip",
                self.peer,
                "peer_link",
                "PortChannel1",
                "keepalive_interval",
                "1",
                "session_timeout",
                "30",
            ]
        )
        for lag in (TARGET_LAG, *PRIMER_LAGS):
            self.command(redis + ["HSET", f"MCLAG_INTERFACE|1|{lag}", "NULL", "NULL"])

    def start_mclagsyncd(self, binary: pathlib.Path, suffix: str = "") -> subprocess.Popen[str]:
        log = (self.temp / f"{self.name}.mclagsyncd{suffix}.log").open("w")
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = "/usr/local/lib" + (
            f":{env['LD_LIBRARY_PATH']}" if env.get("LD_LIBRARY_PATH") else ""
        )
        proc = subprocess.Popen(
            self.ns_argv(["env", f"LD_LIBRARY_PATH={env['LD_LIBRARY_PATH']}", str(binary)]),
            text=True,
            stdout=log,
            stderr=subprocess.STDOUT,
            restore_signals=False,
        )
        self.processes.append(proc)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            listening = self.command(
                ["ss", "-H", "-ltn", "sport", "=", ":2626"],
                check=False,
            )
            if listening.stdout.strip():
                return proc
            if proc.poll() is not None:
                raise RuntimeError(f"{self.name}: mclagsyncd exited with {proc.returncode}")
            time.sleep(0.1)
        raise RuntimeError(f"{self.name}: mclagsyncd did not listen")

    def start_iccpd(self) -> subprocess.Popen[str]:
        log_path = self.temp / f"{self.name}.iccpd.log"
        log = log_path.open("w")
        # supervisord/Python launchers inherit SIGPIPE ignored.  Preserve that
        # deployment disposition so a stale-sidecar write returns EPIPE and the
        # daemon's error path can be observed instead of process termination.
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)
        daemon_argv = [str(ICCPD), "-c", "-p", "2015", "-l", str(log_path)]
        if os.environ.get("MC3_STRACE") == "1":
            daemon_argv = [
                "strace", "-ff", "-tt", "-s", "128", "-o",
                str(self.temp / f"{self.name}.strace"), *daemon_argv,
            ]
        proc = subprocess.Popen(
            self.ns_argv(daemon_argv),
            text=True,
            stdout=log,
            stderr=subprocess.STDOUT,
            restore_signals=False,
        )
        self.processes.append(proc)
        return proc

    def ctl(self, *args: str, check: bool = False) -> str:
        result = self.command([str(MCLAGDCTL), *args], check=check, timeout=8)
        return result.stdout

    def redis_get(self, database: int, key: str, field_name: str) -> str:
        result = self.command(
            [
                "redis-cli",
                "--raw",
                "-s",
                "/var/run/redis/redis.sock",
                "-n",
                str(database),
                "HGET",
                key,
                field_name,
            ],
            check=False,
        )
        return result.stdout.strip()

    def terminate_process(self, proc: subprocess.Popen[str]) -> None:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    def cleanup(self) -> None:
        for proc in reversed(self.processes):
            self.terminate_process(proc)
        if self.keeper is not None:
            self.terminate_process(self.keeper)


def wait_for_exchange(nodes: list[Node], timeout: float = 35) -> list[str]:
    deadline = time.monotonic() + timeout
    latest = ["", ""]
    while time.monotonic() < deadline:
        latest = [node.ctl("-i", "1", "dump", "state") for node in nodes]
        if all(
            "mclag info sync is: completed" in state.lower()
            and "keepalive is: ok" in state.lower()
            for state in latest
        ):
            return latest
        time.sleep(0.5)
    details = "\n".join(f"{node.name}:\n{state}" for node, state in zip(nodes, latest))
    raise RuntimeError(f"MLACP did not reach Exchange:\n{details}")


def wait_for_log(path: pathlib.Path, terms: tuple[str, ...], timeout: float) -> str:
    deadline = time.monotonic() + timeout
    text = ""
    while time.monotonic() < deadline:
        if path.exists():
            text = path.read_text(errors="replace")
            if all(term.lower() in text.lower() for term in terms):
                return text
        time.sleep(0.1)
    return text


def concise_state(raw: str) -> str:
    lines = [line.rstrip() for line in raw.splitlines() if line.strip()]
    return "\n".join(lines[:18])


def port_fields(raw: str, name: str) -> tuple[str, dict[str, str]]:
    for block in raw.split("-" * 60):
        if f"PortName: {name}" not in block:
            continue
        fields: dict[str, str] = {}
        for line in block.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                fields[key.strip()] = value.strip()
        return block.strip(), fields
    return "", {}


def counter_values(raw: str, name: str) -> tuple[int, int]:
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == name:
            return int(parts[1]), int(parts[2])
    return 0, 0


def main() -> int:
    for program in ("git", "g++", "unshare", "nsenter", "ip", "redis-server", "redis-cli", "ss", "sysctl"):
        require_program(program)
    if not ICCPD.is_file() or not MCLAGDCTL.is_file():
        raise RuntimeError("build src/iccpd first (iccpd and mclagdctl binaries are required)")
    if not (SWSS_COMMON_LUA / "producer_state_table_apply_view.lua").is_file():
        raise RuntimeError(f"swsscommon Lua scripts are missing under {SWSS_COMMON_LUA}")

    mclagsyncd = build_real_mclagsyncd()
    enter_outer_namespace(mclagsyncd)

    temp = pathlib.Path(tempfile.mkdtemp(prefix="mc3-run."))
    node_a = Node("nodeA", "10.77.0.1", "10.77.0.2", "02:00:00:00:00:01", temp)
    node_b = Node("nodeB", "10.77.0.2", "10.77.0.1", "02:00:00:00:00:02", temp)
    nodes = [node_a, node_b]

    print(f"source_head={run(['git', '-C', str(WORKTREE), 'rev-parse', 'HEAD']).stdout.strip()}")
    print(f"mclagsyncd_source={PINNED_SWSS}")
    print("prior_level0_attempt=graceful sidecar EOF; TCP half-close accepted post-EOF writes locally")
    print("trigger_level=1 (SIGSTOP sidecar plus bounded TCP window; normal LAG operations)")

    try:
        for node in nodes:
            node.start_namespace()

        run(["ip", "link", "add", "mc3vetha", "type", "veth", "peer", "name", "mc3vethb"])
        run(["ip", "link", "set", "mc3vetha", "netns", str(node_a.pid)])
        run(["ip", "link", "set", "mc3vethb", "netns", str(node_b.pid)])
        node_a.configure_links("mc3vetha")
        node_b.configure_links("mc3vethb")

        for node in nodes:
            node.setup_redis()
        sync_a = node_a.start_mclagsyncd(mclagsyncd)
        sync_b = node_b.start_mclagsyncd(mclagsyncd)
        iccp_a = node_a.start_iccpd()
        iccp_b = node_b.start_iccpd()

        deadline = time.monotonic() + 8
        peer_target_removed = False
        while time.monotonic() < deadline:
            peer_ports = node_a.ctl("-i", "1", "dump", "portlist", "peer")
            if TARGET_LAG not in peer_ports:
                peer_target_removed = True
                break
            time.sleep(0.2)
        if not peer_target_removed:
            raise RuntimeError("peer target interface deletion was not observed")
        print("peer_target_interface_known_before_flap=False")
        startup_status = {
            "sync_a": sync_a.poll(),
            "sync_b": sync_b.poll(),
            "iccp_a": iccp_a.poll(),
            "iccp_b": iccp_b.poll(),
        }
        print(f"startup_process_status={startup_status}")
        if iccp_a.poll() is not None or iccp_b.poll() is not None:
            raise RuntimeError(f"iccpd exited during startup: {startup_status}")

        initial = wait_for_exchange(nodes)
        print("initial_exchange=yes")
        print("nodeA_initial_state:")
        print(concise_state(initial[0]))

        # Establish the target's forwarding-enabled baseline through the real
        # down/up + peer-ACK sequence while mclagsyncd is healthy.
        node_a.command(["ip", "link", "set", TARGET_LAG, "down"])
        time.sleep(0.1)
        node_a.command(["ip", "link", "set", TARGET_LAG, "up"])
        deadline = time.monotonic() + 10
        target_baseline_fields: dict[str, str] = {}
        while time.monotonic() < deadline:
            baseline_ports = node_a.ctl("-i", "1", "dump", "portlist", "local")
            _, target_baseline_fields = port_fields(baseline_ports, TARGET_LAG)
            if (
                target_baseline_fields.get("State", "").lower() == "up"
                and target_baseline_fields.get("IsTrafficDisable") == "No"
            ):
                break
            time.sleep(0.2)
        if target_baseline_fields.get("IsTrafficDisable") != "No":
            raise RuntimeError("target did not reach forwarding-enabled baseline")
        print("target_forwarding_enabled_baseline=True")
        # ProducerStateTable stores pending consumer data in an underscore
        # staging hash.  With no orchagent in this focused environment, that is
        # the genuine mclagsyncd output to inspect.
        staged_lag_key = f"_LAG_TABLE:{TARGET_LAG}"
        deadline = time.monotonic() + 5
        consumer_baseline = ""
        while time.monotonic() < deadline:
            consumer_baseline = node_a.redis_get(0, staged_lag_key, "traffic_disable")
            if consumer_baseline == "false":
                break
            time.sleep(0.1)
        if consumer_baseline != "false":
            raise RuntimeError("real mclagsyncd did not publish healthy traffic-enable baseline")
        print("real_mclagsyncd_APPL_DB_baseline_traffic_disable=false")

        # Remove the target from the peer via the real CONFIG_DB API.  This is
        # the implementation-level counterpart of counterexample State 2.
        node_b.command(
            [
                "redis-cli",
                "-s",
                "/var/run/redis/redis.sock",
                "-n",
                "4",
                "DEL",
                "MCLAG_INTERFACE|1|PortChannel100",
            ]
        )
        time.sleep(2)

        # Pause the genuine sidecar so it cannot drain its bounded TCP receive
        # window.  Normal link changes on the real peer generate remote-interface
        # updates through ICCP until production send(2) reaches EAGAIN.  No
        # protocol or daemon state is injected.
        os.kill(sync_a.pid, signal.SIGSTOP)
        paused_socket = node_a.command(
            ["ss", "-Htan", "dst", "127.0.0.6", "dport", "=", ":2626"],
            check=False,
        ).stdout.strip()
        print(f"sidecar_socket_while_paused={paused_socket or '<not listed>'}")

        # The target remains untouched until iccpd's real SetRemoteIntfSts
        # TX_ERROR counter increases beyond its startup baseline.  Pace events
        # so the MLACP FSM consumes transitions rather than coalescing a batch.
        baseline_debug = node_a.ctl("-i", "1", "dump", "debug", "counters")
        baseline_remote_ok, baseline_remote_error = counter_values(
            baseline_debug, "SetRemoteIntfSts"
        )
        churn_cycles = 4000
        churn_script = (
            f"for i in $(seq 1 {churn_cycles}); do "
            f"ip link set {PRIMER_LAGS[0]} down; sleep 0.003; "
            f"ip link set {PRIMER_LAGS[0]} up; sleep 0.003; done"
        )
        churn = subprocess.Popen(
            node_b.ns_argv(["bash", "-c", churn_script]),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        node_b.processes.append(churn)
        remote_ok_count = baseline_remote_ok
        remote_error_count = baseline_remote_error
        primer_debug = baseline_debug
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            primer_debug = node_a.ctl("-i", "1", "dump", "debug", "counters")
            remote_ok_count, remote_error_count = counter_values(
                primer_debug, "SetRemoteIntfSts"
            )
            if remote_error_count >= baseline_remote_error + 10:
                break
            if churn.poll() is not None and remote_ok_count == baseline_remote_ok:
                break
            time.sleep(0.2)
        print(f"SetRemoteIntfSts_TX_OK_baseline={baseline_remote_ok}")
        print(f"SetRemoteIntfSts_TX_OK_after_churn={remote_ok_count}")
        print(f"SetRemoteIntfSts_TX_ERROR_baseline={baseline_remote_error}")
        print(f"SetRemoteIntfSts_TX_ERROR_after_churn={remote_error_count}")
        if remote_error_count < baseline_remote_error + 10:
            raise RuntimeError("paused sidecar did not surface a new send error after peer link churn")
        _, primer_error_count = counter_values(primer_debug, "TrafficDistDisable")
        print(f"peer_primer_flap_cycle_limit={churn_cycles}")
        print(f"SetRemoteIntfSts_TX_ERROR_before_target={remote_error_count}")
        print(f"TrafficDistDisable_TX_ERROR_before_target={primer_error_count}")

        # Target trigger: DOWN then rapid UP through real RTM_NEWLINK events.
        node_a.command(["ip", "link", "set", TARGET_LAG, "down"])
        time.sleep(0.05)
        node_a.command(["ip", "link", "set", TARGET_LAG, "up"])
        time.sleep(2)
        node_b.terminate_process(churn)
        if iccp_a.poll() is not None:
            raise RuntimeError(f"nodeA iccpd exited during target flap: {iccp_a.returncode}")

        # Now crash the unresponsive sidecar.  The ignored EOF/read-error leaves
        # sync_fd positive, which the replacement-sidecar check below observes.
        os.kill(sync_a.pid, signal.SIGKILL)
        sync_a.wait(timeout=5)
        time.sleep(1)

        local_after_flap = node_a.ctl("-i", "1", "dump", "portlist", "local")
        debug_after_flap = node_a.ctl("-i", "1", "dump", "debug", "counters")
        traffic_before_restart = node_a.redis_get(0, staged_lag_key, "traffic_disable")

        # A genuine replacement sidecar listens, but scheduler's fd > 0 guard
        # prevents reconnection and the lost disable is not replayed.
        replacement = node_a.start_mclagsyncd(mclagsyncd, suffix=".replacement")
        time.sleep(4)
        replacement_log = (temp / "nodeA.mclagsyncd.replacement.log").read_text(errors="replace")
        traffic_after_restart = node_a.redis_get(0, staged_lag_key, "traffic_disable")
        local_after_wait = node_a.ctl("-i", "1", "dump", "portlist", "local")
        target_block, target_fields = port_fields(local_after_wait, TARGET_LAG)
        disable_tx_ok, disable_tx_error = counter_values(debug_after_flap, "TrafficDistDisable")

        iccp_log = (temp / "nodeA.iccpd.log").read_text(errors="replace")
        error_lines = [
            line.strip()
            for line in iccp_log.splitlines()
            if any(word in line.lower() for word in ("traffic", "sync_fd", "broken pipe", "failed to send"))
        ]

        print(f"nodeA_iccpd_alive_after_failed_disable={iccp_a.poll() is None}")
        print(f"target_traffic_disable_before_restart={traffic_before_restart or '<absent>'}")
        print(f"replacement_sidecar_waiting_without_connection={'Waiting for connection' in replacement_log and 'Connected!' not in replacement_log}")
        print(f"target_traffic_disable_after_restart_wait={traffic_after_restart or '<absent>'}")
        print("nodeA_target_port_after_restart_wait:")
        print(target_block or "<not found>")
        print("nodeA_relevant_log_lines:")
        print("\n".join(error_lines[-12:]) if error_lines else "<none captured>")
        print(f"TrafficDistDisable_TX_OK={disable_tx_ok}")
        print(f"TrafficDistDisable_TX_ERROR={disable_tx_error}")

        # Assertions bind the verdict to genuine observed state, not to text
        # emitted by a test double.
        target_up = (
            target_fields.get("State", "").lower() == "up"
            and target_fields.get("PortchannelIsUp") == "1"
        )
        target_forwarding_enabled = target_fields.get("IsTrafficDisable") == "No"
        consumer_never_disabled = (
            traffic_before_restart == "false" and traffic_after_restart == "false"
        )
        stale_no_reconnect = "Waiting for connection" in replacement_log and "Connected!" not in replacement_log
        send_failed = disable_tx_error > primer_error_count
        passed = (
            target_up
            and target_forwarding_enabled
            and consumer_never_disabled
            and stale_no_reconnect
            and send_failed
            and iccp_a.poll() is None
        )
        print(f"assert_target_oper_up={target_up}")
        print(f"assert_iccpd_forwarding_flag_remained_enabled={target_forwarding_enabled}")
        print(f"assert_real_consumer_never_received_disable={consumer_never_disabled}")
        print(f"assert_stale_fd_prevented_reconnect={stale_no_reconnect}")
        print(f"assert_disable_send_failed={send_failed}")
        print(f"RESULT={'REPRODUCED' if passed else 'NOT_REPRODUCED'}")
        return 0 if passed else 1
    finally:
        for node in reversed(nodes):
            node.cleanup()
        if os.environ.get("MC3_KEEP_TMP") == "1":
            print(f"artifacts={temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"RESULT=ENVIRONMENT_ERROR: {exc}", file=sys.stderr)
        raise

#!/usr/bin/env python3
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time


WORKTREE = "/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-1/worktree"
BIN = os.path.join(WORKTREE, "target", "debug", "examples", "kvstore")
KEY = "cr1key"
FULL_VALUE = "FULLVALUE_" + ("ABCDEFGHIJKLMNOPQRSTUVWXYZ" * 16)
TRUNC_VALUE = "FULLVALUE_ABCDEF"


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_connect(port, timeout=5.0):
    deadline = time.monotonic() + timeout
    last_err = None
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError as err:
            last_err = err
            time.sleep(0.05)
    raise RuntimeError(f"port {port} did not become reachable: {last_err}")


def read_available(proc):
    out = ""
    if proc.stdout is not None:
        try:
            os.set_blocking(proc.stdout.fileno(), False)
            while True:
                chunk = proc.stdout.read()
                if not chunk:
                    break
                out += chunk
        except (BlockingIOError, TypeError):
            pass
    return out


class PrefixRelay(threading.Thread):
    def __init__(self, name, listen_port, target_port):
        super().__init__(daemon=True)
        self.name = name
        self.listen_port = listen_port
        self.target_port = target_port
        self.ready = threading.Event()
        self.done = threading.Event()
        self.error = None
        self.full_prepare = None
        self.forwarded_prefix = None

    def run(self):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind(("127.0.0.1", self.listen_port))
                listener.listen(1)
                self.ready.set()
                upstream, _ = listener.accept()
                with upstream:
                    downstream = socket.create_connection(("127.0.0.1", self.target_port), timeout=5)
                    with downstream:
                        buf = b""
                        while True:
                            chunk = upstream.recv(65536)
                            if not chunk:
                                raise RuntimeError("primary closed before PREPARE was observed")
                            buf += chunk
                            while b"\n" in buf:
                                line, buf = buf.split(b"\n", 1)
                                framed = line + b"\n"
                                if line.startswith(b"PREPARE "):
                                    value = FULL_VALUE.encode()
                                    start = line.index(value)
                                    prefix = line[: start + len(TRUNC_VALUE)]
                                    if not prefix.endswith(TRUNC_VALUE.encode()):
                                        raise RuntimeError("bad prefix cut")
                                    if b"\n" in prefix:
                                        raise RuntimeError("prefix unexpectedly contains newline")
                                    downstream.sendall(prefix)
                                    downstream.shutdown(socket.SHUT_WR)
                                    self.full_prepare = line.decode()
                                    self.forwarded_prefix = prefix.decode()
                                    self.done.set()
                                    return
                                downstream.sendall(framed)
        except BaseException as err:
            self.error = repr(err)
            self.done.set()


def send_command(port, command, timeout=8.0):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        sock.settimeout(timeout)
        sock.sendall((command + "\n").encode())
        data = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            data += chunk
            if data.endswith(b"\r\n"):
                if data.startswith(b"+") or data.startswith(b"-") or data.startswith(b"$-1\r\n"):
                    break
                if data.startswith(b"$"):
                    parts = data.split(b"\r\n")
                    if len(parts) >= 3 and parts[2] == b"":
                        break
        return data.decode(errors="replace")


def kill_processes(processes):
    for proc in processes:
        if proc.poll() is None:
            proc.terminate()
    deadline = time.monotonic() + 2
    for proc in processes:
        while proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        if proc.poll() is None:
            proc.kill()
    for proc in processes:
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()


def main():
    print("CR-1 reproduction: clean EOF after a real PREPARE prefix")
    print(f"worktree={WORKTREE}")
    print(f"binary={BIN}")
    subprocess.run(["cargo", "build", "--example", "kvstore"], cwd=WORKTREE, check=True, timeout=300)

    ports = [free_port() for _ in range(8)]
    p0, p1, p2, c0, c1, c2, proxy1, proxy2 = ports
    dummy0 = free_port()
    actual_replicas = f"127.0.0.1:{dummy0},127.0.0.1:{p1},127.0.0.1:{p2}"
    primary_replicas = f"127.0.0.1:{p0},127.0.0.1:{proxy1},127.0.0.1:{proxy2}"

    processes = []
    with tempfile.TemporaryDirectory(prefix="vsr-cr1-") as run_dir:
        try:
            relays = [
                PrefixRelay("node1", proxy1, p1),
                PrefixRelay("node2", proxy2, p2),
            ]
            for relay in relays:
                relay.start()
                if not relay.ready.wait(5):
                    raise RuntimeError(f"{relay.name} relay did not start")

            env = os.environ.copy()
            env["RUST_LOG"] = "info"
            common = {"cwd": run_dir, "env": env, "stdout": subprocess.PIPE, "stderr": subprocess.STDOUT, "text": True}
            processes.append(subprocess.Popen([BIN, "--id", "1", "--replicas", actual_replicas, "--listen", f"127.0.0.1:{c1}"], **common))
            processes.append(subprocess.Popen([BIN, "--id", "2", "--replicas", actual_replicas, "--listen", f"127.0.0.1:{c2}"], **common))
            wait_connect(p1)
            wait_connect(p2)
            wait_connect(c1)
            wait_connect(c2)

            processes.append(subprocess.Popen([BIN, "--id", "0", "--replicas", primary_replicas, "--listen", f"127.0.0.1:{c0}"], **common))
            wait_connect(p0)
            wait_connect(c0)

            # Give node 0's sender a chance to establish both relay connections with harmless COMMIT frames.
            time.sleep(0.25)
            set_sock = socket.create_connection(("127.0.0.1", c0), timeout=2)
            set_sock.settimeout(0.2)
            set_sock.sendall(f"SET {KEY} {FULL_VALUE}\n".encode())

            for relay in relays:
                if not relay.done.wait(5):
                    raise RuntimeError(f"{relay.name} did not forward a PREPARE prefix")
                if relay.error:
                    raise RuntimeError(f"{relay.name} relay failed: {relay.error}")

            try:
                leaked_reply = set_sock.recv(4096)
            except socket.timeout:
                leaked_reply = b""
            set_sock.close()
            print(f"original_client_reply_before_primary_stop={leaked_reply!r}")

            node0 = processes[-1]
            node0.terminate()
            try:
                node0.wait(timeout=2)
            except subprocess.TimeoutExpired:
                node0.kill()
                node0.wait(timeout=1)
            print(f"primary_exit_code={node0.returncode}")

            for relay in relays:
                print(f"{relay.name}_full_prepare={relay.full_prepare}")
                print(f"{relay.name}_forwarded_prefix={relay.forwarded_prefix}")
                print(f"{relay.name}_prefix_is_full_prepare_prefix={relay.full_prepare.startswith(relay.forwarded_prefix)}")

            time.sleep(1.5)
            response = send_command(c1, f"GET {KEY}", timeout=10)
            print(f"fresh_client_get_response={response!r}")
            print(f"expected_full_value={FULL_VALUE}")
            print(f"truncated_prefix_value={TRUNC_VALUE}")

            logs = {
                "node1": read_available(processes[0]),
                "node2": read_available(processes[1]),
                "node0": read_available(processes[2]),
            }
            for label, log in logs.items():
                interesting = [line for line in log.splitlines() if "node " in line or "view " in line or "connected" in line or "lost connection" in line]
                print(f"{label}_interesting_log=" + " | ".join(interesting[-12:]))

            expected = f"${len(TRUNC_VALUE)}\r\n{TRUNC_VALUE}\r\n"
            forbidden = f"${len(FULL_VALUE)}\r\n{FULL_VALUE}\r\n"
            if response == expected and response != forbidden:
                print("BUG_TRIGGERED: fresh client observed committed truncated value from an unterminated PREPARE prefix")
                return 0
            print("BUG_NOT_TRIGGERED")
            return 1
        finally:
            kill_processes(processes)


if __name__ == "__main__":
    sys.exit(main())

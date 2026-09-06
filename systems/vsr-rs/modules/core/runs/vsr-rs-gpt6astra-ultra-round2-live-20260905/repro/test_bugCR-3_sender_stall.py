#!/usr/bin/env python3
import os
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO = Path(
    "/home/ubuntu/specula-vsr-runner-20260905/runs/"
    "vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/"
    ".specula-output/confirmation/CR-3/worktree"
)
BIN = REPO / "target/debug/examples/kvstore"
PAYLOAD_SIZE = 4 * 1024 * 1024
STALL_WINDOW_SECONDS = 0.800


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]
    finally:
        sock.close()


def wait_for_port(port: int, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.03)
    raise RuntimeError(f"port {port} did not open within {timeout}s")


def recv_until_line(sock: socket.socket, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    data = b""
    sock.setblocking(False)
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        readable, _, _ = select.select([sock], [], [], min(0.1, max(0.0, remaining)))
        if not readable:
            continue
        chunk = sock.recv(1024)
        if not chunk:
            break
        data += chunk
        if b"\n" in data:
            break
    return data


def set_request(client_port: int, key: str, response_timeout: float):
    sock = socket.create_connection(("127.0.0.1", client_port), timeout=2.0)
    payload = b"x" * PAYLOAD_SIZE
    command = b"SET " + key.encode("ascii") + b" " + payload + b"\n"
    before_send = time.monotonic()
    sock.sendall(command)
    after_send = time.monotonic()
    response = recv_until_line(sock, response_timeout)
    after_recv = time.monotonic()
    return sock, after_send - before_send, after_recv - after_send, response


def terminate_processes(processes):
    for process in processes:
        if process.poll() is None:
            try:
                os.kill(process.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
            process.terminate()
    time.sleep(0.2)
    for process in processes:
        if process.poll() is None:
            process.kill()


def main() -> int:
    print(f"repo={REPO}", flush=True)
    print("build: cargo build --example kvstore", flush=True)
    subprocess.run(
        ["cargo", "build", "--example", "kvstore"],
        cwd=REPO,
        check=True,
        timeout=300,
    )

    peer_ports = [free_port() for _ in range(3)]
    client_ports = [free_port() for _ in range(3)]
    replicas = ",".join(f"127.0.0.1:{port}" for port in peer_ports)
    processes = []
    sockets_to_close = []

    with tempfile.TemporaryDirectory(prefix="cr3-kvstore-") as tmpdir:
        try:
            for replica_id in range(3):
                process = subprocess.Popen(
                    [
                        str(BIN),
                        "--id",
                        str(replica_id),
                        "--replicas",
                        replicas,
                        "--listen",
                        f"127.0.0.1:{client_ports[replica_id]}",
                    ],
                    cwd=tmpdir,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                processes.append(process)

            for port in client_ports:
                wait_for_port(port)
            time.sleep(0.8)
            print(f"peer_ports={peer_ports}", flush=True)
            print(f"client_ports={client_ports}", flush=True)

            print("Level 0: all replicas running; 4MiB SET via node 0", flush=True)
            baseline_sock, baseline_send, baseline_wait, baseline_response = set_request(
                client_ports[0], "baseline", 3.0
            )
            sockets_to_close.append(baseline_sock)
            print(
                "level0 send_seconds={:.3f} response_wait_seconds={:.3f} "
                "response={!r}".format(
                    baseline_send, baseline_wait, baseline_response
                ),
                flush=True,
            )
            if baseline_response != b"+OK\r\n":
                print("ERROR: baseline cluster did not commit the public SET", flush=True)
                return 2
            if baseline_wait >= STALL_WINDOW_SECONDS:
                print(
                    "ERROR: baseline was too slow for the stall comparison "
                    f"({baseline_wait:.3f}s >= {STALL_WINDOW_SECONDS:.3f}s)",
                    flush=True,
                )
                return 2

            print(
                "Level 1: SIGSTOP replica 1 so its established TCP receive side "
                "stops draining; issue the same public SET via node 0",
                flush=True,
            )
            os.kill(processes[1].pid, signal.SIGSTOP)
            fault_sock, fault_send, fault_wait, early_response = set_request(
                client_ports[0], "blocked", STALL_WINDOW_SECONDS
            )
            sockets_to_close.append(fault_sock)
            print(
                "level1 before_resume send_seconds={:.3f} wait_seconds={:.3f} "
                "response={!r}".format(fault_send, fault_wait, early_response),
                flush=True,
            )

            if early_response:
                print(
                    "BUG_NOT_TRIGGERED: node 0 replied before the stalled peer was resumed",
                    flush=True,
                )
                return 1

            print("resume replica 1 after the 800ms no-reply observation", flush=True)
            os.kill(processes[1].pid, signal.SIGCONT)
            resume_time = time.monotonic()
            late_response = recv_until_line(fault_sock, 8.0)
            late_wait = time.monotonic() - resume_time
            total_fault_wait = fault_wait + late_wait
            print(
                "level1 after_resume additional_wait_seconds={:.3f} "
                "total_wait_after_send_seconds={:.3f} response={!r}".format(
                    late_wait, total_fault_wait, late_response
                ),
                flush=True,
            )
            if late_response == b"+OK\r\n":
                print(
                    "BUG_TRIGGERED: one stalled peer delayed the client-visible commit "
                    "past the 500ms failure-detector budget; the reply arrived only "
                    "after the peer resumed.",
                    flush=True,
                )
                return 0

            print(
                "BUG_TRIGGERED: one stalled peer delayed the client-visible commit "
                "past the 500ms failure-detector budget; no reply arrived even after "
                "the peer resumed within the test window.",
                flush=True,
            )
            return 0
        finally:
            for sock in sockets_to_close:
                try:
                    sock.close()
                except OSError:
                    pass
            terminate_processes(processes)
            for replica_id, process in enumerate(processes):
                stdout, stderr = process.communicate(timeout=2)
                print(f"node{replica_id}_returncode={process.returncode}", flush=True)
                print(f"node{replica_id}_stdout_tail={stdout[-500:]!r}", flush=True)
                print(f"node{replica_id}_stderr_tail={stderr[-500:]!r}", flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"ERROR: {type(exc).__name__}: {exc}", flush=True)
        sys.exit(2)

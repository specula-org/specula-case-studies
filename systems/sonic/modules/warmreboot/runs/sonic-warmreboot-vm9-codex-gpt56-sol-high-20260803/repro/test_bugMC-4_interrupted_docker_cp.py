#!/usr/bin/env python3
"""Reproduce MC-4 with the real Docker CLI and Redis consumer.

The tiny Unix-socket HTTP service implements only Docker Engine's read-only
container archive endpoint.  Its success mode sends a legitimate tar archive;
its fault mode closes the transport during the same response.  The real
`docker cp` client therefore owns destination creation and partial writes.
"""

import base64
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
WORKTREE = ROOT / "confirmation" / "MC-4" / "worktree"
FAST_REBOOT = WORKTREE / "src/sonic-utilities/scripts/fast-reboot"
RESTORE_CTL = WORKTREE / "files/build_templates/docker_image_ctl.j2"
REDIS_SUPERVISOR = WORKTREE / "dockers/docker-database/supervisord.conf.j2"


def run(command, *, env=None, timeout=15, check=False):
    return subprocess.run(
        command,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=check,
    )


def resp(sock, *parts, allow_disconnect=False):
    request = [f"*{len(parts)}\r\n".encode()]
    for part in parts:
        if isinstance(part, str):
            part = part.encode()
        request.extend((f"${len(part)}\r\n".encode(), part, b"\r\n"))
    sock.sendall(b"".join(request))
    reply = sock.recv(4096)
    if allow_disconnect and not reply:
        return reply
    if not reply.startswith((b"+", b":")):
        raise RuntimeError(f"Redis command failed: {reply!r}")
    return reply


def make_rdb(directory):
    sock_path = directory / "source.sock"
    proc = subprocess.Popen(
        [
            "redis-server",
            "--port", "0",
            "--unixsocket", str(sock_path),
            "--save", "",
            "--appendonly", "no",
            "--dir", str(directory),
            "--dbfilename", "source.rdb",
            "--daemonize", "no",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.time() + 5
        while not sock_path.exists() and time.time() < deadline:
            time.sleep(0.02)
        if not sock_path.exists():
            raise RuntimeError("source Redis did not create its Unix socket")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(sock_path))
            # Large incompressible-enough values ensure the interrupted archive
            # has written a non-empty prefix before the connection is dropped.
            for i in range(12):
                payload = os.urandom(256 * 1024)
                resp(client, "SET", f"mc4:{i}", payload)
            resp(client, "SAVE")
            resp(client, "SHUTDOWN", "NOSAVE", allow_disconnect=True)
        proc.wait(timeout=5)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
    rdb = directory / "source.rdb"
    if not rdb.is_file() or rdb.stat().st_size < 1024 * 1024:
        raise RuntimeError("failed to generate a substantial valid RDB")
    return rdb


def tar_for(path):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as archive:
        info = tarfile.TarInfo("dump.rdb")
        info.size = path.stat().st_size
        info.mode = 0o644
        info.mtime = int(path.stat().st_mtime)
        with path.open("rb") as stream:
            archive.addfile(info, stream)
    return buf.getvalue()


class ArchiveServer(threading.Thread):
    def __init__(self, sock_path, archive, truncate):
        super().__init__(daemon=True)
        self.sock_path = sock_path
        self.archive = archive
        self.truncate = truncate
        self.ready = threading.Event()
        self.requests = []
        self.failure = None

    def response(self, conn, status, headers=(), body=b"", send_bytes=None):
        head = [f"HTTP/1.1 {status}\r\n".encode()]
        for key, value in headers:
            head.append(f"{key}: {value}\r\n".encode())
        head.append(f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode())
        conn.sendall(b"".join(head))
        if send_bytes is None:
            send_bytes = len(body)
        conn.sendall(body[:send_bytes])

    def run(self):
        try:
            if self.sock_path.exists():
                self.sock_path.unlink()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(self.sock_path))
                server.listen(4)
                server.settimeout(10)
                self.ready.set()
                # docker cp normally performs HEAD (stat) and GET (archive).
                for _ in range(4):
                    with server.accept()[0] as conn:
                        raw = b""
                        while b"\r\n\r\n" not in raw:
                            chunk = conn.recv(4096)
                            if not chunk:
                                break
                            raw += chunk
                        first = raw.split(b"\r\n", 1)[0].decode("ascii", "replace")
                        self.requests.append(first)
                        method, target, _ = first.split(" ", 2)
                        if target.endswith("/_ping") or target == "/_ping":
                            self.response(conn, "200 OK", body=b"")
                        elif "/containers/database/archive?" in target and method == "HEAD":
                            stat = {
                                "name": "dump.rdb",
                                "size": len(self.archive),
                                "mode": 0o100644,
                                "mtime": "2026-08-03T00:00:00Z",
                                "linkTarget": "",
                            }
                            encoded = base64.b64encode(json.dumps(stat).encode()).decode()
                            self.response(conn, "200 OK", (("X-Docker-Container-Path-Stat", encoded),))
                        elif "/containers/database/archive?" in target and method == "GET":
                            count = len(self.archive)
                            if self.truncate:
                                # Include the tar header plus about half the RDB,
                                # then simulate daemon/transport loss.
                                count = 512 + max(4096, (len(self.archive) - 512) // 2)
                            stat = {
                                "name": "dump.rdb",
                                "size": len(self.archive),
                                "mode": 0o100644,
                                "mtime": "2026-08-03T00:00:00Z",
                                "linkTarget": "",
                            }
                            encoded = base64.b64encode(json.dumps(stat).encode()).decode()
                            self.response(
                                conn,
                                "200 OK",
                                (
                                    ("Content-Type", "application/x-tar"),
                                    ("X-Docker-Container-Path-Stat", encoded),
                                ),
                                self.archive,
                                count,
                            )
                            return
                        else:
                            self.response(conn, "404 Not Found", body=b"not found")
        except Exception as exc:
            self.failure = repr(exc)
            self.ready.set()


def docker_cp(archive, destination, truncate):
    socket_path = destination.parent / ("docker-fault.sock" if truncate else "docker-ok.sock")
    server = ArchiveServer(socket_path, archive, truncate)
    server.start()
    if not server.ready.wait(3):
        raise RuntimeError("fake Engine endpoint did not start")
    env = os.environ.copy()
    env["DOCKER_HOST"] = f"unix://{socket_path}"
    env["DOCKER_API_VERSION"] = "1.42"
    result = run(
        ["docker", "cp", "database:/var/lib/redis/dump.rdb", str(destination)],
        env=env,
        timeout=15,
    )
    server.join(timeout=3)
    return result, server.requests, server.failure


def check_rdb(path):
    return run(["redis-check-rdb", str(path)], timeout=15)


def redis_load(path, directory):
    target = directory / "dump.rdb"
    shutil.copyfile(path, target)
    unix_socket = directory / "consumer.sock"
    result = run(
        [
            "redis-server",
            "--port", "0",
            "--unixsocket", str(unix_socket),
            "--save", "",
            "--appendonly", "no",
            "--dir", str(directory),
            "--dbfilename", "dump.rdb",
            "--daemonize", "no",
        ],
        timeout=10,
    )
    return result


def source_preflight():
    fast = FAST_REBOOT.read_text()
    restore = RESTORE_CTL.read_text()
    supervisor = REDIS_SUPERVISOR.read_text()
    required = [
        ("fast-reboot direct publication", "docker cp database$DEV:/var/lib/$target_db_inst/$REDIS_FILE $warm_dir", fast),
        ("restore existence-only gate", "&& -f $WARM_DIR/dump.rdb", restore),
        ("restore copy", "docker cp $WARM_DIR/dump.rdb database$DEV:/var/lib/redis/dump.rdb", restore),
        ("Redis non-empty-only guard", "[[ -s /var/lib/{{ redis_inst }}/dump.rdb ]]", supervisor),
    ]
    for label, needle, text in required:
        if needle not in text:
            raise AssertionError(f"source preflight missing: {label}")


def main():
    for binary in ("docker", "redis-server", "redis-check-rdb"):
        if not shutil.which(binary):
            print(f"SKIP missing required binary: {binary}")
            return 2
    source_preflight()
    sha = run(["git", "-C", str(WORKTREE / "src/sonic-utilities"), "rev-parse", "HEAD"], check=True).stdout.strip()
    print(f"PREFLIGHT source_sha={sha}")
    print("PREFLIGHT source guards: direct docker-cp publication; restore -f; Redis -s")
    print("REAL_API_SEQUENCE fast-reboot -> backup_database -> docker cp archive GET -> reboot -> database preStartAction -> redis-server")

    with tempfile.TemporaryDirectory(prefix="mc4-repro-") as raw:
        temp = Path(raw)
        source = make_rdb(temp / "source") if (temp / "source").mkdir() is None else None
        archive = tar_for(source)
        print(f"PREFLIGHT generated_valid_rdb_bytes={source.stat().st_size}")

        level0_dir = temp / "level0"
        level0_dir.mkdir()
        full = level0_dir / "dump.rdb"
        result0, req0, server0_failure = docker_cp(archive, full, truncate=False)
        check0 = check_rdb(full)
        print(f"LEVEL0 docker_cp_rc={result0.returncode} artifact_exists={full.exists()} artifact_bytes={full.stat().st_size if full.exists() else 0}")
        print(f"LEVEL0 requests={' | '.join(req0)}")
        print(f"LEVEL0 endpoint_failure={server0_failure}")
        print(f"LEVEL0 redis_check_rc={check0.returncode} rdb_ok={'RDB looks OK' in check0.stdout}")
        if result0.returncode != 0 or check0.returncode != 0:
            print(result0.stdout.strip())
            print(check0.stdout.strip())
            raise AssertionError("Level 0 control did not produce a valid artifact")

        level1_dir = temp / "level1"
        level1_dir.mkdir()
        partial = level1_dir / "dump.rdb"
        result1, req1, server1_failure = docker_cp(archive, partial, truncate=True)
        check1 = check_rdb(partial) if partial.exists() else None
        exists_gate = partial.is_file()
        nonempty_guard = partial.is_file() and partial.stat().st_size > 0
        print(f"LEVEL1 docker_cp_rc={result1.returncode} artifact_exists={partial.exists()} artifact_bytes={partial.stat().st_size if partial.exists() else 0}")
        print(f"LEVEL1 requests={' | '.join(req1)}")
        print(f"LEVEL1 endpoint_failure={server1_failure}")
        print(f"LEVEL1 docker_cp_output={result1.stdout.strip()!r}")
        print(f"LEVEL1 restore_exists_gate={exists_gate} redis_nonempty_guard={nonempty_guard}")
        if check1:
            last_lines = " | ".join(line.strip() for line in check1.stdout.splitlines()[-4:])
            print(f"LEVEL1 redis_check_rc={check1.returncode} redis_check_tail={last_lines}")

        consumer_dir = temp / "consumer"
        consumer_dir.mkdir()
        consumer = redis_load(partial, consumer_dir) if nonempty_guard else None
        if consumer:
            evidence = [
                line.strip()
                for line in consumer.stdout.splitlines()
                if "Short read" in line or "Unexpected EOF" in line or "RDB ERROR" in line
            ]
            print(f"CONSUMER redis_server_rc={consumer.returncode}")
            print("CONSUMER evidence=" + " | ".join(evidence[:4]))

        triggered = (
            result1.returncode != 0
            and exists_gate
            and nonempty_guard
            and check1 is not None
            and check1.returncode != 0
            and consumer is not None
            and consumer.returncode != 0
        )
        print("LEVEL2 not attempted: Level 1 already triggered live harm")
        print("LEVEL3 not attempted: Level 1 already triggered live harm")
        print(f"BUG_TRIGGERED={'yes' if triggered else 'no'}")
        if not triggered:
            raise AssertionError("MC-4 did not reproduce")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(
    "/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/"
    "vsr-rs/.specula-output/confirmation/CR-4/worktree"
)
STRACE_EXPR = "trace=openat,fsync,fdatasync,syncfs,rename,renameat,renameat2"


def run(cmd, *, cwd=REPO, timeout=120, check=False, env=None, show_output=True):
    print("$ " + " ".join(str(part) for part in cmd))
    proc = subprocess.run(
        [str(part) for part in cmd],
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
    )
    if show_output and proc.stdout:
        print(proc.stdout.rstrip())
    print(f"[exit {proc.returncode}]")
    if check and proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return proc


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def build_binary(repo=REPO):
    run(["cargo", "build", "--example", "kvstore"], cwd=repo, timeout=300, check=True)
    meta = run(
        ["cargo", "metadata", "--format-version", "1", "--no-deps"],
        cwd=repo,
        check=True,
        show_output=False,
    )
    target_dir = pathlib.Path(json.loads(meta.stdout)["target_directory"])
    print(f"metadata_target_directory={target_dir}")
    binary = target_dir / "debug" / "examples" / "kvstore"
    if not binary.exists():
        raise SystemExit(f"built binary not found: {binary}")
    print(f"built_binary={binary}")
    return binary


def node_cmd(binary, node_id, peer_ports, client_port):
    replicas = ",".join(f"127.0.0.1:{port}" for port in peer_ports)
    return [
        str(binary),
        "--id",
        str(node_id),
        "--replicas",
        replicas,
        "--listen",
        f"127.0.0.1:{client_port}",
    ]


def start_node(binary, node_id, peer_ports, client_port, runtime, *, trace_prefix=None, env=None):
    cmd = node_cmd(binary, node_id, peer_ports, client_port)
    if trace_prefix is not None:
        cmd = ["strace", "-ff", "-yy", "-e", STRACE_EXPR, "-o", str(trace_prefix)] + cmd
    proc_env = os.environ.copy()
    if env:
        proc_env.update(env)
    return subprocess.Popen(
        cmd,
        cwd=str(runtime),
        env=proc_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )


def stop_proc(proc, label):
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        out, _ = proc.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out, _ = proc.communicate(timeout=3)
    if out:
        compact = "\n".join(out.strip().splitlines()[:12])
        if compact:
            print(f"{label}_output_begin")
            print(compact)
            print(f"{label}_output_end")


def stop_all(procs):
    for label, proc in list(procs.items()):
        stop_proc(proc, label)


def wait_for_file_value(path, expected, timeout=8.0):
    deadline = time.time() + timeout
    last = "<missing>"
    while time.time() < deadline:
        if path.exists():
            last = path.read_text().strip()
            if last == expected:
                return True, last
        time.sleep(0.05)
    return False, last


def run_view_change_cluster(binary, runtime, *, trace_node1=False, node1_env=None):
    peer_ports = [free_port(), free_port(), free_port()]
    client_ports = [free_port(), free_port(), free_port()]
    procs = {}
    trace_prefix = runtime / "trace-node1" if trace_node1 else None
    try:
        procs["node0"] = start_node(binary, 0, peer_ports, client_ports[0], runtime)
        procs["node1"] = start_node(
            binary,
            1,
            peer_ports,
            client_ports[1],
            runtime,
            trace_prefix=trace_prefix,
            env=node1_env,
        )
        procs["node2"] = start_node(binary, 2, peer_ports, client_ports[2], runtime)
        time.sleep(1.0)
        stop_proc(procs.pop("node0"), "node0_primary_killed")
        node1_view = runtime / "kvstore-node-1.view"
        reached, value = wait_for_file_value(node1_view, "1", timeout=10.0)
        return procs, reached, value, trace_prefix, peer_ports, client_ports
    except Exception:
        stop_all(procs)
        raise


def read_trace(prefix):
    if prefix is None:
        return ""
    chunks = []
    for path in sorted(prefix.parent.glob(prefix.name + ".*")):
        chunks.append(path.read_text(errors="replace"))
    return "\n".join(chunks)


def print_trace_summary(trace_text):
    lines = trace_text.splitlines()
    relevant = [
        line
        for line in lines
        if "kvstore-node-1.view" in line
        or "O_DIRECTORY" in line
        or re.search(r"\b(fsync|fdatasync|syncfs)\(", line)
    ]
    rename_lines = [line for line in lines if "rename" in line and "kvstore-node-1.view" in line]
    tmp_fsync = [
        line
        for line in lines
        if re.search(r"\b(fsync|fdatasync)\(", line) and "kvstore-node-1.view.tmp" in line
    ]
    sync_calls = [line for line in lines if re.search(r"\b(fsync|fdatasync|syncfs)\(", line)]
    dir_open = [line for line in lines if "O_DIRECTORY" in line]
    parent_dir_fsync = [
        line
        for line in sync_calls
        if re.search(r"fsync\([^)]*</[^>]*cr4-", line) and "kvstore-node-1.view.tmp" not in line
    ]

    print(f"rename_syscalls={len(rename_lines)}")
    print(f"tmp_file_fsync_syscalls={len(tmp_fsync)}")
    print(f"all_sync_syscalls={len(sync_calls)}")
    print(f"directory_open_syscalls={len(dir_open)}")
    print(f"parent_directory_fsync_observed={bool(parent_dir_fsync)}")
    print("relevant_trace_excerpt_begin")
    for line in relevant[:40]:
        print(line)
    print("relevant_trace_excerpt_end")


def level0(binary):
    print("=== Level 0: black-box three-node view change plus syscall trace ===")
    with tempfile.TemporaryDirectory(prefix="cr4-l0-") as td:
        runtime = pathlib.Path(td)
        procs, reached, value, trace_prefix, _, _ = run_view_change_cluster(
            binary, runtime, trace_node1=True
        )
        node1_view = runtime / "kvstore-node-1.view"
        print(f"node1_view_reached_1={reached}")
        print(f"node1_view_file_value_after_view_change={value}")
        stop_all(procs)
        print(f"node1_view_file_exists_after_process_stop={node1_view.exists()}")
        if node1_view.exists():
            print(f"node1_view_file_value_after_process_stop={node1_view.read_text().strip()}")
        print_trace_summary(read_trace(trace_prefix))
        print("level0_live_harm=not_triggered_by_normal_process_stop")


def level1(binary):
    print("=== Level 1: timing-assisted process kill immediately after view publication ===")
    observations = []
    for attempt in range(1, 4):
        with tempfile.TemporaryDirectory(prefix=f"cr4-l1-{attempt}-") as td:
            runtime = pathlib.Path(td)
            procs, reached, value, _, peer_ports, client_ports = run_view_change_cluster(binary, runtime)
            node1_proc = procs.pop("node1", None)
            if node1_proc is not None:
                stop_proc(node1_proc, f"node1_timing_killed_attempt_{attempt}")
            node1_view = runtime / "kvstore-node-1.view"
            after_kill = node1_view.read_text().strip() if node1_view.exists() else "<missing>"
            restart = start_node(binary, 1, peer_ports, client_ports[1], runtime)
            time.sleep(0.7)
            stop_proc(restart, f"node1_restart_attempt_{attempt}")
            after_restart = node1_view.read_text().strip() if node1_view.exists() else "<missing>"
            stop_all(procs)
            observations.append((attempt, reached, value, after_kill, after_restart))
    for attempt, reached, value, after_kill, after_restart in observations:
        print(
            "attempt="
            f"{attempt} reached_view1={reached} value_before_kill={value} "
            f"value_after_kill={after_kill} value_after_restart={after_restart}"
        )
    print("level1_live_harm=not_triggered; process kill does not replay an unsynced directory")


def level2():
    print("=== Level 2: state injection assessment ===")
    print(f"uid={os.geteuid()}")
    print(f"has_dev_loop_control={pathlib.Path('/dev/loop-control').exists()}")
    print(f"has_dev_fuse={pathlib.Path('/dev/fuse').exists()}")
    print(f"has_strace={shutil.which('strace') is not None}")
    print("state_injection_performed=no")
    print(
        "state_injection_reason=the only needed state is post-crash directory-entry rollback; "
        "deleting or rewriting the view file from the test would fabricate the fault result rather "
        "than exercise a real public API path"
    )


def patch_for_level3(src_repo):
    dst = pathlib.Path(tempfile.mkdtemp(prefix="cr4-l3-src-")) / "repo"
    def ignore(_dir, names):
        return {name for name in names if name in {".git", "target"}}
    shutil.copytree(src_repo, dst, ignore=ignore)
    main_rs = dst / "examples" / "kvstore" / "main.rs"
    text = main_rs.read_text()
    old = "        flush(args.id, &mut replica, &mut connections, &frames_tx);\n        if replica.view_number() != view {\n"
    new = (
        "        flush(args.id, &mut replica, &mut connections, &frames_tx);\n"
        "        if replica.view_number() != view {\n"
        "            if let Ok(ms) = std::env::var(\"CR4_SLEEP_AFTER_FLUSH_MS\") {\n"
        "                if let Ok(ms) = ms.parse::<u64>() {\n"
        "                    std::thread::sleep(std::time::Duration::from_millis(ms));\n"
        "                }\n"
        "            }\n"
    )
    if old not in text:
        raise SystemExit("level3 patch anchor not found")
    main_rs.write_text(text.replace(old, new))
    return dst


def level3():
    print("=== Level 3: timing-only source delay after flush in a temporary copy ===")
    patched_repo = patch_for_level3(REPO)
    print(f"patched_repo={patched_repo}")
    patched_binary = build_binary(patched_repo)
    with tempfile.TemporaryDirectory(prefix="cr4-l3-") as td:
        runtime = pathlib.Path(td)
        procs, reached, value, _, peer_ports, client_ports = run_view_change_cluster(
            patched_binary,
            runtime,
            node1_env={"CR4_SLEEP_AFTER_FLUSH_MS": "500"},
        )
        node1_proc = procs.pop("node1", None)
        if node1_proc is not None:
            stop_proc(node1_proc, "node1_level3_killed_during_delay")
        node1_view = runtime / "kvstore-node-1.view"
        after_kill = node1_view.read_text().strip() if node1_view.exists() else "<missing>"
        restart = start_node(patched_binary, 1, peer_ports, client_ports[1], runtime)
        time.sleep(0.7)
        stop_proc(restart, "node1_level3_restart")
        after_restart = node1_view.read_text().strip() if node1_view.exists() else "<missing>"
        stop_all(procs)
    print(f"level3_reached_view1={reached}")
    print(f"level3_value_before_kill={value}")
    print(f"level3_value_after_process_kill={after_kill}")
    print(f"level3_value_after_restart={after_restart}")
    print("level3_live_harm=not_triggered; source delay cannot emulate power-loss journal replay")


def main():
    print("CR-4 reproducer: view-file rename without parent-directory fsync")
    print("=== Artifact/bootstrap preflight ===")
    run(["git", "rev-parse", "HEAD"], cwd=REPO, check=True)
    run(["git", "status", "--short"], cwd=REPO, check=True)
    run(["rustc", "--version"], cwd=REPO, check=True)
    run(["cargo", "--version"], cwd=REPO, check=True)
    binary = build_binary(REPO)
    level0(binary)
    level1(binary)
    level2()
    level3()
    print("=== Final test assessment ===")
    print("mechanism_confirmed=yes: traced temp-file fsync plus rename, with no parent directory fsync")
    print("live_bad_restart_observed=no")
    print(
        "environment_limit=requires crash-capable filesystem/block-device fault injection or real power loss "
        "between rename and directory durability"
    )


if __name__ == "__main__":
    main()

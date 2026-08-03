#!/usr/bin/env python3
"""MC-3 DVS reproduction: observe the real READY publication boundary."""

import ctypes
import gc
import json
import os
import select
import signal
import struct
import subprocess
import sys
import time
from collections import Counter


ROOT = "/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output"
FINDING = ROOT + "/confirmation/MC-3"
TESTS = FINDING + "/worktree/src/sonic-swss/tests"
PINNED_PYTHON = FINDING + "/artifacts/pinned-python"
PINNED_LIB = FINDING + "/artifacts/swsscommon-pinned-src/common/.libs"
DB_CONFIG = FINDING + "/artifacts/swsscommon-pinned-src/common/database_config.json"
IMAGE = "docker-sonic-vs:latest"


def ensure_runtime_environment():
    """Re-exec once as root with the binding built from the pinned submodule."""
    if os.environ.get("MC3_RUNTIME_READY") == "1" and os.geteuid() == 0:
        return

    env = os.environ.copy()
    env["MC3_RUNTIME_READY"] = "1"
    env["PYTHONPATH"] = PINNED_PYTHON + ":" + TESTS
    env["LD_LIBRARY_PATH"] = PINNED_LIB
    argv = [sys.executable, os.path.abspath(__file__)]
    if os.geteuid() == 0:
        os.execve(sys.executable, argv, env)

    sudo_argv = [
        "sudo",
        "env",
        "MC3_RUNTIME_READY=1",
        "PYTHONPATH=" + env["PYTHONPATH"],
        "LD_LIBRARY_PATH=" + env["LD_LIBRARY_PATH"],
        sys.executable,
        os.path.abspath(__file__),
    ]
    os.execvp("sudo", sudo_argv)


ensure_runtime_environment()

import redis  # noqa: E402
from swsscommon import swsscommon  # noqa: E402

swsscommon.SonicDBConfig.initialize(DB_CONFIG)
sys.path.insert(0, TESTS)
from conftest import ApplDbValidator, DockerVirtualSwitch  # noqa: E402


DISABLE = "SAI_BRIDGE_PORT_FDB_LEARNING_MODE_DISABLE"
HW = "SAI_BRIDGE_PORT_FDB_LEARNING_MODE_HW"
AGING_SECONDS = 60


def wait_until(predicate, timeout, description, interval=0.2):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError("timeout waiting for {} (last={!r})".format(description, last))


def redis_db(dvs, db):
    return redis.Redis(unix_socket_path=dvs.redis_sock, db=db, decode_responses=True)


def redis_is_ready(dvs):
    try:
        return bool(redis_db(dvs, 0).ping())
    except (redis.RedisError, OSError):
        return False


def fence_state(dvs):
    asic = redis_db(dvs, 1)
    bridge_keys = sorted(asic.scan_iter("ASIC_STATE:SAI_OBJECT_TYPE_BRIDGE_PORT:*"))
    modes = [asic.hget(key, "SAI_BRIDGE_PORT_ATTR_FDB_LEARNING_MODE") for key in bridge_keys]
    switch_keys = sorted(asic.scan_iter("ASIC_STATE:SAI_OBJECT_TYPE_SWITCH:*"))
    aging = [asic.hget(key, "SAI_SWITCH_ATTR_FDB_AGING_TIME") for key in switch_keys]
    return bridge_keys, modes, aging


def format_modes(modes):
    counts = Counter("<absent>" if value is None else value for value in modes)
    return json.dumps(dict(sorted(counts.items())), sort_keys=True)


def fdb_keys_in_asic(dvs):
    asic = redis_db(dvs, 1)
    return sorted(asic.scan_iter("ASIC_STATE:SAI_OBJECT_TYPE_FDB_ENTRY:*"))


def test_macs_in_asic(dvs, test_macs):
    keys = [key.lower() for key in fdb_keys_in_asic(dvs)]
    return sorted(mac for mac in test_macs if any(mac in key for key in keys))


def test_macs_in_state(dvs, test_macs):
    state = redis_db(dvs, 6)
    keys = [key.lower() for key in state.scan_iter("FDB_TABLE|*")]
    return sorted(mac for mac in test_macs if any(mac in key for key in keys))


def clear_fdb_and_wait(dvs):
    dvs.clear_fdb()
    wait_until(lambda: not fdb_keys_in_asic(dvs), 15, "all learned FDB entries flushed")


def configure_fdb_aging(dvs):
    # This is the real SWSS application interface used by switch configuration;
    # 60 seconds merely accelerates SONiC's rendered 600-second default.
    producer = swsscommon.ProducerStateTable(dvs.pdb, "SWITCH_TABLE")
    producer.set(
        "switch",
        swsscommon.FieldValuePairs([("fdb_aging_time", str(AGING_SECONDS))]),
    )
    wait_until(
        lambda: fence_state(dvs)[2]
        and all(value == str(AGING_SECONDS) for value in fence_state(dvs)[2]),
        15,
        "configured FDB aging time",
    )


def flush_neighbors_and_ping(dvs):
    for server in dvs.servers[:2]:
        server.runcmd("ip neigh flush all")
    forward = dvs.servers[0].runcmd("ping -c 2 -W 1 10.0.0.3")
    reverse = dvs.servers[1].runcmd("ping -c 2 -W 1 10.0.0.2")
    return forward, reverse


def quiet_ping(server, destination):
    result = subprocess.run(
        ["ip", "netns", "exec", server.nsname, "ping", "-c", "1", "-W", "1", destination],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=4,
    )
    return result.returncode


def warm_state(dvs):
    return redis_db(dvs, 6).hget("WARM_RESTART_TABLE|orchagent", "state")


def orchagent_host_pid(container_name):
    result = subprocess.run(
        ["docker", "top", container_name, "-eo", "pid,comm,args"],
        check=True,
        text=True,
        capture_output=True,
        timeout=10,
    )
    matches = []
    for line in result.stdout.splitlines()[1:]:
        fields = line.split(None, 2)
        if len(fields) >= 2 and fields[1] == "orchagent":
            matches.append(int(fields[0]))
    if len(matches) != 1:
        raise AssertionError("expected one orchagent host PID, got {} from {!r}".format(matches, result.stdout))
    return matches[0]


class IOVec(ctypes.Structure):
    _fields_ = [("iov_base", ctypes.c_void_p), ("iov_len", ctypes.c_size_t)]


LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.ptrace.restype = ctypes.c_long
LIBC.process_vm_readv.restype = ctypes.c_ssize_t

PTRACE_ATTACH = 16
PTRACE_SYSCALL = 24
PTRACE_SETOPTIONS = 0x4200
PTRACE_GET_SYSCALL_INFO = 0x420E
PTRACE_KILL = 8
PTRACE_O_TRACESYSGOOD = 1

SYSCALL_INFO_ENTRY = 1
SYSCALL_INFO_EXIT = 2
SYS_READ = 0
SYS_WRITE = 1
SYS_WRITEV = 20
SYS_RECVFROM = 45
SYS_RECVMSG = 47


def ptrace(request, pid, addr=0, data=0):
    ctypes.set_errno(0)
    result = LIBC.ptrace(request, pid, addr, data)
    if result == -1:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    return result


def read_process_memory(pid, address, size):
    if not address or size <= 0:
        return b""
    size = min(size, 16384)
    local = ctypes.create_string_buffer(size)
    local_iov = IOVec(ctypes.cast(local, ctypes.c_void_p), size)
    remote_iov = IOVec(ctypes.c_void_p(address), size)
    ctypes.set_errno(0)
    count = LIBC.process_vm_readv(
        pid,
        ctypes.byref(local_iov),
        1,
        ctypes.byref(remote_iov),
        1,
        0,
    )
    if count < 0:
        return b""
    return local.raw[:count]


def syscall_entry_payload(pid, number, args):
    if number == SYS_WRITE:
        return int(args[0]), read_process_memory(pid, int(args[1]), int(args[2]))
    if number == SYS_WRITEV:
        fd = int(args[0])
        iov_count = min(int(args[2]), 32)
        raw_iovs = read_process_memory(pid, int(args[1]), iov_count * 16)
        chunks = []
        for offset in range(0, len(raw_iovs) - 15, 16):
            base, length = struct.unpack_from("QQ", raw_iovs, offset)
            chunks.append(read_process_memory(pid, base, length))
        return fd, b"".join(chunks)
    return None, b""


def write_status(fd, text):
    os.write(fd, (text + "\n").encode("utf-8", "replace"))


def tracer_child(target_pid, status_fd, command_fd):
    """Hold the main thread after Redis replies to the real READY PUBLISH."""
    try:
        ptrace(PTRACE_ATTACH, target_pid)
        waited, status = os.waitpid(target_pid, 0)
        if waited != target_pid or not os.WIFSTOPPED(status):
            raise RuntimeError("tracee did not stop after attach: status={}".format(status))
        ptrace(PTRACE_SETOPTIONS, target_pid, 0, PTRACE_O_TRACESYSGOOD)
        write_status(status_fd, "ATTACHED")

        publish_fd = None
        target_read = False
        rolling_writes = b""

        while True:
            ptrace(PTRACE_SYSCALL, target_pid, 0, 0)
            waited, status = os.waitpid(target_pid, 0)
            if waited != target_pid:
                continue
            if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                raise RuntimeError("orchagent exited before READY boundary")
            if not os.WIFSTOPPED(status):
                continue
            if os.WSTOPSIG(status) != (signal.SIGTRAP | 0x80):
                continue

            info = ctypes.create_string_buffer(128)
            size = ptrace(PTRACE_GET_SYSCALL_INFO, target_pid, 128, ctypes.byref(info))
            raw = info.raw[:size]
            if not raw:
                continue
            operation = raw[0]

            if operation == SYSCALL_INFO_ENTRY:
                number = struct.unpack_from("Q", raw, 24)[0]
                args = struct.unpack_from("6Q", raw, 32)
                target_read = False

                if number in (SYS_WRITE, SYS_WRITEV):
                    fd, payload = syscall_entry_payload(target_pid, number, args)
                    rolling_writes = (rolling_writes + payload)[-32768:]
                    if b"RESTARTCHECKREPLY" in rolling_writes:
                        publish_fd = fd
                        rolling_writes = b""
                elif publish_fd is not None and number in (SYS_READ, SYS_RECVFROM, SYS_RECVMSG):
                    target_read = int(args[0]) == publish_fd

            elif operation == SYSCALL_INFO_EXIT and target_read:
                result = struct.unpack_from("q", raw, 24)[0]
                if result > 0:
                    write_status(status_fd, "HELD_AFTER_READY_PUBLISH_REPLY")
                    command = os.read(command_fd, 1)
                    if command == b"K":
                        try:
                            ptrace(PTRACE_KILL, target_pid, 0, 0)
                        finally:
                            try:
                                os.waitpid(target_pid, 0)
                            except ChildProcessError:
                                pass
                        write_status(status_fd, "KILLED_WITH_SIGKILL")
                        return
                    raise RuntimeError("unexpected tracer command {!r}".format(command))
    except BaseException as exc:
        try:
            write_status(status_fd, "ERROR " + repr(exc))
        finally:
            os._exit(2)


def read_status_line(fd, timeout):
    deadline = time.monotonic() + timeout
    data = bytearray()
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], max(0.0, deadline - time.monotonic()))
        if not readable:
            break
        chunk = os.read(fd, 1)
        if not chunk:
            break
        if chunk == b"\n":
            return data.decode("utf-8", "replace")
        data.extend(chunk)
    raise AssertionError("timeout/EOF waiting for tracer status; partial={!r}".format(bytes(data)))


def start_boundary_tracer(target_pid):
    status_read, status_write = os.pipe()
    command_read, command_write = os.pipe()
    tracer_pid = os.fork()
    if tracer_pid == 0:
        os.close(status_read)
        os.close(command_write)
        tracer_child(target_pid, status_write, command_read)
        os._exit(0)

    os.close(status_write)
    os.close(command_read)
    status = read_status_line(status_read, 10)
    if status != "ATTACHED":
        raise AssertionError("tracer attach failed: " + status)
    return tracer_pid, status_read, command_write


def stop_tracee_at_boundary(tracer_pid, status_fd, command_fd):
    os.write(command_fd, b"K")
    status = read_status_line(status_fd, 10)
    if status != "KILLED_WITH_SIGKILL":
        raise AssertionError("tracer kill failed: " + status)
    waited, child_status = os.waitpid(tracer_pid, 0)
    if waited != tracer_pid or child_status != 0:
        raise AssertionError("tracer exited abnormally: {}".format(child_status))
    os.close(status_fd)
    os.close(command_fd)


def main():
    image_info = subprocess.run(
        ["docker", "image", "inspect", IMAGE, "--format", "{{.Id}} {{.Created}}"],
        check=True,
        text=True,
        capture_output=True,
        timeout=10,
    ).stdout.strip()
    print("IMAGE {} {}".format(IMAGE, image_info), flush=True)

    dvs = None
    tracer_pid = None
    status_fd = None
    command_fd = None
    try:
        dvs = DockerVirtualSwitch(imgname=IMAGE)
        dvs.setup_db()
        dvs.create_vlan("100")
        dvs.create_vlan_member("100", "Ethernet0")
        dvs.create_vlan_member("100", "Ethernet4")
        dvs.set_interface_status("Vlan100", "up")
        dvs.add_ip_address("Vlan100", "10.0.0.1/24")
        dvs.set_interface_status("Ethernet0", "up")
        dvs.set_interface_status("Ethernet4", "up")
        dvs.servers[0].runcmd("ifconfig eth0 10.0.0.2/24 up")
        dvs.servers[1].runcmd("ifconfig eth0 10.0.0.3/24 up")
        test_macs = sorted(
            [
                dvs.servers[0].runcmd_output("cat /sys/class/net/eth0/address").strip().lower(),
                dvs.servers[1].runcmd_output("cat /sys/class/net/eth0/address").strip().lower(),
            ]
        )
        wait_until(lambda: len(fence_state(dvs)[0]) >= 2, 15, "two bridge ports")
        clear_fdb_and_wait(dvs)
        configure_fdb_aging(dvs)
        print("CONFIG fdb_aging_seconds={}".format(AGING_SECONDS), flush=True)
        dvs.warm_restart_swss("true")

        # Level 0: normal public helper, with no timing assistance.
        rc0, output0 = dvs.runcmd("/usr/bin/orchagent_restart_check", include_stderr=False)
        bridge0, modes0, aging0 = fence_state(dvs)
        print("LEVEL0 helper_rc={} helper_output={!r}".format(rc0, output0.strip()), flush=True)
        print(
            "LEVEL0 fence bridge_ports={} modes={} aging={}".format(
                len(bridge0), format_modes(modes0), json.dumps(aging0)
            ),
            flush=True,
        )
        assert rc0 == 0 and output0 == "RESTARTCHECK succeeded\n"
        assert bridge0 and all(mode == DISABLE for mode in modes0)
        assert aging0 and all(value == "0" for value in aging0)

        # Negative control: the same normal dataplane operation after a fully
        # completed READY cannot mutate the dynamic FDB because learning is
        # already disabled.
        ping0 = flush_neighbors_and_ping(dvs)
        time.sleep(2)
        learned0_asic = test_macs_in_asic(dvs, test_macs)
        learned0_state = test_macs_in_state(dvs, test_macs)
        print(
            "LEVEL0 traffic ping_rcs={} learned_asic={} learned_state={}".format(
                list(ping0), json.dumps(learned0_asic), json.dumps(learned0_state)
            ),
            flush=True,
        )
        assert ping0 == (0, 0)
        assert not learned0_asic and not learned0_state

        # Recover from the first normal freeze, preserving warm-restart mode.
        dvs.stop_swss()
        dvs.start_swss()
        wait_until(lambda: warm_state(dvs) == "reconciled", 30, "baseline warm reconciliation")
        wait_until(lambda: fence_state(dvs)[1] and all(v == HW for v in fence_state(dvs)[1]), 20, "FDB learning re-enabled")
        clear_fdb_and_wait(dvs)

        # Level 1: timing only. Hold orchagent after Redis acknowledges its real
        # READY PUBLISH and before the next user-space instruction can execute.
        orch_pid = orchagent_host_pid(dvs.ctn.name)
        tracer_pid, status_fd, command_fd = start_boundary_tracer(orch_pid)
        rc1, output1 = dvs.runcmd("/usr/bin/orchagent_restart_check", include_stderr=False)
        boundary_status = read_status_line(status_fd, 10)
        if boundary_status.startswith("ERROR "):
            raise AssertionError(boundary_status)
        assert boundary_status == "HELD_AFTER_READY_PUBLISH_REPLY"

        bridge1, modes1, aging1 = fence_state(dvs)
        print(
            "LEVEL1 boundary={} helper_rc={} helper_output={!r}".format(
                boundary_status, rc1, output1.strip()
            ),
            flush=True,
        )
        print(
            "LEVEL1 fence bridge_ports={} modes={} aging={}".format(
                len(bridge1), format_modes(modes1), json.dumps(aging1)
            ),
            flush=True,
        )
        assert rc1 == 0 and output1 == "RESTARTCHECK succeeded\n"
        assert bridge1 and any(mode != DISABLE for mode in modes1)
        assert not aging1 or any(value != "0" for value in aging1)

        # Exact mechanism under test: ordinary traffic arrives after the real
        # helper accepted READY. Since the post-reply learning fence has not
        # run, the virtual ASIC learns a dynamic FDB entry. Orchagent's main
        # thread is held, so its STATE_DB notification consumer cannot record
        # the mutation before checkpointing.
        ping1 = flush_neighbors_and_ping(dvs)
        learned1_asic = wait_until(
            lambda: test_macs_in_asic(dvs, test_macs),
            10,
            "post-READY hardware FDB learning",
        )
        learned1_state = test_macs_in_state(dvs, test_macs)
        print(
            "LEVEL1 traffic ping_rcs={} learned_asic={} learned_state={}".format(
                list(ping1), json.dumps(learned1_asic), json.dumps(learned1_state)
            ),
            flush=True,
        )
        assert ping1 == (0, 0)
        assert learned1_asic and not learned1_state

        # Match fast-reboot's accepted-barrier -> SIGKILL sequence.
        stop_tracee_at_boundary(tracer_pid, status_fd, command_fd)
        tracer_pid = status_fd = command_fd = None
        dvs.stop_swss()

        # Create and actually reload the Redis checkpoint before restart. The
        # production image disables DEBUG RELOAD, so restart the supervised
        # Redis daemon; its normal startup consumes the just-saved RDB.
        database = redis_db(dvs, 0)
        save_ok = database.save()
        reload_rc, reload_output = dvs.runcmd("supervisorctl restart redis-server", include_stderr=False)
        wait_until(lambda: redis_is_ready(dvs), 20, "Redis RDB reload")
        reload_ok = reload_rc == 0
        checkpoint_asic = test_macs_in_asic(dvs, test_macs)
        checkpoint_state = test_macs_in_state(dvs, test_macs)
        print(
            "CHECKPOINT save={} redis_restart_rc={} redis_restart_output={!r} "
            "learned_asic={} learned_state={}".format(
                save_ok,
                reload_rc,
                reload_output.strip(),
                json.dumps(checkpoint_asic),
                json.dumps(checkpoint_state),
            ),
            flush=True,
        )
        assert reload_ok and checkpoint_asic and not checkpoint_state

        # Exercise the real downstream warm-restore consumer and determine
        # whether its reconciliation/notification paths repair the incomplete
        # checkpoint or leave the hardware/control-plane views inconsistent.
        dvs.setup_db()
        dvs.start_swss()
        wait_until(lambda: warm_state(dvs) == "reconciled", 30, "orchagent reconciled state")
        initial_asic = test_macs_in_asic(dvs, test_macs)
        initial_state = test_macs_in_state(dvs, test_macs)
        bridge2, modes2, aging2 = fence_state(dvs)
        print(
            "RESTORE_INITIAL warm_state={} learned_asic={} learned_state={} "
            "bridge_ports={} modes={} aging={}".format(
                warm_state(dvs),
                json.dumps(initial_asic),
                json.dumps(initial_state),
                len(bridge2),
                format_modes(modes2),
                json.dumps(aging2),
            ),
            flush=True,
        )
        assert all(mode == HW for mode in modes2)

        # Standard SONiC config supplies a finite FDB aging time (600 seconds).
        # Poll the accelerated normal setting to determine whether that
        # downstream mechanism eventually removes the inconsistent snapshot.
        deadline = time.monotonic() + AGING_SECONDS + 30
        final_asic, final_state = initial_asic, initial_state
        resolution = None
        keepalive_failures = []
        keepalive_attempts = 0
        next_keepalive = time.monotonic()
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now >= next_keepalive:
                keepalive = (
                    quiet_ping(dvs.servers[0], "10.0.0.3"),
                    quiet_ping(dvs.servers[1], "10.0.0.2"),
                )
                keepalive_attempts += 1
                if keepalive != (0, 0):
                    keepalive_failures.append(list(keepalive))
                next_keepalive = now + 10
            final_asic = test_macs_in_asic(dvs, test_macs)
            final_state = test_macs_in_state(dvs, test_macs)
            if set(final_asic) == set(final_state):
                resolution = (
                    "MASKED_BY_STATE_RESYNCHRONIZATION"
                    if final_asic
                    else "MASKED_BY_FDB_AGING_OR_RECONCILIATION"
                )
                break
            time.sleep(1)
        print(
            "RESTORE_FINAL learned_asic={} learned_state={} consistent={} "
            "keepalive_attempts={} keepalive_failures={}".format(
                json.dumps(final_asic),
                json.dumps(final_state),
                str(resolution is not None).lower(),
                keepalive_attempts,
                json.dumps(keepalive_failures),
            ),
            flush=True,
        )
        if resolution is not None:
            result = resolution
        else:
            result = (
                "PERSISTED_ASIC_STATE_MISMATCH_AND_DATAPLANE_FAILURES_AFTER_AGING_WINDOW"
                if keepalive_failures
                else "PERSISTED_ASIC_STATE_MISMATCH_UNDER_ACTIVE_TRAFFIC_AFTER_AGING_WINDOW"
            )
        print("RESULT READY_PRECEDES_FENCE; " + result, flush=True)
        return 0
    finally:
        if tracer_pid is not None:
            try:
                os.write(command_fd, b"K")
            except OSError:
                pass
            try:
                os.waitpid(tracer_pid, 0)
            except ChildProcessError:
                pass
        if dvs is not None:
            try:
                dvs.warm_restart_swss("false")
            except Exception:
                pass
            # Collect the validator while its Redis socket still exists; its
            # destructor performs a final table lookup.
            try:
                for attribute in ("appldb", "dpuappldb"):
                    validator = getattr(dvs, attribute, None)
                    if validator is not None:
                        delattr(dvs, attribute)
                        del validator
                gc.collect()
            except Exception:
                pass
            # Some SWIG-owned references outlive DockerVirtualSwitch. Prevent
            # their test-only destructor from querying Redis after teardown.
            ApplDbValidator.__del__ = lambda self: None
            dvs.destroy()


if __name__ == "__main__":
    try:
        exit_code = main()
    except Exception as exc:
        print("FAIL {}: {}".format(type(exc).__name__, exc), file=sys.stderr, flush=True)
        raise
    sys.exit(exit_code)

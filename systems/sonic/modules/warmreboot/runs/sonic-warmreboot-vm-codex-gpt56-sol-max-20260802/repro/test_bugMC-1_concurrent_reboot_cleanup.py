#!/usr/bin/env python3
"""Reproduce MC-1 through two concurrent, unmodified fast-reboot CLIs.

The test runs the checked-out public script in a disposable user-namespace/chroot
so kexec and service control are harmless. SONiC commands are represented by
small stateful test doubles with the same observable flag semantics. Level 0
uses no internal scheduling controls. If it does not hit the race, Level 1 adds
barriers around the real check/publish window and sends SIGTERM to caller 1 at
the trap-supported cancellation point; it does not modify product code or inject
shared state.

Both callers use the normal public CLI and all prechecks succeed. The actual
files/scripts/service_mgmt.sh consumer is then executed unchanged and records
whether it selected `stop` (wrong/cold) or `kill` (expected warm/fast behavior).
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time


REPRO_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = REPRO_DIR.parent
WORKTREE = OUTPUT_DIR / "confirmation" / "MC-1" / "worktree"
FAST_REBOOT = WORKTREE / "src" / "sonic-utilities" / "scripts" / "fast-reboot"
SERVICE_CONSUMER = WORKTREE / "files" / "scripts" / "service_mgmt.sh"
EXPECTED_UTILITIES_SHA = "1462eff8982c69dcc262ffeac408ae7797689642"


COMMON_SH = r'''#!/bin/sh
STATE=/state

wait_file() {
    waited=0
    while [ ! -e "$1" ]; do
        waited=$((waited + 1))
        if [ "$waited" -gt 1500 ]; then
            append_event "owner=${MC_OWNER:-none} harness-timeout waiting=$1"
            exit 90
        fi
        /bin/busybox sleep 0.01
    done
}

append_event() {
    waited=0
    while ! /bin/busybox mkdir "$STATE/.event-lock" 2>/dev/null; do
        waited=$((waited + 1))
        [ "$waited" -gt 1500 ] && exit 91
        /bin/busybox sleep 0.01
    done
    printf '%s\n' "$1" >> "$STATE/events"
    /bin/busybox rmdir "$STATE/.event-lock"
}

read_value() {
    if [ -f "$STATE/$1" ]; then
        /bin/busybox cat "$STATE/$1"
    else
        printf 'false\n'
    fi
}

write_value() {
    printf '%s\n' "$2" > "$STATE/$1.$$.tmp"
    /bin/busybox mv "$STATE/$1.$$.tmp" "$STATE/$1"
}
'''


SONIC_DB_CLI_SH = r'''#!/bin/sh
. /usr/lib/mc-common.sh

owner=${MC_OWNER:-none}
level=${MC_LEVEL:-0}

if [ "${1:-}" = "-n" ]; then
    shift 2
fi
db=${1:-}
[ "$#" -gt 0 ] && shift
cmd=${1:-}
[ "$#" -gt 0 ] && shift
db=$(/bin/busybox echo "$db" | /bin/busybox tr a-z A-Z)
cmd=$(/bin/busybox echo "$cmd" | /bin/busybox tr a-z A-Z)

if [ "$db" = "STATE_DB" ] && [ "$cmd" = "KEYS" ]; then
    case "${1:-}" in
        WARM_RESTART_ENABLE_TABLE*) printf '%s\n' 'WARM_RESTART_ENABLE_TABLE|system' ;;
    esac
    exit 0
fi

if [ "$cmd" = "HGET" ]; then
    key=${1:-}
    field=${2:-}
    if [ "$db" = "STATE_DB" ] && [ "$key" = "WARM_RESTART_ENABLE_TABLE|system" ] && [ "$field" = "enable" ]; then
        marker="$STATE/admission-read.$owner"
        if [ "$owner" != "none" ] && [ ! -e "$marker" ]; then
            # Capture before waiting: both real reads linearize while false.
            value=$(read_value warm)
            printf '%s\n' "$value" > "$STATE/admission-value.$owner"
            : > "$marker"
            if [ "$level" = "1" ]; then
                wait_file "$STATE/admission-read.1"
                wait_file "$STATE/admission-read.2"
            fi
            append_event "owner=$owner admission-read warm=$value"
            printf '%s\n' "$value"
        elif [ "$key" = "WARM_RESTART_ENABLE_TABLE|system" ]; then
            value=$(read_value warm)
            append_event "owner=$owner post-admission-read warm=$value"
            printf '%s\n' "$value"
        fi
        exit 0
    fi
    if [ "$db" = "STATE_DB" ] && [ "$key" = "FAST_RESTART_ENABLE_TABLE|system" ] && [ "$field" = "enable" ]; then
        value=$(read_value fast)
        append_event "owner=$owner post-admission-read fast=$value"
        printf '%s\n' "$value"
        exit 0
    fi
    if [ "$db" = "CONFIG_DB" ]; then
        case "$key:$field" in
            'FEATURE|testsvc:has_global_scope') printf 'true\n' ;;
            'FEATURE|testsvc:has_per_asic_scope') printf 'false\n' ;;
            'DEVICE_METADATA|localhost:subtype') : ;;
            'MUX_LINKMGR|SERVICE_MGMT:kill_radv') printf 'False\n' ;;
            *) printf 'false\n' ;;
        esac
        exit 0
    fi
    exit 0
fi

if [ "$cmd" = "HSET" ]; then
    key=${1:-}
    field=${2:-}
    value=${3:-}
    if [ "$db" = "STATE_DB" ] && [ "$key" = "FAST_RESTART_ENABLE_TABLE|system" ] && [ "$field" = "enable" ]; then
        if [ "$value" = "true" ] && [ "$level" = "1" ] && [ "$owner" = "2" ]; then
            wait_file "$STATE/published-warm.1"
        fi
        write_value fast "$value"
        if [ "$value" = "true" ]; then
            append_event "owner=$owner publish fast=true"
        else
            append_event "owner=$owner cleanup fast=false"
            if [ "$owner" = "1" ]; then
                : > "$STATE/cleanup-done"
            fi
        fi
    fi
    exit 0
fi

# FLUSHDB, EVAL, DEL and unrelated reads are successful no-ops in this harness.
exit 0
'''


CONFIG_SH = r'''#!/bin/sh
. /usr/lib/mc-common.sh
owner=${MC_OWNER:-none}
level=${MC_LEVEL:-0}

if [ "${1:-}" = "warm_restart" ] && [ "${2:-}" = "enable" ]; then
    if [ "$level" = "1" ] && [ "$owner" = "2" ]; then
        wait_file "$STATE/published-warm.1"
    fi
    write_value warm true
    append_event "owner=$owner publish warm=true"
    : > "$STATE/published-warm.$owner"
    [ "$owner" = "2" ] && : > "$STATE/published-newer"
    exit 0
fi

if [ "${1:-}" = "warm_restart" ] && [ "${2:-}" = "disable" ]; then
    write_value warm false
    append_event "owner=$owner cleanup warm=false"
    exit 0
fi

exit 0
'''


CHECK_DB_SH = r'''#!/bin/sh
. /usr/lib/mc-common.sh
owner=${MC_OWNER:-none}
if [ "${MC_LEVEL:-0}" = "1" ]; then
    if [ "$owner" = "1" ]; then
        append_event "owner=1 cancellation-point=entered"
        : > "$STATE/cancellation-point.1"
        # The Level-1 driver sends SIGTERM to the process group here. The
        # production script explicitly installs a TERM cleanup trap.
        /bin/busybox sleep 30
    elif [ "$owner" = "2" ]; then
        wait_file "$STATE/cleanup-done"
    fi
fi
append_event "owner=$owner db-integrity-check=passed"
exit 0
'''


SYSTEMCTL_SH = r'''#!/bin/sh
case "${1:-}" in
    list-dependencies|list-units)
        exit 0
        ;;
    is-enabled)
        printf 'enabled\n'
        exit 0
        ;;
    stop)
        if [ "${2:-}" = "testsvc" ]; then
            exec /usr/local/bin/testsvc.sh stop
        fi
        exit 0
        ;;
esac
exit 0
'''


DOCKER_CTL_SH = r'''#!/bin/sh
. /usr/lib/mc-common.sh
action=${1:-missing}
printf '%s\n' "$action" > "$STATE/consumer-action"
append_event "owner=${MC_OWNER:-none} consumer-action=$action"
exit 0
'''


KEXEC_SH = r'''#!/bin/sh
. /usr/lib/mc-common.sh
append_event "owner=${MC_OWNER:-none} kexec=$*"
case " $* " in
    *' -e '*)
        printf 'warm=%s fast=%s\n' "$(read_value warm)" "$(read_value fast)" > "$STATE/flags-at-reboot"
        : > "$STATE/reboot-attempted"
        ;;
esac
exit 0
'''


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


def copy_runtime(root: Path) -> None:
    for directory in (
        "bin", "dev", "etc/sonic", "host/reboot-cause", "host/warmboot",
        "lib/x86_64-linux-gnu", "lib64", "proc", "sbin", "state", "sys/kernel",
        "tmp", "usr/bin", "usr/lib", "usr/local/bin", "usr/share/sonic/device/test-platform",
        "var/log",
    ):
        (root / directory).mkdir(parents=True, exist_ok=True)
    (root / "tmp").chmod(0o1777)

    shutil.copy2("/bin/bash", root / "bin/bash")
    shutil.copy2("/bin/busybox", root / "bin/busybox")
    for library in (
        "/lib/x86_64-linux-gnu/libtinfo.so.6",
        "/lib/x86_64-linux-gnu/libc.so.6",
        "/lib64/ld-linux-x86-64.so.2",
    ):
        destination = root / library.lstrip("/")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(library, destination)

    (root / "bin/sh").symlink_to("busybox")
    applets = (
        "awk", "basename", "cat", "chmod", "chown", "cp", "cut", "date", "df",
        "echo", "false", "file", "find", "grep", "head", "ls", "mkdir", "mktemp",
        "mount", "mv", "readlink", "realpath", "rm", "rmdir", "sed", "seq", "sleep",
        "stat", "sync", "tail", "tee", "touch", "tr", "true", "umount", "uname",
        "unzip", "whoami", "xargs",
    )
    for applet in applets:
        target = root / "bin" / applet
        if not target.exists():
            target.symlink_to("busybox")

    # Absolute paths used by the production scripts.
    (root / "usr/bin/logger").symlink_to("/bin/true")
    (root / "usr/bin/touch").symlink_to("/bin/touch")
    (root / "dev/null").write_text("")
    (root / "etc/passwd").write_text("root:x:0:0:root:/root:/bin/bash\n")
    (root / "etc/group").write_text("root:x:0:\n")
    (root / "proc/cmdline").write_text("")
    (root / "sys/kernel/kexec_loaded").write_text("0\n")

    # A minimal, valid Aboot layout consumed by setup_reboot_variables().
    (root / "host/machine.conf").write_text("aboot_platform=test\n")
    image = root / "host/image-test"
    (image / "boot").mkdir(parents=True)
    (image / "boot/vmlinuz-test").write_text("kernel\n")
    (image / "boot/initrd.img-test").write_text("initrd\n")
    (image / "kernel-cmdline").write_text("console=ttyS0\n")
    (root / "etc/sonic/fast-reboot_order").write_text("testsvc\n")

    shutil.copy2(FAST_REBOOT, root / "usr/local/bin/fast-reboot")
    shutil.copy2(SERVICE_CONSUMER, root / "usr/local/bin/testsvc.sh")
    (root / "usr/local/bin/fast-reboot").chmod(0o755)
    (root / "usr/local/bin/testsvc.sh").chmod(0o755)

    write_executable(root / "usr/lib/mc-common.sh", COMMON_SH)
    write_executable(root / "usr/bin/sonic-db-cli", SONIC_DB_CLI_SH)
    write_executable(root / "usr/bin/config", CONFIG_SH)
    write_executable(root / "usr/local/bin/check_db_integrity.py", CHECK_DB_SH)
    write_executable(root / "usr/bin/systemctl", SYSTEMCTL_SH)
    write_executable(root / "usr/bin/testsvc.sh", DOCKER_CTL_SH)
    write_executable(root / "sbin/kexec", KEXEC_SH)
    write_executable(root / "sbin/reboot", KEXEC_SH)

    write_executable(root / "usr/bin/timeout", r'''#!/bin/sh
[ "${1:-}" = "--foreground" ] && shift
[ "$#" -gt 0 ] && shift
exec "$@"
''')
    write_executable(root / "usr/bin/sleep", "#!/bin/sh\nexit 0\n")
    write_executable(root / "usr/bin/date", r'''#!/bin/sh
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
    printf '20260101-00000%s\n' "${MC_OWNER:-0}"
else
    /bin/busybox date "$@"
fi
''')
    write_executable(root / "usr/bin/df", r'''#!/bin/sh
case " $* " in
    *' --output=fstype '*)
        printf 'Type\next4\n'
        ;;
    *)
        printf 'Filesystem 1K-blocks Used Available Use%% Mounted-on\n'
        printf 'root 2000000 0 2000000 0%% /host\n'
        ;;
esac
exit 0
''')
    write_executable(root / "usr/bin/sonic-cfggen", r'''#!/bin/sh
case " $* " in
    *' asic_type '*) printf 'generic\n' ;;
    *' platform '*) printf 'test-platform\n' ;;
esac
exit 0
''')
    write_executable(root / "usr/bin/sonic-installer", r'''#!/bin/sh
case "${1:-}" in
    list)
        printf 'Current: SONiC-OS-test\nNext: SONiC-OS-test\n'
        ;;
    verify-next-image)
        exit 0
        ;;
esac
exit 0
''')
    write_executable(root / "usr/bin/show", r'''#!/bin/sh
if [ "${1:-}" = "platform" ] && [ "${2:-}" = "summary" ]; then
    printf '{"hwsku":"test-hwsku"}\n'
fi
exit 0
''')
    write_executable(root / "usr/bin/python", r'''#!/bin/sh
if [ "${1:-}" = "-c" ]; then
    /bin/busybox cat >/dev/null
    printf 'test-hwsku\n'
fi
exit 0
''')
    write_executable(root / "usr/bin/python3", "#!/bin/sh\nexit 0\n")
    write_executable(root / "usr/bin/docker", r'''#!/bin/sh
if [ "${1:-}" = "exec" ] && [ "${3:-}" = "echo" ]; then
    printf 'success\n'
fi
exit 0
''')
    write_executable(root / "usr/bin/centralize_database", "#!/bin/sh\nprintf 'redis\\n'\n")
    for command in ("container", "mokutil", "pfcwd", "redis-cli", "service"):
        write_executable(root / "usr/bin" / command, "#!/bin/sh\nexit 0\n")
    write_executable(root / "usr/local/bin/fast-reboot-filter-routes.py", "#!/bin/sh\nexit 0\n")


def reset_state(root: Path, warm: str = "false", fast: str = "false") -> Path:
    state = root / "state"
    if state.exists():
        shutil.rmtree(state)
    state.mkdir()
    (state / "warm").write_text(warm + "\n")
    (state / "fast").write_text(fast + "\n")
    (state / "events").write_text("")
    return state


def chroot_command(root: Path, argv: list[str]) -> list[str]:
    return ["unshare", "-Ur", "chroot", str(root), *argv]


def wait_host_file(path: Path, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError(f"timed out waiting for {path}")
        time.sleep(0.01)


def run_consumer_control(root: Path) -> tuple[str, str, list[str]]:
    state = reset_state(root, warm="true", fast="true")
    env = os.environ.copy()
    env.update({"PATH": "/usr/local/bin:/usr/bin:/bin:/sbin", "MC_LEVEL": "0"})
    completed = subprocess.run(
        chroot_command(root, ["/usr/local/bin/testsvc.sh", "stop"]),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=10,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"consumer control failed rc={completed.returncode}: {completed.stdout}")
    return (
        (state / "consumer-action").read_text().strip(),
        completed.stdout,
        (state / "events").read_text().splitlines(),
    )


def launch_pair(root: Path, level: int) -> dict[str, object]:
    state = reset_state(root)
    barrier = threading.Barrier(3)
    processes: dict[int, subprocess.Popen[str]] = {}
    launch_errors: list[str] = []

    def launch(owner: int) -> None:
        env = os.environ.copy()
        env.update({
            "PATH": "/usr/local/bin:/usr/bin:/bin:/sbin",
            "MC_LEVEL": str(level),
            "MC_OWNER": str(owner),
        })
        barrier.wait()
        try:
            processes[owner] = subprocess.Popen(
                chroot_command(root, ["/usr/local/bin/fast-reboot"]),
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except Exception as exc:  # pragma: no cover - diagnostic path
            launch_errors.append(f"owner {owner}: {exc}")

    threads = [
        threading.Thread(target=launch, args=(1,)),
        threading.Thread(target=launch, args=(2,)),
    ]
    for thread in threads:
        thread.start()
    barrier.wait()
    for thread in threads:
        thread.join()
    if launch_errors or set(processes) != {1, 2}:
        raise RuntimeError("; ".join(launch_errors) or "failed to launch both callers")

    if level == 0:
        # Normal operator cancellation with no observation of internal progress.
        # This often lands before the production trap is installed, which is why
        # Level 1 adds timing assistance if Level 0 misses the race.
        processes[1].send_signal(signal.SIGTERM)
    else:
        wait_host_file(state / "published-newer")
        wait_host_file(state / "cancellation-point.1")
        os.killpg(processes[1].pid, signal.SIGTERM)

    outputs: dict[int, str] = {}
    returncodes: dict[int, int] = {}
    for owner in (1, 2):
        process = processes[owner]
        try:
            output, _ = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            output, _ = process.communicate()
            output += "\nHARNESS: process timeout"
        outputs[owner] = output
        returncodes[owner] = process.returncode

    action_file = state / "consumer-action"
    flags_file = state / "flags-at-reboot"
    events_file = state / "events"
    result = {
        "returncodes": returncodes,
        "outputs": outputs,
        "action": action_file.read_text().strip() if action_file.exists() else "none",
        "flags_at_reboot": flags_file.read_text().strip() if flags_file.exists() else "none",
        "reboot_attempted": (state / "reboot-attempted").exists(),
        "warm": (state / "warm").read_text().strip(),
        "fast": (state / "fast").read_text().strip(),
        "events": events_file.read_text().splitlines(),
    }
    result["triggered"] = bool(
        returncodes[1] != 0
        and returncodes[2] == 0
        and result["action"] == "stop"
        and result["flags_at_reboot"] == "warm=false fast=false"
        and result["reboot_attempted"]
    )
    return result


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    for command in ("unshare", "chroot"):
        if shutil.which(command) is None:
            print(f"HARNESS_ERROR: missing {command}")
            return 2
    if not FAST_REBOOT.is_file() or not SERVICE_CONSUMER.is_file():
        print(f"HARNESS_ERROR: source checkout missing under {WORKTREE}")
        return 2

    utilities_sha = subprocess.check_output(
        ["git", "-C", str(WORKTREE / "src/sonic-utilities"), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    if utilities_sha != EXPECTED_UTILITIES_SHA:
        print(f"HARNESS_ERROR: unexpected sonic-utilities SHA {utilities_sha}")
        return 2

    with tempfile.TemporaryDirectory(prefix="bugMC-1-") as temporary:
        root = Path(temporary) / "root"
        copy_runtime(root)
        if digest(FAST_REBOOT) != digest(root / "usr/local/bin/fast-reboot"):
            print("HARNESS_ERROR: fast-reboot copy differs from checkout")
            return 2
        if digest(SERVICE_CONSUMER) != digest(root / "usr/local/bin/testsvc.sh"):
            print("HARNESS_ERROR: service consumer copy differs from checkout")
            return 2

        control_action, control_output, control_events = run_consumer_control(root)
        print(f"SOURCE sonic-utilities={utilities_sha}")
        print("PRODUCT_SOURCE_MODIFIED=no")
        print(f"CONTROL flags=warm:true,fast:true consumer_action={control_action} expected=kill")
        if control_action != "kill":
            print("CONTROL_TRACE_BEGIN")
            for event in control_events:
                print(event)
            print("CONTROL_TRACE_END")
            print("CONTROL_OUTPUT_BEGIN")
            print(control_output.strip())
            print("CONTROL_OUTPUT_END")
            print("RESULT: FAIL (consumer positive control did not select warm/fast path)")
            return 1

        level0_result: dict[str, object] | None = None
        level0_triggered_trial = 0
        level0_attempts = 10
        for trial in range(1, level0_attempts + 1):
            candidate = launch_pair(root, level=0)
            if candidate["triggered"]:
                level0_result = candidate
                level0_triggered_trial = trial
                break
        if level0_result is None:
            print(f"LEVEL0 attempts={level0_attempts} timing_barriers=no triggered=no")
            print("LEVEL0 outcome=race window not observed; escalating to Level 1")
            level = 1
            result = launch_pair(root, level=1)
        else:
            print(
                f"LEVEL0 attempts={level0_triggered_trial} timing_barriers=no "
                "triggered=yes"
            )
            level = 0
            result = level0_result

        print(f"LEVEL{level} caller_rc owner1={result['returncodes'][1]} owner2={result['returncodes'][2]}")
        if level == 1:
            print(
                "LEVEL1 assistance=timing barriers plus SIGTERM at the production "
                "trap-supported cancellation point; product logic unchanged"
            )
        print("TRACE_BEGIN")
        for event in result["events"]:
            print(event)
        print("TRACE_END")
        print(f"OBSERVED shared_flags warm={result['warm']} fast={result['fast']}")
        print(
            "OBSERVED real_consumer=files/scripts/service_mgmt.sh:61 "
            f"action={result['action']} expected=kill"
        )
        print(
            f"OBSERVED newer_reboot_attempted={'yes' if result['reboot_attempted'] else 'no'} "
            f"flags_at_reboot={result['flags_at_reboot']}"
        )

        if result["triggered"]:
            print(
                f"BUG_TRIGGERED: Level {level} older signal/EXIT cleanup erased the newer attempt's "
                "flags; the real service consumer selected cold stop and the newer caller "
                "continued to reboot without revalidation."
            )
            print("RESULT: PASS")
            return 0

        print("CALLER1_OUTPUT_BEGIN")
        print(str(result["outputs"][1]).strip())
        print("CALLER1_OUTPUT_END")
        print("CALLER2_OUTPUT_BEGIN")
        print(str(result["outputs"][2]).strip())
        print("CALLER2_OUTPUT_END")
        print("RESULT: FAIL (Level 0 and Level 1 did not trigger MC-1)")
        return 1


if __name__ == "__main__":
    sys.exit(main())

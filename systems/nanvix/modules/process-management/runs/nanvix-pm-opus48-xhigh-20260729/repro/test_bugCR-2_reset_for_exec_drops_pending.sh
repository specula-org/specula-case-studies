#!/usr/bin/env bash
#
# CR-2 reproduction: execv() clears the process pending-signal set, contrary to POSIX.
#
# POSIX (man 7 signal): "the pending signal set is preserved across an execve(2)"; only signal
# dispositions that have handlers are reset to the default. Nanvix's
# SignalControl::reset_for_exec() (src/kernel/src/pm/process/state/signal.rs:496) instead does
# `self.pending = 0;`, silently discarding every signal posted (and possibly blocked) before the
# exec.
#
# This script drives the EXACT code path execv() takes, mirroring the real kernel calls:
#   1. sigaction()  -> set_disposition(sig, Handler)   installs a caught handler
#   2. kill()       -> post(sig)                        posts a caught/deferred signal to `pending`
#                      (ProcessManager::kill does signals.post(signum) for a Handler disposition,
#                       manager/mod.rs:855)
#   3. execv()      -> RunningProcess::replace_image -> SignalControl::reset_for_exec()
#                      (state/running.rs:189) resets dispositions AND zeroes `pending` (the bug)
#
# A real consumer then observes the loss: sigpending() returns `pending & blocked`
# (manager/mod.rs:696) and asynchronous delivery evaluates signals.pending() (manager/signal.rs:242).
#
# The reproduction is an in-kernel unit test (this codebase's native test vehicle: the kernel is
# no_std and its modules can only be exercised inside the kernel, run under the standalone UserVM).
# The injected test asserts the POSIX-correct behavior (pending preserved) and therefore FAILS on
# the current implementation, panicking with a "CR-2 REPRODUCED" diagnostic that prints the dropped
# pending set. This script injects the test, builds+runs the test kernel, checks for the marker, and
# restores the source unconditionally.
#
# Escalation level: Level 0 / Level 1 — the setup uses only the same operations the real
# sigaction()/kill()/execv() kernel calls perform on a process's SignalControl (no unreachable
# state is injected, no system logic is modified).
#
# Exit 0  => BUG REPRODUCED (pending set was dropped across exec)
# Exit 1  => not reproduced
# Exit 2  => environment/build error

set -uo pipefail

WORKTREE="${CR2_WORKTREE:-/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/CR-2/worktree}"
SIG="$WORKTREE/src/kernel/src/pm/process/state/signal_test.rs"
LOG="$(mktemp /tmp/cr2_repro.XXXXXX.log)"

if [[ ! -f "$SIG" ]]; then
    echo "ENV ERROR: cannot find signal_test.rs at $SIG" >&2
    exit 2
fi

BACKUP="$(mktemp)"
cp "$SIG" "$BACKUP"
restore() { cp "$BACKUP" "$SIG"; rm -f "$BACKUP"; }
trap restore EXIT

# ---- Inject the in-kernel reproduction test (idempotent) ------------------------------------------
python3 - "$SIG" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()

if "test_reset_for_exec_preserves_pending_signals" in src:
    sys.exit(0)  # already injected

test_fn = r'''
//==================================================================================================
// Exec Pending-Set Preservation Test (CR-2)
//==================================================================================================

/// CR-2 reproduction. `reset_for_exec()` must PRESERVE the process pending-signal set across an
/// `execv()` image replacement (POSIX: "the pending signal set is preserved across an execve(2)").
/// This test drives the exact code path execv() takes: sigaction() installs a caught handler,
/// kill() posts the caught/deferred signal to `pending`, then execv() -> replace_image ->
/// reset_for_exec resets dispositions AND (the bug) zeroes `pending`. Asserts the POSIX-correct
/// behavior, so it FAILS on the current implementation.
fn test_reset_for_exec_preserves_pending_signals() -> bool {
    let mut control: SignalControl = SignalControl::default();

    // sigaction(): install user handlers so kill() defers these signals to the pending set.
    let _ = control.set_disposition(SIGTERM, handler(0x1000, 0, 0, 0));
    let _ = control.set_disposition(SIGCHLD, handler(0x2000, 0, 0, 0));

    // kill(): a caught, deferred signal is recorded in the process pending set.
    control.post(SIGTERM);
    control.post(SIGCHLD);

    let expected: u64 = bit(SIGTERM) | bit(SIGCHLD);
    let before: u64 = control.pending();
    if before != expected {
        error!("setup failed: pending set not populated (got {before:#x}, want {expected:#x})");
        return false;
    }

    // execv(): replace_image() resets dispositions (correct) and clears the pending set (the bug).
    control.reset_for_exec();

    if !matches!(control.disposition(SIGTERM), Some(SignalDisposition::Default)) {
        error!("reset_for_exec() did not reset the caught SIGTERM disposition to default");
        return false;
    }

    let after: u64 = control.pending();
    if after != expected {
        error!(
            "CR-2 REPRODUCED: reset_for_exec() dropped pending signals across exec: expected \
             pending {expected:#x}, got {after:#x} (POSIX requires the pending set be preserved \
             across execve(2); SIGTERM/SIGCHLD posted+blocked before exec are silently lost)"
        );
        return false;
    }

    true
}

'''

marker = "//==================================================================================================\n// Test Aggregator"
idx = src.index(marker)
src = src[:idx] + test_fn.lstrip("\n") + "\n" + src[idx:]

# Register in the aggregator, right after the last pending-set test.
src = src.replace(
    "    passed &= run_test!(test_post_rejects_out_of_range);\n    passed\n",
    "    passed &= run_test!(test_post_rejects_out_of_range);\n"
    "    passed &= run_test!(test_reset_for_exec_preserves_pending_signals);\n    passed\n",
)

open(path, "w").write(src)
print("injected CR-2 in-kernel test")
PY

# ---- Build the test kernel + UserVM and run the in-kernel tests -----------------------------------
echo "[repro] building and running in-kernel tests (cold build may take several minutes)..."
cd "$WORKTREE" || { echo "ENV ERROR: cannot cd to $WORKTREE" >&2; exit 2; }
timeout 40m make run-kernel-tests >"$LOG" 2>&1
make_rc=$?

echo "----------------------------------------------------------------------"
grep -nE "passed: test_post|CR-2 REPRODUCED|FAILED: test_reset_for_exec|kpanic|Error 202|hello, world!" "$LOG" || true
echo "----------------------------------------------------------------------"
echo "[repro] make exit code: $make_rc   full log: $LOG"

if grep -q "CR-2 REPRODUCED" "$LOG"; then
    echo "REPRO-RESULT: BUG REPRODUCED — reset_for_exec() dropped the pending-signal set across exec"
    exit 0
fi

if [[ $make_rc -eq 124 ]]; then
    echo "REPRO-RESULT: TIMEOUT (build/run exceeded budget) — treat as ENV_LIMITED, inspect $LOG" >&2
    exit 2
fi

echo "REPRO-RESULT: NOT REPRODUCED — marker absent (build error?). Inspect $LOG" >&2
exit 1

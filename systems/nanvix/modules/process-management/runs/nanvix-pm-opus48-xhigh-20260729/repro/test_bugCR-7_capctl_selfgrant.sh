#!/usr/bin/env bash
#
# Reproduction for finding CR-7:
#   "capctl performs no privilege check -- any process can self-grant any capability"
#   code-review finding, cited site src/kernel/src/pm/kcall/capctl.rs:32.
#
# ROOT CAUSE (real code, unmodified):
#   do_capctl() (capctl.rs:24-35) mutates a process's capability set with NO authorization check:
#       trace!(...);
#       //FIXME: check if process has enough privileges to change capabilities.
#       pm.capctl(pid, capability, value)          // <-- no gate
#   `pid` is the kernel-derived caller pid (dispatcher.rs:61,93), so every process can self-mutate
#   its OWN capabilities. New processes start with Capabilities::default() = 0 (no capabilities).
#   Meanwhile terminate() (terminate.rs:49-56), cross-process signal post (manager/mod.rs:819) and
#   event control (event/manager.rs:416) all gate on has_capability(caller, ProcessManagement).
#   Because capctl is ungated, that gate is trivially bypassable: any process self-grants
#   ProcessManagement and the gate then passes.
#
# HOW THIS REPRODUCES IT (Level 0 -- pure black-box public kcall API; no system logic altered,
# only an integration TEST is added to the shipped test daemon `testd`):
#   escalation.rs runs inside testd (an ordinary unprivileged user process) and, targeting a
#   process id that cannot exist (1_000_000, so nothing is ever actually killed), observes the
#   terminate() authorization gate flip solely because of a self-capctl:
#     A) __kcall_terminate(1_000_000)                         -> Err(PermissionDenied)  [gate active]
#     B) __kcall_capctl(ProcessManagement, true)              -> Ok(())                 [THE BUG]
#     C) __kcall_terminate(1_000_000)                         -> Err(NoSuchProcess)     [gate PASSED]
#   The transition PermissionDenied -> NoSuchProcess (target lookup) with only a self-capctl in
#   between is the privilege escalation. A correctly-gated capctl would deny (B) and leave (C) as
#   PermissionDenied. Corroborated by the kernel's own logs: on (A) it logs
#   "do_terminate(): process does not have process management capability"; on (C) it does NOT --
#   it proceeds to the lookup and logs "find_process_mut(): process not found (pid=1000000)".
#
# Usage: ./test_bugCR-7_capctl_selfgrant.sh
# Exit 0 iff the kernel booted testd and the escalation markers are present.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/CR-7/worktree"
LOG="$HERE/test_bugCR-7_capctl_selfgrant.run.log"
BUILD_LOG="$HERE/test_bugCR-7_build.log"
MODULE_SRC="$HERE/test_bugCR-7_capctl_selfgrant.rs"
PM_DIR="$WORKTREE/src/tests/integration/test-rust-testd/src/pm"
PM_MOD="$PM_DIR/mod.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-guest escalation test into testd (idempotent).
cp -f "$MODULE_SRC" "$PM_DIR/escalation.rs" || fail "copy module"

# 2) Declare the module in testd pm/mod.rs (idempotent).
if ! grep -q "mod escalation;" "$PM_MOD"; then
    perl -0777 -pi -e 's/(mod duplicate_burst;\n)/$1mod escalation;\n/' "$PM_MOD"
fi

# 3) Wire it into the pm test aggregator (pm::test()) after terminate::test() (idempotent).
if ! grep -q "escalation::test()" "$PM_MOD"; then
    perl -0777 -pi -e 's/(\n    terminate::test\(\);\n)/$1    escalation::test();\n/' "$PM_MOD"
fi

grep -q "mod escalation;" "$PM_MOD" && grep -q "escalation::test()" "$PM_MOD" \
    || fail "failed to wire the CR-7 test module"
echo "[repro] CR-7 escalation test installed + wired into testd."

# 4) Build the system image bundling procd/memd/vfsd/testd (incremental; timeout 45m).
echo "[repro] building system image (timeout 45m) ..."
timeout 45m make image >"$BUILD_LOG" 2>&1 \
    || { echo "[repro] build failed; see $BUILD_LOG"; tail -60 "$BUILD_LOG"; exit 2; }

# 5) Boot the image (procd/memd/vfsd/testd) and stream the console. testd runs the escalation test
#    early in main(); the VM later exits on testd's final page-fault test, so `make run` terminates
#    on its own -- still wrapped in a timeout as a safety net.
echo "[repro] booting system image (timeout 5m) ..."
timeout 5m make run LOG_LEVEL=info > "$LOG" 2>&1
echo "[repro] make run exit=$?  (full console captured to $LOG)"

echo
echo "==================== CR-7 reproduction markers ===================="
grep -nE "does not have process management capability|find_process_mut\(\): process not found \(pid=1000000\)|pm::escalation\] (baseline|BUG|ESCALATED|passed)" "$LOG"
echo "==================================================================="
echo

# Success criterion: unprivileged terminate denied, self-grant Ok, gate flips to NoSuchProcess.
if grep -q "baseline: unprivileged terminate() -> PermissionDenied" "$LOG" \
   && grep -q "BUG: capctl(ProcessManagement, true) -> Ok (no privilege check)" "$LOG" \
   && grep -q "ESCALATED: terminate() -> NoSuchProcess (gate PASSED after self-grant)" "$LOG" \
   && grep -q "passed test_capctl_self_grant_escalates_terminate" "$LOG"; then
    echo "[repro] CR-7 REPRODUCED: an unprivileged process self-granted ProcessManagement via the"
    echo "        ungated capctl() kcall and thereby bypassed the terminate() authorization gate."
    exit 0
else
    echo "[repro] markers missing -- inspect $LOG"
    exit 1
fi

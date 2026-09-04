#!/usr/bin/env bash
#
# Reproduction for finding CR-8:
#   "duplicate/fork child receives Capabilities::default() instead of inheriting the parent's"
#   code-review finding, cited site src/kernel/src/pm/process/state/mod.rs:253.
#
# MECHANISM (real code, unmodified):
#   ProcessState::new (state/mod.rs:249-265) unconditionally sets capabilities: Capabilities::default()
#   (line 253 == empty set). duplicate_process (manager/mod.rs:1485-1642) is the kernel side of fork:
#   it EXPLICITLY inherits the parent's signal state
#       let inherited_signals = self.get_running().state().signals().inherited_for_fork();  // 1606-07
#       ...
#       process.set_signals(inherited_signals);                                             // 1629
#   but has NO equivalent step for capabilities -- the child body is built by
#   RunnableProcess::new -> ProcessState::new -> Capabilities::default(). So a forked child ALWAYS
#   starts with an EMPTY capability set, unlike the libc fork() "exact copy of the calling process"
#   contract (unistd/bindings/fork.rs:18-19) and unlike the deliberately-inherited signals.
#
# HOW THIS REPRODUCES IT (Level 0 -- pure black-box public kcall API; no system logic altered, only
# an integration TEST is added to the shipped test daemon `testd`, wired FIRST in pm::test() so the
# parent process is pristine -- no owned events / empty mailbox -- when it calls duplicate()):
#   Probe the terminate() authorization gate (terminate.rs:50 gates on ProcessManagement):
#     PermissionDenied => caller lacks ProcessManagement ; NoSuchProcess => caller has it (lookup
#     then fails on the non-existent pid 1_000_000, so nothing is ever actually killed).
#     A) parent (unprivileged)                     terminate() -> PermissionDenied
#     B) parent self-grants ProcessManagement, re-probe -> NoSuchProcess   (gate PASSES for parent)
#     C) parent forks child via __kcall_duplicate; CHILD probes -> PermissionDenied
#        == the child did NOT inherit the parent's ProcessManagement capability  [THE BEHAVIOUR]
#     D) child self-grants (ungated capctl), re-probe -> NoSuchProcess
#        == the MASK: the child is never actually stuck; ungated self-service capctl lets it recover.
#
# Usage: ./test_bugCR-8_fork_cap_inherit.sh
# Exit 0 iff the kernel booted testd and the child "capability NOT inherited" marker is present.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/CR-8/worktree"
LOG="$HERE/test_bugCR-8_fork_cap_inherit.run.log"
BUILD_LOG="$HERE/test_bugCR-8_build.log"
MODULE_SRC="$HERE/test_bugCR-8_fork_cap_inherit.rs"
PM_DIR="$WORKTREE/src/tests/integration/test-rust-testd/src/pm"
PM_MOD="$PM_DIR/mod.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-guest capability-inheritance test into testd (idempotent).
cp -f "$MODULE_SRC" "$PM_DIR/capinherit.rs" || fail "copy module"

# 2) Declare the module in testd pm/mod.rs (idempotent), after `mod capability;`.
if ! grep -q "mod capinherit;" "$PM_MOD"; then
    perl -0777 -pi -e 's/(mod capability;\n)/$1mod capinherit;\n/' "$PM_MOD"
fi

# 3) Wire it FIRST in pm::test() (idempotent), before sched::test() so the parent process owns no
#    events and has an empty mailbox when it calls duplicate().
if ! grep -q "capinherit::test()" "$PM_MOD"; then
    perl -0777 -pi -e 's/(pub fn test\(\) \{\n)(    sched::test\(\);\n)/$1    capinherit::test();\n$2/' "$PM_MOD"
fi

grep -q "mod capinherit;" "$PM_MOD" && grep -q "capinherit::test()" "$PM_MOD" \
    || fail "failed to wire the CR-8 test module"
echo "[repro] CR-8 capability-inheritance test installed + wired into testd."

# 4) Build the system image bundling procd/memd/vfsd/testd (incremental; timeout 45m).
echo "[repro] building system image (timeout 45m) ..."
timeout 45m make image >"$BUILD_LOG" 2>&1 \
    || { echo "[repro] build failed; see $BUILD_LOG"; tail -60 "$BUILD_LOG"; exit 2; }

# 5) Boot the image and stream the console. testd runs pm::test() early in main(); the VM later
#    exits on testd's final page-fault test, so `make run` terminates on its own -- still wrapped in
#    a timeout as a safety net.
echo "[repro] booting system image (timeout 5m) ..."
timeout 5m make run LOG_LEVEL=info > "$LOG" 2>&1
echo "[repro] make run exit=$?  (full console captured to $LOG)"

echo
echo "==================== CR-8 reproduction markers ===================="
grep -nE "\[CR-8\]\[(parent|child)\]|does not have process management capability|passed test_fork_child_does_not_inherit_capabilities" "$LOG"
echo "==================================================================="
echo

# Success criterion: the forked CHILD is denied by the terminate() gate (capability NOT inherited),
# while the PARENT that self-granted the capability passes it.
if grep -q "\[CR-8\]\[parent\] baseline terminate() -> PermissionDenied" "$LOG" \
   && grep -q "\[CR-8\]\[parent\] privileged terminate() -> NoSuchProcess" "$LOG" \
   && grep -q "\[CR-8\]\[child\] terminate() -> PermissionDenied (capability NOT inherited from parent)" "$LOG"; then
    echo "[repro] CR-8 BEHAVIOUR CONFIRMED: a forked child did NOT inherit the parent's"
    echo "        ProcessManagement capability (parent passes the terminate() gate, child is denied)."
    if grep -q "\[CR-8\]\[child\] after self-capctl: terminate() -> NoSuchProcess (MASK fires" "$LOG"; then
        echo "[repro] MASK demonstrated: the child recovered via the ungated self-service capctl,"
        echo "        so no live harm today (see CR-7)."
    fi
    exit 0
else
    echo "[repro] markers missing -- inspect $LOG"
    exit 1
fi

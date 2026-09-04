#!/usr/bin/env bash
#
# Reproduction driver for finding CR-2 (Creation/fork/exec/address-space rollback completeness).
#
# CR-2 flags two residual rollback "gaps":
#   Gap 1 (fork CoW restore): a failed fork/link_user_pages does not restore the parent's
#          copy-on-write page marks (mm/virt/manager.rs:390-399, 443-453).
#   Gap 2 (best-effort mmap rollback): ProcessManager::rollback_mmap may leave an earlier
#          batch mapped if try_unmap_upage fails during rollback (pm/.../mod.rs:3548-3599).
#
# This driver builds the in-kernel test suite (which runs under QEMU via the UserVM) and runs it.
# The suite exercises the REAL rollback code paths through the public interfaces:
#   * Gap 1: test_link_user_pages_rolls_back_on_partial_failure  -> forces link_user_pages to fail
#            mid-way (refcount saturation, a reachable OOM-class failure) and asserts the child is
#            fully rolled back (no leak); the parent's CoW mark is intentionally left in place.
#            test_cow_resolution_fast_path_when_sole_owner        -> shows the parent's post-rollback
#            CoW page (now sole owner) resolves via a no-alloc/no-copy fast path -> benign.
#   * Gap 2: test_mmap_rollback_reclaims_earlier_batch (added for this finding) -> drives the real
#            public mmap()/munmap() API to force a mid-mmap batch failure, then asserts rollback_mmap
#            fully reclaimed the earlier batch (no leak).
#
# run_test! uses assert!(result): any failing test PANICS the kernel and it never reaches the
# terminal magic string "hello, world!". So a run that prints "passed: <test>" for every test AND
# reaches "hello, world!" demonstrates the rollback paths behave correctly (no leak / no corruption).
#
# Escalation level: Level 0 (public API) for Gap 2; Level 2 (reachable refcount-saturation failure,
# the developers' own harness) for Gap 1.

set -u

WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/CR-2/worktree"
cd "$WORKTREE" || { echo "cannot cd to worktree"; exit 2; }

echo "=== [CR-2] Building + running in-kernel test suite (rollback paths) ==="
# Build the test kernel + UserVM and run the in-kernel tests under QEMU.
# MACHINE=microvm / TARGET=x86 mirror the known-good harness build recipe.
timeout 20m make run-kernel-tests MACHINE=microvm TARGET=x86 2>&1
status=$?

echo "=== [CR-2] make exited with status ${status} ==="
exit $status

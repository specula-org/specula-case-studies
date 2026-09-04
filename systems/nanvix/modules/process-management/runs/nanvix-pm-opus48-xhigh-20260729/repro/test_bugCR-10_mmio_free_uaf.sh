#!/usr/bin/env bash
# Reproduction driver for finding CR-10:
#   "mmio_free drops the ownership record without revoking the underlying page-table entries."
#
# Strategy (Level 0, pure black-box, public kcall interface only; kernel logic UNMODIFIED):
#   The guest test `test-rust-mmio-free` (src/tests/integration/test-rust-mmio-free) does:
#       capctl(IoManagement) -> mmio_alloc(RAMFS) -> mmio_info -> read base (ok)
#       -> mmio_free(RAMFS)  -> read base AGAIN
#   Correct behavior: mmio_free revokes the mapping, so the post-free read faults ->
#     SIGSEGV default action -> process exit code 4.  The runner config therefore sets
#     expected_exit_code = 4.
#   Buggy behavior (CR-10): the read after free SUCCEEDS (stale PTE) -> main returns Ok ->
#     exit code 0, and the runner reports `exit code mismatch (expected=4, actual=0)`.
#
#   A CONTROL test (`test-rust-mmio-fault`, writes PAST the region -> genuinely unmapped)
#   is run first to prove the environment DOES fault on truly-unmapped access (exit 4).
#
# Usage:  ./test_bugCR-10_mmio_free_uaf.sh
set -u

WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/CR-10/worktree"
CONFIG="test/test-mmio-free-repro.toml"

cd "$WORKTREE" || { echo "worktree not found: $WORKTREE"; exit 2; }

# Locate the host-side nanvix-test runner binary.
RUNNER=""
for cand in ./bin/nanvix-test.elf ./bin/nanvix-test ./bin/nanvix-test.exe; do
    [ -x "$cand" ] && RUNNER="$cand" && break
done
if [ -z "$RUNNER" ]; then
    echo "nanvix-test runner not found under ./bin (build first: make all-nanvix)"; exit 2
fi

echo "=================================================================="
echo "RUNNER  = $RUNNER"
echo "CONFIG  = $CONFIG"
echo "NANVIXD = ./bin/nanvixd.elf"
echo "RAMFS   = ./bin/test-kernel-ramfs.img"
echo "=================================================================="

# The http executor manages nanvixd itself; the guest console (syslog) is written under logs/.
RUST_LOG=info timeout 300 "$RUNNER" "$CONFIG"
rc=$?

echo "=================================================================="
echo "nanvix-test exit code = $rc  (nonzero => at least one test's exit code did not match)"
echo "=== guest console lines mentioning the test (from logs/) ==="
grep -rEh "test-mmio-free|test-mmio-fault|BUGCR10" logs/ 2>/dev/null | tail -40 || true
echo "=================================================================="
exit $rc

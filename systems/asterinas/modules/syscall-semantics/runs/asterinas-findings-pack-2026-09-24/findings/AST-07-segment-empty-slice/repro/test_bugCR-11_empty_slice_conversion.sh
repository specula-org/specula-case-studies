#!/usr/bin/env bash
# Reproduction driver for finding CR-11:
#   "Empty `Segment::slice` can reach conversions that assume a first frame"
#
# What it does
#   1. Installs the ktest module into the Asterinas worktree (idempotent).
#   2. Boots ostd's ktest kernel under QEMU and runs the three `cr11_repro`
#      tests, each in its own kernel boot so a panic in one does not hide the
#      others.
#   3. Reports the CR11| measurement lines and the pass/fail result.
#
# Escalation level: 0 for all three tests — safe, public `ostd::mm` API only
# (`FrameAllocOptions`, `Segment::slice`, `Split::split`, `From`/`TryFrom`).
# No source under test is modified; the only edit to the worktree is
# registering the new `#[cfg(ktest)]` module in ostd/src/mm/frame/mod.rs.
#
# Usage: test_bugCR-11_empty_slice_conversion.sh [worktree] [osdk-binary]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="${1:-$HERE/../confirmation/CR-11/worktree}"
WORKTREE="$(cd "$WORKTREE" && pwd)"
# The OSDK bakes `CARGO_MANIFEST_DIR` in at its own compile time and derives the
# `ostd` path dependency from it (osdk/src/util.rs:20, base_crate/mod.rs:270), so
# a binary built from another checkout would silently test *that* checkout's
# ostd. The OSDK must be built from this worktree.
OSDK_BIN="${2:-$WORKTREE/osdk/target/debug/cargo-osdk}"
LOG="$HERE/test_bugCR-11_empty_slice_conversion.log"
BUILD_TIMEOUT_SECONDS="${BUILD_TIMEOUT_SECONDS:-2400}"
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-2400}"

in_dev_shell() {
    local directory="$1" limit="$2"
    shift 2
    if command -v nix >/dev/null 2>&1; then
        (cd "$directory" && timeout "$limit" nix develop "$WORKTREE" \
            --accept-flake-config --command "$@")
    else
        (cd "$directory" && timeout "$limit" "$@")
    fi
}

install_sources() {
    cp "$HERE/test_bugCR-11_empty_slice_conversion.rs" \
       "$WORKTREE/ostd/src/mm/frame/cr11_repro.rs"

    python3 - "$WORKTREE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

mod = root / "ostd/src/mm/frame/mod.rs"
text = mod.read_text()
if "mod cr11_repro;" not in text:
    anchor = "#[cfg(ktest)]\nmod test;"
    assert anchor in text, "ostd/src/mm/frame/mod.rs is missing the ktest module block"
    text = text.replace(
        anchor, "#[cfg(ktest)]\npub(crate) mod cr11_repro;\n" + anchor, 1
    )
    mod.write_text(text)
PY
}

install_sources

if [[ ! -x "$OSDK_BIN" ]]; then
    echo "Building the worktree-local OSDK ..."
    in_dev_shell "$WORKTREE" "$BUILD_TIMEOUT_SECONDS" \
        env OSDK_LOCAL_DEV=1 cargo build --manifest-path osdk/Cargo.toml
fi
[[ -x "$OSDK_BIN" ]] || { echo "no OSDK binary at $OSDK_BIN" >&2; exit 2; }

# The ktest whitelist matches whole path *suffixes*, so each test has to be
# named in full; a bare module name matches nothing.
TESTS=(
    cr11_repro::cr11_l0_empty_slice_round_trip_matrix
    cr11_repro::cr11_l0_empty_slice_answers_from_a_foreign_frame
    cr11_repro::cr11_l0_empty_slice_at_end_boundary_faults
    cr11_repro::cr11_l0_max_tracked_boundary_probe
)

echo "Running the CR-11 reproduction ..."
: >"$LOG"
status=0
for t in "${TESTS[@]}"; do
    echo "=================== $t ===================" >>"$LOG"
    set +e
    in_dev_shell "$WORKTREE/ostd" "$TEST_TIMEOUT_SECONDS" \
        env "$OSDK_BIN" osdk test "$t" --target-arch x86_64 \
        >>"$LOG" 2>&1
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || status=$rc
done

echo "--- CR-11 measurements ---"
# Not anchored at column 0: the ktest runner leaves the "test <name> ..." prefix
# on the same line as a test's first `println!`.
grep -aoE 'CR11\|[^ ]*' "$LOG" || echo "(no CR11| lines: the tests did not reach their measurements)"
echo "--- test result ---"
grep -aE 'test result:|panicked|FAILED|\[ktest runner\]' "$LOG" | tail -20 || true

# `cr11_l0_empty_slice_at_end_boundary_faults` takes the kernel down inside the
# conversion, so it produces neither a panic message nor a "test result:" line.
# A missing completion marker after the "about_to_call" marker IS the finding.
echo "--- hard-fault check ---"
if grep -aq 'CR11|fault|about_to_call' "$LOG"; then
    if grep -aq 'CR11|fault|survived' "$LOG"; then
        echo "kernel survived the read (see CR11|fault|survived above)"
    else
        echo "KERNEL DIED inside Segment::try_from: 'about_to_call' present, 'survived' absent"
        status=1
    fi
else
    echo "(the faulting test never reached its conversion)"
fi
echo "Full log: $LOG (exit=$status)"
exit "$status"

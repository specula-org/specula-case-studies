#!/usr/bin/env bash
# Reproduction driver for finding CR-20:
#   "IOMMU teardown removes PTEs without IOTLB invalidation before frame reuse"
#
# Derived from §6 of CR-20-verification-report.md, with three fixes for this
# checkout's actual layout. See cr20/HANDOFF.md §3 for why each was needed.
#
# What it does
#   1. Installs the ktest into the worktree (idempotent).
#   2. CREATES `ostd/OSDK.toml` with IOMMU + edu + vtd tracing, and DELETES it
#      on exit. OSDK resolves its manifest from the CWD first and only falls
#      back to the workspace root (osdk/src/config/manifest.rs:55-61), so a
#      package-level file placed next to `ostd` is a complete override while
#      `osdk test` runs from there.
#   3. Boots ostd's ktest kernel under QEMU against UNMODIFIED ostd sources.
#
# Escalation level 0/1: no ostd logic is patched. The guest uses only the
# public DMA API plus ordinary PCI config-space / MMIO device programming.
#
# Usage: cr20/run.sh [worktree]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="${1:-$HERE/..}"
WORKTREE="$(cd "$WORKTREE" && pwd)"
# OSDK bakes `CARGO_MANIFEST_DIR` in at its own compile time and derives the
# `ostd` path dependency from it, so a binary built from another checkout would
# silently test *that* checkout's ostd. Build it from this worktree.
OSDK_BIN="${OSDK_BIN:-$WORKTREE/osdk/target/debug/cargo-osdk}"
LOG="$HERE/run.log"
BUILD_TIMEOUT_SECONDS="${BUILD_TIMEOUT_SECONDS:-2400}"
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-3000}"
FILTER=cr20_repro::cr20_stale_iotlb_after_dma_teardown
SMP="${SMP:-2}"

# This checkout has no `ostd/OSDK.toml`; only the workspace-root one. We create
# the package-level file and remove it again, rather than back up and restore.
OSDK_TOML="$WORKTREE/ostd/OSDK.toml"

in_dev_shell() {
    local directory="$1" limit="$2"
    shift 2
    if command -v nix >/dev/null 2>&1 && [[ -f "$WORKTREE/flake.nix" ]]; then
        (cd "$directory" && timeout "$limit" nix develop "$WORKTREE" \
            --accept-flake-config --command "$@")
    else
        (cd "$directory" && timeout "$limit" "$@")
    fi
}

install_sources() {
    cp "$HERE/test_bugCR-20_stale_iotlb_after_teardown.rs" \
        "$WORKTREE/ostd/src/cr20_repro.rs"
    if ! grep -q "mod cr20_repro;" "$WORKTREE/ostd/src/lib.rs"; then
        python3 - "$WORKTREE/ostd/src/lib.rs" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
addition = "#[cfg(ktest)]\npub(crate) mod cr20_repro;\n"
# The anchor from the original script does not exist in this tree; appending is
# the documented fallback and is equivalent for module registration.
anchor = "#[cfg(ktest)]\nmod tla_scenarios;\n"
if anchor in text:
    text = text.replace(anchor, anchor + addition, 1)
else:
    text = text.rstrip("\n") + "\n\n" + addition
path.write_text(text)
print("registered mod cr20_repro in", path)
PY
    fi
}

remove_qemu_args() {
    if [[ -f "$OSDK_TOML" ]]; then
        rm -f "$OSDK_TOML"
        echo "removed $OSDK_TOML"
    fi
}

install_qemu_args() {
    if [[ -e "$OSDK_TOML" ]]; then
        echo "refusing to clobber an existing $OSDK_TOML" >&2
        exit 1
    fi
    cat >"$OSDK_TOML" <<'TOML'
[boot]
method = "qemu-direct"

# 8G of RAM, matching the product's own `iommu` scheme: the IOMMU registers sit
# at ~0xfed90000 and ostd reaches them through the linear map, which only covers
# 0..max_paddr. With ostd's default 2G the kernel faults inside `iommu::init`.
[test.qemu]
args = """
    -machine q35,kernel-irqchip=split
    -cpu max,+x2apic
    -smp ${SMP:-2}
    -m 8G
    --no-reboot
    -nographic
    -display none
    -serial stdio
    -monitor none
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
    -device intel-iommu,intremap=on,device-iotlb=on
    -device edu,dma_mask=0xffffffffff
    -trace enable=vtd_iotlb_page_hit
    -trace enable=vtd_iotlb_page_update
    -trace enable=vtd_iotlb_reset
    -trace enable=vtd_inv_desc_iotlb_global
    -trace enable=vtd_inv_desc_iotlb_domain
    -trace enable=vtd_inv_desc_iotlb_pages
    -trace enable=vtd_dmar_fault
"""
TOML
    echo "created $OSDK_TOML (IOMMU + edu device + vtd tracing)"
}

build_osdk() {
    if [[ -x "$OSDK_BIN" ]]; then
        echo "== OSDK already built: $OSDK_BIN"
        echo "   (delete it to force a rebuild if the worktree has moved on)"
        return
    fi
    echo "== building the source-local OSDK"
    in_dev_shell "$WORKTREE" "$BUILD_TIMEOUT_SECONDS" \
        env OSDK_LOCAL_DEV=1 cargo build --manifest-path osdk/Cargo.toml
}

run_ktest() {
    echo "== running $FILTER with SMP=$SMP"
    set +e
    in_dev_shell "$WORKTREE/ostd" "$TEST_TIMEOUT_SECONDS" \
        env SMP="$SMP" "$OSDK_BIN" osdk test "$FILTER" --target-arch x86_64 \
        >"$LOG" 2>&1
    local status=$?
    set -e
    echo "-- exit status: $status"
    return $status
}

install_sources
build_osdk

trap remove_qemu_args EXIT
install_qemu_args

status=0
run_ktest || status=$?

remove_qemu_args
trap - EXIT

echo
echo "######## guest output ########"
grep -E "^CR20\||test result|panicked at|iommu:" "$LOG" || true
echo
echo "######## host-side vIOMMU translation-cache events ########"
echo "IOTLB fills   : $(grep -c 'vtd_iotlb_page_update' "$LOG" || true)"
echo "IOTLB hits    : $(grep -c 'vtd_iotlb_page_hit' "$LOG" || true)"
echo "IOTLB flushes : $(grep -cE 'vtd_inv_desc_iotlb_|vtd_iotlb_reset' "$LOG" || true)"
echo "DMAR faults   : $(grep -c 'vtd_dmar_fault' "$LOG" || true)"
echo
echo "NOTE: a FAILED ktest is the POSITIVE result. See report §4."
echo "RESULT: ktest exit status $status (full log: $LOG)"
exit "$status"

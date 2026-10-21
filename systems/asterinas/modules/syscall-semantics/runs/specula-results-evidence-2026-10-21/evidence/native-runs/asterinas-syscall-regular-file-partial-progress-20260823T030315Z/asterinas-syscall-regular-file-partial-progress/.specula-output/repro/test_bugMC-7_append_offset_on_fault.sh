#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# MC-7 driver: does a failed O_APPEND write leave the shared open-file
# description offset at EOF?
#
# Escalation Level 0 only. The kernel is the pristine baseline (kernel/ is
# reverted before the build); the trigger uses nothing but open/dup/mmap/
# mprotect/write/lseek/read. Linux runs the identical binary as the control.
#
# Both backends the counterexample and the harness trace touch are exercised:
#   /ext2   virtio-blk ext2, the MC counterexample's "Ext2Buffered"
#   /tmp    ramfs, the backend of harness trace traces/ramfs_zero_append.ndjson

set -euo pipefail

REPRO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WORKTREE=$REPRO_DIR/../confirmation/MC-7/worktree
WORKTREE=$(cd -- "$WORKTREE" && pwd)
OUT=$REPRO_DIR/out_bugMC-7
SRC=$REPRO_DIR/test_bugMC-7_append_offset_on_fault.c
GUEST_DIR=$WORKTREE/test/initramfs/src/regression/io/specula

CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805

mkdir -p "$OUT"

echo "== MC-7 repro: shared OFD offset after a failed O_APPEND write =="
echo "worktree: $WORKTREE"

# ---------------------------------------------------------------- Linux control
echo
echo "-- [1/3] Linux control --"
LINUX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mc7.XXXXXX")
trap 'rm -rf "$LINUX_DIR"' EXIT
gcc -Wall -Werror -O2 -o "$OUT/mc7_linux" "$SRC"
"$OUT/mc7_linux" "$LINUX_DIR" 2>&1 | tee "$OUT/linux.log" || true

# ------------------------------------------------------- pristine kernel + stage
echo
echo "-- [2/3] Staging on the pristine baseline kernel --"
git -C "$WORKTREE" checkout -- kernel/
echo "baseline commit: $(git -C "$WORKTREE" rev-parse HEAD)"
echo "kernel/ tree state (must be empty => no kernel modification):"
git -C "$WORKTREE" status --short -- kernel/ |
	grep -v '^?? kernel/core/src/tla_trace.rs$' |
	grep -v '^?? kernel/core/comps/block/src/tla_trace.rs$' || true

install -m 0644 "$SRC" "$GUEST_DIR/mc7_append_offset_on_fault.c"
cat >"$GUEST_DIR/run_mc7.sh" <<'EOF'
#!/bin/sh
set -u

echo "MC7_SECTION ext2"
/test/io/specula/mc7_append_offset_on_fault /ext2 || true

echo "MC7_SECTION ramfs"
/test/io/specula/mc7_append_offset_on_fault /tmp || true

rm -f /ext2/mc7_* 2>/dev/null || true
sync || true

echo "SPECULA_SCENARIO_PASS mc7"
EOF
chmod 0755 "$GUEST_DIR/run_mc7.sh"

if [ ! -c /dev/kvm ]; then
	echo "repro: /dev/kvm is required for the Asterinas guest run" >&2
	exit 1
fi

echo
echo "-- [3/3] Asterinas guest run --"
timeout 5400 docker run --rm --privileged --network=host \
	--device=/dev/kvm \
	-v "$RUSTUP_CACHE":/root/.rustup \
	-v "$CARGO_CACHE/registry":/root/.cargo/registry \
	-v "$CARGO_CACHE/git":/root/.cargo/git \
	-v "$WORKTREE":/root/asterinas \
	-v "$OUT":/root/mc7-out \
	-w /root/asterinas \
	"$IMAGE" bash -lc '
		set -euo pipefail
		out_uid=$(stat -c %u /root/mc7-out)
		out_gid=$(stat -c %g /root/mc7-out)
		trap '\''chown -R "$out_uid:$out_gid" /root/mc7-out 2>/dev/null || true'\'' EXIT

		export RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu
		export CARGO_NET_GIT_FETCH_WITH_CLI=true

		timeout 3600 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			> /root/mc7-out/build.log 2>&1

		timeout 1200 make run_kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			SPECULA_INIT=/test/io/specula/run_mc7.sh \
			2>&1 | tee /root/mc7-out/guest.log >/dev/null
	'

echo
echo "== Asterinas guest output =="
grep -aE '^(MC7_|SPECULA_SCENARIO)' "$OUT/guest.log" | tee "$OUT/asterinas.log"

echo
echo "== Linux control =="
cat "$OUT/linux.log"

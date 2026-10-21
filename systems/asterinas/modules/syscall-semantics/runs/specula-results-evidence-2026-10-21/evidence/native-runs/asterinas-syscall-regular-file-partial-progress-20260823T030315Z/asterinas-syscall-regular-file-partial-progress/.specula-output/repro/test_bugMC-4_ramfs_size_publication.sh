#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# MC-4 reproduction driver -- escalation Level 0 (pure black box).
#
# Runs the same C program twice:
#   1. on Linux (host, tmpfs at /dev/shm) as the reference control;
#   2. inside the Asterinas guest (ramfs root) built from the PRISTINE
#      baseline kernel -- the Specula trace instrumentation is reverted first,
#      so nothing in the kernel logic under test is modified.
#
# No failpoints, no injected state, no kernel patch: only open/pwrite/write/
# lseek/fstat/mprotect from user space.

set -euo pipefail

REPRO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RUN_ROOT=$(dirname -- "$(dirname -- "$REPRO_DIR")")
WORKTREE=$REPRO_DIR/../confirmation/MC-4/worktree
WORKTREE=$(cd -- "$WORKTREE" && pwd)
OUT=$REPRO_DIR/out_bugMC-4
SRC=$REPRO_DIR/test_bugMC-4_ramfs_size_publication.c
GUEST_DIR=$WORKTREE/test/initramfs/src/regression/io/specula

CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805

mkdir -p "$OUT"

echo "== MC-4 repro: Level 0, pure black box =="
echo "worktree: $WORKTREE"

# ---------------------------------------------------------------- Linux control
echo
echo "-- [1/3] Linux control (tmpfs /dev/shm) --"
# the host toolchain has no static glibc; the guest build uses -static via the
# initramfs Makefile
gcc -Wall -Werror -o "$OUT/mc4_linux" "$SRC"
"$OUT/mc4_linux" /dev/shm 2>&1 | tee "$OUT/linux.log"

# ------------------------------------------------------- pristine kernel + stage
echo
echo "-- [2/3] Building Asterinas from the pristine baseline kernel --"
git -C "$WORKTREE" checkout -- kernel/
echo "baseline commit: $(git -C "$WORKTREE" rev-parse HEAD)"
echo "kernel/ tree state (must be empty => no kernel modification):"
git -C "$WORKTREE" status --short -- kernel/ | grep -v '^?? kernel/core/src/tla_trace.rs$' |
	grep -v '^?? kernel/core/comps/block/src/tla_trace.rs$' || true

install -m 0644 "$SRC" "$GUEST_DIR/mc4_size_publication.c"
cat >"$GUEST_DIR/run_mc4.sh" <<'EOF'
#!/bin/sh
set -eu
/test/io/specula/mc4_size_publication /
echo "SPECULA_SCENARIO_PASS mc4"
EOF
chmod 0755 "$GUEST_DIR/run_mc4.sh"

if [ ! -c /dev/kvm ]; then
	echo "repro: /dev/kvm is required for the Asterinas guest run" >&2
	exit 1
fi

timeout 1200 docker run --rm --network=host \
	-v "$RUSTUP_CACHE":/root/.rustup \
	"$IMAGE" bash -lc '
		set -eu
		cd /tmp
		timeout 1100 rustup toolchain install nightly-2026-07-21 \
			--profile minimal \
			--component rust-src \
			--component rustc-dev \
			--component llvm-tools-preview \
			--target x86_64-unknown-none
	' >"$OUT/toolchain.log" 2>&1

echo
echo "-- [3/3] Asterinas guest run (ramfs root) --"
timeout 3000 docker run --rm --privileged --network=host \
	--device=/dev/kvm \
	-v "$RUSTUP_CACHE":/root/.rustup \
	-v "$CARGO_CACHE/registry":/root/.cargo/registry \
	-v "$CARGO_CACHE/git":/root/.cargo/git \
	-v "$WORKTREE":/root/asterinas \
	-v "$OUT":/root/mc4-out \
	-w /root/asterinas \
	"$IMAGE" bash -lc '
		set -euo pipefail
		out_uid=$(stat -c %u /root/mc4-out)
		out_gid=$(stat -c %g /root/mc4-out)
		trap '\''chown -R "$out_uid:$out_gid" /root/mc4-out 2>/dev/null || true'\'' EXIT

		export RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu
		export CARGO_NET_GIT_FETCH_WITH_CLI=true

		timeout 2000 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			> /root/mc4-out/build.log 2>&1

		timeout 600 make run_kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			SPECULA_INIT=/test/io/specula/run_mc4.sh \
			2>&1 | tee /root/mc4-out/guest.log >/dev/null
	'

echo
echo "== Asterinas guest output =="
grep -aE '^(CASE |MC4_)' "$OUT/guest.log" | tee "$OUT/asterinas.log"

echo
echo "== Side-by-side =="
printf '%-6s %-46s %-10s %-10s\n' CASE OPERATION LINUX ASTERINAS
for tag in A B C D E; do
	l=$(grep -a "^CASE $tag " "$OUT/linux.log" | head -1)
	a=$(grep -a "^CASE $tag " "$OUT/asterinas.log" | head -1)
	op=$(printf '%s' "$l" | awk '{print $3}' | tr -d ':')
	lv=$(printf '%s' "$l" | sed -n 's/.*size_after=\([0-9-]*\).*/\1/p')
	av=$(printf '%s' "$a" | sed -n 's/.*size_after=\([0-9-]*\).*/\1/p')
	printf '%-6s %-46s %-10s %-10s\n' "$tag" "$op" "size=$lv" "size=$av"
done

echo
grep -a '^MC4_SUMMARY' "$OUT/linux.log" "$OUT/asterinas.log"

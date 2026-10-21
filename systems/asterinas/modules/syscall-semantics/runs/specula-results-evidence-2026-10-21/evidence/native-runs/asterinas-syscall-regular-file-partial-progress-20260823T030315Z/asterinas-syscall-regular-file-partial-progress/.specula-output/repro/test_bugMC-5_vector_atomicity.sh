#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# MC-5 reproduction driver -- escalation Level 0 (pure black box).
#
# Runs the same C program twice:
#   1. on Linux (host, tmpfs at /dev/shm) as the reference control;
#   2. inside the Asterinas guest (ramfs root, SMP=2) built from the PRISTINE
#      baseline kernel -- the Specula trace instrumentation is reverted first,
#      so nothing in the kernel logic under test is modified.
#
# No failpoints, no injected state, no kernel patch: only
# open/dup/readv/writev/read/write/lseek/ftruncate/pread from user space.
#
# CASE D is a positive control: it replaces readv() with the per-entry scalar
# read() loop that do_sys_readv performs internally.  It must tear on Linux
# too -- that is what proves the detector is not blind.

set -euo pipefail

REPRO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WORKTREE=$REPRO_DIR/../confirmation/MC-5/worktree
WORKTREE=$(cd -- "$WORKTREE" && pwd)
OUT=$REPRO_DIR/out_bugMC-5
SRC=$REPRO_DIR/test_bugMC-5_vector_atomicity.c
GUEST_DIR=$WORKTREE/test/initramfs/src/regression/io/specula

CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805

mkdir -p "$OUT"

echo "== MC-5 repro: Level 0, pure black box =="
echo "worktree: $WORKTREE"

# ---------------------------------------------------------------- Linux control
echo
echo "-- [1/3] Linux control (tmpfs /dev/shm) --"
# the host toolchain has no static glibc; the guest build uses -static via the
# initramfs Makefile
gcc -Wall -Werror -O2 -o "$OUT/mc5_linux" "$SRC" -lpthread
"$OUT/mc5_linux" /dev/shm 2>&1 | tee "$OUT/linux.log"

# ------------------------------------------------------- pristine kernel + stage
echo
echo "-- [2/3] Building Asterinas from the pristine baseline kernel --"
git -C "$WORKTREE" checkout -- kernel/
echo "baseline commit: $(git -C "$WORKTREE" rev-parse HEAD)"
echo "kernel/ tree state (must be empty => no kernel modification):"
git -C "$WORKTREE" status --short -- kernel/ | grep -v '^?? kernel/core/src/tla_trace.rs$' |
	grep -v '^?? kernel/core/comps/block/src/tla_trace.rs$' || true

install -m 0644 "$SRC" "$GUEST_DIR/mc5_vector_atomicity.c"
cat >"$GUEST_DIR/run_mc5.sh" <<'EOF'
#!/bin/sh
set -eu
/test/io/specula/mc5_vector_atomicity /
echo "SPECULA_SCENARIO_PASS mc5"
EOF
chmod 0755 "$GUEST_DIR/run_mc5.sh"

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
echo "-- [3/3] Asterinas guest run (ramfs root, SMP=2) --"
timeout 3600 docker run --rm --privileged --network=host \
	--device=/dev/kvm \
	-v "$RUSTUP_CACHE":/root/.rustup \
	-v "$CARGO_CACHE/registry":/root/.cargo/registry \
	-v "$CARGO_CACHE/git":/root/.cargo/git \
	-v "$WORKTREE":/root/asterinas \
	-v "$OUT":/root/mc5-out \
	-w /root/asterinas \
	"$IMAGE" bash -lc '
		set -euo pipefail
		out_uid=$(stat -c %u /root/mc5-out)
		out_gid=$(stat -c %g /root/mc5-out)
		trap '\''chown -R "$out_uid:$out_gid" /root/mc5-out 2>/dev/null || true'\'' EXIT

		export RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu
		export CARGO_NET_GIT_FETCH_WITH_CLI=true

		timeout 2400 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			> /root/mc5-out/build.log 2>&1

		timeout 900 make run_kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			SPECULA_INIT=/test/io/specula/run_mc5.sh \
			2>&1 | tee /root/mc5-out/guest.log >/dev/null
	'

echo
echo "== Asterinas guest output =="
grep -aE '^(CASE |MC5_)' "$OUT/guest.log" | tee "$OUT/asterinas.log"

echo
echo "== Side-by-side (VERDICT per case) =="
printf '%-6s %-34s %-14s %-14s\n' CASE OPERATION LINUX ASTERINAS
for tag in A B C D E; do
	l=$(grep -a "^CASE $tag " "$OUT/linux.log" | head -1)
	a=$(grep -a "^CASE $tag " "$OUT/asterinas.log" | head -1)
	op=$(printf '%s' "$l" | awk '{print $3}' | tr -d ':')
	lv=$(printf '%s' "$l" | sed -n 's/.*VERDICT=\([A-Z_]*\).*/\1/p')
	av=$(printf '%s' "$a" | sed -n 's/.*VERDICT=\([A-Z_]*\).*/\1/p')
	printf '%-6s %-34s %-14s %-14s\n' "$tag" "$op" "$lv" "$av"
done

echo
echo "== Detail (torn rounds / gap counts) =="
grep -a '^CASE ' "$OUT/linux.log" | sed 's/^/linux     /'
grep -a '^CASE ' "$OUT/asterinas.log" | sed 's/^/asterinas /'

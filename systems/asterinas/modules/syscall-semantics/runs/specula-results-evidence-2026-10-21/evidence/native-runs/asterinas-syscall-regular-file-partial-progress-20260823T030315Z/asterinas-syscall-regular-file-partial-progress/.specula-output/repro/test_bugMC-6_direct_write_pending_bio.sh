#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# MC-6 reproduction driver -- escalation Level 0 (pure black box).
#
# Runs the same C program twice:
#   1. on Linux (host, ext4 under $TMPDIR) as the reference control;
#   2. inside the Asterinas guest on the ext2 volume mounted at /ext2, built
#      from the PRISTINE baseline kernel -- the Specula trace instrumentation
#      is reverted first, so nothing in the kernel logic under test is modified.
#
# No failpoints, no injected state, no kernel patch: only
# open/pwrite/pread/mmap/mprotect/unlink from user space.
#
# CASE C is the negative control: a contiguously allocated victim with the same
# faulting buffer must publish nothing, because the fault then lands inside the
# first and only mapped run, before any BIO is submitted.

set -euo pipefail

REPRO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WORKTREE=$REPRO_DIR/../confirmation/MC-6/worktree
WORKTREE=$(cd -- "$WORKTREE" && pwd)
OUT=$REPRO_DIR/out_bugMC-6
SRC=$REPRO_DIR/test_bugMC-6_direct_write_pending_bio.c
GUEST_DIR=$WORKTREE/test/initramfs/src/regression/io/specula

CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805

mkdir -p "$OUT"

echo "== MC-6 repro: Level 0, pure black box =="
echo "worktree: $WORKTREE"

# ---------------------------------------------------------------- Linux control
echo
echo "-- [1/3] Linux control (ext4) --"
LINUX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mc6.XXXXXX")
trap 'rm -rf "$LINUX_DIR"' EXIT
echo "linux dir: $LINUX_DIR ($(stat -f -c %T "$LINUX_DIR"))"
gcc -Wall -Werror -O2 -o "$OUT/mc6_linux" "$SRC" -lpthread
"$OUT/mc6_linux" "$LINUX_DIR" 2>&1 | tee "$OUT/linux.log" || true

# ------------------------------------------------------- pristine kernel + stage
echo
echo "-- [2/3] Building Asterinas from the pristine baseline kernel --"
git -C "$WORKTREE" checkout -- kernel/
echo "baseline commit: $(git -C "$WORKTREE" rev-parse HEAD)"
echo "kernel/ tree state (must be empty => no kernel modification):"
git -C "$WORKTREE" status --short -- kernel/ | grep -v '^?? kernel/core/src/tla_trace.rs$' |
	grep -v '^?? kernel/core/comps/block/src/tla_trace.rs$' || true

install -m 0644 "$SRC" "$GUEST_DIR/mc6_direct_write_pending_bio.c"
cat >"$GUEST_DIR/run_mc6.sh" <<'EOF'
#!/bin/sh
set -eu
/test/io/specula/mc6_direct_write_pending_bio /ext2 || true
echo "SPECULA_SCENARIO_PASS mc6"
EOF
chmod 0755 "$GUEST_DIR/run_mc6.sh"

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
echo "-- [3/3] Asterinas guest run (ext2 at /ext2, SMP=2) --"
timeout 3600 docker run --rm --privileged --network=host \
	--device=/dev/kvm \
	-v "$RUSTUP_CACHE":/root/.rustup \
	-v "$CARGO_CACHE/registry":/root/.cargo/registry \
	-v "$CARGO_CACHE/git":/root/.cargo/git \
	-v "$WORKTREE":/root/asterinas \
	-v "$OUT":/root/mc6-out \
	-w /root/asterinas \
	"$IMAGE" bash -lc '
		set -euo pipefail
		out_uid=$(stat -c %u /root/mc6-out)
		out_gid=$(stat -c %g /root/mc6-out)
		trap '\''chown -R "$out_uid:$out_gid" /root/mc6-out 2>/dev/null || true'\'' EXIT

		export RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu
		export CARGO_NET_GIT_FETCH_WITH_CLI=true

		timeout 2400 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			> /root/mc6-out/build.log 2>&1

		timeout 900 make run_kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			SPECULA_INIT=/test/io/specula/run_mc6.sh \
			2>&1 | tee /root/mc6-out/guest.log >/dev/null
	'

echo
echo "== Asterinas guest output =="
grep -aE '^(CASE |MC6_)' "$OUT/guest.log" | tee "$OUT/asterinas.log"

echo
echo "== Side-by-side (VERDICT per case) =="
printf '%-6s %-16s %-24s %-24s\n' CASE SHAPE LINUX ASTERINAS
for tag in A B C D E F G; do
	l=$(grep -a "^CASE $tag " "$OUT/linux.log" | head -1)
	a=$(grep -a "^CASE $tag " "$OUT/asterinas.log" | head -1)
	shape=$(printf '%s' "$l" | awk '{print $3}')
	lv=$(printf '%s' "$l" | sed -n 's/.*VERDICT=\([A-Z_]*\).*/\1/p')
	av=$(printf '%s' "$a" | sed -n 's/.*VERDICT=\([A-Z_]*\).*/\1/p')
	printf '%-6s %-16s %-24s %-24s\n' "$tag" "$shape" "$lv" "$av"
done

echo
echo "== Detail =="
grep -a '^CASE ' "$OUT/linux.log" | sed 's/^/linux     /'
grep -a '^CASE ' "$OUT/asterinas.log" | sed 's/^/asterinas /'

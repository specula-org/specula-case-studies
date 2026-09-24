#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# MC-6 challenger driver: exercise the ROLLBACK/CLEANUP path that turn 1 never
# reached, on both block devices the project's own default QEMU configuration
# provides.
#
#   /ext2   virtio-blk-pci, num-queues=1  (tools/qemu_args.sh:141)
#   /nvme   -device nvme                  (tools/qemu_args.sh:231-232), the
#           256 MiB ext2 image built by test/initramfs/Makefile:$(SSD_IMAGE);
#           driven by the in-tree aster-nvme driver, whose worker thread is
#           spawned next to the virtio one in
#           kernel/core/src/device/registry/block.rs:44-55.
#
# The second device matters because turn 1's MASKED verdict rests on the claim
# that a single in-order virtio-blk virtqueue always drains the orphaned BIO
# before any later request. NVMe explicitly permits out-of-order execution and
# completion within one submission queue, so if that mask is what holds the
# harm back, this is where it should let go.
#
# Level 0/1 only: no failpoint, no injected state, pristine kernel.

set -euo pipefail

REPRO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WORKTREE=$REPRO_DIR/../confirmation/MC-6/worktree
WORKTREE=$(cd -- "$WORKTREE" && pwd)
OUT=$REPRO_DIR/out_bugMC-6_extend
SRC=$REPRO_DIR/test_bugMC-6_extend_rollback_free.c
TURN1_SRC=$REPRO_DIR/test_bugMC-6_direct_write_pending_bio.c
GUEST_DIR=$WORKTREE/test/initramfs/src/regression/io/specula

CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805

mkdir -p "$OUT"

echo "== MC-6 challenger repro: extending-write rollback, virtio-blk + NVMe =="
echo "worktree: $WORKTREE"

# ---------------------------------------------------------------- Linux control
echo
echo "-- [1/3] Linux control (ext4) --"
LINUX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mc6x.XXXXXX")
trap 'rm -rf "$LINUX_DIR"' EXIT
gcc -Wall -Werror -O2 -o "$OUT/mc6x_linux" "$SRC" -lpthread
"$OUT/mc6x_linux" "$LINUX_DIR" 2>&1 | tee "$OUT/linux.log" || true

# ------------------------------------------------------- pristine kernel + stage
echo
echo "-- [2/3] Staging on the pristine baseline kernel --"
git -C "$WORKTREE" checkout -- kernel/
echo "baseline commit: $(git -C "$WORKTREE" rev-parse HEAD)"
echo "kernel/ tree state (must be empty => no kernel modification):"
git -C "$WORKTREE" status --short -- kernel/ |
	grep -v '^?? kernel/core/src/tla_trace.rs$' |
	grep -v '^?? kernel/core/comps/block/src/tla_trace.rs$' || true

install -m 0644 "$SRC" "$GUEST_DIR/mc6x_extend_rollback_free.c"
install -m 0644 "$TURN1_SRC" "$GUEST_DIR/mc6_direct_write_pending_bio.c"
cat >"$GUEST_DIR/run_mc6x.sh" <<'EOF'
#!/bin/sh
set -u

echo "MC6X_DEVNODES_BEGIN"
ls -l /dev 2>/dev/null | grep -E 'vd|nvme' || echo "MC6X_DEVNODES none"
echo "MC6X_DEVNODES_END"

if [ -e /dev/nvme0n1 ]; then
	mkdir -p /nvme
	if mount -t ext2 /dev/nvme0n1 /nvme; then
		echo "MC6X_NVME mounted"
		echo "MC6X_SECTION nvme_ext2"
		/test/io/specula/mc6x_extend_rollback_free /nvme full || true
		echo "MC6X_SECTION nvme_turn1_cases"
		/test/io/specula/mc6_direct_write_pending_bio /nvme || true
	else
		echo "MC6X_NVME mount_failed rc=$?"
	fi
else
	echo "MC6X_NVME absent"
fi

echo "MC6X_SECTION virtio_ext2"
/test/io/specula/mc6x_extend_rollback_free /ext2 full || true

rm -f /ext2/mc6f_* /ext2/mc6x_* 2>/dev/null || true
rm -f /nvme/mc6f_* /nvme/mc6x_* 2>/dev/null || true
sync || true

echo "SPECULA_SCENARIO_PASS mc6x"
EOF
chmod 0755 "$GUEST_DIR/run_mc6x.sh"

if [ ! -c /dev/kvm ]; then
	echo "repro: /dev/kvm is required for the Asterinas guest run" >&2
	exit 1
fi

echo
echo "-- [3/3] Asterinas guest run (SMP=2) --"
timeout 3600 docker run --rm --privileged --network=host \
	--device=/dev/kvm \
	-v "$RUSTUP_CACHE":/root/.rustup \
	-v "$CARGO_CACHE/registry":/root/.cargo/registry \
	-v "$CARGO_CACHE/git":/root/.cargo/git \
	-v "$WORKTREE":/root/asterinas \
	-v "$OUT":/root/mc6x-out \
	-w /root/asterinas \
	"$IMAGE" bash -lc '
		set -euo pipefail
		out_uid=$(stat -c %u /root/mc6x-out)
		out_gid=$(stat -c %g /root/mc6x-out)
		trap '\''chown -R "$out_uid:$out_gid" /root/mc6x-out 2>/dev/null || true'\'' EXIT

		export RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu
		export CARGO_NET_GIT_FETCH_WITH_CLI=true

		timeout 2400 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			> /root/mc6x-out/build.log 2>&1

		timeout 1800 make run_kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			SPECULA_INIT=/test/io/specula/run_mc6x.sh \
			2>&1 | tee /root/mc6x-out/guest.log >/dev/null
	'

echo
echo "== Asterinas guest output =="
grep -aE '^(MC6X_|MC6_|CASE )' "$OUT/guest.log" | tee "$OUT/asterinas.log"

echo
echo "== Linux control =="
cat "$OUT/linux.log"

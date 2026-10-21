#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# Driver for the MC-3 reproduction.
#
# Escalation level 0: the guest payload (test_bugMC-3_ramfs_read_past_eof.c)
# uses only public syscalls (open/ftruncate/pwrite/pread/read/lseek/preadv).
# The kernel under test is the pristine baseline -- `git status` in the worktree
# must show nothing under kernel/ or ostd/. The only source changes are the
# initramfs build wiring that ships the test binary into the guest.
#
# Step 1 (control): run the identical payload on the Linux host, on tmpfs
#                   (/dev/shm), which is the closest Linux analogue of the
#                   Asterinas ramfs under test.
# Step 2 (target) : build the pristine Asterinas kernel and boot it with the
#                   payload as init; the payload runs against the root ramfs.
#
# Reuses the known-good recipe from .specula-output/harness/run.sh: same docker
# image, same rustup/cargo caches, KVM, SMP=2.

set -eu

REPRO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$REPRO_DIR")
SOURCE_ROOT=$OUTPUT_DIR/confirmation/MC-3/worktree
LOG_DIR=$OUTPUT_DIR/confirmation/MC-3
CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-/tmp}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805
PAYLOAD=$REPRO_DIR/test_bugMC-3_ramfs_read_past_eof.c
CONTROL_DIR=${MC3_CONTROL_DIR:-/dev/shm/mc3-control}

echo "=============================================================="
echo "STEP 1  Linux control (same payload, tmpfs, host kernel $(uname -r))"
echo "=============================================================="
cc -Wall -Werror -O2 -o /tmp/mc3_repro_host "$PAYLOAD"
mkdir -p "$CONTROL_DIR"
/tmp/mc3_repro_host "$CONTROL_DIR" 2>&1 | tee "$LOG_DIR/linux-control.log"

echo
echo "=============================================================="
echo "STEP 2  Asterinas (pristine kernel + same payload as init)"
echo "=============================================================="
echo "--- kernel/ostd modifications in the tree under test (must be empty) ---"
git -C "$SOURCE_ROOT" status --short -- kernel ostd
echo "--- end ---"

if [ ! -c /dev/kvm ]; then
	echo "test_bugMC-3: /dev/kvm is required for the Asterinas run" >&2
	exit 1
fi

# Ship the payload into the initramfs test tree.
GUEST_DIR=$SOURCE_ROOT/test/initramfs/src/regression/io/specula
mkdir -p "$GUEST_DIR"
cp "$PAYLOAD" "$GUEST_DIR/mc3_repro.c"
cat > "$GUEST_DIR/run_mc3_repro.sh" <<'GUEST'
#!/bin/sh
set -eu
mkdir -p /mc3
/test/io/specula/mc3_repro /mc3
echo "SPECULA_SCENARIO_PASS mc3_repro"
GUEST
chmod +x "$GUEST_DIR/run_mc3_repro.sh"

mkdir -p "$RUSTUP_CACHE" "$CARGO_CACHE/registry" "$CARGO_CACHE/git"

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
	'

timeout 3000 docker run --rm --privileged --network=host \
	--device=/dev/kvm \
	-v "$RUSTUP_CACHE":/root/.rustup \
	-v "$CARGO_CACHE/registry":/root/.cargo/registry \
	-v "$CARGO_CACHE/git":/root/.cargo/git \
	-v "$SOURCE_ROOT":/root/asterinas \
	-v "$LOG_DIR":/root/mc3-logs \
	-w /root/asterinas \
	"$IMAGE" bash -lc '
		set -euo pipefail
		out_uid=$(stat -c %u /root/mc3-logs)
		out_gid=$(stat -c %g /root/mc3-logs)
		trap '\''chown -R "$out_uid:$out_gid" /root/mc3-logs /root/asterinas/target 2>/dev/null || true'\'' EXIT

		export RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu
		export CARGO_NET_GIT_FETCH_WITH_CLI=true

		timeout 2400 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			> /root/mc3-logs/asterinas-build.log 2>&1

		timeout 600 make run_kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			SPECULA_INIT=/test/io/specula/run_mc3_repro.sh \
			2>&1 | tee /root/mc3-logs/asterinas-run.log >/dev/null
	'

echo
echo "--- Asterinas guest output ---"
sed -n '/MC-3 repro:/,/MC3_SCENARIO_DONE/p' "$LOG_DIR/asterinas-run.log" \
	| tr -d '\r'

echo
echo "=============================================================="
echo "VERDICT"
echo "=============================================================="
host_result=$(grep -o 'MC3_RESULT [A-Z_]*' "$LOG_DIR/linux-control.log" | tail -1)
guest_result=$(tr -d '\r' < "$LOG_DIR/asterinas-run.log" \
	| grep -o 'MC3_RESULT [A-Z_]*' | tail -1)
echo "Linux host : $host_result"
echo "Asterinas  : $guest_result"

if [ "$host_result" = "MC3_RESULT MATCHES_LINUX" ] \
	&& [ "$guest_result" = "MC3_RESULT DIVERGES_FROM_LINUX" ]; then
	echo "MC-3 REPRODUCED"
	exit 0
fi
echo "MC-3 NOT REPRODUCED"
exit 1

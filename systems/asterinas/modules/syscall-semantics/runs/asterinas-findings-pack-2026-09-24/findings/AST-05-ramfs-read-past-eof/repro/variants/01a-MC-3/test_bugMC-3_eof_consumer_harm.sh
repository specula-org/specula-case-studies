#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# Driver for the MC-3 challenge reproduction (Agent B).
#
# Escalation level 0.  The guest payload uses only public syscalls
# (open/pwrite/ftruncate/pread/preadv/fstat).  The kernel under test is the
# pristine baseline: `git status --short -- kernel ostd` in the worktree must be
# empty.  Only initramfs build wiring is added.
#
# One boot runs BOTH payloads:
#   mc3_repro    -- Agent A's contract test (independent re-verification)
#   mc3_consumer -- this challenge: application-level harm, stale-vs-zero,
#                   and a negative control on the page-aligned-capacity theory
#
# Reuses the recipe from .specula-output/harness/run.sh, same as turn 1.

set -eu

REPRO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$REPRO_DIR")
SOURCE_ROOT=$OUTPUT_DIR/confirmation/MC-3/worktree
LOG_DIR=$OUTPUT_DIR/confirmation/MC-3
CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-/tmp}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805
PAYLOAD_A=$REPRO_DIR/test_bugMC-3_ramfs_read_past_eof.c
PAYLOAD_B=$REPRO_DIR/test_bugMC-3_eof_consumer_harm.c
CONTROL_DIR=${MC3_CONTROL_DIR:-/dev/shm/mc3c-control}

echo "=============================================================="
echo "STEP 1  Linux control (challenge payload, tmpfs, host $(uname -r))"
echo "=============================================================="
cc -Wall -Werror -O2 -o /tmp/mc3c_host "$PAYLOAD_B"
mkdir -p "$CONTROL_DIR"
/tmp/mc3c_host "$CONTROL_DIR" 2>&1 | tee "$LOG_DIR/challenge-linux-control.log"

echo
echo "=============================================================="
echo "STEP 2  Asterinas (pristine kernel, both payloads in one boot)"
echo "=============================================================="
echo "--- kernel/ostd modifications in the tree under test (must be empty) ---"
git -C "$SOURCE_ROOT" status --short -- kernel ostd
echo "--- end ---"

if [ ! -c /dev/kvm ]; then
	echo "test_bugMC-3 challenge: /dev/kvm is required" >&2
	exit 1
fi

GUEST_DIR=$SOURCE_ROOT/test/initramfs/src/regression/io/specula
mkdir -p "$GUEST_DIR"
cp "$PAYLOAD_A" "$GUEST_DIR/mc3_repro.c"
cp "$PAYLOAD_B" "$GUEST_DIR/mc3_consumer.c"
cat > "$GUEST_DIR/run_mc3_challenge.sh" <<'GUEST'
#!/bin/sh
set -eu
mkdir -p /mc3
/test/io/specula/mc3_repro /mc3
/test/io/specula/mc3_consumer /mc3
echo "SPECULA_SCENARIO_PASS mc3_challenge"
GUEST
chmod +x "$GUEST_DIR/run_mc3_challenge.sh"

mkdir -p "$RUSTUP_CACHE" "$CARGO_CACHE/registry" "$CARGO_CACHE/git"

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
			> /root/mc3-logs/challenge-build.log 2>&1

		timeout 600 make run_kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			SPECULA_INIT=/test/io/specula/run_mc3_challenge.sh \
			2>&1 | tee /root/mc3-logs/challenge-asterinas-run.log >/dev/null
	'

echo
echo "--- Asterinas guest output ---"
sed -n '/MC-3 repro:/,/MC3C_SCENARIO_DONE/p' "$LOG_DIR/challenge-asterinas-run.log" | tr -d '\r'

echo
echo "=============================================================="
echo "VERDICT"
echo "=============================================================="
host_result=$(grep -o 'MC3C_RESULT [A-Z_]*' "$LOG_DIR/challenge-linux-control.log" | tail -1)
guest_result=$(tr -d '\r' < "$LOG_DIR/challenge-asterinas-run.log" \
	| grep -o 'MC3C_RESULT [A-Z_]*' | tail -1)
guest_control=$(tr -d '\r' < "$LOG_DIR/challenge-asterinas-run.log" \
	| grep -o 'control_failures=[0-9]*' | tail -1)
echo "Linux host      : $host_result"
echo "Asterinas       : $guest_result"
echo "Asterinas ctrl  : $guest_control (must be control_failures=0)"

if [ "$host_result" = "MC3C_RESULT MATCHES_LINUX" ] \
	&& [ "$guest_result" = "MC3C_RESULT DIVERGES_FROM_LINUX" ] \
	&& [ "$guest_control" = "control_failures=0" ]; then
	echo "MC-3 CHALLENGE: consumer-level harm CONFIRMED (negative control held)"
	exit 0
fi
echo "MC-3 CHALLENGE: consumer-level harm NOT confirmed"
exit 1

#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# CR-1 driver: can a regular-file read/write hand EINTR to the syscall wrapper,
# and if a restart happens, is committed progress replayed?
#
# Escalation Levels 0 and 1 only. kernel/ is reverted to the pristine baseline
# before the build, so the kernel under test is unmodified Asterinas. Level 1 is
# userspace timing assistance: a signal-storm thread, a concurrent fsync thread,
# and O_DIRECT to force real block-device waits.
#
# Backends exercised (all regular files, the campaign's scope):
#   /tmp    ramfs
#   /ext2   virtio-blk ext2, buffered
#   /ext2   virtio-blk ext2, O_DIRECT  (forces a real block-device wait)
#   /ext2   virtio-blk ext2, O_SYNC    (forces a write-back wait per write)
# Plus a pipe positive control that proves the same read.rs EINTR arm is live.
#
# Linux runs the identical binary as the reference.

set -euo pipefail

REPRO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WORKTREE=$REPRO_DIR/../confirmation/CR-1/worktree
WORKTREE=$(cd -- "$WORKTREE" && pwd)
OUT=$REPRO_DIR/out_bugCR-1
SRC=$REPRO_DIR/test_bugCR-1_restart_progress_provenance.c
GUEST_DIR=$WORKTREE/test/initramfs/src/regression/io/specula

CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805

mkdir -p "$OUT"

echo "== CR-1 repro: restart vs. committed progress on regular files =="
echo "worktree: $WORKTREE"

# ---------------------------------------------------------------- Linux control
echo
echo "-- [1/3] Linux reference --"
LINUX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cr1.XXXXXX")
trap 'rm -rf "$LINUX_DIR"' EXIT
gcc -Wall -Wextra -O2 -o "$OUT/cr1_linux" "$SRC" -lpthread
{
	"$OUT/cr1_linux" --ctrl || true
	"$OUT/cr1_linux" "$LINUX_DIR" linuxfs || true
	"$OUT/cr1_linux" "$LINUX_DIR" linuxfssync sync || true
} 2>&1 | tee "$OUT/linux.log"

# ------------------------------------------------------- pristine kernel + stage
echo
echo "-- [2/3] Staging on the pristine baseline kernel --"
git -C "$WORKTREE" checkout -- kernel/
echo "baseline commit: $(git -C "$WORKTREE" rev-parse HEAD)"
echo "kernel/ tree state (must be empty => no kernel modification):"
git -C "$WORKTREE" status --short -- kernel/ |
	grep -v '^?? kernel/core/src/tla_trace.rs$' |
	grep -v '^?? kernel/core/comps/block/src/tla_trace.rs$' || true

install -m 0644 "$SRC" "$GUEST_DIR/cr1_restart_progress.c"
cat >"$GUEST_DIR/run_cr1.sh" <<'EOF'
#!/bin/sh
set -u

echo "CR1_SECTION ctrl"
/test/io/specula/cr1_restart_progress --ctrl || true

echo "CR1_SECTION ramfs"
/test/io/specula/cr1_restart_progress /tmp ramfs || true

echo "CR1_SECTION ext2"
/test/io/specula/cr1_restart_progress /ext2 ext2 || true

echo "CR1_SECTION ext2direct"
/test/io/specula/cr1_restart_progress /ext2 ext2direct direct || true

echo "CR1_SECTION ext2sync"
/test/io/specula/cr1_restart_progress /ext2 ext2sync sync || true

rm -f /ext2/cr1-* 2>/dev/null || true
sync || true

echo "SPECULA_SCENARIO_PASS cr1"
EOF
chmod 0755 "$GUEST_DIR/run_cr1.sh"

if [ ! -c /dev/kvm ]; then
	echo "repro: /dev/kvm is required for the Asterinas guest run" >&2
	exit 1
fi

run_guest() {
	timeout 5400 docker run --rm --privileged --network=host \
	--device=/dev/kvm \
	-v "$RUSTUP_CACHE":/root/.rustup \
	-v "$CARGO_CACHE/registry":/root/.cargo/registry \
	-v "$CARGO_CACHE/git":/root/.cargo/git \
	-v "$WORKTREE":/root/asterinas \
	-v "$OUT":/root/cr1-out \
	-w /root/asterinas \
	"$IMAGE" bash -lc '
		set -euo pipefail
		out_uid=$(stat -c %u /root/cr1-out)
		out_gid=$(stat -c %g /root/cr1-out)
		trap '\''chown -R "$out_uid:$out_gid" /root/cr1-out 2>/dev/null || true'\'' EXIT

		export RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu
		export CARGO_NET_GIT_FETCH_WITH_CLI=true

		timeout 3600 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			> /root/cr1-out/build.log 2>&1

		timeout 1200 make run_kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			SPECULA_INIT=/test/io/specula/run_cr1.sh \
			2>&1 | tee /root/cr1-out/guest.log >/dev/null
	'
}
echo
echo "-- [3/3] Asterinas guest run --"
# QEMU host-forward ports are picked per run and occasionally collide with a
# port already bound on the host (--network=host); retry rather than fail.
attempt=1
while :; do
	if run_guest; then
		break
	fi
	if [ "$attempt" -ge 4 ]; then
		echo "repro: guest run failed after $attempt attempts" >&2
		exit 1
	fi
	echo "repro: guest attempt $attempt failed, retrying" >&2
	attempt=$((attempt + 1))
	sleep 5
done

echo
echo "== Asterinas guest output =="
grep -aE '^(CR1_|SPECULA_SCENARIO)' "$OUT/guest.log" | tee "$OUT/asterinas.log"

echo
echo "== Linux reference =="
cat "$OUT/linux.log"

echo
echo "== Escalation ladder =="
cat <<'LADDER'
Level 0  Pure black-box, pristine kernel. open/dup/read/write/lseek/fstat plus a
         SIGUSR1 handler. Ran as CR1_PROBE/CR1_APPEND/CR1_OFFSET above with the
         storm thread already active. Outcome: no EINTR, no replay.

Level 1  Timing assistance, still a pristine kernel. Three additions, all in
         userspace: (a) a storm thread on the other CPU calling pthread_kill in
         a tight loop, (b) a syncer thread calling fsync every 200 us so buffered
         writes meet pages under write-back, (c) O_DIRECT and O_SYNC modes so the
         write path blocks on the block device (comps/block/src/bio.rs:355) and
         on write-back (vm/page_cache/cache_page.rs:319) respectively. Signal
         delivery is proven live by CR1_CTRL_PIPE (RESTARTED with SA_RESTART,
         EINTR without) and by handler_hits > 0 in every section.
         Outcome: no EINTR, no replay, on ramfs and on ext2 in all three modes.

Level 2  State injection: NOT ADMISSIBLE for this finding, and therefore not
         used as evidence.
         The state to inject is "a regular-file FileOps::read_at/write_at commits
         a positive byte prefix and then returns Err(EINTR)". No real-API call
         sequence produces it: grep over the pristine tree finds zero EINTR
         producers under kernel/core/src/fs/, kernel/core/src/vm/ and ostd/src/,
         and every regular-file wait is the uninterruptible wait_until
         (cache_page.rs:319, bio.rs:355), never pause_until. The only object in
         this tree that emits it is the harness-only ReferenceFileOps
         (kernel/core/src/tla_trace.rs:729-740, 799-815), a synthetic
         Mutex<Vec<u8>> backend reachable only through instrumentation that is
         not part of the kernel, selected by process name. Per the skill that is
         "a mock that emits a value a real peer never sends" -- an unsound
         injection. It also could not show the sharp consequence even if used:
         its write_at clamps to a fixed-size buffer, so it has no O_APPEND
         growth to double.

Level 3  Minimal code modification: NOT APPLICABLE.
         Level 3 is for inserting a delay to make a race deterministic. There is
         no race here: the mechanism is a missing byte count on an error value,
         not a timing window. The only edit that would produce the symptom is
         inserting `return Err(EINTR)` after a commit inside a real ext2/ramfs
         backend, i.e. writing the bug into the system under test. Prohibited.
LADDER

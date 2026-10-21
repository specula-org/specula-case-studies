#!/usr/bin/env bash
# Reproduction runner for finding MC-2 (AST-36).
#
# Reuses the proven harness-validation recipe
# (.specula-output/harness/run.sh + harness/src/guest-build.sh) on the
# confirmation worktree, whose source is byte-identical to the tree that
# produced the existing build artifacts:
#   1. sync source mtimes from the original tree and copy its cargo
#      target/ cache so the kernel build is a warm no-op (the kernel is
#      unchanged; only the initramfs init binary differs),
#   2. build the ISO in the asterinas/kernel-dev container,
#   3. boot it under QEMU/KVM and capture the guest log,
#   4. compile the same test for the host and run it as the Linux control.
set -euo pipefail

T=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights
W=$T/.specula-output/confirmation/MC-2/worktree-1
H=$T/.specula-output/harness
B=$T/.specula-output/confirmation/MC-2/build
REPRO=$T/.specula-output/repro/test_bugMC-2_payload_fault_retain.c

mkdir -p "$B/root/dev" "$B/root/tmp" "$H/build/cargo-git" "$H/build/cargo-registry"

# 1. Warm cache: worktree-1 (this turn's git worktree, pin 0c6053709 + the
#    same scm-trace instrumentation) is content-identical to $T/source
#    (verified with diff -rq). Only mtimes need syncing so cargo fingerprints
#    match; then copy the root-owned target/ caches from the original tree.
if [ ! -d "$W/target" ]; then
    rsync -a --existing --exclude .git --exclude .codex \
        --exclude target --exclude osdk/target "$T/source/" "$W/"
    sudo -n rm -rf "$W/osdk/target"
    sudo -n cp -a "$T/source/target" "$W/target"
    sudo -n cp -a "$T/source/osdk/target" "$W/osdk/target"
fi

# 2. Build the initramfs and the ISO inside the container (same image,
#    mounts, and commands as harness/src/guest-build.sh; the worktree takes
#    the /home/chin39/Documents/asterinas-dev mount so the OSDK_LOCAL_DEV
#    paths embedded in the cached osdk binary stay valid).
sudo -n docker -H unix:///var/run/docker.sock rm -f mc2-build >/dev/null 2>&1 || true
sudo -n docker -H unix:///var/run/docker.sock create --name mc2-build \
    --cpus 2 --memory 8g --pids-limit 512 --device /dev/kvm \
    --mount "type=bind,src=$T,dst=/work" \
    --mount "type=bind,src=$W,dst=/home/chin39/Documents/asterinas-dev" \
    --mount "type=bind,src=$H/build/cargo-git,dst=/root/.cargo/git" \
    --mount "type=bind,src=$H/build/cargo-registry,dst=/root/.cargo/registry" \
    -e CARGO_NET_OFFLINE=false -e CARGO_BUILD_JOBS=2 -e OSDK_LOCAL_DEV=1 \
    asterinas/kernel-dev:0.18.1-20260926 \
    bash -c '
set -euo pipefail
cd /home/chin39/Documents/asterinas-dev
timeout 900 cargo build --locked --manifest-path osdk/Cargo.toml
gcc -static -O2 -g -pthread -Wall -Werror \
    /work/.specula-output/repro/test_bugMC-2_payload_fault_retain.c \
    -o /work/.specula-output/confirmation/MC-2/build/root/init
gcc -static -O2 -g -pthread -Wall -Werror \
    /work/.specula-output/repro/test_bugMC-2_payload_fault_retain.c \
    -o /work/.specula-output/confirmation/MC-2/build/linux-control
cd /work/.specula-output/confirmation/MC-2/build/root
find . -print0 | cpio --null -o --format=newc > ../initramfs.cpio
cd /home/chin39/Documents/asterinas-dev/kernel
../osdk/target/debug/cargo-osdk osdk build --scheme scm-trace --release \
    --initramfs /work/.specula-output/confirmation/MC-2/build/initramfs.cpio \
    --kcmd-args=loglevel=error --kcmd-args=console=ttyS0 --kcmd-args=earlycon
'
set +e
timeout 1800 sudo -n docker -H unix:///var/run/docker.sock start -a mc2-build \
    > "$B/build.log" 2>&1
build_status=$?
set -e
sudo -n docker -H unix:///var/run/docker.sock rm -f mc2-build >/dev/null
printf 'build_status=%s\n' "$build_status"
[ "$build_status" = 0 ]

# 3. Boot the ISO (same QEMU invocation as harness/run.sh).
sudo -n docker -H unix:///var/run/docker.sock rm -f mc2-guest >/dev/null 2>&1 || true
sudo -n docker -H unix:///var/run/docker.sock create --name mc2-guest \
    --cpus 2 --memory 8g --pids-limit 512 --device /dev/kvm \
    --mount "type=bind,src=$T,dst=/work" \
    --mount "type=bind,src=$W,dst=/home/chin39/Documents/asterinas-dev" \
    asterinas/kernel-dev:0.18.1-20260926 \
    timeout 300 qemu-system-x86_64 \
    -bios /root/ovmf/release/OVMF.fd -machine q35,kernel-irqchip=split \
    -m 2G -smp 2 -cpu host -accel kvm -nographic -monitor none -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -cdrom /home/chin39/Documents/asterinas-dev/target/osdk/asterinas-osdk-bin.iso
set +e
timeout 360 sudo -n docker -H unix:///var/run/docker.sock start -a mc2-guest \
    > "$B/guest.log" 2>&1
guest_status=$?
set -e
sudo -n docker -H unix:///var/run/docker.sock rm -f mc2-guest >/dev/null
printf 'guest_status=%s\n' "$guest_status"
grep -q '^MC2_RESULT' "$B/guest.log" || { tail -40 "$B/guest.log"; exit 1; }

# 4. Linux control on the host.
timeout 120 "$B/linux-control" > "$B/linux.log" 2>&1
printf 'linux_control_status=%s\n' "$?"

echo "=== guest (Asterinas) ==="
grep -E '^MC2_' "$B/guest.log"
echo "=== host (Linux control) ==="
grep -E '^MC2_' "$B/linux.log"

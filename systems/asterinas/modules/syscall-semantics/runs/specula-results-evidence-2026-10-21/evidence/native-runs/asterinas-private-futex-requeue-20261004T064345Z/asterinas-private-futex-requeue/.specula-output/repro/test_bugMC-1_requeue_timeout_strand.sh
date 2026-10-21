#!/usr/bin/env bash
# Reproduction runner for finding MC-1 (see test_bugMC-1_requeue_timeout_strand.c).
#
# Level 0 (black-box): the trigger uses only FUTEX_WAIT/FUTEX_REQUEUE/FUTEX_WAKE
# syscalls in a real Asterinas SMP=2 KVM guest. The already-built instrumented
# kernel image from the campaign harness is reused unchanged (its probes are
# observation-only and are used for test setup: bucket identity + enrollment).
# The same test binary is also run natively on Linux as the control that shows
# the expected (correct) behavior.
#
# The kernel boot is a heavy stage. The receiving controller already holds
# heavy.lock for the whole phase (resources.json phase_worker_rule: a phase
# worker must not reacquire it), so this runner does not flock it again and
# instead keeps the per-lane limits: container 2 CPUs, 8g memory, 512 PIDs,
# guest SMP=2 with 2G RAM.
set -euo pipefail

SPEC=/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output
RUN=$(dirname "$SPEC")
REPRO="$SPEC/repro"
C_TEST="$REPRO/test_bugMC-1_requeue_timeout_strand.c"

KERNEL_BIN="$SPEC/harness/build/target/osdk/iso_root/boot/asterinas-osdk-bin"
[[ -f "$KERNEL_BIN" ]]

mkdir -p "$REPRO"

echo "=== [control] native Linux run of the same scenario (expected: no bug) ==="
# Dynamic linking is fine for the native control; the NixOS host has no static glibc.
gcc -pthread -O2 -o "$REPRO/mc1_host" "$C_TEST"
timeout 60 "$REPRO/mc1_host" || echo "(control exit $?)"
echo

echo "=== [guest] Asterinas SMP=2 KVM run (compile, package ISO, boot) ==="
# Guest-side script executed inside the asterinas/kernel-dev container.
cat > "$REPRO/guest_mc1_inner.sh" <<'EOF'
set -euo pipefail
REPRO=/work/.specula-output/repro
KERNEL=/work/.specula-output/harness/build/target/osdk/iso_root/boot/asterinas-osdk-bin
[[ -f "$KERNEL" ]]
gcc -static -pthread -O2 -o /tmp/repro-init "$REPRO/test_bugMC-1_requeue_timeout_strand.c"
rm -rf /tmp/mc1-initramfs /tmp/mc1-iso-root
mkdir -p /tmp/mc1-initramfs/sbin /tmp/mc1-initramfs/dev /tmp/mc1-initramfs/proc /tmp/mc1-initramfs/tmp
cp /tmp/repro-init /tmp/mc1-initramfs/init
# Asterinas's initramfs unpacker expects a raw newc cpio (the harness's
# initramfs.cpio.gz is an uncompressed cpio despite the .gz name).
(cd /tmp/mc1-initramfs && find . -print0 | cpio --null -o --format=newc > /tmp/mc1-initramfs.cpio.gz)
mkdir -p /tmp/mc1-iso-root/boot/grub
cp "$KERNEL" /tmp/mc1-iso-root/boot/asterinas-osdk-bin
cp /tmp/mc1-initramfs.cpio.gz /tmp/mc1-iso-root/boot/initramfs.cpio.gz
cat > /tmp/mc1-iso-root/boot/grub/grub.cfg <<'GRUB'
set timeout_style=hidden
set timeout=0
menuentry 'asterinas' {
    multiboot2 /boot/asterinas-osdk-bin SHELL=/bin/sh LOGNAME=root HOME=/ USER=root PATH=/bin:/benchmark rdinit=/init console=ttyS0 loglevel=error earlycon -- sh -l
    module2 --nounzip /boot/initramfs.cpio.gz
    boot
}
GRUB
timeout 120 grub-mkrescue -o /tmp/mc1.iso /tmp/mc1-iso-root > "$REPRO/package-mc1.log" 2>&1
sha256sum /tmp/mc1.iso "$KERNEL" /tmp/mc1-initramfs.cpio.gz > "$REPRO/images-mc1.sha256"
status=0
timeout -k 10 180 qemu-system-x86_64 -machine q35,accel=kvm -cpu host \
    -m 2G -smp 2 -bios /root/ovmf/release/OVMF.fd -no-reboot -display none \
    -serial stdio -monitor none -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -drive file=/tmp/mc1.iso,format=raw,index=2,media=cdrom > "$REPRO/guest-mc1.log" 2>&1 || status=$?
# Asterinas encodes successful isa-debug-exit shutdown as QEMU status 33.
[[ $status == 0 || $status == 33 ]] || echo "MC1_WARN qemu exit status $status"
grep -q "MC1_VERDICT" "$REPRO/guest-mc1.log" || { echo "MC1_ERR guest log has no verdict"; tail -50 "$REPRO/guest-mc1.log"; exit 1; }
echo "=== guest serial output (MC1 lines) ==="
grep -a "MC1_" "$REPRO/guest-mc1.log" || true
EOF

sudo -n docker -H unix:///var/run/docker.sock run --rm --cpus=2 --memory=8g --pids-limit=512 --device=/dev/kvm \
    -v "$RUN:/work" asterinas/kernel-dev:0.18.1-20260926 bash /work/.specula-output/repro/guest_mc1_inner.sh

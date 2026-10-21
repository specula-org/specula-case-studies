#!/usr/bin/env bash
# Inner script for test_bugMC-3_requeue_zero_move_same_bucket.sh -- runs
# INSIDE the asterinas/kernel-dev container with /work bound to the campaign
# run dir.
#
# Compiles the MC-3 repro as a static guest /init (same source as the Linux
# control run, -DGUEST only adds the clean shutdown), packages it with the
# campaign's already-built kernel image (harness
# build/target/osdk/iso_root/boot/asterinas-osdk-bin, source 0c6053709,
# sha256 39ae3549... -- the same binary the harness used for all 18 trace
# cases including case-05; futex logic upstream-identical per
# confirmation/MC-3/investigation.md), and boots it under QEMU exactly like
# the campaign harness container.sh recipe (KVM, OVMF, SMP 2, 2G,
# isa-debug-exit shutdown; exit 33 = clean shutdown).
set -euo pipefail
cd /work/.specula-output/repro/mc3_guest

# 1. Compile the test as a static guest init binary.
gcc -O2 -Wall -static -pthread -DGUEST -o init \
    ../test_bugMC-3_requeue_zero_move_same_bucket.c

# 2. Build the initramfs (same layout as the harness: init + dev/proc/tmp/sbin;
#    uncompressed cpio stored under the .cpio.gz name, matching the kernel's
#    plain-cpio sniffing path used by all 18 harness boots).
rm -rf initramfs iso_root
mkdir -p initramfs/dev initramfs/proc initramfs/tmp initramfs/sbin
cp init initramfs/init
( cd initramfs && find . -print0 | cpio --null -o --format=newc ) > initramfs.cpio

# 3. Package the ISO with the reused campaign kernel binary.
kernel=/work/.specula-output/harness/build/target/osdk/iso_root/boot/asterinas-osdk-bin
mkdir -p iso_root/boot/grub
cp "$kernel" iso_root/boot/
cp initramfs.cpio iso_root/boot/initramfs.cpio.gz
cat > iso_root/boot/grub/grub.cfg <<'EOF'
# AUTOMATICALLY GENERATED FILE, DO NOT EDIT IF YOU KNOW WHAT YOU'RE DOING

set timeout_style=hidden
set timeout=0

menuentry 'asterinas' {
    multiboot2 /boot/asterinas-osdk-bin SHELL=/bin/sh LOGNAME=root HOME=/ USER=root PATH=/bin:/benchmark rdinit=/init console=ttyS0 loglevel=error earlycon -- sh -l
    module2 --nounzip /boot/initramfs.cpio.gz
    boot
}
EOF
grub-mkrescue -o mc3.iso iso_root > grub.log 2>&1

# 4. Boot the guest (harness recipe; 33 = clean isa-debug-exit shutdown).
status=0
timeout -k 10 240 qemu-system-x86_64 -machine q35,accel=kvm -cpu host \
    -m 2G -smp 2 -bios /root/ovmf/release/OVMF.fd -no-reboot -display none \
    -serial stdio -monitor none -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -drive "file=mc3.iso,format=raw,index=2,media=cdrom" > guest.log 2>&1 || status=$?
echo "QEMU_STATUS=$status"
[[ $status == 0 || $status == 33 ]]

# 5. The test must have run to completion.
grep -q "MC3_TEST_DONE" guest.log

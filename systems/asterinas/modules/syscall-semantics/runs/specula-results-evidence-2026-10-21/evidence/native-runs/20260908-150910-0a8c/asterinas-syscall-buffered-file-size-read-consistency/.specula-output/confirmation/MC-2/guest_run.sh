#!/usr/bin/env bash
# Runs INSIDE the dev container. Boots the prebuilt (instrumented, passive
# trace hooks only) kernel with the MC-2 repro initramfs.
set -euo pipefail
B=/work/.specula-output/confirmation/MC-2/build
K=/work/.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf
cd "$B"
exec timeout 240 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
    -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -display none -monitor none -serial stdio \
    -nic none -kernel "$K" -initrd "$B"/initramfs-mc2.cpio \
    -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
    -drive if=none,format=raw,id=x0,file="$B"/ext2-mc2.img \
    -drive if=none,format=raw,id=x1,file="$B"/exfat-mc2.img \
    -device virtio-blk-pci,drive=x0,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device virtio-blk-pci,drive=x1,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04

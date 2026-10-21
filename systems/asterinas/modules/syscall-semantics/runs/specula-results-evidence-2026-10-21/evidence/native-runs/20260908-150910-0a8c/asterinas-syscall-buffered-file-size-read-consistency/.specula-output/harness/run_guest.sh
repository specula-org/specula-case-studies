#!/usr/bin/env bash
set -euo pipefail
cd /work/.specula-output/harness/build
exec timeout 180 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
    -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -vga std -display vnc=unix:/work/.specula-output/harness/build/vnc.sock -qmp unix:/work/.specula-output/harness/build/qmp.sock,server=on,wait=off -monitor none -serial stdio \
    -nic none -kernel kernel-direct/asterinas-osdk-bin.qemu_elf -initrd initramfs.cpio -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
    -drive if=none,format=raw,id=x0,file=ext2.img \
    -drive if=none,format=raw,id=x1,file=exfat.img \
    -device virtio-blk-pci,drive=x0,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device virtio-blk-pci,drive=x1,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04

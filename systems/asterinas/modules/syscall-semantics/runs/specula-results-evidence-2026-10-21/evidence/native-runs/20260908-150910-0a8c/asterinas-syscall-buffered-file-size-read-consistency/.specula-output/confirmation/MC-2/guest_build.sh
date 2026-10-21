#!/usr/bin/env bash
# Runs INSIDE the dev container. Builds the MC-2 repro + init, packs an
# initramfs, creates fresh ext2/exfat images.
set -euo pipefail
B=/work/.specula-output/confirmation/MC-2/build
mkdir -p "$B"/root/{dev,proc,tmp,ramfs,ext2,exfat}
timeout 120 gcc -static -O2 -Wall -Wextra -pthread \
    /work/.specula-output/repro/test_bugMC-2_exfat_read_past_prefix.c -o "$B"/root/repro
timeout 120 gcc -static -O2 -Wall -Wextra \
    /work/.specula-output/confirmation/MC-2/init_mc2.c -o "$B"/root/init
cd "$B"/root
find . -print0 | cpio --null -o --format=newc > "$B"/initramfs-mc2.cpio
cd "$B"
truncate -s 128M ext2-mc2.img
mkfs.ext2 -q -F -b 4096 ext2-mc2.img
truncate -s 128M exfat-mc2.img
mkfs.exfat -c 4096 exfat-mc2.img
echo "guest build done"

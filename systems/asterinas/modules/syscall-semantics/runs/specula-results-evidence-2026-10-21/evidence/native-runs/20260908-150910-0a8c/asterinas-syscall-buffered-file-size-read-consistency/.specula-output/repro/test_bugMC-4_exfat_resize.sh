#!/usr/bin/env bash
# MC-4: ExFAT successful ftruncate retains the old logical size.
#
# Level 0 (pure black-box): boot the already-built Asterinas kernel
# (harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf, built from the
# Specula-instrumented worktree whose exFAT resize logic is byte-identical to
# upstream main) with fresh ext2/exFAT fixtures, and drive public syscalls:
#   A) create empty file, ftruncate(1)        -> fstat/pread  (MC trace step)
#   B) write 4096, ftruncate(8192)            -> fstat/pread  (cross-cluster grow)
#   C) write 4096, ftruncate(2048)            -> fstat/pread  (same-cluster shrink)
# ext2 is run as a control backend.
# Bug signature: ftruncate returns 0 but st_size is unchanged (and reads are
# bounded by the stale size).
set -euo pipefail

OUT_DIR=$(cd "$(dirname "$0")" && pwd)
SPEC_OUT=$(dirname "$OUT_DIR")
HARNESS="$SPEC_OUT/harness"
WORK="$OUT_DIR/work_mc4"
QEMU=${QEMU:-/nix/store/bp7xirbcfly3cjfvkx7wyahcaqkn6rcz-qemu-10.2.1/bin/qemu-system-x86_64}
MKEXFAT=${MKFS_EXFAT:-/nix/store/dzyfajlzhgizm8xwxnxchjzls1xs1vkd-exfatprogs-1.3.2/sbin/mkfs.exfat}
KERNEL="$HARNESS/build/kernel-direct/asterinas-osdk-bin.qemu_elf"

mkdir -p "$WORK/root"
mkdir -p "$WORK/root"/{dev,proc,tmp,ext2,exfat}
cat > "$WORK/test.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>

static int bugs;

/* Returns file size after ftruncate(len) on a file of size before. */
static long do_case(const char *path, long before, long len, long *read_n)
{
    char buf[8192];
    memset(buf, 0xAA, sizeof(buf));
    prctl(0x53504543, 0UL, 2048UL, 16384UL, 0UL); /* (re)arm kernel trace recorder */
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) { perror("open"); write(1, "MC4CASE openfail\n", 18); return -2; }
    if (before > 0) {
        if (write(fd, buf, before) != before) { perror("write"); return -2; }
        fsync(fd);
    }
    int r = ftruncate(fd, len);
    int e = errno;
    struct stat st;
    fstat(fd, &st);
    memset(buf, 0x55, sizeof(buf));
    ssize_t n = pread(fd, buf, sizeof(buf), 0);
    prctl(0x53504544, 0UL, 0UL, 0UL, 0UL); /* drain kernel trace receipts */
    printf("MC4CASE %s before=%ld ftruncate(%ld)=%d errno=%d st_size=%ld pread=%zd\n",
           path, before, len, r, r ? e : 0, (long)st.st_size, n);
    if (r == 0 && (long)st.st_size != len) {
        printf("MC4BUG  %s: ftruncate(%ld) succeeded but st_size=%ld\n",
               path, len, (long)st.st_size);
        bugs++;
    }
    if (r == 0 && (long)n != len) {
        printf("MC4BUG  %s: after successful ftruncate(%ld), pread at 0 returned %zd bytes\n",
               path, len, n);
        bugs++;
    }
    *read_n = n;
    close(fd);
    return st.st_size;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    write(1, "MC4INIT start\n", 15);
    mkdir("/dev", 0755); mkdir("/proc", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("proc", "/proc", "proc", 0, NULL);
    mkdir("/ext2", 0777); mkdir("/exfat", 0777);
    if (mount("/dev/vda", "/ext2", "ext2", 0, NULL)) perror("mount ext2");
    write(1, "MC4INIT ext2 mounted\n", 21);
    if (mount("/dev/vdb", "/exfat", "exfat", 0, NULL)) perror("mount exfat");
    write(1, "MC4INIT exfat mounted\n", 22);

    long rn;
    /* A: empty exFAT file extended by ftruncate (the MC counterexample step) */
    do_case("/exfat/mc4a", 0, 1, &rn);
    do_case("/exfat/mc4a2", 0, 8192, &rn);
    /* B: cross-cluster grow */
    do_case("/exfat/mc4b", 4096, 8192, &rn);
    /* C: same-cluster shrink */
    do_case("/exfat/mc4c", 4096, 2048, &rn);
    /* ext2 control */
    do_case("/ext2/mc4a", 0, 8192, &rn);
    do_case("/ext2/mc4c", 4096, 2048, &rn);

    printf("MC4VERDICT %s bugs=%d\n", bugs ? "BUG" : "CLEAN", bugs);
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
EOF

GLIBC_STATIC=${GLIBC_STATIC:-/nix/store/yj1pjc2syqq4gn6gr9jjda2sxhlhaqnk-glibc-2.42/lib}
gcc -static -O2 -Wall -B"$GLIBC_STATIC" -L"$GLIBC_STATIC" -o "$WORK/root/init" "$WORK/test.c"
(cd "$WORK/root" && find . -print0 | cpio --null -o --format=newc > "$WORK/initramfs.cpio")

# Fresh fixtures, same shape as the harness (128M images, 4K clusters).
truncate -s 128M "$WORK/ext2.img"
mkfs.ext2 -q -F -b 4096 "$WORK/ext2.img"
truncate -s 128M "$WORK/exfat.img"
"$MKEXFAT" -c 4096 "$WORK/exfat.img" >/dev/null

cd "$WORK"
set +e
timeout 90 "$QEMU" -enable-kvm -machine q35,kernel-irqchip=split \
    -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -display none -serial stdio \
    -nic none -kernel "$KERNEL" -initrd "$WORK/initramfs.cpio" \
    -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
    -drive if=none,format=raw,id=x0,file="$WORK/ext2.img" \
    -drive if=none,format=raw,id=x1,file="$WORK/exfat.img" \
    -device virtio-blk-pci,drive=x0,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device virtio-blk-pci,drive=x1,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    2>&1 | tee "$WORK/guest.log"
set -e
echo "---- MC4 case lines ----"
grep -aE "MC4CASE|MC4BUG|MC4VERDICT" "$WORK/guest.log" || true
echo "---- ExfatResizeAllocation receipts (in-kernel size/allocated/clusters) ----"
grep -ao 'SPECULA_RAW {"event":"ExfatResize[A-Za-z]*"[^}]*"v":\[[^]]*\]' "$WORK/guest.log" || true

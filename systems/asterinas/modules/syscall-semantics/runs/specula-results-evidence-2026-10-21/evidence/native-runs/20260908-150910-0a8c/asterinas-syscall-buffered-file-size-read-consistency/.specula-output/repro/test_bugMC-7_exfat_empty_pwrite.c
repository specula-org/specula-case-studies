/* SPDX-License-Identifier: MPL-2.0 */
/*
 * test_bugMC-7: ExFAT zero-count positional writes can enlarge the file.
 *
 * Guest-side reproduction for Specula finding MC-7
 * (counterexample spec/output/MC_hunt_s4_empty_exfat_bfs1.out):
 *   pwrite64(fd, buf, 0, off) with off > size on exFAT sets size := off,
 *   allocates clusters, returns 0. Linux contract (man write(2)): "If count
 *   is zero ... 0 is returned without causing any other effects."
 *
 * Runs as the guest init: mounts fixtures, drops to uid 1000 (unprivileged),
 * then exercises the exact CE scenario plus sibling syscalls that reach the
 * same ExfatInode::write_at path, with ext2 as a same-kernel control.
 *
 * Level 0: pure black-box public syscalls, no failpoints, no kernel changes.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static int n_bug;

/* One zero-count-positional-write probe.
 * kind: 0 = pwrite64(fd, buf, 0, off)
 *       1 = pwritev with a single zero-length iov (kernel probes write_at(off,0))
 *       2 = lseek(off) + write(fd, buf, 0)  (shared-offset path)
 * Returns 1 if the file was enlarged (bug), 0 otherwise. */
static int probe(const char *tag, const char *path, int kind, off_t off)
{
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return -1; }
    if (write(fd, "AB", 2) != 2) { perror("seed write"); close(fd); return -1; }

    struct stat before, after;
    fstat(fd, &before);

    char buf[1] = {0};
    ssize_t ret;
    errno = 0;
    if (kind == 0) {
        ret = pwrite(fd, buf, 0, off);
    } else if (kind == 1) {
        struct iovec iov = { .iov_base = buf, .iov_len = 0 };
        ret = pwritev(fd, &iov, 1, off);
    } else {
        if (lseek(fd, off, SEEK_SET) < 0) { perror("lseek"); close(fd); return -1; }
        ret = write(fd, buf, 0);
    }
    int err = errno;
    fstat(fd, &after);

    /* Read-back checks: seed bytes intact; range (2, off) visibility. */
    char rd[16];
    memset(rd, 0x5A, sizeof(rd));
    ssize_t r0 = pread(fd, rd, 2, 0);
    int seed_ok = (r0 == 2 && rd[0] == 'A' && rd[1] == 'B');
    ssize_t rhole = pread(fd, rd, sizeof(rd), 2);   /* bytes 2..17 */
    int hole_zeros = 1;
    for (ssize_t i = 0; i < rhole; i++) if (rd[i] != 0) hole_zeros = 0;

    int enlarged = (after.st_size != 2);
    printf("%s: ret=%zd errno=%d size %lld->%lld blocks %lld->%lld seed_ok=%d"
           " hole_read=%zd hole_zeros=%d => %s\n",
           tag, ret, err,
           (long long)before.st_size, (long long)after.st_size,
           (long long)before.st_blocks, (long long)after.st_blocks,
           seed_ok, rhole, hole_zeros,
           enlarged ? "FILE ENLARGED" : "no effect");
    fflush(stdout);
    close(fd);
    return enlarged;
}

static void run_tests(void)
{
    printf("MC7: uid=%d starting zero-count write probes\n", getuid());
    fflush(stdout);

    /* T1: the exact MC scenario on exFAT. */
    int t1 = probe("T1 exfat pwrite64(fd,b,0,4096)", "/exfat/mc7_t1", 0, 4096);
    /* T2: same scenario on ext2 (same-kernel control, has the zero-length guard). */
    int t2 = probe("T2 ext2  pwrite64(fd,b,0,4096)", "/ext2/mc7_t2", 0, 4096);
    /* T3: pwritev with an empty iov list; do_sys_pwritev probes write_at(off,0). */
    int t3 = probe("T3 exfat pwritev empty-iov @8192", "/exfat/mc7_t3", 1, 8192);
    /* T4: lseek beyond EOF + write(fd, buf, 0) on exFAT (shared-offset path). */
    int t4 = probe("T4 exfat lseek+write(0) @16384", "/exfat/mc7_t4", 2, 16384);
    /* T5: zero write exactly at EOF on exFAT: new_size==size, must be a no-op. */
    int t5 = probe("T5 exfat pwrite64(fd,b,0,@EOF)", "/exfat/mc7_t5", 0, 2);
    /* T6: zero write inside the file on exFAT: must be a no-op. */
    int t6 = probe("T6 exfat pwrite64(fd,b,0,1)  ", "/exfat/mc7_t6", 0, 1);

    if (t1 > 0) n_bug++;
    if (t3 > 0) n_bug++;
    if (t4 > 0) n_bug++;
    printf("MC7_SUMMARY t1_exfat=%s t2_ext2=%s t3_pwritev=%s t4_lseek_write=%s"
           " t5_at_eof=%s t6_inside=%s\n",
           t1 > 0 ? "BUG" : "clean", t2 > 0 ? "BUG" : "clean",
           t3 > 0 ? "BUG" : "clean", t4 > 0 ? "BUG" : "clean",
           t5 > 0 ? "BUG" : "clean", t6 > 0 ? "BUG" : "clean");
    printf("MC7_RESULT %s\n", n_bug > 0 ? "REPRODUCED" : "NOT_REPRODUCED");
    fflush(stdout);
}

int main(void)
{
    mkdir("/dev", 0755); mkdir("/proc", 0755); mkdir("/tmp", 0777);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("proc", "/proc", "proc", 0, NULL);
    mkdir("/ext2", 0777); mkdir("/exfat", 0777);
    if (mount("/dev/vda", "/ext2", "ext2", 0, NULL) ||
        mount("/dev/vdb", "/exfat", "exfat", 0, NULL)) {
        perror("mount fixtures");
        printf("SPECULA_BOOT_ERROR\n"); fflush(stdout);
        reboot(RB_POWER_OFF);
        return 1;
    }
    chown("/ext2", 1000, 1000); chown("/exfat", 1000, 1000);
    chmod("/ext2", 0777); chmod("/exfat", 0777);

    pid_t child = fork();
    if (child == 0) {
        if (setgid(1000) || setuid(1000)) _exit(120);
        run_tests();
        _exit(0);
    }
    int status = 0;
    waitpid(child, &status, 0);
    printf("SPECULA_EXIT %d\n", status); fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}

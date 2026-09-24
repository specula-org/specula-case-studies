// SPDX-License-Identifier: MPL-2.0
/*
 * test_bugCR-1 — VmIo no-short-transfer contract vs VMO capacity-clamped success.
 *
 * Hypothesis (from code audit):
 *   Vmo::read clamps the transfer to the page-aligned VMO capacity and returns
 *   Ok(()), violating VmIo's "no short reads / no short writes" contract and
 *   delivering up to `capacity` bytes even when the filesystem layer reports a
 *   smaller count. ramfs and exfat pass the *unclamped* user VmWriter into
 *   page_cache.read() but return a read_len clamped to the logical file size,
 *   so a plain sequential read()/pread64() into a large buffer gets more bytes
 *   written into the user buffer than the returned count accounts for
 *   (over-delivery). ext2 limits the writer first and serves as the control.
 *
 * Oracle (Linux/POSIX behavior): read(2)/pread64(2) transfer exactly `ret`
 * bytes into the buffer; bytes beyond `ret` remain untouched.
 *
 * Runs as PID 1 (mode "init") or as the unprivileged test process
 * (mode "test", uid/gid 1000) inside the Asterinas guest.
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
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define REQ 8192          /* user buffer / request length */
#define PAYLOAD 100       /* file size: deliberately not page-aligned */
#define SENT 0x5A         /* sentinel pre-fill */
#define DONOR_BYTE 0xC3

static int anomalies;

/* Count bytes beyond a read's return value that the kernel overwrote. */
static void scan_tail(const char *tag, const unsigned char *buf, ssize_t ret)
{
    long clobbered = 0, zeros = 0, donor = 0, other = 0;
    long first = -1, last = -1;
    for (long i = (ret > 0 ? ret : 0); i < REQ; i++) {
        unsigned char b = buf[i];
        if (b == SENT)
            continue;
        clobbered++;
        if (b == 0x00) zeros++;
        else if (b == DONOR_BYTE) donor++;
        else other++;
        if (first < 0) first = i;
        last = i;
    }
    printf("CR1|%s|ret=%zd clobbered_beyond_ret=%ld (zeros=%ld donorC3=%ld other=%ld) span=[%ld..%ld]\n",
           tag, ret, clobbered, zeros, donor, other, first, last);
    if (clobbered > 0) {
        printf("CR1|%s|ANOMALY over-delivery: kernel wrote %ld bytes beyond returned count %zd\n",
               tag, clobbered, ret);
        anomalies++;
    } else {
        printf("CR1|%s|clean: buffer beyond returned count untouched\n", tag);
    }
}

/* Verify the [0..ret) region equals the written payload byte. */
static void check_data(const char *tag, const unsigned char *buf, ssize_t ret, unsigned char payload)
{
    long bad = 0;
    for (long i = 0; i < ret; i++)
        if (buf[i] != payload) bad++;
    if (bad) {
        printf("CR1|%s|ANOMALY data mismatch in [0..%zd): %ld bytes wrong\n", tag, ret, bad);
        anomalies++;
    }
}

/* small-file large-request read probe (the core CR-1 trigger). */
static void probe_small_file(const char *dir, const char *fsname, int use_pread)
{
    char path[256];
    snprintf(path, sizeof path, "%s/cr1_small.bin", dir);
    char tag[320];

    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) { printf("CR1|%s|open failed errno=%d\n", fsname, errno); anomalies++; return; }

    unsigned char w[PAYLOAD];
    memset(w, 'A', sizeof w);
    ssize_t wn = pwrite(fd, w, PAYLOAD, 0);
    if (wn != PAYLOAD) {
        printf("CR1|%s|pwrite failed n=%zd errno=%d\n", fsname, wn, errno);
        anomalies++; close(fd); return;
    }

    static unsigned char buf[REQ];

    /* probe 1: read at offset 0 with REQ-byte buffer */
    memset(buf, SENT, REQ);
    ssize_t rn;
    snprintf(tag, sizeof tag, "%s/small/%s@0", fsname, use_pread ? "pread" : "read");
    if (use_pread) {
        rn = pread(fd, buf, REQ, 0);
    } else {
        if (lseek(fd, 0, SEEK_SET) < 0) { printf("CR1|%s|lseek failed\n", tag); }
        rn = read(fd, buf, REQ);
    }
    if (rn < 0) { printf("CR1|%s|read failed errno=%d\n", tag, errno); anomalies++; close(fd); return; }
    if (rn != PAYLOAD)
        printf("CR1|%s|NOTE unexpected ret=%zd (expected %d)\n", tag, rn, PAYLOAD);
    check_data(tag, buf, rn, 'A');
    scan_tail(tag, buf, rn);

    /* probe 2: read at EOF -> expect ret==0 and no bytes written at all */
    memset(buf, SENT, REQ);
    snprintf(tag, sizeof tag, "%s/small/pread@eof4096", fsname);
    rn = pread(fd, buf, REQ, 4096);
    if (rn < 0) { printf("CR1|%s|pread failed errno=%d\n", tag, errno); anomalies++; }
    else {
        printf("CR1|%s|ret=%zd (EOF read, expected 0)\n", tag, rn);
        scan_tail(tag, buf, rn);
    }

    close(fd);
    unlink(path);
}

/* empty file (zero VMO capacity) probe: documents the zero-capacity branch. */
static void probe_empty_file(const char *dir, const char *fsname)
{
    char path[256], tag[320];
    snprintf(path, sizeof path, "%s/cr1_empty.bin", dir);
    snprintf(tag, sizeof tag, "%s/empty/pread@0", fsname);

    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) { printf("CR1|%s|open failed errno=%d\n", tag, errno); anomalies++; return; }

    static unsigned char buf[REQ];
    memset(buf, SENT, REQ);
    ssize_t rn = pread(fd, buf, REQ, 0);
    if (rn < 0) { printf("CR1|%s|pread failed errno=%d\n", tag, errno); anomalies++; }
    else {
        printf("CR1|%s|ret=%zd (empty file, expected 0)\n", tag, rn);
        scan_tail(tag, buf, rn);
    }
    close(fd);
    unlink(path);
}

/*
 * exfat informational probe: over-delivered tail bytes come from a full-page
 * backend read with no [size..capacity) zeroing. A donor file patterns the
 * disk, is deleted, and a victim file reuses its cluster. We classify what
 * actually lands in the over-delivered region (zeros vs stale donor bytes).
 */
static void probe_exfat_stale(const char *dir)
{
    char path[256];
    snprintf(path, sizeof path, "%s/cr1_donor.bin", dir);
    int d = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (d < 0) { printf("CR1|exfat/donor|open failed errno=%d\n", errno); return; }
    static unsigned char pat[16384];
    memset(pat, DONOR_BYTE, sizeof pat);
    ssize_t wn = pwrite(d, pat, sizeof pat, 0);
    if (wn != (ssize_t)sizeof pat)
        printf("CR1|exfat/donor|pwrite n=%zd errno=%d\n", wn, errno);
    fsync(d);
    close(d);
    if (unlink(path) < 0)
        printf("CR1|exfat/donor|unlink failed errno=%d\n", errno);

    snprintf(path, sizeof path, "%s/cr1_victim.bin", dir);
    int v = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (v < 0) { printf("CR1|exfat/victim|open failed errno=%d\n", errno); return; }
    unsigned char w[PAYLOAD];
    memset(w, 'B', sizeof w);
    wn = pwrite(v, w, PAYLOAD, 0);
    if (wn != PAYLOAD)
        printf("CR1|exfat/victim|pwrite n=%zd errno=%d\n", wn, errno);

    static unsigned char buf[REQ];
    memset(buf, SENT, REQ);
    ssize_t rn = pread(v, buf, REQ, 0);
    if (rn < 0) { printf("CR1|exfat/victim|pread failed errno=%d\n", errno); anomalies++; }
    else {
        check_data("exfat/victim/pread@0", buf, rn, 'B');
        scan_tail("exfat/victim/pread@0", buf, rn);
    }
    close(v);
    unlink(path);
}

static int run_tests(void)
{
    printf("CR1|begin|pid=%d uid=%d\n", getpid(), getuid());

    /* ramfs: pread64 path and shared-offset read() path */
    probe_small_file("/ramfs", "ramfs", 1);
    probe_small_file("/ramfs", "ramfs", 0);
    probe_empty_file("/ramfs", "ramfs");

    /* ext2: control backend (limits the writer before page_cache.read) */
    probe_small_file("/ext2", "ext2", 1);
    probe_empty_file("/ext2", "ext2");

    /* exfat: over-delivery from a backend page cache */
    probe_small_file("/exfat", "exfat", 1);
    probe_empty_file("/exfat", "exfat");
    probe_exfat_stale("/exfat");

    printf("CR1|end|anomalies=%d\n", anomalies);
    return anomalies;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "test") == 0) {
        int n = run_tests();
        fflush(stdout);
        return n ? 42 : 0;
    }

    /* PID 1: set up mounts, then run the test as uid/gid 1000. */
    mkdir("/dev", 0755); mkdir("/proc", 0755); mkdir("/tmp", 0777);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("proc", "/proc", "proc", 0, NULL);
    mkdir("/ramfs", 0777); mkdir("/ext2", 0777); mkdir("/exfat", 0777);
    if (mount("/dev/vda", "/ext2", "ext2", 0, NULL))
        perror("mount ext2");
    if (mount("/dev/vdb", "/exfat", "exfat", 0, NULL))
        perror("mount exfat");
    chown("/ramfs", 1000, 1000); chown("/ext2", 1000, 1000); chown("/exfat", 1000, 1000);
    chmod("/ramfs", 0777); chmod("/ext2", 0777); chmod("/exfat", 0777);

    pid_t child = fork();
    if (child == 0) {
        if (setgid(1000) || setuid(1000)) _exit(120);
        execl("/init", "/init", "test", NULL);
        perror("exec");
        _exit(121);
    }
    int status = 0;
    waitpid(child, &status, 0);
    printf("CR1_DONE child_status=%d\n", status);
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}

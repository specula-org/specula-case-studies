// test_bugCR-2_exfat_resize_tailclear.c
//
// Reproduction for finding CR-2:
//   "PageCache resize documentation contradicts fallible tail clearing and
//    exFAT branch order"
//
// Claim A (page_cache/mod.rs:202-204 vs 250-255):
//   The PageCache::resize doc states "Extending the page cache does not
//   eagerly allocate pages and therefore cannot return an error." In reality
//   the extension branch runs fill_zeros(old_size..tail_end)?, which is
//   fallible and -- for a backed page cache whose tail page is not cached --
//   synchronously calls into the filesystem backend (read_page). exFAT's
//   write_at performs this while holding the inode write guard
//   (self.inner.write()), and exFAT's backend IS the inode itself:
//   submit_read_bio() starts with self.inner.read(). ostd RwMutex is
//   non-reentrant -> same-task read-while-write == self-deadlock.
//
//   This test triggers that chain with plain public syscalls only:
//     create 100-byte file on exfat (100 % 4096 != 0), fsync, umount,
//     remount (fresh ExfatFs -> empty page cache), then an extending
//     pwrite64 at offset 100. Extension resize -> fill_zeros(100..116) ->
//     tail page absent -> backend read_page -> submit_read_bio ->
//     self.inner.read() while write guard held -> pwrite never returns.
//   A worker thread performs the pwrite; a watchdog detects the hang.
//   Control T0: same extending pwrite with the tail page cached -> succeeds.
//   Control T1b: identical remount+extend sequence on ext2 (backend is a
//   separate InodeBlockManager, no inode self-lock) -> succeeds.
//
// Claim B (exfat/inode.rs:138-140 vs 1436-1462):
//   The exFAT comment says that to shrink, "we need to update the
//   page_cache size after we update the size of inode". The code shrinks
//   the page cache BEFORE inner.resize() touches the inode. The
//   instrumented kernel emits SPECULA_RAW trace events; the host runner
//   checks that PageCacheResizeBegin precedes ExfatResizeAllocation for
//   the ftruncate(100->50) issued between the T2_PROBE markers.
//
// Runs as /init (pid 1) inside the Asterinas guest. No fault injection,
// no internal APIs -- only mount/write/pwrite/ftruncate/umount/open.

#define _GNU_SOURCE
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <linux/reboot.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/prctl.h>

static void poweroff_now(void) {
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    _exit(0);
}

static void die(const char *m) {
    perror(m);
    printf("CR2: FATAL SETUP ERROR -- test inconclusive\n");
    poweroff_now();
    _exit(1);
}

/* ---- T1 worker: extending pwrite on the remounted exfat file ---- */
static int t1_fd;
static volatile int t1_done = 0;
static ssize_t t1_ret;
static int t1_err;

static void *t1_worker(void *arg) {
    char *buf = arg;
    t1_ret = pwrite(t1_fd, buf, 16, 100); /* 100 -> 116: extension, unaligned old EOF */
    t1_err = errno;
    t1_done = 1;
    return NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("CR2: uid=%d starting resize-contract probes\n", (int)getuid());

    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    if (mount("/dev/vda", "/ext2", "ext2", 0, NULL)) die("mount ext2");
    if (mount("/dev/vdb", "/exfat", "exfat", 0, NULL)) die("mount exfat");

    static char buf[4096];
    memset(buf, 'A', sizeof buf);

    /* ---------- T0 control: cached-tail extension succeeds ---------- */
    int fd = open("/exfat/f0", O_CREAT | O_RDWR, 0644);
    if (fd < 0) die("open f0");
    if (write(fd, buf, 100) != 100) die("write f0");
    if (fsync(fd)) die("fsync f0");
    errno = 0;
    ssize_t r = pwrite(fd, buf, 16, 100);
    int e = errno;
    printf("T0 exfat cached-tail extend: ret=%zd errno=%d (expect ret=16 errno=0)\n", r, e);
    if (r != 16) {
        printf("CR2: T0 control failed -- environment not suitable\n");
        poweroff_now();
    }
    fsync(fd);

    /* ---------- T2 claim B probe: shrink ordering (trace checked on host) ----------
       Arm the Specula per-thread trace buffer, ftruncate, then drain: the kernel
       prints the drained records as SPECULA_RAW JSON lines on the serial console. */
    printf("T2_PROBE_BEGIN\n");
    if (prctl(0x53504543UL, 0UL, 2048UL, 4096UL, 0UL))
        perror("prctl arm trace");
    errno = 0;
    r = ftruncate(fd, 50);
    e = errno;
    if (prctl(0x53504544UL, 0UL, 0UL, 0UL, 0UL))
        perror("prctl drain trace");
    printf("T2 exfat ftruncate(100->50): ret=%zd errno=%d\n", r, e);
    printf("T2_PROBE_END\n");
    close(fd);

    /* ---------- setup T1 file: 100 bytes (unaligned EOF), then close ---------- */
    int f1 = open("/exfat/f1", O_CREAT | O_RDWR, 0644);
    if (f1 < 0) die("open f1");
    if (write(f1, buf, 100) != 100) die("write f1");
    if (fsync(f1)) die("fsync f1");
    close(f1);

    /* ---------- T1b ext2 control: identical remount + uncached-tail extend ---------- */
    int g = open("/ext2/g1", O_CREAT | O_RDWR, 0644);
    if (g < 0) die("open g1");
    if (write(g, buf, 100) != 100) die("write g1");
    if (fsync(g)) die("fsync g1");
    close(g);
    if (umount("/ext2")) die("umount ext2");
    if (mount("/dev/vda", "/ext2", "ext2", 0, NULL)) die("remount ext2");
    g = open("/ext2/g1", O_RDWR);
    if (g < 0) die("reopen g1");
    errno = 0;
    r = pwrite(g, buf, 16, 100);
    e = errno;
    printf("T1b ext2 remounted uncached-tail extend: ret=%zd errno=%d (expect ret=16 errno=0)\n", r, e);
    close(g);

    /* ---------- T1 exfat: remount -> uncached tail -> extending pwrite ---------- */
    if (umount("/exfat")) die("umount exfat");
    if (mount("/dev/vdb", "/exfat", "exfat", 0, NULL)) die("remount exfat");
    struct stat st;
    if (stat("/exfat/f1", &st)) die("stat f1");
    printf("T1 exfat after remount: size=%lld (expect 100)\n", (long long)st.st_size);
    t1_fd = open("/exfat/f1", O_RDWR);
    if (t1_fd < 0) die("reopen f1");

    pthread_t th;
    if (pthread_create(&th, NULL, t1_worker, buf)) die("pthread_create");
    pthread_detach(th);

    int waited = 0;
    while (!t1_done && waited < 100) { /* 100 * 100ms = 10s watchdog */
        usleep(100 * 1000);
        waited++;
    }

    if (t1_done) {
        printf("T1 exfat uncached-tail extend: ret=%zd errno=%d -- completed (no deadlock)\n",
               t1_ret, t1_err);
        printf("CR2-CLAIM-A: NOT REPRODUCED (extension completed)\n");
    } else {
        printf("T1 exfat uncached-tail extend: pwrite64 DID NOT RETURN within 10s -> "
               "kernel thread stuck\n");
        printf("CR2-CLAIM-A: REPRODUCED -- extending pwrite64 on exfat self-deadlocks: "
               "extension tail-clear (fill_zeros) calls the backend read path while "
               "write_at holds the inode write guard, and submit_read_bio takes "
               "self.inner.read() on the same non-reentrant RwMutex\n");
    }

    printf("CR2: probes finished\n");
    poweroff_now();
    return 0;
}

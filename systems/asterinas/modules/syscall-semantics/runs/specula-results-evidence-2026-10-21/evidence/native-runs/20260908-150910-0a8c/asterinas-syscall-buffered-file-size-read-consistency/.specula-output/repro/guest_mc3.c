/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Reproduction guest for MC-3: ExFAT stale write preparation permits false
 * success and inconsistent extents.
 *
 * Counterexample MC_hunt_s2_exfat_extent_bfs1.out instantiated with
 * PAGE_SIZE = 4096 on a 4096-byte seeded exFAT file:
 *   t1 (higher extender): pwrite64(fd, 'B', 4096, 8192)  -> prepares C=12288
 *   t0 (lower extender):  pwrite64(fd, 'A', 4096, 4096)  -> prepares C=8192 (LOWERS C)
 *   t0 copies 4096 bytes, publishes L=8192, returns 4096
 *   t1 copies at 8192 with C=8192 -> Vmo::write clamps to 0 bytes (vmo/mod.rs:571),
 *      publishes stale L=12288 (exfat/inode.rs write_at), returns 4096.
 *   Settled: L=12288 > C=8192 (SettledReadableExtent violated).
 *
 * Native observable consequences (real consumer: userspace pread64/pwrite64
 * return values, kernel/core/src/syscall/pread64.rs:33-41):
 *   CHECK1  settled st_size == 8192 while t1 already returned success for
 *           extent 12288: the file size regressed below a completed write
 *           (the CE's other completion order).
 *   CHECK3  post-settle pread of the in-EOF hole [8192,12288) returns 4096
 *           while delivering 0 bytes (0x55 sentinel survives): read_at counts
 *           from L but Vmo::read clamps to C. A correct kernel returns zeros.
 *   CHECK4  a third, non-racing pwrite64 at 8192 again returns 4096 while
 *           delivering 0 bytes (L already 12288 -> no resize -> C stays 8192),
 *           and the range still reads back as untouched sentinel: the bad
 *           state is permanent, not transient.
 *
 * Modes (compile-time -DMC3_MODE):
 *   L1  Level 1 timing assistance only: unpatched kernel, CPU pinning + TSC
 *       rendezvous + swept userspace entry delay, MC3_L1_TRIALS trials.
 *   L3  Level 3 minimal code modification: t1 arms the prctl hook
 *       (PRCTL_SPECULA_MC3) so the patched kernel busy-waits inside write_at
 *       right after ExfatWriteAtReleasePreparation (the exact CE window,
 *       states 8-11); t0 enters 5 ms later and completes inside the window.
 *       Lands the CE's exact order: t0 copy+publish before t1 copy+publish.
 *   L3R Same hook, both writers armed with different stalls so t1 copies
 *       after t0's prepare but publishes before t0: the regression order.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>
#include <x86intrin.h>

#ifndef MC3_MODE
#define MC3_MODE 1
#endif

#define PRCTL_SPECULA_MC3 0x53504551

#define SEED_SIZE 4096
#define T0_OFF    4096
#define T1_OFF    8192
#define WRITE_LEN 4096
#define SENTINEL  0x55

#ifndef MC3_L1_TRIALS
#define MC3_L1_TRIALS 500
#endif

/* Busy-wait iterations armed through prctl (kernel-side spin). */
#define T1_STALL_ITERS 50000000UL   /* ~50-100 ms: t1 parked across t0's whole write */
#define T0_STALL_ITERS 100000000UL  /* L3R: t0 parked until after t1 publishes */

static void die(const char *msg)
{
    perror(msg);
    fflush(stdout);
    _exit(111);
}

static int hook_arm(unsigned long iters)
{
    return prctl(PRCTL_SPECULA_MC3, 1UL, iters, 0UL, 0UL);
}

static void hook_disarm(void)
{
    (void)prctl(PRCTL_SPECULA_MC3, 0UL, 0UL, 0UL, 0UL);
}

struct attempt {
    int fd;
    unsigned long stall;
    ssize_t result;
    int error;
};

static pthread_barrier_t start_bar;

static void *t1_worker(void *arg)
{
    struct attempt *a = arg;
    unsigned char buf[WRITE_LEN];
    memset(buf, 'B', sizeof(buf));
    cpu_set_t cpu;
    CPU_ZERO(&cpu);
    CPU_SET(1, &cpu);
    if (sched_setaffinity(0, sizeof(cpu), &cpu))
        die("affinity t1");
    if (a->stall && hook_arm(a->stall))
        die("hook arm t1 (patched kernel required)");
    pthread_barrier_wait(&start_bar);
    errno = 0;
    a->result = pwrite(a->fd, buf, WRITE_LEN, T1_OFF);
    a->error = errno;
    if (a->stall)
        hook_disarm();
    return NULL;
}

static int new_subject(int *fd_out)
{
    unlink("/exfat/mc3_subject");
    int fd = open("/exfat/mc3_subject", O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0)
        die("open subject");
    unsigned char seed[SEED_SIZE];
    memset(seed, 'S', sizeof(seed));
    if (pwrite(fd, seed, SEED_SIZE, 0) != SEED_SIZE)
        die("seed pwrite");
    if (fsync(fd))
        die("fsync");
    *fd_out = fd;
    return 0;
}

/* Full post-settle inspection. Returns nonzero iff a bug signature fired. */
static int inspect(int fd, int level, int trial, ssize_t r0, int e0,
                   ssize_t r1, int e1)
{
    struct stat st;
    if (fstat(fd, &st))
        die("fstat");

    unsigned char rbuf[WRITE_LEN];
    memset(rbuf, SENTINEL, sizeof(rbuf));
    errno = 0;
    ssize_t rr = pread(fd, rbuf, WRITE_LEN, T1_OFF);
    int re = errno;
    long changed = 0;
    for (long i = 0; i < WRITE_LEN; i++)
        if (rbuf[i] != SENTINEL)
            changed++;

    /* CHECK4: third, non-racing write into the stale extent. */
    unsigned char buf3[WRITE_LEN];
    memset(buf3, 'C', sizeof(buf3));
    errno = 0;
    ssize_t r3 = pwrite(fd, buf3, WRITE_LEN, T1_OFF);
    int e3 = errno;
    unsigned char rbuf3[WRITE_LEN];
    memset(rbuf3, SENTINEL, sizeof(rbuf3));
    errno = 0;
    ssize_t rr3 = pread(fd, rbuf3, WRITE_LEN, T1_OFF);
    int re3 = errno;
    long changed3 = 0;
    for (long i = 0; i < WRITE_LEN; i++)
        if (rbuf3[i] != SENTINEL)
            changed3++;
    struct stat st4;
    if (fstat(fd, &st4))
        die("fstat4");

    int check1 = (r1 == WRITE_LEN && st.st_size == T0_OFF + WRITE_LEN);
    int check3 = (rr == WRITE_LEN && changed == 0 && st.st_size >= T1_OFF + WRITE_LEN);
    int check4 = (r3 == WRITE_LEN && rr3 == WRITE_LEN && changed3 == 0);

    printf("MC3_RESULT {\"level\":%d,\"trial\":%d,\"t0_ret\":%zd,\"t0_errno\":%d,"
           "\"t1_ret\":%zd,\"t1_errno\":%d,\"size_after\":%ld,"
           "\"read_ret\":%zd,\"read_errno\":%d,\"read_bytes_changed\":%ld,"
           "\"w3_ret\":%zd,\"w3_errno\":%d,\"r3_ret\":%zd,\"r3_errno\":%d,"
           "\"r3_changed\":%ld,\"size_final\":%ld,"
           "\"CHECK1_size_regressed_below_completed_write\":%d,"
           "\"CHECK3_read_overreport_sentinel_survives\":%d,"
           "\"CHECK4_persistent_false_success\":%d}\n",
           level, trial, r0, e0, r1, e1, (long)st.st_size, rr, re, changed,
           r3, e3, rr3, re3, changed3, (long)st4.st_size, check1, check3, check4);
    fflush(stdout);
    return check1 || check3 || check4;
}

/* One race attempt. t0_entry_spin = userspace pause iterations before t0's
 * pwrite (L1 sweep); t0_stall/t1_stall = kernel hook iterations (L3/L3R). */
static int race_once(int level, int trial, unsigned long t0_entry_spin,
                     unsigned long t0_stall, unsigned long t1_stall)
{
    int fd;
    new_subject(&fd);
    struct attempt a1 = {.fd = fd, .stall = t1_stall, .result = -1, .error = 0};
    atomic_thread_fence(memory_order_seq_cst);
    pthread_barrier_init(&start_bar, NULL, 2);
    pthread_t th;
    if (pthread_create(&th, NULL, t1_worker, &a1))
        die("pthread_create");

    cpu_set_t cpu;
    CPU_ZERO(&cpu);
    CPU_SET(0, &cpu);
    if (sched_setaffinity(0, sizeof(cpu), &cpu))
        die("affinity t0");
    if (t0_stall && hook_arm(t0_stall))
        die("hook arm t0 (patched kernel required)");

    pthread_barrier_wait(&start_bar);
    for (volatile unsigned long i = 0; i < t0_entry_spin; i++)
        _mm_pause();
    if (level >= 3) {
        /* t0 must enter after t1's prepare (so t0 lowers C) and, for L3,
         * inside t1's parked window. */
        struct timespec ts = {.tv_sec = 0,
                              .tv_nsec = t0_stall ? 2000000 : 5000000};
        nanosleep(&ts, NULL);
    }
    unsigned char buf0[WRITE_LEN];
    memset(buf0, 'A', sizeof(buf0));
    errno = 0;
    ssize_t r0 = pwrite(fd, buf0, WRITE_LEN, T0_OFF);
    int e0 = errno;
    if (t0_stall)
        hook_disarm();

    if (pthread_join(th, NULL))
        die("join");
    pthread_barrier_destroy(&start_bar);

    int bug = inspect(fd, level, trial, r0, e0, a1.result, a1.error);
    close(fd);
    return bug;
}

int main(void)
{
    mkdir("/dev", 0755);
    mkdir("/proc", 0755);
    mkdir("/exfat", 0777);
    /* devtmpfs may be absent; Asterinas populates /dev itself (as does the
     * harness init, which ignores these two mounts' results). */
    (void)mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    (void)mount("proc", "/proc", "proc", 0, NULL);
    if (mount("/dev/vda", "/exfat", "exfat", 0, NULL))
        die("mount exfat");

#if MC3_MODE == 1
    printf("MC3_BEGIN mode=L1 timing-only trials=%d (unpatched kernel)\n", MC3_L1_TRIALS);
    fflush(stdout);
    for (int t = 0; t < MC3_L1_TRIALS; t++) {
        /* Sweep t0's entry delay: 0..~12.5k pause iterations. */
        unsigned long spin = (unsigned long)t * 25;
        if (race_once(1, t, spin, 0, 0)) {
            printf("MC3_VERDICT L1 BUG_TRIGGERED trial=%d\n", t);
            fflush(stdout);
            sync();
            reboot(RB_POWER_OFF);
            return 42;
        }
    }
    printf("MC3_VERDICT L1 not_triggered trials=%d\n", MC3_L1_TRIALS);
#elif MC3_MODE == 3
    printf("MC3_BEGIN mode=L3 kernel-delay hook (CE order: t0 completes first)\n");
    fflush(stdout);
    int bug = race_once(3, 0, 0, 0, T1_STALL_ITERS);
    printf("MC3_VERDICT L3 %s\n", bug ? "BUG_TRIGGERED" : "not_triggered");
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return bug ? 42 : 0;
#elif MC3_MODE == 4
    printf("MC3_BEGIN mode=L3R kernel-delay hook (regression order)\n");
    fflush(stdout);
    int bug = race_once(3, 0, 0, T0_STALL_ITERS, T1_STALL_ITERS);
    printf("MC3_VERDICT L3R %s\n", bug ? "BUG_TRIGGERED" : "not_triggered");
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return bug ? 42 : 0;
#endif

    sync();
    reboot(RB_POWER_OFF);
    return 0;
}

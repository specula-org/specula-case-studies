/*
 * MC-4 reproduction: vectored I/O (readv/writev) is not atomic against a
 * shared-offset competitor.
 *
 * Mechanism (matches counterexample MC_hunt_s3_vector_linearization):
 * do_sys_readv/do_sys_writev dispatch ONE scalar file op per iovec
 * (kernel/core/src/syscall/preadv.rs:159 / pwritev.rs:155); each scalar op
 * independently acquires and releases the shared open-description offset
 * mutex (kernel/core/src/fs/file/inode_handle.rs:292 / :346). A competing
 * shared-offset write can therefore commit BETWEEN the vector entries.
 * CE commit order: Readv@0 (iov 1), Write@2, Readv@4 (iov 2) -- no serial
 * order of the two syscalls produces it. Linux holds f_pos_lock across the
 * whole vector op, so the BUG signature must never fire there (control).
 *
 * Test: two threads share ONE open description (fd + dup(fd)).
 *  - A: readv(fd, {entry1[L], entry2[8]})  /  writev(fd, {D[L], ZZ[8]})
 *  - B: write(fd2, "XYXYXYXY", 8) after a rotating delay.
 * All file words are pat64(k) = splitmix64(k). NW = L/8. Classification:
 *  readv: e1w0==pat64(1)                    -> serialB (B committed at 0)
 *         e1w0==pat64(0) && e2==pat64(NW)   -> serialA (B after the vector)
 *         e1w0==pat64(0) && e2==pat64(NW+1)
 *               && pread word NW == XY      -> BUG (B committed between
 *                                             the entries at offset L)
 *  writev: head==XY                         -> serialB (B at 0)
 *          head==pat64(0) && word NW==ZZ    -> serialA (B at/after NW+1)
 *          head==pat64(0) && word NW==XY
 *               && word NW+1==ZZ            -> BUG (XY at NW, ZZ at NW+1)
 *
 * Escalation: Level 0 (2-byte entries, 150k rounds, no delay grid) and a
 * first Level-1 variant (fixed tick grid, 64 KiB entry) ran in earlier
 * sessions of this same finding (Level 0: no trigger; the fixed-tick Level-1
 * variant triggered both cases in one worktree and missed in 4000 rounds in
 * another -- fixed tick units do not track the actual entry-1 duration).
 * This variant stays Level 1 (timing assistance ONLY: public syscalls,
 * stock kernel logic, no source modification): entry-1 is enlarged so its
 * lock-held page-cache copy is long, and B's delay sweeps a grid calibrated
 * against the MEASURED entry-1 duration (clock_gettime around a serial
 * readv), so grid points land inside entry-1's critical section -- putting
 * B on the offset mutex exactly at entry-1's release, i.e. in the
 * between-entries boundary.
 *
 * Usage: specula_repro_mc4 [rounds_per_geometry]   (default 6000)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#define PATH "/tmp/mc4race.bin"
#define WORD 8
#define XY8 0x5859585958595859ULL /* "XYXYXYXY" */
#define ZZ8 0x5A5A5A5A5A5A5A5AULL /* "ZZZZZZZZ" */
#define GEOM_COUNT 2
static const size_t geoms[GEOM_COUNT] = { 64 * 1024, 512 * 1024 };
#define GRID 256
#define ROUND_TIMEOUT_POLLS 30000 /* x100us = 3s without progress -> abort */

static int fd = -1, fd2 = -1;
static unsigned rounds_max = 6000;

/* geometry (read-only for workers between rounds) */
static size_t g_L;
static uint32_t g_NW;
static volatile int g_case; /* 0 = readv race, 1 = writev race */
static uint8_t *buf_e1; /* A: entry-1 / D-block buffer (g_L bytes) */
static uint8_t buf_e2[WORD]; /* A: entry-2 (readv) */
static const uint64_t zz_word = ZZ8;

/* rendezvous */
static volatile unsigned go_gen;
static volatile long done_cnt;
static pthread_barrier_t round_barrier;
static uint64_t shared_delay_ns;
static volatile long a_ret, b_ret;
static volatile int a_err, b_err;

static uint64_t pat64(uint64_t k)
{
    uint64_t z = k + 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

static void out(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        ssize_t w = write(1, buf, (size_t)n);
        (void)w;
    }
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void spin_until(uint64_t deadline_ns)
{
    while (now_ns() < deadline_ns)
        __asm__ volatile("pause");
}

static void *thread_vector(void *unused)
{
    (void)unused;
    unsigned seen = 0;
    for (;;) {
        while (__atomic_load_n(&go_gen, __ATOMIC_ACQUIRE) == seen)
            __asm__ volatile("pause");
        seen = __atomic_load_n(&go_gen, __ATOMIC_RELAXED);
        if (seen == 0xFFFFFFFFu)
            return NULL;
        pthread_barrier_wait(&round_barrier);
        long r;
        if (__atomic_load_n(&g_case, __ATOMIC_RELAXED) == 0) {
            struct iovec iov[2] = { { buf_e1, g_L }, { buf_e2, WORD } };
            r = readv(fd, iov, 2);
        } else {
            struct iovec iov[2] = { { buf_e1, g_L }, { (void *)&zz_word, WORD } };
            r = writev(fd, iov, 2);
        }
        a_ret = r;
        a_err = (r < 0) ? errno : 0;
        __atomic_fetch_add(&done_cnt, 1, __ATOMIC_RELEASE);
    }
}

static void *thread_scalar(void *unused)
{
    (void)unused;
    uint64_t xy = XY8;
    unsigned seen = 0;
    for (;;) {
        while (__atomic_load_n(&go_gen, __ATOMIC_ACQUIRE) == seen)
            __asm__ volatile("pause");
        seen = __atomic_load_n(&go_gen, __ATOMIC_RELAXED);
        if (seen == 0xFFFFFFFFu)
            return NULL;
        pthread_barrier_wait(&round_barrier);
        uint64_t dl = shared_delay_ns; /* set by main before the release */
        spin_until(now_ns() + dl);
        long r = write(fd2, &xy, WORD);
        b_ret = r;
        b_err = (r < 0) ? errno : 0;
        __atomic_fetch_add(&done_cnt, 1, __ATOMIC_RELEASE);
    }
}

/* ---- file helpers (main thread only) ---- */

static int pread_word(uint64_t *w, off_t off)
{
    return (int)pread(fd, w, WORD, off);
}

/* readv case: file is (NW+2) words of pat64. B damages word 0, NW or NW+1. */
static void reset_readv_file(void)
{
    uint64_t w;
    for (off_t k = 0; k <= (off_t)g_NW + 1; k += (k == 0 ? (off_t)g_NW : 1)) {
        w = pat64((uint64_t)k);
        if (pwrite(fd, &w, WORD, k * WORD) != WORD) {
            out("MC4_ERROR where=reset_readv err=%d\n", errno);
            exit(1);
        }
    }
    if (lseek(fd, 0, SEEK_SET) == (off_t)-1) {
        out("MC4_ERROR where=reset_lseek err=%d\n", errno);
        exit(1);
    }
}

/* writev case: no truncate needed; A+B rewrite exactly words [0, NW+1]
 * every round, nothing ever extends past (NW+2)*WORD bytes. */
static void reset_writev_file(void)
{
    if (lseek(fd, 0, SEEK_SET) == (off_t)-1) {
        out("MC4_ERROR where=reset_lseek err=%d\n", errno);
        exit(1);
    }
}

/* full verify that entry 1 (readv) / D-block (writev) matches pat64 */
static int verify_e1_pattern(void)
{
    uint64_t *words = (uint64_t *)buf_e1;
    for (uint32_t k = 0; k < g_NW; k++)
        if (words[k] != pat64(k))
            return 0;
    return 1;
}

static int verify_d_block_on_disk(void)
{
    for (uint32_t k = 0; k < g_NW; k++) {
        uint64_t w;
        if (pread(fd, &w, WORD, (off_t)k * WORD) != WORD || w != pat64(k))
            return 0;
    }
    return 1;
}

/* ---- one race case over one geometry ----
 * Returns 1 if the BUG signature fired. */
static int run_case(int is_writev, size_t L, uint64_t *t_e1_ns_out)
{
    g_L = L;
    g_NW = (uint32_t)(L / WORD);
    __atomic_store_n(&g_case, is_writev, __ATOMIC_RELEASE);
    memset(buf_e2, 0, WORD);

    /* fresh file */
    if (ftruncate(fd, 0) < 0) {
        out("MC4_ERROR where=ftruncate err=%d\n", errno);
        exit(1);
    }
    if (!is_writev) {
        for (uint32_t k = 0; k <= g_NW + 1; k++) {
            uint64_t w = pat64(k);
            if (pwrite(fd, &w, WORD, (off_t)k * WORD) != WORD) {
                out("MC4_ERROR where=init_pwrite err=%d\n", errno);
                exit(1);
            }
        }
    } else {
        /* A's D-block content: word k of the block is pat64(k), so the
         * serialA/serialB/BUG layouts are distinguishable by content. */
        for (uint32_t k = 0; k < g_NW; k++)
            ((uint64_t *)buf_e1)[k] = pat64(k);
    }

    /* calibrate: measure a serial full vector op, take the max of 3 */
    uint64_t t_e1 = 0;
    if (!is_writev) {
        struct iovec iov[2] = { { buf_e1, g_L }, { buf_e2, WORD } };
        for (int i = 0; i < 3; i++) {
            reset_readv_file();
            uint64_t t0 = now_ns();
            long r = readv(fd, iov, 2);
            uint64_t t1 = now_ns();
            if (r != (long)(g_L + WORD)) {
                out("MC4_ERROR where=calib_readv ret=%ld err=%d\n", r, errno);
                exit(1);
            }
            if (t1 - t0 > t_e1)
                t_e1 = t1 - t0;
        }
    } else {
        for (int i = 0; i < 3; i++) {
            reset_writev_file();
            uint64_t t0 = now_ns();
            long r = write(fd, buf_e1, g_L);
            uint64_t t1 = now_ns();
            if (r != (long)g_L) {
                out("MC4_ERROR where=calib_write ret=%ld err=%d\n", r, errno);
                exit(1);
            }
            if (t1 - t0 > t_e1)
                t_e1 = t1 - t0;
        }
    }
    if (t_e1 < 20000) /* coarse/broken clock: fall back by geometry */
        t_e1 = (uint64_t)(L / (64 * 1024)) * 150000 + 150000;
    *t_e1_ns_out = t_e1;

    /* serial sanity for this geometry */
    if (!is_writev) {
        reset_readv_file();
        struct iovec iov[2] = { { buf_e1, g_L }, { buf_e2, WORD } };
        long r = readv(fd, iov, 2);
        uint64_t e1w0 = ((uint64_t *)buf_e1)[0];
        uint64_t e2w = ((uint64_t *)buf_e2)[0];
        out("MC4_SANITY case=readv L=%zu ret=%ld e1w0=%016lx e2=%016lx "
            "ok=%d\n", L, r, e1w0, e2w,
            r == (long)(L + WORD) && e1w0 == pat64(0) && e2w == pat64(g_NW));
    } else {
        reset_writev_file();
        struct iovec iov[2] = { { buf_e1, g_L }, { (void *)&zz_word, WORD } };
        long r = writev(fd, iov, 2);
        uint64_t head, tail;
        pread_word(&head, 0);
        pread_word(&tail, (off_t)g_NW * WORD);
        out("MC4_SANITY case=writev L=%zu ret=%ld head=%016lx nw=%016lx "
            "ok=%d\n", L, r, head, tail,
            r == (long)(L + WORD) && head == pat64(0) && tail == ZZ8);
    }

    const char *cname = is_writev ? "write" : "read";
    out("MC4_CASE name=%sv_race L=%zu t_e1_ns=%lu rules='%s'\n", cname, L,
        t_e1, is_writev ?
        "head=XY:serialB head=pat0+NW=ZZ:serialA head=pat0+NW=XY+NW1=ZZ:BUG" :
        "e1w0=pat1:serialB e1w0=pat0+e2=patNW:serialA e1w0=pat0+XY@NW+e2=patNW1:BUG");

    unsigned long serialA = 0, serialB = 0, other = 0;
    int bug = 0;

    for (unsigned rd = 1; rd <= rounds_max && !bug; rd++) {
        if (!is_writev)
            reset_readv_file();
        else
            reset_writev_file();

        /* delay grid: sweep [0, 1.25 * t_e1] over GRID steps */
        shared_delay_ns = (uint64_t)((rd % GRID) * t_e1 / GRID) +
                          (uint64_t)((rd % GRID) * t_e1 / 4 / GRID);
        done_cnt = 0;
        a_ret = b_ret = -2;
        __atomic_store_n(&go_gen, rd, __ATOMIC_RELEASE);

        int polls = 0;
        while (__atomic_load_n(&done_cnt, __ATOMIC_ACQUIRE) < 2) {
            usleep(100);
            if (++polls > ROUND_TIMEOUT_POLLS) {
                out("MC4_ERROR where=round_timeout case=%s round=%u "
                    "a_ret=%ld b_ret=%ld\n", cname, rd, a_ret, b_ret);
                exit(1);
            }
        }
        /* settle: let both threads park on go_gen before the next prep */
        usleep(150);

        long aret = a_ret, bret = b_ret;
        int aerr = a_err, berr = b_err;
        int cls; /* 0 serialA, 1 serialB, 2 BUG, 3 other */
        if (!is_writev) {
            uint64_t e1w0 = ((uint64_t *)buf_e1)[0];
            uint64_t e2w = ((uint64_t *)buf_e2)[0];
            if (aret != (long)(g_L + WORD) || bret != WORD) {
                cls = 3;
                out("MC4_ANOM case=readv round=%u aret=%ld aerr=%d bret=%ld "
                    "berr=%d\n", rd, aret, aerr, bret, berr);
            } else if (e1w0 == pat64(1)) {
                cls = 1;
            } else if (e1w0 == pat64(0) && e2w == pat64(g_NW)) {
                cls = 0;
            } else if (e1w0 == pat64(0) && e2w == pat64(g_NW + 1)) {
                uint64_t nw;
                pread_word(&nw, (off_t)g_NW * WORD);
                if (nw == XY8 && verify_e1_pattern()) {
                    cls = 2;
                    out("MC4_TRIGGER case=readv L=%zu round=%u e1w0=%016lx "
                        "e2=%016lx expect_serialA_e2=%016lx XY_at_NW=1 "
                        "readv_ret=%ld write_ret=%ld delay_ns=%lu\n",
                        g_L, rd, e1w0, e2w, pat64(g_NW), aret, bret,
                        shared_delay_ns);
                    out("MC4_TRIGGER_CONT e1_full_pattern_verified=1\n");
                } else {
                    cls = 3;
                }
            } else {
                cls = 3;
            }
        } else {
            uint64_t head, nw, nw1;
            pread_word(&head, 0);
            pread_word(&nw, (off_t)g_NW * WORD);
            pread_word(&nw1, (off_t)(g_NW + 1) * WORD);
            if (aret != (long)(g_L + WORD) || bret != WORD) {
                cls = 3;
                out("MC4_ANOM case=writev round=%u aret=%ld aerr=%d bret=%ld "
                    "berr=%d\n", rd, aret, aerr, bret, berr);
            } else if (head == XY8) {
                cls = 1;
            } else if (head == pat64(0) && nw == ZZ8) {
                cls = 0; /* B committed at/after word NW+1 */
            } else if (head == pat64(0) && nw == XY8 && nw1 == ZZ8) {
                cls = (verify_d_block_on_disk()) ? 2 : 3;
                if (cls == 2)
                    out("MC4_TRIGGER case=writev L=%zu round=%u head=%016lx "
                        "nw=%016lx nw1=%016lx writev_ret=%ld write_ret=%ld "
                        "delay_ns=%lu\n", g_L, rd, head, nw, nw1, aret, bret,
                        shared_delay_ns);
            } else {
                cls = 3;
            }
        }

        if (cls == 0)
            serialA++;
        else if (cls == 1)
            serialB++;
        else if (cls == 2)
            bug = 1;
        else
            other++;

        if (rd % 1000 == 0)
            out("MC4_PROGRESS case=%sv L=%zu round=%u serialA=%lu serialB=%lu"
                " other=%lu\n", cname, g_L, rd, serialA, serialB, other);
    }

    out("MC4_CASE_RESULT case=%sv L=%zu rounds=%u serialA=%lu serialB=%lu "
        "other=%lu bug=%d\n", cname, g_L, rounds_max, serialA, serialB, other,
        bug);
    return bug;
}

int main(int argc, char **argv)
{
    if (argc > 1)
        rounds_max = (unsigned)strtoul(argv[1], NULL, 0);

    out("MC4_REPRO_VERSION 4 rounds=%u\n", rounds_max);

    size_t maxL = geoms[GEOM_COUNT - 1];
    buf_e1 = malloc(maxL);
    if (!buf_e1) {
        out("MC4_ERROR where=malloc\n");
        return 1;
    }

    fd = open(PATH, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        out("MC4_ERROR where=open err=%d\n", errno);
        return 1;
    }
    fd2 = dup(fd); /* SAME open description -> shared offset */
    if (fd2 < 0) {
        out("MC4_ERROR where=dup err=%d\n", errno);
        return 1;
    }

    if (pthread_barrier_init(&round_barrier, NULL, 2) != 0) {
        out("MC4_ERROR where=barrier_init\n");
        return 1;
    }
    pthread_t ta, tb;
    pthread_create(&ta, NULL, thread_vector, NULL);
    pthread_create(&tb, NULL, thread_scalar, NULL);

    int readv_bug = 0, writev_bug = 0;
    uint64_t t;
    for (int gi = 0; gi < GEOM_COUNT && !readv_bug; gi++)
        readv_bug = run_case(0, geoms[gi], &t);
    for (int gi = 0; gi < GEOM_COUNT && !writev_bug; gi++)
        writev_bug = run_case(1, geoms[gi], &t);

    __atomic_store_n(&go_gen, 0xFFFFFFFFu, __ATOMIC_RELEASE);
    usleep(200000);

    out("MC4_SUMMARY readv=%d writev=%d (1=triggered 0=exhausted -1=error)\n",
        readv_bug, writev_bug);
    out("MC4_REPRO_DONE\n");
    return 0;
}

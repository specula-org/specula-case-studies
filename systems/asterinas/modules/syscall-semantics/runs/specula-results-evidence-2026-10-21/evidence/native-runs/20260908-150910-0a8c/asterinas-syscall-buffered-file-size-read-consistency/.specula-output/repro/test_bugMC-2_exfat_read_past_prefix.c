/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Reproduction for MC-2: ExFAT reads copy beyond their reported prefix
 * during write preparation.
 *
 * Mechanism (kernel/core/src/fs/fs_impls/exfat/inode.rs):
 *   ExfatInode::read_at computes read_len clamped to the logical size, but
 *   passes the caller's UNLIMITED VmWriter to PageCache::read; Vmo::read
 *   copies up to the page cache's own (block-aligned) capacity. An extending
 *   write_at grows size_allocated + page-cache capacity in its preparation
 *   phase and publishes inner.size only after the copy completes, so a
 *   concurrent read copies bytes beyond the logical EOF (zero-filled by the
 *   backend, submit_read_bio -> BioStatus::Zeros) while returning only the
 *   old, smaller read_len. The user buffer past the returned count is
 *   clobbered. read(2) stores at most the returned number of bytes.
 *
 * Part B (Level 0, sequential control): a 2-byte file has a block-aligned
 *   page-cache capacity of 4096; pread across/at EOF must leave bytes past
 *   the return value untouched (Linux behavior). Same missing-limit defect,
 *   deterministic, no concurrency. This is the shape upstream PR
 *   asterinas/asterinas#3778 describes.
 *
 * Part A (Level 1, the MC counterexample schedule): t1 extends
 *   4096 -> 4096+2MiB with one buffered pwrite64; t0 loops pread64(.,8192,0).
 *   A pread that lands in [capacity grown, size published) returns 4096 but
 *   clobbers buf[4096..8192). Sentinel 0xAA must survive past the return.
 *
 * Success criterion (observable): any byte at index >= ret differs from the
 * sentinel the caller placed there. ext2 is run as a negative control
 * (limits its writer and holds the write lock across the copy).
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
#include <sys/stat.h>
#include <unistd.h>
#include <x86intrin.h>

#define SENT 0xAA
#define SEED 'S'
#define WTAG 'B'
#define RBUF_LEN 8192
#define EXT_LEN (2 * 1024 * 1024) /* extension write length: 4096 -> 2101248 */
#define TRIALS 40
#define MAX_ITERS 400000

static atomic_int writer_done;
static atomic_long launch_tsc;

struct worker_arg {
    int fd;
    int cpu;
    long reader_reads;
    long hits;
    long ret4096;
    long ret8192;
    long retother;
    ssize_t writer_ret;
    int writer_err;
    /* first 3 hits, recorded */
    long hit_iter[3];
    long hit_ret[3];
    long hit_clobbered[3];
    long hit_first[3];
    unsigned char hit_bytes[3][8];
};

static void pin_cpu(int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0)
        perror("sched_setaffinity");
}

static void wait_launch(void)
{
    unsigned long launch;
    while (!(launch = atomic_load_explicit(&launch_tsc, memory_order_acquire)))
        _mm_pause();
    while (__rdtsc() < launch)
        _mm_pause();
}

/* Reader: loop pread until the writer finished; flag stores past ret. */
static void *reader_main(void *argp)
{
    struct worker_arg *a = argp;
    unsigned char buf[RBUF_LEN];
    pin_cpu(a->cpu);
    wait_launch();
    long iter = 0;
    while (!atomic_load_explicit(&writer_done, memory_order_acquire) &&
           iter < MAX_ITERS) {
        memset(buf, SENT, sizeof buf);
        errno = 0;
        ssize_t r = pread(a->fd, buf, sizeof buf, 0);
        if (r < 0) {
            a->retother++;
            printf("MC2_A_READ_ERROR iter=%ld errno=%d\n", iter, errno);
            iter++;
            continue;
        }
        a->reader_reads++;
        if (r == 4096) a->ret4096++;
        else if (r == 8192) a->ret8192++;
        else a->retother++;
        long clobbered = 0, first = -1;
        for (long i = r; i < RBUF_LEN; i++) {
            if (buf[i] != SENT) {
                clobbered++;
                if (first < 0) first = i;
            }
        }
        if (clobbered > 0) {
            long h = a->hits++;
            if (h < 3) {
                a->hit_iter[h] = iter;
                a->hit_ret[h] = r;
                a->hit_clobbered[h] = clobbered;
                a->hit_first[h] = first;
                for (int k = 0; k < 8; k++)
                    a->hit_bytes[h][k] = buf[first + k];
            }
        }
        iter++;
    }
    return NULL;
}

/* Writer: one extending buffered pwrite64. */
static void *writer_main(void *argp)
{
    struct worker_arg *a = argp;
    static unsigned char *wbuf;
    pin_cpu(a->cpu);
    wbuf = malloc(EXT_LEN);
    if (!wbuf) { perror("malloc"); atomic_store(&writer_done, 1); return NULL; }
    memset(wbuf, WTAG, EXT_LEN);
    wait_launch();
    errno = 0;
    a->writer_ret = pwrite(a->fd, wbuf, EXT_LEN, 4096);
    a->writer_err = errno;
    atomic_store_explicit(&writer_done, 1, memory_order_release);
    free(wbuf);
    return NULL;
}

static int make_seeded_file(const char *path)
{
    unlink(path);
    int fd = open(path, O_CREAT | O_RDWR, 0644);
    if (fd < 0) { perror("open"); return -1; }
    unsigned char seed[4096];
    memset(seed, SEED, sizeof seed);
    if (write(fd, seed, sizeof seed) != (ssize_t)sizeof seed) {
        perror("seed write");
        close(fd);
        return -1;
    }
    if (fsync(fd) != 0) perror("fsync");
    return fd;
}

/* Part A: the MC counterexample schedule (read vs extending write). */
static long part_a(const char *backend, const char *tag)
{
    long total_hits = 0, total_reads = 0;
    int first_hit_printed = 0;
    for (int t = 0; t < TRIALS; t++) {
        char path[256];
        snprintf(path, sizeof path, "/%s/mc2a_%s_%d", backend, tag, t);
        int fd = make_seeded_file(path);
        if (fd < 0) continue;
        atomic_store(&writer_done, 0);
        atomic_store(&launch_tsc, 0);
        struct worker_arg r = {.fd = fd, .cpu = 0}, w = {.fd = fd, .cpu = 1};
        pthread_t rt, wt;
        if (pthread_create(&rt, NULL, reader_main, &r) ||
            pthread_create(&wt, NULL, writer_main, &w)) {
            perror("pthread_create");
            close(fd);
            continue;
        }
        /* Reader launches first so it is already looping when the writer's
         * preparation grows the page-cache capacity. */
        unsigned long t0 = __rdtsc() + 2000000;
        /* both threads read the same launch var; writer idled on barrier-free
         * launch too, so it starts within a few hundred ns of the reader */
        atomic_store_explicit(&launch_tsc, t0, memory_order_release);
        pthread_join(rt, NULL);
        pthread_join(wt, NULL);
        struct stat st;
        if (fstat(fd, &st) != 0) perror("fstat");
        total_hits += r.hits;
        total_reads += r.reader_reads;
        printf("MC2_A_TRIAL backend=%s t=%d writer_ret=%zd writer_errno=%d "
               "final_size=%ld reads=%ld ret4096=%ld ret8192=%ld retother=%ld hits=%ld\n",
               backend, t, w.writer_ret, w.writer_err, (long)st.st_size,
               r.reader_reads, r.ret4096, r.ret8192, r.retother, r.hits);
        for (int h = 0; h < 3 && h < r.hits; h++) {
            printf("MC2_A_HIT backend=%s t=%d iter=%ld ret=%ld clobbered=%ld "
                   "first=%ld bytes_at_first=%02x %02x %02x %02x %02x %02x %02x %02x\n",
                   backend, t, r.hit_iter[h], r.hit_ret[h], r.hit_clobbered[h],
                   r.hit_first[h],
                   r.hit_bytes[h][0], r.hit_bytes[h][1], r.hit_bytes[h][2],
                   r.hit_bytes[h][3], r.hit_bytes[h][4], r.hit_bytes[h][5],
                   r.hit_bytes[h][6], r.hit_bytes[h][7]);
            first_hit_printed = 1;
        }
        close(fd);
        unlink(path);
    }
    printf("MC2_A_SUMMARY backend=%s trials=%d reads=%ld hits=%ld\n",
           backend, TRIALS, total_reads, total_hits);
    (void)first_hit_printed;
    return total_hits;
}

/* One Part B check: fill buffer with sentinel, do one read op, count stores
 * past the returned count. */
static void part_b_check(int fd, const char *backend, const char *how,
                         off_t off, int positional)
{
    static unsigned char buf[RBUF_LEN];
    memset(buf, SENT, sizeof buf);
    errno = 0;
    ssize_t r;
    if (positional)
        r = pread(fd, buf, sizeof buf, off);
    else {
        if (lseek(fd, off, SEEK_SET) < 0) { perror("lseek"); return; }
        r = read(fd, buf, sizeof buf);
    }
    if (r < 0) {
        printf("MC2_B backend=%s %s off=%ld ERROR errno=%d\n",
               backend, how, (long)off, errno);
        return;
    }
    long clobbered = 0, first = -1;
    for (long i = r; i < RBUF_LEN; i++) {
        if (buf[i] != SENT) {
            clobbered++;
            if (first < 0) first = i;
        }
    }
    printf("MC2_B backend=%s %s off=%ld ret=%zd clobbered_past_ret=%ld first=%ld %s\n",
           backend, how, (long)off, r, clobbered, first,
           clobbered ? "VULNERABLE" : "clean");
}

static int part_b(const char *backend)
{
    char path[256];
    snprintf(path, sizeof path, "/%s/mc2b", backend);
    unlink(path);
    int fd = open(path, O_CREAT | O_RDWR, 0644);
    if (fd < 0) { perror("open"); return 0; }
    if (write(fd, "hi", 2) != 2) { perror("seed"); close(fd); return 0; }
    if (fsync(fd) != 0) perror("fsync");
    part_b_check(fd, backend, "pread-across-eof", 1, 1);
    part_b_check(fd, backend, "pread-at-eof", 2, 1);
    part_b_check(fd, backend, "read-across-eof", 1, 0);
    close(fd);
    unlink(path);
    return 0;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("MC2_BEGIN exfat-read-past-reported-prefix\n");

    /* Level 0 control: deterministic sequential manifestation. */
    part_b("exfat");
    part_b("ext2");
    part_b("ramfs");

    /* Level 1: the MC counterexample schedule. */
    long hits_exfat = part_a("exfat", "x");
    long hits_ext2 = part_a("ext2", "c"); /* negative control */

    printf("MC2_RESULT exfat_hits=%ld ext2_control_hits=%ld\n",
           hits_exfat, hits_ext2);
    printf("MC2_END %s\n", hits_exfat > 0 ? "BUG_REPRODUCED" : "NOT_OBSERVED");
    return 0;
}

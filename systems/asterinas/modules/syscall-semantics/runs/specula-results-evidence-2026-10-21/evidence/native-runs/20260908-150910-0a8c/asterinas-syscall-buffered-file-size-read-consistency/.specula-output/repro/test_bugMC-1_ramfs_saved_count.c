/* MC-1 reproduction: ramfs read returns a saved count that differs from delivered bytes.
 *
 * Guest program for the Asterinas ramfs backend. Two cooperating threads act on
 * one regular file through the public syscall interface only:
 *
 *   GROW   T0: pread(fd, buf, 8192, 0)   while T1: pwrite(fd, seed, 8192, 2048)
 *          file starts at 4096 B. A win means read returned the size observed
 *          BEFORE the extension (4096) while more bytes (e.g. 8192, including
 *          T1's fresh payload) were actually copied into buf.
 *   SHRINK T0: pread(fd, buf, 8192, 0)   while T1: ftruncate(fd, 0)
 *          file starts at 4096 B. A win means read returned 4096 while ZERO
 *          bytes were delivered into buf (canary untouched).
 *
 * Delivered bytes are measured by pre-filling the destination with a canary and
 * counting non-canary bytes after the call. Return counts, delivered bytes,
 * final file size and shared-offset effects are printed as MC1_REPRO lines.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <x86intrin.h>

#define FILE0 4096          /* initial file size in bytes */
#define REQN  8192          /* read request length */
#define GROW_OFF 2048       /* extending write offset -> new size 10240 */
#define CANARY 0xA5
#define SEEDBYTE 0x53       /* 'S' initial payload */
#define WBYTE 0x42          /* 'B' grow payload */

static unsigned char seed[REQN];
static _Atomic unsigned long launch_tsc;
static _Atomic int grow_hits, shrink_hits;

struct attempt {
    int fd, tid, scenario; /* 0 = grow, 1 = shrink */
    ssize_t result;
    unsigned char buf[REQN + 64] __attribute__((aligned(64)));
};

static void rendezvous(void)
{
    unsigned long launch;
    while (!(launch = atomic_load_explicit(&launch_tsc, memory_order_acquire)))
        _mm_pause();
    while (__rdtsc() < launch)
        _mm_pause();
}

static void *worker(void *arg)
{
    struct attempt *a = arg;
    cpu_set_t cpu;
    CPU_ZERO(&cpu);
    CPU_SET(a->tid, &cpu);
    if (sched_setaffinity(0, sizeof(cpu), &cpu) != 0)
        perror("sched_setaffinity");
    memset(a->buf, CANARY, sizeof(a->buf));
    if (a->tid == 0) {
        rendezvous();
        a->result = pread(a->fd, a->buf, REQN, 0);
    } else {
        rendezvous();
        if (a->scenario == 0)
            a->result = pwrite(a->fd, seed, REQN, GROW_OFF);
        else
            a->result = ftruncate(a->fd, 0) == 0 ? 0 : -1;
    }
    return NULL;
}

static int make_file(const char *path)
{
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) { perror("open"); _exit(2); }
    unsigned char payload[FILE0];
    memset(payload, SEEDBYTE, sizeof(payload));
    if (pwrite(fd, payload, sizeof(payload), 0) != (ssize_t)sizeof(payload)) { perror("seed"); _exit(2); }
    fsync(fd);
    return fd;
}

static int one_trial(int scenario, int trial)
{
    int fd = make_file("/ramfs/mc1subject");
    atomic_store_explicit(&launch_tsc, 0, memory_order_release);
    pthread_t th[2];
    struct attempt a[2] = {
        {.fd = fd, .tid = 0, .scenario = scenario},
        {.fd = fd, .tid = 1, .scenario = scenario},
    };
    pthread_create(&th[0], NULL, worker, &a[0]);
    pthread_create(&th[1], NULL, worker, &a[1]);
    atomic_store_explicit(&launch_tsc, __rdtsc() + 500000, memory_order_release);
    pthread_join(th[0], NULL);
    pthread_join(th[1], NULL);

    long delivered = 0, prefix = 0;
    for (long i = 0; i < REQN; i++)
        if (a[0].buf[i] != CANARY) delivered++;
    while (prefix < REQN && a[0].buf[prefix] != CANARY) prefix++;
    int saw_writer = 0;
    for (long i = 0; i < REQN; i++)
        if (a[0].buf[i] == WBYTE) { saw_writer = 1; break; }
    struct stat st;
    fstat(fd, &st);

    int hit = 0;
    if (scenario == 0) {
        /* GROW: return is the pre-extension EOF (FILE0) but more was delivered */
        hit = (a[0].result > 0 && delivered > a[0].result);
        if (hit) atomic_fetch_add(&grow_hits, 1);
        if (hit || trial < 3)
            printf("MC1_REPRO scenario=grow trial=%d read_ret=%zd write_ret=%zd delivered=%ld prefix=%ld saw_writer_data=%d final_size=%ld hit=%d\n",
                   trial, a[0].result, a[1].result, delivered, prefix, saw_writer, (long)st.st_size, hit);
    } else {
        /* SHRINK: return is the pre-shrink EOF (FILE0) but nothing was delivered */
        hit = (a[0].result > 0 && delivered == 0);
        if (hit) atomic_fetch_add(&shrink_hits, 1);
        if (hit || trial < 3)
            printf("MC1_REPRO scenario=shrink trial=%d read_ret=%zd trunc_ret=%zd delivered=%ld final_size=%ld hit=%d\n",
                   trial, a[0].result, a[1].result, delivered, (long)st.st_size, hit);
    }
    fflush(stdout);
    close(fd);
    return hit;
}

/* tid1 competitor for the shared-offset trial (T0 runs read(2) inline). */
static void *competitor(void *arg)
{
    struct attempt *a = arg;
    cpu_set_t cpu;
    CPU_ZERO(&cpu);
    CPU_SET(1, &cpu);
    if (sched_setaffinity(0, sizeof(cpu), &cpu) != 0)
        perror("sched_setaffinity");
    rendezvous();
    if (a->scenario == 0)
        a->result = pwrite(a->fd, seed, REQN, GROW_OFF);
    else
        a->result = ftruncate(a->fd, 0) == 0 ? 0 : -1;
    return NULL;
}

/* Shared-offset read: race read(2) against grow/shrink; the file position
 * advances by the RETURNED count, which need not match delivered bytes. */
static int shared_offset_trial(int scenario, int trial)
{
    int fd = make_file("/ramfs/mc1subject");
    atomic_store_explicit(&launch_tsc, 0, memory_order_release);
    struct attempt a = {.fd = fd, .tid = 1, .scenario = scenario};
    pthread_t th;
    pthread_create(&th, NULL, competitor, &a);
    unsigned char buf[REQN + 64] __attribute__((aligned(64)));
    memset(buf, CANARY, sizeof(buf));
    unsigned long launch = __rdtsc() + 500000;
    atomic_store_explicit(&launch_tsc, launch, memory_order_release);
    while (__rdtsc() < launch) _mm_pause();
    ssize_t result = read(fd, buf, REQN);
    pthread_join(th, NULL);
    off_t pos = lseek(fd, 0, SEEK_CUR);
    long delivered = 0;
    for (long i = 0; i < REQN; i++)
        if (buf[i] != CANARY) delivered++;
    int hit = (result > 0 && (delivered == 0 || delivered > result));
    if (hit || trial < 3)
        printf("MC1_REPRO scenario=%s-shared trial=%d read_ret=%zd delivered=%ld offset_after=%ld hit=%d\n",
               scenario == 0 ? "grow" : "shrink", trial, result, delivered, (long)pos, hit);
    fflush(stdout);
    close(fd);
    return hit;
}

int main(void)
{
    memset(seed, WBYTE, sizeof(seed));
    setvbuf(stdout, NULL, _IOLBF, 0);
    int grow_first = -1, shrink_first = -1;
    for (int t = 0; t < 20000 && grow_first < 0; t++)
        if (one_trial(0, t)) grow_first = t;
    for (int t = 0; t < 20000 && shrink_first < 0; t++)
        if (one_trial(1, t)) shrink_first = t;
    int so_hits = 0;
    for (int t = 0; t < 5000; t++)
        so_hits += shared_offset_trial(t & 1, t);
    printf("MC1_SUMMARY grow_hits=%d shrink_hits=%d shared_offset_hits=%d\n",
           atomic_load(&grow_hits), atomic_load(&shrink_hits), so_hits);
    printf("MC1_RESULT %s\n", (grow_first >= 0 || shrink_first >= 0 || so_hits > 0) ? "BUG_TRIGGERED" : "NOT_TRIGGERED");
    fflush(stdout);
    return 0;
}

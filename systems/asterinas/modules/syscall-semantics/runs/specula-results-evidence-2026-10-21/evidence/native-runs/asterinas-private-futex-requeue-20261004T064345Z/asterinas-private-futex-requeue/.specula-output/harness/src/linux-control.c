// SPDX-License-Identifier: MPL-2.0
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

static _Atomic int words[2];
static int cpus[2];

struct waiter {
    pthread_t thread;
    _Atomic int tid;
    int cpu;
    long result;
    int error;
};

static uint64_t now_ns(void)
{
    struct timespec t;
    assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static void *wait_one(void *arg)
{
    struct waiter *w = arg;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(w->cpu, &set);
    assert(sched_setaffinity(0, sizeof(set), &set) == 0);
    atomic_store_explicit(&w->tid, syscall(SYS_gettid), memory_order_release);
    errno = 0;
    w->result = syscall(SYS_futex, &words[0], FUTEX_WAIT_PRIVATE, 0, 0, 0, 0);
    w->error = errno;
    return NULL;
}

static void enrolled(struct waiter *w, unsigned case_id, unsigned generation)
{
    uint64_t deadline = now_ns() + 2000000000;
    for (;;) {
        int tid = atomic_load_explicit(&w->tid, memory_order_acquire);
        char path[96], symbol[128] = {0};
        if (tid) {
            snprintf(path, sizeof(path), "/proc/self/task/%d/wchan", tid);
            FILE *f = fopen(path, "r");
            if (f) {
                if (!fgets(symbol, sizeof(symbol), f))
                    symbol[0] = '\0';
                fclose(f);
                symbol[strcspn(symbol, "\n")] = '\0';
            }
            // The waiter reaches this sleeping futex frame after queueing. A
            // userspace ready flag alone would not establish that observation.
            if (strstr(symbol, "futex_wait")) {
                printf("{\"case\":%u,\"generation\":%u,\"tid\":%d,"
                       "\"observed_wchan\":\"%s\"}\n",
                       case_id, generation, tid, symbol);
                return;
            }
        }
        assert(now_ns() < deadline);
        usleep(1000);
    }
}

static long wake(_Atomic int *word, int count)
{
    return syscall(SYS_futex, word, FUTEX_WAKE_PRIVATE, count, 0, 0, 0);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    struct utsname u;
    assert(uname(&u) == 0);
    cpu_set_t available;
    assert(sched_getaffinity(0, sizeof(available), &available) == 0);
    int n = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE && n < 2; cpu++)
        if (CPU_ISSET(cpu, &available))
            cpus[n++] = cpu;
    assert(n == 2);
    printf("{\"kernel\":\"%s\",\"release\":\"%s\",\"version\":\"%s\","
           "\"machine\":\"%s\",\"cpus\":[%d,%d],\"A\":\"%p\",\"B\":\"%p\","
           "\"bucket_identity\":\"not_observed\"}\n",
           u.sysname, u.release, u.version, u.machine, cpus[0], cpus[1],
           (void *)&words[0], (void *)&words[1]);

    const int quotas[][2] = {{1, 1}, {1, 0}, {0, 1}, {0, 0}, {1, 1}, {0, 0}};
    for (unsigned c = 1; c <= 6; c++) {
        atomic_store(&words[0], 0);
        atomic_store(&words[1], 0);
        struct waiter waits[2] = {{.cpu = cpus[0]}, {.cpu = cpus[1]}};
        for (unsigned i = 0; i < 2; i++) {
            assert(pthread_create(&waits[i].thread, NULL, wait_one, &waits[i]) == 0);
            enrolled(&waits[i], c, i + 1);
        }
        int nw = quotas[c - 1][0], nm = quotas[c - 1][1];
        _Atomic int *dst = c == 5 ? &words[0] : &words[1];
        errno = 0;
        long result = c == 6 ? wake(&words[0], 0)
                            : syscall(SYS_futex, &words[0], FUTEX_REQUEUE_PRIVATE,
                                      nw, nm, dst, 0);
        int error = errno;
        long dst_wakes = wake(dst, 2);
        long src_wakes = wake(&words[0], 2);
        for (unsigned i = 0; i < 2; i++)
            assert(pthread_join(waits[i].thread, NULL) == 0);
        printf("{\"case\":%u,\"operation\":\"%s\",\"nw\":%d,\"nm\":%d,"
               "\"same_address\":%s,\"result\":%ld,\"errno\":%d,"
               "\"destination_wakes\":%ld,\"source_wakes\":%ld,"
               "\"wait_results\":[%ld,%ld],\"wait_errnos\":[%d,%d]}\n",
               c, c == 6 ? "WAKE" : "REQUEUE", nw, nm,
               c == 5 ? "true" : "false", result, error, dst_wakes, src_wakes,
               waits[0].result, waits[1].result, waits[0].error, waits[1].error);
    }
    return 0;
}

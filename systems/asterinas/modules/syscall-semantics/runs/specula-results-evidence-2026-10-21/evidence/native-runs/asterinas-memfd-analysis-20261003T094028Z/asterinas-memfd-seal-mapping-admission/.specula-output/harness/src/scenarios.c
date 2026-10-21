// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/memfd.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include "test.h"

#define BASE ((void *)0x40000000UL)
#define PAGE 4096UL
#define CONTROL 0x53504543
static int fd[3];
static pthread_barrier_t barrier;
static int race_kind;
static long race_result;
static int race_errno;
static unsigned long start_ns;
static unsigned long seal_delay_ns;

static unsigned long clock_ns(void)
{
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now));
    return now.tv_sec * 1000000000UL + now.tv_nsec;
}

static void await_start(unsigned long delay)
{
    while (clock_ns() < start_ns + delay)
        __asm__ volatile("pause");
}

static void pin(int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    CHECK(sched_setaffinity(0, sizeof(set), &set));
}

static void capture(int thread)
{
#ifdef SPECULA_TRACE
    CHECK(prctl(CONTROL, (unsigned long)thread, (unsigned long)fd[0],
                (unsigned long)fd[1], (unsigned long)fd[2]));
#else
    (void)thread;
#endif
}

static void begin(const char *name, int allow)
{
    CHECK(munmap(BASE, 3 * PAGE));
    fd[0] = CHECK(memfd_create(name, allow ? MFD_ALLOW_SEALING : 0));
    CHECK(ftruncate(fd[0], 3 * PAGE));
    char path[80];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd[0]);
    fd[1] = CHECK(open(path, O_RDWR));
    fd[2] = CHECK(open(path, O_RDONLY));
    struct stat a, b, c;
    CHECK(fstat(fd[0], &a)); CHECK(fstat(fd[1], &b)); CHECK(fstat(fd[2], &c));
    CHECK_WITH(a.st_ino == b.st_ino && a.st_ino == c.st_ino, _ret);
    int modes[3];
    for (int i = 0; i < 3; ++i)
        modes[i] = CHECK(fcntl(fd[i], F_GETFL)) & O_ACCMODE;
    CHECK_WITH(modes[0] == O_RDWR && modes[1] == O_RDWR && modes[2] == O_RDONLY, _ret);
    int seals = CHECK(fcntl(fd[0], F_GET_SEALS));
    CHECK_WITH(seals == (allow ? 0 : F_SEAL_SEAL), _ret);
    printf("SPECULA_BEGIN {\"name\":\"%s\",\"allow_sealing\":%s,\"initial_seals\":%d,\"modes\":[%d,%d,%d],\"eof_bytes\":%ld}\n",
           name, allow ? "true" : "false", seals, modes[0], modes[1], modes[2], (long)a.st_size);
    fflush(stdout);
    capture(1);
}

static void end(void)
{
    capture(0);
    puts("SPECULA_END"); fflush(stdout);
    CHECK(munmap(BASE, 3 * PAGE));
    for (int i = 0; i < 3; ++i) CHECK(close(fd[i]));
}

static void *map(int lo, int hi, int off, int handle, int shared, int perms, int fixed)
{
    return mmap((char *)BASE + lo * PAGE, (hi - lo) * PAGE, perms,
                (shared ? MAP_SHARED : MAP_PRIVATE) | (fixed ? MAP_FIXED : 0),
                fd[handle], off * PAGE);
}

static int protect(int lo, int hi, int perms)
{
    return mprotect((char *)BASE + lo * PAGE, (hi - lo) * PAGE, perms);
}

static int unmap(int lo, int hi)
{
    return munmap((char *)BASE + lo * PAGE, (hi - lo) * PAGE);
}

static int fault(int page)
{
#ifdef SPECULA_TRACE
    return prctl(CONTROL, 3UL, (unsigned long)BASE + page * PAGE, 0UL, 0UL);
#else
    *((volatile unsigned char *)BASE + page * PAGE) = 0x5a;
    return 0;
#endif
}

FN_TEST(admission_controls)
{
    begin("tv1a-write-read", 1);
    TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE));
#ifdef SPECULA_TRACE
    TEST_ERRNO(map(0, 1, 0, 0, 1, PROT_READ, 0), EPERM);
#else
    TEST_RES(map(0, 1, 0, 0, 1, PROT_READ, 0), _ret == BASE);
    TEST_SUCC(unmap(0, 1));
#endif
    TEST_RES(map(0, 1, 0, 2, 1, PROT_READ, 0), _ret == BASE);
    TEST_SUCC(protect(0, 1, PROT_READ));
    TEST_ERRNO(protect(0, 1, PROT_READ | PROT_WRITE), EACCES);
    TEST_ERRNO(map(1, 2, 1, 2, 1, PROT_READ | PROT_WRITE, 0), EACCES);
    TEST_RES(map(1, 2, 1, 2, 0, PROT_READ | PROT_WRITE, 0), _ret == (char *)BASE + PAGE);
    TEST_SUCC(unmap(0, 2));
    TEST_RES(fcntl(fd[0], F_GET_SEALS), _ret == F_SEAL_WRITE);
    end();

    begin("tv1b-future-read", 1);
    TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_FUTURE_WRITE));
    TEST_RES(map(0, 1, 0, 0, 1, PROT_READ, 0), _ret == BASE);
    TEST_ERRNO(protect(0, 1, PROT_READ | PROT_WRITE), EACCES);
#ifdef SPECULA_TRACE
    TEST_ERRNO(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE), EBUSY);
#else
    TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE));
#endif
    TEST_SUCC(unmap(0, 1));
    TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_SEAL));
    TEST_ERRNO(fcntl(fd[0], F_ADD_SEALS, 0), EPERM);
    TEST_RES(fcntl(fd[0], F_GET_SEALS), _ret == (F_SEAL_FUTURE_WRITE | F_SEAL_WRITE | F_SEAL_SEAL));
    end();

    begin("default-seal", 0);
    TEST_ERRNO(fcntl(fd[0], F_ADD_SEALS, F_SEAL_FUTURE_WRITE), EPERM);
    TEST_RES(map(0, 1, 0, 0, 1, PROT_READ, 0), _ret == BASE);
    TEST_SUCC(protect(0, 1, PROT_READ | PROT_WRITE));
    TEST_SUCC(unmap(0, 1));
    TEST_RES(fcntl(fd[0], F_GET_SEALS), _ret == F_SEAL_SEAL);
    end();
}
END_TEST()

FN_TEST(rejected_replacement_and_prefix)
{
    for (int partial = 0; partial < 2; ++partial) {
        begin(partial ? "tv2-partial" : "tv2-full", 1);
        TEST_RES(map(0, 3, 0, 0, 1, PROT_READ | PROT_WRITE, 0), _ret == BASE);
        TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_FUTURE_WRITE));
        TEST_ERRNO(map(partial ? 1 : 0, partial ? 2 : 3, partial ? 1 : 0, 0, 1,
                       PROT_READ | PROT_WRITE, 1), EPERM);
#ifdef SPECULA_TRACE
        TEST_ERRNO(protect(partial ? 1 : 0, partial ? 2 : 3, PROT_READ), ENOMEM);
#else
        TEST_SUCC(protect(partial ? 1 : 0, partial ? 2 : 3, PROT_READ));
#endif
        TEST_SUCC(unmap(0, 3));
        TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE));
        end();
    }
    begin("prefix-eacces", 1);
    TEST_RES(map(0, 1, 0, 0, 1, PROT_READ, 0), _ret == BASE);
    TEST_RES(map(1, 2, 1, 2, 1, PROT_READ, 0), _ret == (char *)BASE + PAGE);
    TEST_ERRNO(protect(0, 2, PROT_READ | PROT_WRITE), EACCES);
    TEST_SUCC(fault(0));
    TEST_ERRNO(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_FUTURE_WRITE | F_SEAL_SEAL), EBUSY);
    TEST_RES(fcntl(fd[0], F_GET_SEALS), _ret == 0);
    TEST_SUCC(unmap(0, 2));
    end();

    begin("prefix-hole", 1);
    TEST_RES(map(0, 1, 0, 0, 1, PROT_READ, 0), _ret == BASE);
    TEST_RES(map(2, 3, 2, 0, 1, PROT_READ, 0), _ret == (char *)BASE + 2 * PAGE);
    TEST_ERRNO(protect(0, 3, PROT_READ | PROT_WRITE), ENOMEM);
    TEST_SUCC(fault(0));
    TEST_SUCC(unmap(0, 3));
    TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE));
    end();
}
END_TEST()

FN_TEST(lifecycle)
{
    begin("split-merge-flush", 1);
    TEST_RES(map(0, 3, 0, 0, 1, PROT_READ | PROT_WRITE, 0), _ret == BASE);
    for (int i = 0; i < 3; ++i) TEST_SUCC(fault(i));
    TEST_SUCC(protect(1, 2, PROT_READ));
    TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_FUTURE_WRITE));
    TEST_SUCC(protect(1, 2, PROT_READ | PROT_WRITE));
    TEST_SUCC(fault(1));
    TEST_ERRNO(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE), EBUSY);
    TEST_SUCC(unmap(1, 2));
    TEST_ERRNO(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE), EBUSY);
    TEST_SUCC(unmap(0, 1));
    TEST_ERRNO(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE), EBUSY);
    TEST_SUCC(unmap(2, 3));
    TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE));
    end();

    for (int separate = 0; separate < 2; ++separate) {
        begin(separate ? "different-descriptions" : "noncontiguous-offsets", 1);
        TEST_RES(map(0, 1, 0, 0, 1, PROT_READ, 0), _ret == BASE);
        TEST_RES(map(1, 2, separate ? 1 : 2, separate ? 1 : 0, 1, PROT_READ, 0),
                 _ret == (char *)BASE + PAGE);
        TEST_SUCC(protect(0, 2, PROT_READ | PROT_WRITE));
        TEST_ERRNO(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE), EBUSY);
        TEST_SUCC(unmap(0, 2));
        TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE));
        end();
    }
}
END_TEST()

static void *seal_worker(void *unused)
{
    (void)unused;
    pin(1);
    capture(2);
    pthread_barrier_wait(&barrier);
    pthread_barrier_wait(&barrier);
    await_start(seal_delay_ns);
    errno = 0;
    race_result = race_kind == 2 ? fcntl(fd[0], F_GET_SEALS) :
        fcntl(fd[0], F_ADD_SEALS, race_kind == 1 ? F_SEAL_WRITE : F_SEAL_FUTURE_WRITE);
    race_errno = errno;
    pthread_barrier_wait(&barrier);
    /* Serial output is outside both workers' measured execution. */
    capture(0);
    return NULL;
}

FN_TEST(concurrent_sealing)
{
    pin(0);
    for (int kind = 0; kind < 4; ++kind) {
        race_kind = kind;
        for (int attempt = 0; attempt < (kind == 2 ? 32 : 16); ++attempt) {
            char name[64];
            const char *prefix[] = {"admission-race", "final-unmap-race", "seal-read-race", "old-protect-race"};
            snprintf(name, sizeof(name), "%s-%02d", prefix[kind], attempt);
            begin(name, 1);
            if (kind == 1 || kind == 3) {
                TEST_RES(map(0, 3, 0, 0, 1, PROT_READ | PROT_WRITE, 0), _ret == BASE);
                for (int i = 0; i < 3; ++i) TEST_SUCC(fault(i));
                if (kind == 3) TEST_SUCC(protect(0, 3, PROT_READ));
            }
            CHECK(pthread_barrier_init(&barrier, NULL, 2));
            pthread_t worker;
            seal_delay_ns = kind == 2 ? (attempt % 8) * 1000UL : (attempt % 8) * 20000UL;
            CHECK(pthread_create(&worker, NULL, seal_worker, NULL));
            pthread_barrier_wait(&barrier);
            start_ns = clock_ns() + 1000000UL;
            pthread_barrier_wait(&barrier);
            await_start(0);
            if (kind == 1) {
                TEST_SUCC(unmap(0, 3));
            } else if (kind == 2) {
                TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_FUTURE_WRITE));
            } else if (kind == 3) {
                TEST_SUCC(protect(0, 3, PROT_READ | PROT_WRITE));
            } else {
                TEST_RES(map(0, 2, 0, 0, 1, PROT_READ, 0), _ret == BASE);
            }
            pthread_barrier_wait(&barrier);
            CHECK(pthread_join(worker, NULL));
            CHECK(pthread_barrier_destroy(&barrier));
            CHECK_WITH(race_result == 0 ||
                       (kind == 1 && race_result == -1 && race_errno == EBUSY) ||
                       (kind == 2 && race_result == F_SEAL_FUTURE_WRITE), _ret);
            if (!kind) {
                /* Both retained-eligibility outcomes are recorded for replay. */
                errno = 0;
                int ret = protect(0, 2, PROT_READ | PROT_WRITE);
                int err = errno;
                CHECK_WITH(ret == 0 || (ret == -1 && err == EACCES), _ret);
                TEST_SUCC(unmap(0, 2));
            }
            if (kind != 2) {
                if (kind == 3) TEST_SUCC(unmap(0, 3));
                TEST_SUCC(fcntl(fd[0], F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_SEAL));
                TEST_RES(fcntl(fd[0], F_GET_SEALS), (_ret & (F_SEAL_WRITE | F_SEAL_SEAL)) == (F_SEAL_WRITE | F_SEAL_SEAL));
            }
            end();
        }
    }
}
END_TEST()

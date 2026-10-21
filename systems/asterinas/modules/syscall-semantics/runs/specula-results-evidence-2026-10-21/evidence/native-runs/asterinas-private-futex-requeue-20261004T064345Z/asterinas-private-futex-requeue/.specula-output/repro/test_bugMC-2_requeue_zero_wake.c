// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding MC-2:
//   "Ordinary REQUEUE with a zero wake quota wakes a waiter"
//
// Linux contract (kernel/futex/requeue.c, futex_requeue): the quota is tested
// BEFORE waking each waiter ("if (++task_count <= nr_wake) wake; else
// requeue", and the loop head breaks when "task_count - nr_wake >=
// nr_requeue").  FUTEX_REQUEUE(uaddr, uaddr2, val=0, val2=0) therefore wakes
// no waiter, requeues no waiter, and returns 0.
//
// Asterinas (kernel/core/src/syscall/futex.rs) passes val through
// futex_val_to_max_count(), which raises 0 to 1 -- an at-least-one rule that
// Linux applies to FUTEX_WAKE only (kernel/futex/waitwake.c wakes the first
// waiter before testing the quota).  So REQUEUE(A -> B, 0, 0) wakes one
// waiter and returns 1.
//
// The test enrolls two waiters on the private futex word A (word never
// changes), performs REQUEUE(A -> B, 0, 0) and observes:
//   1. the syscall return value   (Linux: 0;  buggy Asterinas: 1)
//   2. how many waiters' FUTEX_WAIT returned during a 300 ms observation
//      window BEFORE any cleanup wake is issued
//                                (Linux: 0;  buggy Asterinas: 1)
//
// Run natively on Linux for the control result; run as the init program in
// the Asterinas guest (build with -DGUEST) for the bug run.  The enrollment
// gate polls the instrumented kernel's SPECULA probe (futex op 0x5350,
// command 5 = currently enrolled waiter count) when available and falls back
// to a timed spin on uninstrumented kernels.  The probe only observes
// enrollment; the trigger itself is a plain public futex syscall.

#define _GNU_SOURCE
#include <errno.h>
#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static _Atomic int word_a = 0; // source futex word (never modified)
static _Atomic int word_b = 0; // destination futex word (never modified)

static atomic_int about_to_wait = 0; // threads about to call FUTEX_WAIT
static atomic_int wait_done = 0;     // threads whose FUTEX_WAIT returned
static long waiter_results[2] = {99, 99};
static int waiter_errno[2];

static long futex_call(volatile void *addr, int op, long val, long val2,
                       volatile void *addr2)
{
    // Argument order: uaddr, op, val, timeout/val2, uaddr2, val3.
    return syscall(SYS_futex, (int *)addr, op, val, val2, (int *)addr2, 0);
}

static void *waiter_fn(void *arg)
{
    long id = (long)arg;
    atomic_fetch_add(&about_to_wait, 1);
    errno = 0;
    waiter_results[id] = futex_call(&word_a, FUTEX_WAIT_PRIVATE, 0, 0, NULL);
    waiter_errno[id] = errno;
    atomic_fetch_add(&wait_done, 1);
    return NULL;
}

static void spin_ms(long ms)
{
    struct timespec begin, now;
    clock_gettime(CLOCK_MONOTONIC, &begin);
    do {
        sched_yield();
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while ((now.tv_sec - begin.tv_sec) * 1000L +
                 (now.tv_nsec - begin.tv_nsec) / 1000000L < ms);
}

// Wait until both waiters are enrolled in the kernel futex queue.  On the
// instrumented campaign kernel, poll the SPECULA probe (op 0x5350, command 5)
// which returns the number of currently enrolled waiters.  On other kernels
// (e.g. the Linux control run) the probe returns -1/EINVAL; fall back to
// waiting until both threads announced the wait plus a generous delay.
static void wait_for_two_enrolled(void)
{
    errno = 0;
    long r = syscall(SYS_futex, (int *)0, 0x5350, 5, 0, 0, 0);
    if (r >= 0) {
        struct timespec begin, now;
        clock_gettime(CLOCK_MONOTONIC, &begin);
        while (r < 2) {
            sched_yield();
            errno = 0;
            r = syscall(SYS_futex, (int *)0, 0x5350, 5, 0, 0, 0);
            if (r < 0)
                break;
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - begin.tv_sec > 5)
                break;
        }
        if (r >= 2) {
            printf("[MC-2] enrollment gate: kernel reports %ld enrolled waiters\n", r);
            return;
        }
    }
    while (atomic_load(&about_to_wait) < 2)
        sched_yield();
    spin_ms(300);
    printf("[MC-2] enrollment gate: fallback timed spin (probe unavailable)\n");
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("[MC-2] start: enrolling two waiters on private futex A\n");

    pthread_t t0, t1;
    if (pthread_create(&t0, NULL, waiter_fn, (void *)0) != 0 ||
        pthread_create(&t1, NULL, waiter_fn, (void *)1) != 0) {
        printf("[MC-2] ERROR: pthread_create failed\n");
        return 1;
    }
    wait_for_two_enrolled();

    // TRIGGER: REQUEUE(A -> B, nr_wake = 0, nr_requeue = 0), public syscall.
    errno = 0;
    long ret = futex_call(&word_a, FUTEX_REQUEUE_PRIVATE, 0, 0, &word_b);
    int ret_errno = errno;
    printf("[MC-2] REQUEUE(A->B, 0, 0) returned %ld (errno %d)\n", ret, ret_errno);

    // Observe for 300 ms how many waiters returned without any wake.
    spin_ms(300);
    int woken_by_requeue = atomic_load(&wait_done);
    printf("[MC-2] waiters whose FUTEX_WAIT returned before cleanup: %d\n",
           woken_by_requeue);
    for (int i = 0; i < 2; i++) {
        if (waiter_results[i] != 99)
            printf("[MC-2] waiter %d: FUTEX_WAIT = %ld (errno %d)\n", i,
                   waiter_results[i], waiter_errno[i]);
    }
    printf("[MC-2] futex word A = %d (must be 0: nobody ever stores to it)\n",
           atomic_load(&word_a));

    // Cleanup: wake whatever is left so all threads can join.
    long w1 = futex_call(&word_a, FUTEX_WAKE_PRIVATE, 2, 0, NULL);
    long w2 = futex_call(&word_b, FUTEX_WAKE_PRIVATE, 2, 0, NULL);
    spin_ms(100);
    pthread_join(t0, NULL);
    pthread_join(t1, NULL);
    printf("[MC-2] cleanup wakes: A=%ld B=%ld, wait_done=%d\n", w1, w2,
           atomic_load(&wait_done));

    if (ret == 0 && woken_by_requeue == 0) {
        printf("[MC-2] RESULT: LINUX_CORRECT (return 0, no waiter woken)\n");
    } else {
        printf("[MC-2] RESULT: BUG_TRIGGERED (return %ld, %d waiter(s) woken; "
               "Linux returns 0 and wakes none)\n", ret, woken_by_requeue);
    }
    printf("MC2_TEST_DONE\n");
    fflush(stdout);
#ifdef GUEST
    // Clean guest shutdown: the kernel exits QEMU via isa-debug-exit.
    reboot(RB_POWER_OFF);
#endif
    return 0;
}

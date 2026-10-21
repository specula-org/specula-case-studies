// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding MC-1: "A timed-out waiter moved to another
// bucket leaves its entry behind".
//
// Scenario (private futexes, words A and B in DIFFERENT hash buckets):
//   W1: FUTEX_WAIT(A) untimed
//   W2: FUTEX_WAIT(A, 300ms)                 <- enqueued after W1
//   REQUEUE(A -> B, nr_wake=1, nr_requeue=1) <- wakes W1, moves sleeping W2 to B's bucket
//   join W1 (expect 0), join W2 after its timeout.
//
// Linux semantics: W2 times out on B and FUTEX_WAIT returns -1/ETIMEDOUT; the
// kernel removes W2's entry while dequeuing it (futex_unqueue follows
// q->lock_ptr). Asterinas (bug): futex_wait_bitset removes the item only from
// the ORIGINAL bucket saved at futex.rs:79; after the cross-bucket requeue the
// lookup misses, so the syscall returns 0 instead of ETIMEDOUT and the closed
// item stays in bucket B forever.
//
// Downstream harm (LiveMigrationExhaustion, CE MC_hunt_s4_live_migration):
//   W3: FUTEX_WAIT(B) untimed
//   REQUEUE(B -> A, 0, 1): Linux moves the live W3; Asterinas burns the move
//   quota on the dead W2 entry and leaves W3 behind.
//   WAKE(A, 1): Linux wakes W3 and returns 1; Asterinas returns 0 with W3
//   still blocked, because the dead entry absorbs the wake scan.
//
// The reserved instrumentation opcode 0x5350 is used ONLY for setup and
// observation (bucket identity query cmd 4, enrollment count cmd 5, stream
// registration cmd 1); it never enqueues, wakes, moves, or completes a
// waiter. When unavailable (running as the native Linux control), the test
// falls back to fixed delays. The bug trigger itself is exclusively ordinary
// FUTEX_WAIT/FUTEX_REQUEUE/FUTEX_WAKE syscalls.

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

static _Atomic int words[8192];

static long probe(void *addr, int command, unsigned long arg) {
    // Raw query; returns < 0 (errno) when the opcode is unsupported (Linux host).
    return syscall(SYS_futex, addr, 0x5350, command, arg, 0, 0);
}

static long fwait(_Atomic int *p, int expected, long ns) {
    struct timespec t = {.tv_sec = 0, .tv_nsec = ns};
    return syscall(SYS_futex, p, FUTEX_WAIT_PRIVATE, expected, ns < 0 ? 0 : &t, 0, 0);
}
static long fwake(_Atomic int *p, int n) {
    return syscall(SYS_futex, p, FUTEX_WAKE_PRIVATE, n, 0, 0, 0);
}
static long frequeue(_Atomic int *p, _Atomic int *q, int nw, int nm) {
    return syscall(SYS_futex, p, FUTEX_REQUEUE_PRIVATE, nw, nm, q, 0);
}

struct waiter {
    pthread_t thread;
    int stream;
    _Atomic int *word;
    long ns;
    long result;
    int error;
    _Atomic int done;
};

static int have_probe;
static int probe_stream_counter;

static void probe_register_stream(int stream) {
    if (have_probe) {
        long r = probe(0, 1, stream);
        if (r < 0) {
            printf("MC1_ERR probe_register_stream failed %ld\n", r);
            exit(2);
        }
    }
}

static void *wait_fn(void *arg) {
    struct waiter *w = arg;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(w->stream % 2, &set);
    sched_setaffinity(0, sizeof(set), &set); // best effort
    probe_register_stream(w->stream);
    errno = 0;
    w->result = fwait(w->word, 0, w->ns);
    w->error = errno;
    atomic_store(&w->done, 1);
    return 0;
}

static void start(struct waiter *w, int stream, _Atomic int *p, long ns) {
    *w = (struct waiter){.stream = stream, .word = p, .ns = ns};
    atomic_store(&w->done, 0);
    if (pthread_create(&w->thread, 0, wait_fn, w) != 0) {
        printf("MC1_ERR pthread_create failed\n");
        exit(2);
    }
}

// Wait until at least n streams have enrolled (instrumented kernel) or fall
// back to a delay long enough for the wait to have been issued (Linux host).
static void wait_enrolled(unsigned n) {
    if (have_probe) {
        struct timespec begin, now;
        clock_gettime(CLOCK_MONOTONIC, &begin);
        while ((unsigned)probe(0, 5, 0) < n) {
            sched_yield();
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - begin.tv_sec >= 5) {
                printf("MC1_ERR enrollment timeout at n=%u\n", n);
                exit(2);
            }
        }
    } else {
        usleep(100 * 1000);
    }
}

static int done_within_ms(struct waiter *w, long ms) {
    struct timespec begin, now;
    clock_gettime(CLOCK_MONOTONIC, &begin);
    while (!atomic_load(&w->done)) {
        sched_yield();
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((now.tv_sec - begin.tv_sec) * 1000 +
                (now.tv_nsec - begin.tv_nsec) / 1000000 >= ms)
            return 0;
    }
    return 1;
}

// Returns 0 if the bug was observed, 1 if the scenario ran but the bug was
// not observed, 2 on setup failure. Single attempt: the scenario is
// deterministic (the requeue is issued immediately after enrollment while
// W2's 300 ms timeout is far in the future).
static int attempt(unsigned attempt_no) {
    // Stream ids for the four waiters (kernel trace streams are 1..7).
    int s1 = 2, s2 = 3, s3 = 4;

    // A is words[0]. Find B with a different bucket so the requeue takes the
    // cross-bucket path (requeue_items_to_another_bucket).
    _Atomic int *a = &words[0];
    _Atomic int *b = 0;
    long bucket_a = -1;
    if (have_probe) {
        bucket_a = probe(a, 4, 0);
        for (int i = 1; i < 8192; i++) {
            long bi = probe(&words[i], 4, 0);
            if (bi >= 0 && bi != bucket_a) {
                b = &words[i];
                break;
            }
        }
        if (!b) {
            printf("MC1_ERR no cross-bucket B found\n");
            return 2;
        }
        // Register the key addresses so the kernel traces the WAIT/REQUEUE/WAKE
        // calls on them (probe cmd 3, observation-only; needed for the
        // enrollment gate below).
        if (probe(a, 3, 0) < 0 || probe(b, 3, 1) < 0) {
            printf("MC1_ERR key registration failed\n");
            return 2;
        }
        printf("MC1_OBS attempt=%u bucket_a=%ld bucket_b=%ld cross_bucket=1\n",
               attempt_no, bucket_a, probe(b, 4, 0));
    } else {
        b = &words[4096]; // host control: bucket layout irrelevant, Linux is correct either way
        printf("MC1_OBS attempt=%u probe=absent fallback_delays=1\n", attempt_no);
    }
    (void)bucket_a;

    struct waiter w1, w2;

    // W1 first, gated, then W2: guarantees queue order [W1, W2] so the
    // requeue's wake phase (nr_wake=1) wakes W1 and the move phase takes W2.
    start(&w1, s1, a, -1);
    wait_enrolled(1);
    start(&w2, s2, a, 300 * 1000 * 1000L);
    wait_enrolled(2);

    long rq1 = frequeue(a, b, 1, 1);
    pthread_join(w1.thread, 0);
    if (w1.result != 0) {
        printf("MC1_ERR attempt=%u w1 result %ld errno %d (expected 0)\n",
               attempt_no, w1.result, w1.error);
        pthread_join(w2.thread, 0);
        return 2;
    }
    pthread_join(w2.thread, 0);

    // Linux: W2 timed out on B and returned -1/ETIMEDOUT.
    // Bug: cleanup missed the moved item and returned success.
    int bug1 = (w2.result == 0);

    // LiveMigrationExhaustion (CE s4 / trace case-13 shape): with the dead
    // entry queued ahead of two live waiters on B, REQUEUE(B->A,1,1) must wake
    // one live waiter and migrate the other; Asterinas burns the move quota on
    // the dead entry, so the second live waiter stays blocked on B and the
    // follow-up WAKE(A,1) finds only the dead entry (returns 0, wakes nobody).
    // nr_wake must be >= 1: Asterinas maps a zero nr_wake to one wake
    // (futex_val_to_max_count), which would wake the live waiter instead.
    struct waiter w3, w4;
    start(&w3, s3, b, -1);
    wait_enrolled(3);
    start(&w4, s3 + 1, b, -1);
    wait_enrolled(4);
    long rq2 = frequeue(b, a, 1, 1);
    long wake_a = fwake(a, 1);
    int w4_done = done_within_ms(&w4, 300);
    int bug2 = (wake_a == 0 && !w4_done);
    long wake_b = fwake(b, 1);
    pthread_join(w3.thread, 0);
    pthread_join(w4.thread, 0);

    printf("MC1_OBS attempt=%u rq1=%ld w1=(%ld,%d) w2=(%ld,%d) rq2=%ld "
           "wake_a=%ld w4_done_before_wake_b=%d wake_b=%ld w3=(%ld,%d) w4=(%ld,%d)\n",
           attempt_no, rq1, w1.result, w1.error, w2.result, w2.error, rq2,
           wake_a, w4_done, wake_b, w3.result, w3.error, w4.result, w4.error);
    printf("MC1_LINUX_EXPECT w2=(-1,ETIMEDOUT=%d) wake_a=1 w4_done_before_wake_b=1\n",
           ETIMEDOUT);

    if (bug1)
        printf("MC1_BUG1_REPRODUCED attempt=%u timed-out requeued waiter returned "
               "0 instead of -ETIMEDOUT\n", attempt_no);
    else
        printf("MC1_NOBUG1 attempt=%u w2 returned %ld errno %d\n",
               attempt_no, w2.result, w2.error);
    if (bug2)
        printf("MC1_BUG2_REPRODUCED attempt=%u dead entry consumed requeue(B->A,1,1) "
               "move quota: wake(A,1)=0 and live W4 left blocked on B\n", attempt_no);
    else
        printf("MC1_NOBUG2 attempt=%u wake_a=%ld w4_done=%d\n",
               attempt_no, wake_a, w4_done);

    printf("MC1_ATTEMPT_RESULT %u %s\n", attempt_no,
           (bug1 && bug2) ? "REPRODUCED" : "NOT_REPRODUCED");

    return (bug1 && bug2) ? 0 : 1;
}

int main(void) {
    setvbuf(stdout, 0, _IONBF, 0);
    memset(words, 0, sizeof(words));
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(0, &set);
    sched_setaffinity(0, sizeof(set), &set); // best effort

    have_probe = (probe(&words[0], 4, 0) >= 0);
    printf("MC1_START probe=%d\n", have_probe);
    if (have_probe) {
        long r = probe(0, 2, 100); // reset enrollment counters, begin trace
        if (r < 0) {
            printf("MC1_ERR probe reset failed %ld\n", r);
            return 2;
        }
    }

    int reproduced = 0;
    {
        int rc = attempt(0);
        if (rc == 2)
            return 2;
        reproduced = (rc == 0);
    }

    if (have_probe) {
        probe(0, 6, 100); // freeze and dump the kernel trace (observation only)
        printf("MC1_VERDICT %s\n", reproduced ? "REPRODUCED" : "NOT_REPRODUCED");
        reboot(RB_POWER_OFF);
    } else {
        printf("MC1_VERDICT %s\n", reproduced ? "REPRODUCED" : "NOT_REPRODUCED");
    }
    return reproduced ? 0 : 1;
}

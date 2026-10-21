// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding MC-3:
//   "A same-bucket REQUEUE with a zero migration quota moves one waiter"
//
// Linux contract (kernel/futex/requeue.c, futex_requeue): the requeue quota
// is tested BEFORE each waiter is considered ("if (task_count - nr_wake >=
// nr_requeue) break;", requeue.c:600 in the verified Linux 7.2.8 source).
// FUTEX_REQUEUE(uaddr, 1, 0, uaddr2) therefore wakes one waiter, requeues
// none -- regardless of whether the two words hash to the same bucket
// (double_lock_hb permits hb1 == hb2).  A later FUTEX_WAKE on the source
// word then still finds the remaining waiter.
//
// Asterinas (kernel/core/src/process/posix_thread/futex.rs): when the two
// keys land in the same hash bucket, futex_requeue takes the
// update_item_keys path (futex.rs:378), which rekeys a matching entry and
// increments the counter BEFORE testing "count >= max_count"
// (futex.rs:500-511).  With max_nrequeues == 0 the first remaining waiter
// is silently rekeyed to the destination word.  The cross-bucket path
// (requeue_items_to_another_bucket, futex.rs:519-535) tests the quota
// first and moves nothing.  So on Asterinas, REQUEUE(A -> C, 1, 0) with A
// and C in the same bucket leaves the second waiter keyed under C: a later
// WAKE(A, 2) returns 0 (Linux: 1) and only WAKE(C, 2) reaches it
// (Asterinas: 1, Linux: 0).
//
// Same sequence as the MC counterexample
// (spec/output/hunt-round2/MC_hunt_s2_zero_move_same_bucket-bfs.out):
// MCWait(1,"A",0), MCWait(2,"A",0), MCCall requeue A->C nw=1 nm=0,
// violating RequeueMoveQuota == moves <= rawMove (base.tla:559).
//
// Levels (escalation ladder):
//   Level 0 (pure black-box): the test discovers a same-bucket word pair
//     using ONLY public futex syscalls -- for each candidate C it enrolls
//     two waiters on A, performs REQUEUE(A -> C, 1, 0), and reads the
//     WAKE(A)/WAKE(C) signature.  Different bucket: (ret 1, wakeA 1,
//     wakeC 0).  Same bucket on Asterinas: (ret 1, wakeA 0, wakeC 1) --
//     the zero-quota move itself is the detector.  The enrollment
//     handshake is a userspace flag plus cooperative sched_yield()
//     (timing help only, no hooks, no source changes).
//   Level 1 (system-provided test hooks): on the instrumented campaign
//     kernel the SPECULA observation probe (futex op 0x5350) provides a
//     deterministic bucket oracle (command 4 = bucket index of an address,
//     computed by the production FutexKey::new + get_futex_bucket path)
//     and a kernel-side enrollment counter (command 5).  The probe only
//     observes identity and enrollment; the trigger itself is always the
//     plain public futex syscall.
//
// Run natively on Linux for the control (expected: every candidate round
// shows (1, 1, 0), i.e. no zero-quota move exists for ANY bucket layout);
// run as the init program in the Asterinas guest (build with -DGUEST) for
// the bug run.

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

#define NWORDS 4096
#define STOP_ROUND 1000000

static _Atomic int words[NWORDS]; // all zero forever; nobody stores to them
static _Atomic int *const A = &words[0];

/* ---------------- futex wrappers (public syscall API only) ------------- */

static long futex_op(volatile void *addr, int op, long val, long val2,
                     volatile void *addr2)
{
    // Argument order: uaddr, op, val, timeout/val2, uaddr2, val3.
    return syscall(SYS_futex, (int *)addr, op, val, val2, (int *)addr2, 0);
}

static long requeue(_Atomic int *src, _Atomic int *dst, int nw, int nm)
{
    return futex_op(src, FUTEX_REQUEUE_PRIVATE, nw, nm, dst);
}

static long wake(_Atomic int *w, int n)
{
    return futex_op(w, FUTEX_WAKE_PRIVATE, n, 0, NULL);
}

/* Observation probe of the instrumented campaign kernel (op 0x5350).
 * Read-only: stream registration (1), begin/reset (2), key registration
 * (3), bucket index of an address (4), enrolled-waiter count (5). */
static long probe_op(void *addr, long cmd, long arg)
{
    return syscall(SYS_futex, addr, 0x5350, cmd, arg, 0, 0);
}

static int probe_available;

/* ---------------- persistent two-waiter round machine ----------------- */

static atomic_int round_no;    // controller stores r to start round r
static atomic_int armed;       // cumulative "about to wait" events
static atomic_int done_seq[2]; // round id each waiter's last result belongs to
static long w_result[2] = { 99, 99 };
static int w_errno[2];

struct round_out {
    long ret, wa, wc;
    int n_after_ret, n_after_wa, n_done;
    long r0, r1;
    int e0, e1;
};

static void *waiter_fn(void *arg)
{
    long id = (long)arg;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(1, &set);
    sched_setaffinity(0, sizeof(set), &set); // best effort
    probe_op(0, 1, id + 2); // register SPECULA stream 2/3 (EINVAL elsewhere)
    int seen = 0;
    for (;;) {
        while (atomic_load_explicit(&round_no, memory_order_acquire) == seen) {
            if (atomic_load_explicit(&round_no, memory_order_acquire) == STOP_ROUND)
                return NULL;
            sched_yield();
        }
        seen = atomic_load_explicit(&round_no, memory_order_acquire);
        if (seen == STOP_ROUND)
            return NULL;
        atomic_fetch_add_explicit(&armed, 1, memory_order_release);
        struct timespec ts = { .tv_sec = 5 }; // bounded in case of anomalies
        errno = 0;
        long r = futex_op(A, FUTEX_WAIT_PRIVATE, 0, (long)&ts, NULL);
        w_errno[id] = errno;
        w_result[id] = r;
        atomic_store_explicit(&done_seq[id], seen, memory_order_release);
    }
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

static int count_done(int r)
{
    return (atomic_load_explicit(&done_seq[0], memory_order_acquire) >= r) +
           (atomic_load_explicit(&done_seq[1], memory_order_acquire) >= r);
}

/* One round: enroll two waiters on A, then the CE sequence
 * REQUEUE(A -> c, nw=1, nm=0); WAKE(A, 2); WAKE(c, 2).
 * gate 0 = flag spin + cooperative yields (Level 0/1 timing help only).
 * gate 1 = kernel enrollment oracle via the SPECULA probe (Level 1 hook)
 *          with a timed-spin fallback when the probe is unavailable.
 * windows = insert observation windows (formal trigger only). */
static void run_round(_Atomic int *c, struct round_out *out, int gate, int windows)
{
    int r = atomic_load(&round_no) + 1;
    if (gate && probe_available)
        probe_op(0, 2, r); // reset enrollment counters (observation only)
    atomic_store_explicit(&round_no, r, memory_order_release);

    while (atomic_load_explicit(&armed, memory_order_acquire) < 2 * r)
        sched_yield();

    if (gate == 0) {
        // Cooperative timing help: give both waiters time to enter the
        // kernel-side queue. No hooks, no sleeps.
        for (int i = 0; i < 500; i++)
            sched_yield();
    } else if (probe_available) {
        struct timespec begin, now;
        clock_gettime(CLOCK_MONOTONIC, &begin);
        for (;;) {
            if (probe_op(0, 5, 0) >= 2)
                break;
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - begin.tv_sec >= 3) {
                out->ret = -99; // gate failure (should not happen)
                return;
            }
            sched_yield();
        }
    } else {
        spin_ms(300);
    }

    errno = 0;
    out->ret = requeue(A, c, 1, 0);
    if (windows)
        spin_ms(200);
    out->n_after_ret = count_done(r);
    out->wa = wake(A, 2);
    if (windows)
        spin_ms(200);
    out->n_after_wa = count_done(r);
    out->wc = wake(c, 2);

    // Bounded wait for both waiters to record their results (no fixed
    // settle delay: normal rounds complete almost immediately).
    struct timespec begin, now;
    clock_gettime(CLOCK_MONOTONIC, &begin);
    while (count_done(r) < 2) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - begin.tv_sec >= 7)
            break;
        sched_yield();
    }
    out->n_done = count_done(r);
    out->r0 = w_result[0];
    out->r1 = w_result[1];
    out->e0 = w_errno[0];
    out->e1 = w_errno[1];
}

static void print_round(const char *tag, _Atomic int *c, const struct round_out *o)
{
    printf("%s round: C=%p REQUEUE(A->C,1,0)=%ld WAKE(A,2)=%ld WAKE(C,2)=%ld "
           "returned(after R/W-A/final)=%d/%d/%d results=%ld,%ld errno=%d,%d\n",
           tag, (void *)c, o->ret, o->wa, o->wc, o->n_after_ret, o->n_after_wa,
           o->n_done, o->r0, o->r1, o->e0, o->e1);
}

static void formal_trigger(const char *tag, _Atomic int *c, int gate)
{
    printf("%s formal trigger on pair A=%p C=%p\n", tag, (void *)A, (void *)c);
    struct round_out o;
    run_round(c, &o, gate, 1);
    print_round(tag, c, &o);
    if (o.ret == 1 && o.wa == 0 && o.wc == 1 && o.r0 == 0 && o.r1 == 0) {
        printf("%s RESULT: BUG_TRIGGERED -- REQUEUE(A->C, nw=1, nm=0) silently "
               "moved one waiter to C (zero migration quota); WAKE(A) returned "
               "0 where Linux guarantees 1; the waiter was only reachable via "
               "WAKE(C) (returned 1; Linux: 0)\n", tag);
    } else if (o.ret == 1 && o.wa == 1 && o.wc == 0 && o.r0 == 0 && o.r1 == 0) {
        printf("%s RESULT: LINUX_CORRECT -- zero migration quota moved no "
               "waiter; the second waiter stayed reachable via WAKE(A)\n", tag);
    } else {
        printf("%s RESULT: ANOMALY -- unexpected signature (see round line)\n", tag);
    }
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc;
    (void)argv;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(0, &set);
    sched_setaffinity(0, sizeof(set), &set); // best effort

    probe_available = (probe_op(A, 4, 0) >= 0);
    printf("[MC-3] start: A=%p probe=%d kernel=%s\n", (void *)A,
           probe_available,
#ifdef GUEST
           "asterinas-guest"
#else
           "linux-control"
#endif
    );

    pthread_t t0, t1;
    if (pthread_create(&t0, NULL, waiter_fn, (void *)0) != 0 ||
        pthread_create(&t1, NULL, waiter_fn, (void *)1) != 0) {
        printf("[MC-3] ERROR: pthread_create failed\n");
        return 1;
    }

    /* ---- Level 0: black-box same-bucket scan via public syscalls ---- */
    printf("[MC-3] LEVEL0: scanning %d candidate words with the public-API "
           "zero-quota requeue probe\n", NWORDS - 1);
    int found = -1, anomalies = 0, normal = 0, i;
    for (i = 1; i < NWORDS; i++) {
        struct round_out o;
        run_round(&words[i], &o, 0, 0);
        if (o.ret == 1 && o.wa == 0 && o.wc == 1 && o.r0 == 0 && o.r1 == 0) {
            found = i;
            break;
        }
        if (o.ret == 1 && o.wa == 1 && o.wc == 0) {
            normal++; // different bucket (or Linux): correct behavior
        } else {
            if (anomalies < 5)
                print_round("[MC-3] L0-anomaly", &words[i], &o);
            anomalies++;
            if (anomalies > 8) {
                printf("[MC-3] LEVEL0: too many anomalous rounds, aborting scan\n");
                break;
            }
        }
    }
    if (found > 0) {
        printf("[MC-3] LEVEL0: same-bucket zero-quota divergence found at word "
               "%d (of %d scanned, %d normal rounds)\n", found, found, normal);
        formal_trigger("[MC-3] L0", &words[found], 0);
    } else {
        printf("[MC-3] LEVEL0: no zero-quota move divergence in %d candidates "
               "(normal=%d anomalies=%d) -- consistent with the Linux contract "
               "(nm=0 never moves a waiter, any bucket layout)\n",
               i - 1, normal, anomalies);
    }

    /* ---- Level 1 cross-check: deterministic bucket oracle (if present) -- */
    if (probe_available) {
        long ba = probe_op(A, 4, 0);
        printf("[MC-3] L1: probe bucket oracle: bucket(A)=%ld\n", ba);
        probe_op(A, 3, 0); // register A as traced key (observation only)
        int collide = 0, j = -1;
        for (int k = 1; k < NWORDS; k++) {
            long bk = probe_op(&words[k], 4, 0);
            if (bk == ba) {
                collide++;
                if (j < 0)
                    j = k;
            }
        }
        printf("[MC-3] L1: %d words share A's bucket; first is word %d "
               "(bucket=%ld)\n", collide, j, j > 0 ? probe_op(&words[j], 4, 0) : -1);
        if (j > 0) {
            formal_trigger("[MC-3] L1", &words[j], 1);
        } else {
            printf("[MC-3] L1: no same-bucket partner exists in the word array\n");
        }
    } else {
        printf("[MC-3] L1: probe unavailable; LEVEL0 result stands\n");
    }

    atomic_store(&round_no, STOP_ROUND);
    pthread_join(t0, NULL);
    pthread_join(t1, NULL);
    printf("MC3_TEST_DONE\n");
    fflush(stdout);
#ifdef GUEST
    reboot(RB_POWER_OFF); // isa-debug-exit clean shutdown in the guest
#endif
    return 0;
}

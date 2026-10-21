// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding MC-4:
//   "REQUEUE returns only the number of woken waiters"
//
// Linux contract (pinned v6.16.5, kernel/futex/requeue.c): ordinary
// FUTEX_REQUEUE (cmpval=NULL, requeue_pi=0) walks the source bucket and
// increments task_count for EVERY matching waiter -- woken
// ("if (++task_count <= nr_wake) this->wake(...)") or moved
// ("else requeue_futex(...)"), requeue.c:607-610 -- and returns
// "ret ? ret : task_count" (requeue.c:691).  Identical uaddr1/uaddr2 is NOT
// rejected for ordinary REQUEUE (the uaddr1==uaddr2 EINVAL check at
// requeue.c:404 is requeue_pi-only); requeue_futex is a no-op move for the
// same bucket (requeue.c:87-102, only q->key is reassigned) but the waiter
// is still counted.  So REQUEUE(A->B, 1, 1) with two waiters on A returns 2
// (one woken + one requeued), and REQUEUE(A->A, 1, 1) also returns 2.
//
// Asterinas (kernel/core/src/process/posix_thread/futex.rs at 0c6053709):
// futex_requeue returns Ok(nwakes) (futex.rs:381) -- only the woken count.
// The movement helpers report nothing: update_item_keys (futex.rs:500-511)
// and requeue_items_to_another_bucket (futex.rs:513-534) both return (),
// so the moved count is lost.  Identical addresses take the shortcut
// "if futex_new_addr == futex_addr { return futex_wake(futex_addr,
// max_nwakes, ...) }" (futex.rs:353-355), which drops max_nrequeues and
// also returns only the wake count.  So both shapes return 1.
//
// Same sequence as the MC counterexamples
// (spec/output/hunt-round2/MC_hunt_s2_return_count-bfs.out, 30 states:
// MCWait(1,"A",0), MCWait(2,"A",0), MCCall requeue A->B nw=1 nm=1; and
// MC_hunt_s2_same_address-bfs.out, 24 states: requeue A->A nw=1 nm=1),
// violating RequeueReturnCount == result == wakes + processed
// (base.tla:560-561).
//
// The return value is a deterministic function of the syscall arguments and
// the enrolled-waiter count -- no race is involved.  The only timing
// requirement is that both waiters be enrolled before the REQUEUE.  The
// post-round wake signature proves enrollment from public API alone:
// after REQUEUE(A->B,1,1), WAKE(B,2)==1 and WAKE(A,2)==0 with both waiters
// completing FUTEX_WAIT with 0 (not ETIMEDOUT) means exactly two waiters
// were enrolled, one was woken by the REQUEUE, and one was moved to B.
// The invariant decomposition is then wakes=1, processed=1, so the syscall
// must return 2.  Asterinas returns 1.
//
// Cases:
//   F03-distinct : REQUEUE(A->B, 1, 1), two waiters on A, B a different
//                  word (cross-bucket or same-bucket -- the return count
//                  does not depend on the bucket layout).
//   F03-same-bkt : same, with B chosen (via the observation probe, where
//                  available) to share A's hash bucket -- exercises the
//                  update_item_keys movement path.
//   F06-same-addr: REQUEUE(A->A, 1, 1), two waiters on A -- exercises the
//                  futex.rs:353-355 shortcut on Asterinas.
//   CTRL         : REQUEUE(A->B, 2, 1), two waiters on A -- both are woken,
//                  nothing is moved; both kernels must return 2 (agreement
//                  case isolating the divergence to moved waiters).
//
// Levels (escalation ladder):
//   Level 0 (pure black-box): public futex syscalls only; enrollment gate
//     is a userspace armed-flag spin plus cooperative sched_yield()
//     (timing help only, no hooks, no source changes).
//   Level 1 (system-provided test hooks): on the instrumented campaign
//     kernel the SPECULA observation probe (futex op 0x5350) provides a
//     kernel-side enrollment counter (command 5) proving >= 2 waiters are
//     enrolled before the REQUEUE, and a bucket oracle (command 4) for
//     choosing a same-bucket destination word.  The probe only observes
//     identity and enrollment; the trigger itself is always the plain
//     public futex syscall.  Where the probe is unavailable (native Linux
//     control) the gate falls back to a timed spin.
//
// Run natively on Linux for the control (expected: REQUEUE returns 2 in
// every CE round, control case 2); run as the init program in the
// Asterinas guest (build with -DGUEST) for the bug run (expected: 1).

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

#define NWORDS 8192
#define STOP_ROUND 1000000
#define ROUNDS_PER_CASE 3

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
    long ret, wb, wa; // REQUEUE return, WAKE(dst) return, WAKE(src) return
    int n_after_ret;  // waiters whose WAIT returned right after the REQUEUE
    int n_done;       // waiters completed at round end
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

/* One round: enroll two waiters on A, then
 *   REQUEUE(src -> dst, nw, nm); WAKE(dst, 2); WAKE(src, 2).
 * For the same-address case src == dst == A and WAKE(dst) is skipped
 * (it would be the same call as WAKE(src)).
 * gate 0 = armed-flag spin + cooperative yields (Level 0 timing help only).
 * gate 1 = kernel enrollment oracle via the SPECULA probe (Level 1 hook)
 *          with a timed-spin fallback when the probe is unavailable.
 */
static void run_round(_Atomic int *src, _Atomic int *dst, int nw, int nm,
                      int gate, struct round_out *out)
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
                break; // enrollment oracle: both waiters are queued
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - begin.tv_sec >= 3) {
                out->ret = -99; // gate failure (should not happen)
                out->wb = out->wa = -99;
                out->n_after_ret = out->n_done = -1;
                out->r0 = out->r1 = -99;
                out->e0 = out->e1 = -1;
                return;
            }
            sched_yield();
        }
    } else {
        spin_ms(300);
    }

    errno = 0;
    out->ret = requeue(src, dst, nw, nm);
    out->n_after_ret = count_done(r);
    out->wb = (dst == src) ? -1 : wake(dst, 2);
    out->wa = wake(src, 2);

    // Bounded wait for both waiters to record their results.
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

static void print_round(const char *tag, int rd, _Atomic int *src,
                        _Atomic int *dst, int nw, int nm,
                        const struct round_out *o)
{
    printf("%s round %d: REQUEUE(%p->%p,%d,%d)=%ld WAKE(dst)=%ld WAKE(src)=%ld "
           "done(afterR/final)=%d/%d results=%ld,%ld errno=%d,%d\n",
           tag, rd, (void *)src, (void *)dst, nw, nm, o->ret, o->wb, o->wa,
           o->n_after_ret, o->n_done, o->r0, o->r1, o->e0, o->e1);
}

/* Classification: 0 = anomaly, 1 = Linux-correct, 2 = bug-triggered,
 * 3 = control match (both kernels agree). */
static int classify(const struct round_out *o, int same_addr)
{
    int both_woken = (o->r0 == 0 && o->r1 == 0 && o->n_done == 2);
    if (!both_woken)
        return 0;
    if (same_addr) {
        if (o->ret == 2 && o->wa == 1)
            return 1; // Linux: 1 woken + 1 counted no-op requeue
        if (o->ret == 1 && o->wa == 1)
            return 2; // Asterinas: wake-only shortcut count
        return 0;
    }
    if (o->ret == 2 && o->wb == 1 && o->wa == 0)
        return 1; // Linux: 1 woken + 1 moved, count = 2
    if (o->ret == 1 && o->wb == 1 && o->wa == 0)
        return 2; // Asterinas: move happened but was not counted
    return 0;
}

static int classify_ctrl(const struct round_out *o)
{
    int both_woken = (o->r0 == 0 && o->r1 == 0 && o->n_done == 2);
    if (both_woken && o->ret == 2 && o->wb == 0 && o->wa == 0)
        return 3; // both woken, nothing moved: both kernels return 2
    return 0;
}

/* Tallies across rounds: returns via pointers. Control-case matches are
 * tallied separately from Linux-correct CE rounds. */
static void run_case(const char *tag, _Atomic int *src, _Atomic int *dst,
                     int nw, int nm, int gate, int is_ctrl, int *n_linux,
                     int *n_bug, int *n_anom)
{
    for (int rd = 1; rd <= ROUNDS_PER_CASE; rd++) {
        struct round_out o;
        run_round(src, dst, nw, nm, gate, &o);
        print_round(tag, rd, src, dst, nw, nm, &o);
        int c = is_ctrl ? classify_ctrl(&o) : classify(&o, src == dst);
        if (c == 1) {
            (*n_linux)++;
            printf("%s round %d: LINUX_CORRECT (ret=2 == wakes+processed)\n",
                   tag, rd);
        } else if (c == 2) {
            (*n_bug)++;
            printf("%s round %d: BUG_TRIGGERED (ret=%ld but wakes+processed=2: "
                   "one waiter woken by REQUEUE, one %s and provably enrolled)\n",
                   tag, rd, o.ret,
                   src == dst ? "counted as requeued by Linux" : "moved to dst (WAKE(dst)=1)");
        } else if (c == 3) {
            (*n_linux)++; // caller passes the control tally for is_ctrl cases
            printf("%s round %d: CONTROL_MATCH (both kernels return 2 when "
                   "nothing is moved)\n", tag, rd);
        } else {
            (*n_anom)++;
            printf("%s round %d: ANOMALY -- unexpected signature (enrollment "
                   "incomplete or unexpected kernel behavior; not counted)\n",
                   tag, rd);
        }
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
    printf("[MC-4] start: A=%p probe=%d kernel=%s\n", (void *)A,
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
        printf("[MC-4] ERROR: pthread_create failed\n");
        return 1;
    }

    /* Destination words. B_fixed is any other word; where the probe is
     * available, also pick a word sharing A's hash bucket (exercises the
     * update_item_keys same-bucket movement path). */
    _Atomic int *b_fixed = &words[1];
    _Atomic int *b_same = NULL;
    if (probe_available) {
        long ba = probe_op(A, 4, 0);
        for (int k = 1; k < NWORDS; k++) {
            if (probe_op(&words[k], 4, 0) == ba) {
                b_same = &words[k];
                break;
            }
        }
        printf("[MC-4] probe bucket oracle: bucket(A)=%ld same-bucket word=%s\n",
               ba, b_same ? "found" : "none");
        if (b_same == b_fixed)
            b_fixed = &words[NWORDS - 1]; // keep the two destinations distinct
        probe_op(A, 3, 0); // register A as traced key (observation only;
                           // the enrollment counter counts traced keys)
    }

    int n_linux = 0, n_bug = 0, n_anom = 0, n_ctrl = 0;

    /* ---- Level 0: black-box, public syscalls only ---- */
    printf("[MC-4] LEVEL0: CE shape F03 (distinct addresses), REQUEUE(A->B,1,1)\n");
    run_case("[MC-4] L0-F03", A, b_fixed, 1, 1, 0, 0, &n_linux, &n_bug, &n_anom);
    if (b_same) {
        printf("[MC-4] LEVEL0: CE shape F03 (same-bucket destination, "
               "update_item_keys path), REQUEUE(A->B,1,1)\n");
        run_case("[MC-4] L0-F03sb", A, b_same, 1, 1, 0, 0, &n_linux, &n_bug, &n_anom);
    }
    printf("[MC-4] LEVEL0: CE shape F06 (same address, futex.rs:353-355 "
           "shortcut), REQUEUE(A->A,1,1)\n");
    run_case("[MC-4] L0-F06", A, A, 1, 1, 0, 0, &n_linux, &n_bug, &n_anom);
    printf("[MC-4] LEVEL0: control REQUEUE(A->B,2,1) -- both woken, nothing "
           "moved, both kernels must return 2\n");
    run_case("[MC-4] L0-CTRL", A, b_fixed, 2, 1, 0, 1, &n_ctrl, &n_bug, &n_anom);

    /* ---- Level 1: enrollment oracle (probe) / timed spin fallback ---- */
    printf("[MC-4] LEVEL1: formal trigger with enrollment oracle "
           "(gate=%s)\n", probe_available ? "probe" : "timed spin");
    run_case("[MC-4] L1-F03", A, b_fixed, 1, 1, 1, 0, &n_linux, &n_bug, &n_anom);
    run_case("[MC-4] L1-F06", A, A, 1, 1, 1, 0, &n_linux, &n_bug, &n_anom);

    atomic_store(&round_no, STOP_ROUND);
    pthread_join(t0, NULL);
    pthread_join(t1, NULL);

    printf("[MC-4] totals: linux_correct_ce=%d bug_triggered=%d "
           "control_match=%d anomalies=%d\n", n_linux, n_bug, n_ctrl, n_anom);
    if (n_bug > 0 && n_linux == 0 && n_anom == 0)
        printf("[MC-4] RESULT: BUG_TRIGGERED -- FUTEX_REQUEUE returned only "
               "the wake count while a waiter was provably woken AND another "
               "provably moved (or counted); Linux returns wakes+requeues\n");
    else if (n_linux > 0 && n_bug == 0 && n_anom == 0)
        printf("[MC-4] RESULT: LINUX_CONTROL_CORRECT -- REQUEUE returned "
               "wakes+requeues in every CE round\n");
    else
        printf("[MC-4] RESULT: MIXED/ANOMALOUS -- see round lines\n");
    printf("MC4_TEST_DONE\n");
    fflush(stdout);
#ifdef GUEST
    reboot(RB_POWER_OFF); // isa-debug-exit clean shutdown in the guest
#endif
    return 0;
}

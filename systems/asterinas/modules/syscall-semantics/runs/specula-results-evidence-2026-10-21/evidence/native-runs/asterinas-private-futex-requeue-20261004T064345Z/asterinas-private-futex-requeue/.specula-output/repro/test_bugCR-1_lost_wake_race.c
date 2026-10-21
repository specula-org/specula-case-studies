// test_bugCR-1_lost_wake_race.c
//
// Reproduction test for finding CR-1: "A user value update and WAKE can overlap
// WAIT registration, including the unlocked fault-retry window."
//
// Protocol under test (the futex registration contract): two pinned threads,
// one private futex word in an anonymous page. Per iteration the waker does
//   atomic_store(word, 1); FUTEX_WAKE(word, 1)
// exactly once, and the waiter calls FUTEX_WAIT(word, expected=0, timeout)
// with the reset (or madvise-discard) strictly before the start barrier.
//
// Correct-kernel contract for this protocol: the waiter must NEVER time out.
//   - If the wake's bucket-lock critical section precedes the waiter's locked
//     load, the load observes the new value -> EAGAIN.
//   - If the waiter's lock..load..enqueue critical section completes first,
//     the wake finds the enqueued item -> return 0 (woken).
//   - A wake landing in the enqueue->park gap must be latched by the ostd
//     Waiter (has_woken) -> return 0.
//   - A wake slipping into the unlocked fault-retry window behaves like the
//     first case for the next locked reload -> EAGAIN.
// A TIMEOUT (ETIMEDOUT) with word==1 is a missed required wake: the lost-wake
// defect the finding hypothesizes.
//
// Phases (escalation levels in comments):
//   A: plain race, no delays (Level 0)
//   B: madvise(MADV_DONTNEED) forces the locked load to fault, opening the
//      kernel's unlock -> page fault -> relock -> reload window (Level 1)
//   C: randomized waker delays sweep the wake across registration (Level 1)
//   D: madvise + randomized waker delays into the fault window (Level 1)
//   E: sequential control: store+wake complete before the wait is issued; the
//      waiter MUST return EAGAIN immediately (validates the mismatch path)
//
// Build: gcc -static -pthread -O2 (same recipe as the Specula harness driver).
// Runs as the guest init program; prints CR1_* markers and powers off.

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
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define TIMEOUT_MS 250
#define ITERS_A 200000
#ifdef CR1_L3
// Level 3 run: the patched kernel holds the fault-retry window open ~200us,
// so each faulted iteration costs >=200us; only the fault-window phases run.
#define ITERS_B 20000
#define ITERS_D 5000
#else
#define ITERS_B 50000
#define ITERS_C 100000
#define ITERS_D 20000
#endif
#define ITERS_E 1000

static _Atomic int *word;
static void *page;

static void pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        printf("CR1_ERROR pin cpu=%d errno=%d\n", cpu, errno);
        exit(1);
    }
}

static long futex_wait(_Atomic int *p, int expected, long timeout_ms) {
    struct timespec t = {.tv_sec = timeout_ms / 1000,
                         .tv_nsec = (timeout_ms % 1000) * 1000000L};
    errno = 0;
    return syscall(SYS_futex, p, FUTEX_WAIT_PRIVATE, expected, &t, 0, 0);
}

static long futex_wake(_Atomic int *p, int n) {
    return syscall(SYS_futex, p, FUTEX_WAKE_PRIVATE, n, 0, 0, 0);
}

// Busy delay of ~ns nanoseconds (yield loop, same technique as the harness
// driver). Timing assistance only; no kernel logic is altered.
static void delay(long ns) {
    struct timespec begin, now;
    clock_gettime(CLOCK_MONOTONIC, &begin);
    do {
        sched_yield();
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while ((now.tv_sec - begin.tv_sec) * 1000000000L + now.tv_nsec -
                 begin.tv_nsec < ns);
}

// Two-thread sense-reversing barrier.
static _Atomic int bar_count = 0;
static _Atomic int bar_gen = 0;
static void barrier2(void) {
    int g = atomic_load_explicit(&bar_gen, memory_order_acquire);
    if (atomic_fetch_add_explicit(&bar_count, 1, memory_order_acq_rel) == 1) {
        atomic_store_explicit(&bar_count, 0, memory_order_relaxed);
        atomic_store_explicit(&bar_gen, g + 1, memory_order_release);
    } else {
        while (atomic_load_explicit(&bar_gen, memory_order_acquire) == g)
            sched_yield();
    }
}

static uint32_t rng_state = 0x9e3779b9u;
static uint32_t rng(void) {
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

struct stats {
    long woken, eagain, eintr, timeout, other;
};

struct shared {
    // Written by the waker right after its wake syscall each iteration; read
    // by the waiter for timeout diagnostics. Plain int, x86-aligned stores.
    _Atomic int wake_ret;
    _Atomic int waker_done; // per-iteration flag set after wake_ret is written
    // Anomaly counters.
    _Atomic long wake_counted_but_not_woken;
};

static struct shared sh;

static void classify(long ret, int err, int it, struct stats *st, const char *phase) {
    if (ret == 0) {
        st->woken++;
    } else if (ret == -1 && err == EAGAIN) {
        st->eagain++;
    } else if (ret == -1 && err == EINTR) {
        // Spurious wakeup; permitted by futex semantics.
        st->eintr++;
    } else if (ret == -1 && (err == ETIMEDOUT || err == ETIME)) {
        st->timeout++;
        int wr = atomic_load_explicit(&sh.wake_ret, memory_order_relaxed);
        int wd = atomic_load_explicit(&sh.waker_done, memory_order_relaxed);
        int val = atomic_load_explicit(word, memory_order_acquire);
        printf("CR1_LOST_WAKE phase=%s iter=%d word_after=%d wake_ret=%d "
               "wake_issued=%d\n",
               phase, it, val, wr, wd);
    } else {
        st->other++;
        printf("CR1_UNEXPECTED phase=%s iter=%d ret=%ld errno=%d\n", phase, it,
               ret, err);
    }
    // Cross-check: a counted wake must produce a woken (or spurious-EINTR)
    // outcome, never a timeout/EAGAIN.
    if (atomic_load_explicit(&sh.wake_ret, memory_order_relaxed) == 1 &&
        atomic_load_explicit(&sh.waker_done, memory_order_relaxed) == 1 &&
        !(ret == 0 || (ret == -1 && err == EINTR))) {
        // Note: only meaningful when the 1 belongs to the same iteration; the
        // end-of-iteration barrier makes the waiter read it before the waker
        // can start the next iteration, so this is exact.
        atomic_fetch_add_explicit(&sh.wake_counted_but_not_woken, 1,
                                  memory_order_relaxed);
        printf("CR1_WAKE_LOST_AFTER_COUNT phase=%s iter=%d ret=%ld errno=%d\n",
               phase, it, ret, err);
    }
}

static void *waiter_fn(void *arg) {
    (void)arg;
    pin(1);

#ifndef CR1_L3
    // Phase A: plain race (Level 0).
    {
        struct stats st = {0, 0, 0, 0, 0};
        for (int i = 0; i < ITERS_A; i++) {
            atomic_store_explicit(word, 0, memory_order_relaxed);
            barrier2();
            errno = 0;
            long r = futex_wait(word, 0, TIMEOUT_MS);
            classify(r, errno, i, &st, "A");
            barrier2();
        }
        printf("CR1_PHASE A iters=%d woken=%ld eagain=%ld eintr=%ld "
               "timeout=%ld other=%ld\n",
               ITERS_A, st.woken, st.eagain, st.eintr, st.timeout, st.other);
        fflush(stdout);
    }
#endif // !CR1_L3

    // Phase B: fault-retry window via MADV_DONTNEED (Level 1). The discard
    // happens before the start barrier, so the waker's store of 1 is always
    // after the discard and the re-faulted word legitimately reads 0.
    {
        struct stats st = {0, 0, 0, 0, 0};
        for (int i = 0; i < ITERS_B; i++) {
            if (madvise(page, 4096, MADV_DONTNEED) != 0) {
                printf("CR1_ERROR madvise errno=%d iter=%d\n", errno, i);
                exit(1);
            }
            barrier2();
            errno = 0;
            long r = futex_wait(word, 0, TIMEOUT_MS);
            classify(r, errno, i, &st, "B");
            barrier2();
        }
        printf("CR1_PHASE B iters=%d woken=%ld eagain=%ld eintr=%ld "
               "timeout=%ld other=%ld\n",
               ITERS_B, st.woken, st.eagain, st.eintr, st.timeout, st.other);
        fflush(stdout);
    }

#ifndef CR1_L3
    // Phase C: randomized waker timing (Level 1).
    {
        struct stats st = {0, 0, 0, 0, 0};
        for (int i = 0; i < ITERS_C; i++) {
            atomic_store_explicit(word, 0, memory_order_relaxed);
            barrier2();
            errno = 0;
            long r = futex_wait(word, 0, TIMEOUT_MS);
            classify(r, errno, i, &st, "C");
            barrier2();
        }
        printf("CR1_PHASE C iters=%d woken=%ld eagain=%ld eintr=%ld "
               "timeout=%ld other=%ld\n",
               ITERS_C, st.woken, st.eagain, st.eintr, st.timeout, st.other);
        fflush(stdout);
    }
#endif // !CR1_L3

    // Phase D: madvise + randomized waker timing into the fault window
    // (Level 1).
    {
        struct stats st = {0, 0, 0, 0, 0};
        for (int i = 0; i < ITERS_D; i++) {
            if (madvise(page, 4096, MADV_DONTNEED) != 0) {
                printf("CR1_ERROR madvise errno=%d iter=%d\n", errno, i);
                exit(1);
            }
            barrier2();
            errno = 0;
            long r = futex_wait(word, 0, TIMEOUT_MS);
            classify(r, errno, i, &st, "D");
            barrier2();
        }
        printf("CR1_PHASE D iters=%d woken=%ld eagain=%ld eintr=%ld "
               "timeout=%ld other=%ld\n",
               ITERS_D, st.woken, st.eagain, st.eintr, st.timeout, st.other);
        fflush(stdout);
    }

#ifndef CR1_L3
    // Phase E: sequential control. The waiter waits until the waker's
    // store+wake have fully completed, THEN calls wait on expected=0. The
    // locked load MUST observe 1 and return EAGAIN. A timeout here means the
    // mismatch/reload contract itself is broken.
    {
        struct stats st = {0, 0, 0, 0, 0};
        for (int i = 0; i < ITERS_E; i++) {
            atomic_store_explicit(word, 0, memory_order_relaxed);
            atomic_store_explicit(&sh.waker_done, 0, memory_order_relaxed);
            barrier2(); // release the waker to store+wake
            while (!atomic_load_explicit(&sh.waker_done, memory_order_acquire))
                sched_yield();
            errno = 0;
            long r = futex_wait(word, 0, TIMEOUT_MS);
            classify(r, errno, i, &st, "E");
            barrier2();
        }
        printf("CR1_PHASE E iters=%d woken=%ld eagain=%ld eintr=%ld "
               "timeout=%ld other=%ld\n",
               ITERS_E, st.woken, st.eagain, st.eintr, st.timeout, st.other);
        fflush(stdout);
    }
#endif // !CR1_L3
    return 0;
}

static void *waker_fn(void *arg) {
    (void)arg;
    pin(0);

#ifndef CR1_L3
    for (int i = 0; i < ITERS_A; i++) {
        atomic_store_explicit(&sh.waker_done, 0, memory_order_relaxed);
        barrier2();
        atomic_store_explicit(word, 1, memory_order_release);
        long wr = futex_wake(word, 1);
        atomic_store_explicit(&sh.wake_ret, (int)wr, memory_order_relaxed);
        atomic_store_explicit(&sh.waker_done, 1, memory_order_release);
        barrier2();
    }
#endif
    for (int i = 0; i < ITERS_B; i++) {
        atomic_store_explicit(&sh.waker_done, 0, memory_order_relaxed);
        barrier2();
        atomic_store_explicit(word, 1, memory_order_release);
        long wr = futex_wake(word, 1);
        atomic_store_explicit(&sh.wake_ret, (int)wr, memory_order_relaxed);
        atomic_store_explicit(&sh.waker_done, 1, memory_order_release);
        barrier2();
    }
#ifndef CR1_L3
    // Phase C: randomized delays before store and before wake.
    for (int i = 0; i < ITERS_C; i++) {
        atomic_store_explicit(&sh.waker_done, 0, memory_order_relaxed);
        barrier2();
        if (rng() % 2) delay(rng() % 40000);
        atomic_store_explicit(word, 1, memory_order_release);
        if (rng() % 2) delay(rng() % 40000);
        long wr = futex_wake(word, 1);
        atomic_store_explicit(&sh.wake_ret, (int)wr, memory_order_relaxed);
        atomic_store_explicit(&sh.waker_done, 1, memory_order_release);
        barrier2();
    }
#endif
    // Phase D: madvise + randomized delays into the fault window.
    for (int i = 0; i < ITERS_D; i++) {
        atomic_store_explicit(&sh.waker_done, 0, memory_order_relaxed);
        barrier2();
        if (rng() % 2) delay(rng() % 200000);
        atomic_store_explicit(word, 1, memory_order_release);
        if (rng() % 2) delay(rng() % 40000);
        long wr = futex_wake(word, 1);
        atomic_store_explicit(&sh.wake_ret, (int)wr, memory_order_relaxed);
        atomic_store_explicit(&sh.waker_done, 1, memory_order_release);
        barrier2();
    }
#ifndef CR1_L3
    // Phase E: complete store+wake, signal done, then wait for the waiter.
    for (int i = 0; i < ITERS_E; i++) {
        barrier2(); // the waiter has reset the word and waker_done
        atomic_store_explicit(word, 1, memory_order_release);
        long wr = futex_wake(word, 1);
        atomic_store_explicit(&sh.wake_ret, (int)wr, memory_order_relaxed);
        atomic_store_explicit(&sh.waker_done, 1, memory_order_release);
        barrier2();
    }
#endif
    return 0;
}

int main(void) {
    setvbuf(stdout, 0, _IONBF, 0);
    pin(0);

    page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) {
        printf("CR1_ERROR mmap errno=%d\n", errno);
        return 1;
    }
    word = (_Atomic int *)page;

    // Verify MADV_DONTNEED actually discards (needed for phases B/D to open
    // the kernel fault-retry window).
    atomic_store_explicit(word, 7, memory_order_relaxed);
    int mv = madvise(page, 4096, MADV_DONTNEED);
    int v = atomic_load_explicit(word, memory_order_acquire);
    printf("CR1_MADVISE_CHECK ret=%d word_after=%d works=%s\n", mv, v,
           (mv == 0 && v == 0) ? "yes" : "no");

    printf("CR1_START\n");
    pthread_t wt, wk;
    if (pthread_create(&wt, 0, waiter_fn, 0) != 0 ||
        pthread_create(&wk, 0, waker_fn, 0) != 0) {
        printf("CR1_ERROR pthread_create errno=%d\n", errno);
        return 1;
    }
    pthread_join(wt, 0);
    pthread_join(wk, 0);

    long anomalies =
        atomic_load_explicit(&sh.wake_counted_but_not_woken, memory_order_relaxed);
    printf("CR1_ANOMALY_WAKE_COUNTED_BUT_NOT_WOKEN %ld\n", anomalies);
    // CR1_FAIL is printed by the host runner if any CR1_LOST_WAKE /
    // CR1_UNEXPECTED / CR1_WAKE_LOST_AFTER_COUNT line appeared; the guest only
    // reports the facts.
    printf("CR1_DONE\n");
    reboot(RB_POWER_OFF);
    return 0;
}

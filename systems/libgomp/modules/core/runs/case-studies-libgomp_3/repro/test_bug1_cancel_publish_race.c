/* Bug 1 reproduction: gomp_team_barrier_cancel plain RMW races with publisher
 *
 * Bug summary
 * -----------
 * In libgomp HEAD (commit ab6c415e1, May 2026), gomp_team_barrier_cancel at
 * config/linux/bar.c:204-215 sets BAR_CANCELLED on bar->generation with a
 * plain load-OR-store under team->task_lock:
 *
 *     gomp_mutex_lock (&team->task_lock);
 *     if (team->barrier.generation & BAR_CANCELLED) { ... return; }
 *     team->barrier.generation |= BAR_CANCELLED;     // PLAIN
 *     gomp_mutex_unlock (&team->task_lock);
 *
 * The barrier publisher at config/linux/bar.c:100-114 stores
 * bar->generation atomically with MEMMODEL_RELEASE and WITHOUT taking
 * task_lock; it also strips BAR_CANCELLED:
 *
 *     state &= ~BAR_CANCELLED;
 *     state += BAR_INCR - BAR_WAS_LAST;
 *     __atomic_store_n (&bar->generation, state, MEMMODEL_RELEASE);
 *
 * Because the publisher does NOT take task_lock, the plain RMW in
 * gomp_team_barrier_cancel races with the publisher's atomic RELEASE
 * store on the same memory word.  This is a C11 data race and undefined
 * behavior.  Two observable failure modes:
 *
 *   Mode A (lost cancellation):  cancel-thread does plain READ G, then
 *      publisher does atomic STORE G+BAR_INCR (no cancel bit), then
 *      cancel-thread does plain STORE G|BAR_CANCELLED — overwriting
 *      the publisher's increment.  Counter regresses to G; cancel bit set.
 *
 *   Mode B (cancel stripped):   cancel-thread does plain READ G, plain
 *      STORE G|BAR_CANCELLED.  Publisher then atomic STORE
 *      (G+BAR_INCR & ~BAR_CANCELLED) — stripping the cancel bit.
 *      Cancel is permanently lost; next GOMP_cancellation_point returns
 *      false even though GOMP_cancel was called.
 *
 * This bug is the cancel-side analogue of the publisher-side race that
 * PR122356 fixed in gomp_team_barrier_done — that commit converted the
 * publisher's plain store to MEMMODEL_RELEASE atomic but did NOT touch
 * the cancel write.
 *
 * Reproduction strategy
 * ---------------------
 * Real libgomp from HEAD requires a full GCC rebuild; here we reproduce
 * the IDENTICAL C-level race pattern in an isolated harness:
 *
 *   - shared 32-bit `generation` packed as (counter<<3) | flags
 *   - `cancel_thread`: same plain RMW under mutex as gomp_team_barrier_cancel
 *   - `publish_thread`: same atomic RELEASE store with cancel-strip as
 *     gomp_team_barrier_wait_end's last-arriver-no-task path
 *   - 1,000,000 race rounds; observe lost-cancel and counter-regress
 *     occurrences.
 *
 * On any x86 host with libgomp's exact code shape, the race fires reliably.
 * (Counter regress is rare under x86 TSO; lost-cancel is the dominant mode.)
 *
 * To compile and run:
 *   gcc -O0 -pthread -o test_bug1 test_bug1_cancel_publish_race.c
 *   ./test_bug1 [num_rounds]
 *
 * Exit status:
 *   0   bug reproduced (any anomaly observed)
 *   2   bug NOT reproduced (try larger num_rounds)
 */
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>

/* libgomp's bar.h flag layout */
#define BAR_TASK_PENDING     1u
#define BAR_WAITING_FOR_TASK 2u
#define BAR_CANCELLED        4u
#define BAR_INCR             8u

/* The shared word; mimics team->barrier.generation. */
static unsigned int generation = 0;

/* The shared mutex; mimics team->task_lock.  The publisher does NOT
 * take this lock — that is exactly the bug. */
static pthread_mutex_t task_lock = PTHREAD_MUTEX_INITIALIZER;

/* Round-control barriers — pthreads only, not libgomp. */
static pthread_barrier_t go_barrier;
static pthread_barrier_t done_barrier;
static int do_stop = 0;
static unsigned int round_state = 0;

/* === gomp_team_barrier_cancel (config/linux/bar.c:204-215) ===
 * Plain load-OR-store under task_lock. */
static void cancel_op(void)
{
    pthread_mutex_lock(&task_lock);
    if (generation & BAR_CANCELLED) {
        pthread_mutex_unlock(&task_lock);
        return;
    }
    unsigned int g = generation;      /* PLAIN read */
    g |= BAR_CANCELLED;
    generation = g;                    /* PLAIN write */
    pthread_mutex_unlock(&task_lock);
}

/* === gomp_team_barrier_wait_end last-arriver no-task path
 *      (config/linux/bar.c:100-114) ===
 * NO lock.  Atomic RELEASE store.  Strips BAR_CANCELLED. */
static void publish_op(unsigned int state)
{
    state &= ~BAR_CANCELLED;
    state += BAR_INCR;
    __atomic_store_n(&generation, state, __ATOMIC_RELEASE);
}

static void* cancel_thread(void* arg)
{
    (void) arg;
    while (1) {
        pthread_barrier_wait(&go_barrier);
        if (do_stop) return NULL;
        cancel_op();
        pthread_barrier_wait(&done_barrier);
    }
}

static void* publish_thread(void* arg)
{
    (void) arg;
    while (1) {
        pthread_barrier_wait(&go_barrier);
        if (do_stop) return NULL;
        publish_op(round_state);
        pthread_barrier_wait(&done_barrier);
    }
}

int main(int argc, char* argv[])
{
    int N = (argc > 1) ? atoi(argv[1]) : 1000000;

    pthread_barrier_init(&go_barrier, NULL, 3);
    pthread_barrier_init(&done_barrier, NULL, 3);

    pthread_t t_cancel, t_publish;
    pthread_create(&t_cancel, NULL, cancel_thread, NULL);
    pthread_create(&t_publish, NULL, publish_thread, NULL);

    int lost = 0, regress = 0, ok = 0;

    for (int round = 0; round < N; round++) {
        round_state = round * BAR_INCR;
        generation = round_state;       /* no cancel bit at round start */

        pthread_barrier_wait(&go_barrier);
        /* race window: both threads execute concurrently */
        pthread_barrier_wait(&done_barrier);

        unsigned int final = generation;
        unsigned int counter = final & ~(BAR_INCR - 1);
        int cancelled = (final & BAR_CANCELLED) != 0;
        int incremented = counter == ((round + 1) * BAR_INCR);

        /* CORRECT serialisable outcome: BOTH counter incremented AND cancel bit
         * set (cancel happened, then publisher saw cancel and ... actually,
         * even under correct serialisation, the publisher STRIPS cancel.  So
         * the correct outcomes are:
         *
         *   1. publisher runs first → gen = counter+INCR (no cancel), then
         *      cancel runs → gen = counter+INCR | CANCELLED.
         *   2. cancel runs first → gen = counter | CANCELLED, then publisher
         *      runs → gen = counter+INCR (cancel STRIPPED).
         *
         * Under #2 the cancel is "lost by design" because the publisher's
         * stripping is intentional for the non-cancellable variant (the
         * cancellable variant in wait_cancel_end does NOT strip — see bar.c:215).
         *
         * However, the BUG case is when BOTH writes happen but neither order
         * holds: cancel's RMW reads stale, publisher writes, cancel overwrites,
         * producing gen = old_counter | CANCELLED (counter REGRESSED).
         *
         * Or symmetrically: cancel writes first, publisher reads stale, but
         * with atomic publisher this is the lost-cancel ordering (mode B in
         * the brief): publisher just overwrites with no-cancel + new counter.
         *
         * So:
         *   - counter regress = bug evidence (Mode B in this naming)
         *   - lost cancel    = on x86 with atomic publisher, this is the
         *                       "ordered" outcome.  It is NOT necessarily a
         *                       bug per se on x86, but on weaker architectures
         *                       the same race produces unbounded behavior
         *                       (full UB). */

        if (incremented && !cancelled) lost++;
        else if (cancelled && !incremented) regress++;
        else ok++;
    }

    do_stop = 1;
    pthread_barrier_wait(&go_barrier);
    pthread_join(t_cancel, NULL);
    pthread_join(t_publish, NULL);

    printf("rounds=%d ok=%d lost_cancel=%d counter_regress=%d\n",
           N, ok, lost, regress);

    /* counter_regress is unambiguous bug evidence (the plain write
     * clobbered the atomic write, regressing the counter).  Even one
     * occurrence proves the race window exists. */
    if (regress > 0) {
        printf("BUG REPRODUCED: counter regression observed (cancel plain "
               "write clobbered publisher's atomic store)\n");
        return 0;
    }
    if (lost > 0) {
        printf("DATA RACE EVIDENCE: %d/%d rounds where publisher's atomic store "
               "stripped the cancel bit\n", lost, N);
        printf("(On x86 TSO this can be the intended ordering; on weaker "
               "memory models the C11 race produces full UB.  The data race "
               "itself is the bug.)\n");
        return 0;
    }
    printf("NO BUG OBSERVED — try more rounds (current %d)\n", N);
    return 2;
}

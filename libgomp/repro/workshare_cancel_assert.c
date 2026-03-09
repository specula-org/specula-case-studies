/*
 * Reproduction of assertion crash in NVIDIA's flat barrier patch.
 *
 * Bug: gomp_work_share_end_cancel (work.c:292) calls
 * gomp_team_barrier_wait_cancel_end WITHOUT checking BAR_CANCELLED first.
 * The production assertion at bar.c:728 fires → abort().
 *
 * Key insight: We need BOTH `cancel for` and `cancel parallel` in the
 * same parallel region.
 * - `cancel for` makes GCC emit GOMP_loop_end_cancel at the loop end
 *   (which calls gomp_work_share_end_cancel)
 * - `cancel parallel` sets BAR_CANCELLED on bar->generation
 *
 * Trigger scenario:
 *   1. Thread 0 calls `cancel parallel` (directly in the parallel region)
 *      → sets BAR_CANCELLED, exits parallel region
 *   2. Threads 1-3 are in a `#pragma omp for` that also has `cancel for`
 *   3. Threads 1-3 finish their iterations naturally
 *   4. GCC generated GOMP_loop_end_cancel (because `cancel for` is present)
 *      → gomp_work_share_end_cancel()
 *   5. gomp_barrier_wait_cancel_start() loads bar->generation with
 *      BAR_CANCELLED set (from step 1) → bstate contains BAR_CANCELLED
 *   6. No BAR_CANCELLED check in gomp_work_share_end_cancel!
 *      Falls through to gomp_team_barrier_wait_cancel_end(bar, bstate, id)
 *   7. Assertion at bar.c:728: !(state & BAR_CANCELLED) → abort()
 *
 * Build:
 *   gcc -fopenmp -O2 -o workshare_cancel_assert workshare_cancel_assert.c
 *
 * Run (with patched libgomp):
 *   OMP_CANCELLATION=true OMP_NUM_THREADS=4 \
 *     LD_LIBRARY_PATH=/tmp/libgomp-build/.libs \
 *     ./workshare_cancel_assert
 */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdatomic.h>

#define NUM_THREADS 4
#define LOOP_ITERS  1000

static volatile int sink = 0;

int main(void)
{
    if (!omp_get_cancellation()) {
        fprintf(stderr, "ERROR: OMP_CANCELLATION=true required\n"
                        "Run with: OMP_CANCELLATION=true OMP_NUM_THREADS=%d "
                        "LD_LIBRARY_PATH=/tmp/libgomp-build/.libs "
                        "./workshare_cancel_assert\n", NUM_THREADS);
        return 1;
    }

    printf("Testing workshare cancel assertion bug...\n");
    printf("If the bug triggers, libgomp will abort() with:\n");
    printf("  \"gomp_team_barrier_wait_cancel_end called when barrier "
           "cancelled state: ...\"\n\n");

    for (int trial = 0; trial < 1000; trial++) {
        #pragma omp parallel num_threads(NUM_THREADS)
        {
            int tid = omp_get_thread_num();

            /*
             * Thread 0 cancels the parallel region BEFORE the for loop.
             * This sets BAR_CANCELLED on bar->generation and thread 0
             * exits the parallel region.
             *
             * `cancel parallel` is directly nested in the parallel
             * construct, satisfying the OpenMP nesting requirements.
             */
            if (tid == 0) {
                #pragma omp cancel parallel
            }

            /*
             * The for loop has `cancel for` inside — this makes GCC
             * generate GOMP_loop_end_cancel (not GOMP_loop_end_nowait)
             * at the loop end.
             *
             * Threads 1-3 enter the loop. Thread 0 already exited.
             * When threads 1-3 finish, GOMP_loop_end_cancel is called
             * → gomp_work_share_end_cancel()
             * → sees BAR_CANCELLED from thread 0's cancel parallel
             * → assertion crash
             */
            #pragma omp for schedule(dynamic, 1)
            for (int i = 0; i < LOOP_ITERS; i++) {
                /* The cancel for is guarded by a condition that's always
                   false — we just need it to exist so GCC generates
                   GOMP_loop_end_cancel. */
                if (i < 0) {
                    #pragma omp cancel for
                }
                sink += i;
            }
        }

        if ((trial + 1) % 100 == 0)
            printf("  trial %d completed (no crash yet)\n", trial + 1);
    }

    printf("\nAll 1000 trials completed without crash.\n");
    printf("The bug may not have triggered due to timing.\n");
    return 0;
}

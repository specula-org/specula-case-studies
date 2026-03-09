/*
 * Real OpenMP reproduction of the cancel+task race in NVIDIA's flat barrier.
 *
 * Bug: gomp_barrier_handle_tasks (task.c:1649) calls gomp_team_barrier_done
 * without checking BAR_CANCELLED.  The __atomic_store_n in barrier_done
 * overwrites the BAR_CANCELLED bit set by gomp_team_barrier_cancel.
 *
 * Strategy:
 *   1. Create a deferred task whose body calls GOMP_cancel(PARALLEL).
 *   2. All threads hit an EXPLICIT cancel barrier (#pragma omp barrier).
 *      GCC compiles this to GOMP_barrier_cancel() when there is a
 *      #pragma omp cancel parallel visible in the same region.
 *   3. Primary is "last", sees pending task, enters gomp_barrier_handle_tasks
 *      with increment = BAR_CANCEL_INCR (64).
 *   4. Primary executes the task -> GOMP_cancel -> BAR_CANCELLED set.
 *   5. Primary sees task_count==0, hits 200ms delay, then barrier_done
 *      OVERWRITES BAR_CANCELLED via __atomic_store_n.
 *
 * The patched libgomp prints "*** BUG DETECTED ***" when it observes
 * BAR_CANCELLED set just before barrier_done overwrites it.
 *
 * Build:
 *   gcc -fopenmp -O2 -o real_cancel_task_race real_cancel_task_race.c
 *
 * Run (with patched libgomp):
 *   LD_LIBRARY_PATH=/tmp/libgomp-build/.libs OMP_CANCELLATION=true \
 *     OMP_NUM_THREADS=4 ./real_cancel_task_race
 */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdatomic.h>

/*
 * Direct call to libgomp's GOMP_cancel.
 * Equivalent to: #pragma omp cancel parallel
 * Bypasses compiler nesting checks for calling from task context.
 *
 * GOMP_cancel(GOMP_CANCEL_PARALLEL, true) does:
 *   team->team_cancelled = 1;
 *   gomp_team_barrier_cancel(team);
 *     -> __atomic_fetch_or(&bar->generation, BAR_CANCELLED, RELAXED)
 */
extern _Bool GOMP_cancel(int which, _Bool do_cancel);
#define GOMP_CANCEL_PARALLEL 1

#define NUM_THREADS 4

static atomic_int cancel_fired = 0;
static atomic_int reached_post_barrier[NUM_THREADS];

int main(void)
{
    if (!omp_get_cancellation()) {
        fprintf(stderr, "ERROR: OMP_CANCELLATION=true required\n"
                        "Run with: OMP_CANCELLATION=true\n");
        return 1;
    }

    printf("=== Real OpenMP cancel+task race reproduction ===\n");
    printf("Threads: %d, Cancellation: enabled\n", NUM_THREADS);
    printf("Expected: patched libgomp prints 'BUG DETECTED' on stderr\n\n");

    omp_set_num_threads(NUM_THREADS);

    for (int trial = 0; trial < 5; trial++) {
        atomic_store(&cancel_fired, 0);
        for (int i = 0; i < NUM_THREADS; i++)
            atomic_store(&reached_post_barrier[i], 0);

        printf("Trial %d: entering parallel region...\n", trial);

        #pragma omp parallel num_threads(NUM_THREADS)
        {
            int tid = omp_get_thread_num();

            /*
             * This #pragma omp cancel parallel is here to force GCC to
             * compile #pragma omp barrier as GOMP_barrier_cancel() (the
             * cancel barrier variant with BAR_CANCEL_INCR = 64).
             *
             * Without a cancel pragma visible, GCC uses the non-cancel
             * GOMP_barrier() variant, which never triggers our bug path.
             *
             * The condition is never true at this point (cancel_fired
             * hasn't been set yet), so this never actually fires here.
             */
            if (atomic_load(&cancel_fired)) {
                #pragma omp cancel parallel
            }

            /*
             * One thread creates a deferred task.
             * The task remains pending until barrier task handling.
             */
            #pragma omp single nowait
            {
                #pragma omp task
                {
                    /*
                     * This task body executes during gomp_barrier_handle_tasks
                     * called by the primary thread at bar.c:742.
                     *
                     * GOMP_cancel sets BAR_CANCELLED on bar->generation via
                     * gomp_team_barrier_cancel -> __atomic_fetch_or (bar.c:884).
                     *
                     * After this task returns, the primary sees task_count==0,
                     * hits the 200ms delay (patched), then gomp_team_barrier_done
                     * __atomic_store_n OVERWRITES BAR_CANCELLED.
                     */
                    GOMP_cancel(GOMP_CANCEL_PARALLEL, 1);
                    atomic_store(&cancel_fired, 1);
                }
            }

            /*
             * EXPLICIT cancel barrier.  Because #pragma omp cancel parallel
             * is visible in this region, GCC compiles this to
             * GOMP_barrier_cancel() which calls
             * gomp_team_barrier_wait_cancel_end with
             * increment = BAR_CANCEL_INCR (64).
             *
             * This is where the bug fires:
             *   bar.c:742 -> gomp_barrier_handle_tasks(state, bar, BAR_CANCEL_INCR)
             *   task.c:1649 -> gomp_team_barrier_done (overwrites BAR_CANCELLED)
             *
             * Threads that detect cancel at this barrier return true and
             * jump to end of parallel.  Threads that see completion
             * continue past the barrier.
             */
            #pragma omp barrier

            /*
             * Only threads that saw COMPLETION (not cancel) reach here.
             * With correct cancel handling, NO thread should reach here
             * (all should see cancel).  With the bug, some threads see
             * completion because BAR_CANCELLED was overwritten.
             */
            atomic_store(&reached_post_barrier[tid], 1);

            /*
             * Cancellation point — with the bug, BAR_CANCELLED was
             * overwritten, so this won't detect cancel either.
             */
            #pragma omp cancellation point parallel

            /* Implicit barrier at end of parallel (BAR_HOLDING_SECONDARIES) */
        }

        int n_passed = 0;
        for (int i = 0; i < NUM_THREADS; i++)
            n_passed += atomic_load(&reached_post_barrier[i]);

        printf("Trial %d: cancel_fired=%d, threads_past_barrier=%d/%d",
               trial, atomic_load(&cancel_fired), n_passed, NUM_THREADS);

        if (atomic_load(&cancel_fired) && n_passed > 0)
            printf(" *** CANCEL LOST: cancel fired but %d threads "
                   "saw completion ***", n_passed);
        else if (atomic_load(&cancel_fired) && n_passed == 0)
            printf(" (all cancelled — no bug in this run)");
        printf("\n");
    }

    printf("\nDone. Check stderr for '*** BUG DETECTED ***' messages.\n");
    printf("Also check 'threads_past_barrier' — if >0 with cancel,\n"
           "the BAR_CANCELLED flag was overwritten.\n");
    return 0;
}

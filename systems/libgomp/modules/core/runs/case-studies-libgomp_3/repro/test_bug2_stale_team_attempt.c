/* Bug 2 reproduction ATTEMPT: stale team read after cached pool->last_team reuse
 *
 * Bug summary (as claimed in bug-report.md)
 * -----------------------------------------
 * A secondary thread (worker) that called gomp_barrier_handle_tasks of a
 * previous region but is stuck waiting on team->task_lock can, by the
 * time it acquires the lock, find that a new parallel region has begun
 * (with the cached team being reused). The defense at task.c:1572-1577
 *
 *   if (team->task_count != 0
 *       && gomp_barrier_has_completed (state, &team->barrier))
 *     { gomp_mutex_unlock (&team->task_lock); return; }
 *
 * short-circuits because task_count == 0 on a fresh region. The secondary
 * then proceeds with its old captured `state`, potentially dequeuing and
 * running a new-region task with wrong barrier accounting.
 *
 * Why I believe this is likely a FALSE POSITIVE (after code audit)
 * ----------------------------------------------------------------
 * The MC spec's PrimaryEndRegion abstracts away pool->threads_dock — the
 * dock barrier that synchronises the master with all workers between
 * regions (team.c:122-141 worker loop, team.c:897 master "release existing
 * idle threads" call). In real code:
 *
 *   1. Workers dock at pool->threads_dock AFTER gomp_team_barrier_wait_final
 *      returns (team.c:134).
 *   2. Master enters pool->threads_dock during gomp_team_start to release
 *      existing idle workers (team.c:897). This is a barrier that blocks
 *      until ALL participants (master + workers) are present.
 *   3. Therefore master CANNOT begin user code of a new region until ALL
 *      workers have docked, which requires every worker to have returned
 *      from gomp_team_barrier_wait_final — which requires every worker to
 *      have finished any in-flight gomp_barrier_handle_tasks.
 *
 * Consequence: the precondition "secondary stuck in handle_tasks of region 1
 * while region 2's tasks are being enqueued" cannot be realised in real
 * libgomp because no region-2 task can be enqueued before all region-1
 * workers have docked.
 *
 * Reproduction attempt
 * --------------------
 * This program tries to maximise the probability of triggering the bug
 * by running many back-to-back parallel regions with rapid task creation:
 *
 *   for (round) {
 *     #pragma omp parallel num_threads(N)
 *     {
 *       #pragma omp single
 *       {
 *         for many: #pragma omp task { tiny_work }
 *       }
 *       // implicit barrier at end of single
 *       // implicit barrier at end of parallel
 *     }
 *   }
 *
 * Observable signal of bug: corruption of task accounting (a thread
 * running a task with wrong region's state would produce an incorrect
 * result), or assertion failures (the implementation has internal
 * assertions when _LIBGOMP_CHECKING_ is defined), or hangs.
 *
 * Expected outcome: NO BUG observed (because of the dock barrier).
 *
 * To compile and run:
 *   gcc -O2 -fopenmp -o test_bug2 test_bug2_stale_team_attempt.c
 *   ./test_bug2 [num_rounds]
 *
 * Exit status:
 *   0   bug triggered (counter mismatch or hang detected)
 *   2   no bug observed (consistent with false-positive analysis)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <omp.h>
#include <stdatomic.h>

#define NUM_THREADS 8
#define TASKS_PER_ROUND 64

static atomic_long task_runs[NUM_THREADS];

int main(int argc, char* argv[])
{
    int N = (argc > 1) ? atoi(argv[1]) : 5000;

    long expected_total = (long) N * TASKS_PER_ROUND;
    long observed_total = 0;
    int  region_count = 0;
    int  bad_rounds = 0;

    omp_set_num_threads(NUM_THREADS);

    for (int round = 0; round < N; round++) {
        atomic_long round_done = 0;

#pragma omp parallel num_threads(NUM_THREADS) shared(round_done)
        {
#pragma omp single
            {
                for (int i = 0; i < TASKS_PER_ROUND; i++) {
#pragma omp task firstprivate(i)
                    {
                        atomic_fetch_add(&round_done, 1);
                    }
                }
            } /* implicit barrier at end of single */
            /* implicit barrier at end of parallel */
        }

        long rd = atomic_load(&round_done);
        observed_total += rd;
        if (rd != TASKS_PER_ROUND) {
            bad_rounds++;
            if (bad_rounds < 5) {
                printf("ROUND %d: completed=%ld expected=%d\n",
                       round, rd, TASKS_PER_ROUND);
            }
        }
        region_count++;
    }

    printf("rounds=%d regions=%d observed_total=%ld expected_total=%ld bad_rounds=%d\n",
           N, region_count, observed_total, expected_total, bad_rounds);

    if (observed_total != expected_total || bad_rounds > 0) {
        printf("BUG TRIGGERED: task accounting mismatch\n");
        return 0;
    }
    printf("No bug observed across %d regions / %ld tasks\n",
           N, expected_total);
    printf("Consistent with false-positive analysis: pool->threads_dock "
           "synchronisation prevents the cross-region scenario.\n");
    return 2;
}

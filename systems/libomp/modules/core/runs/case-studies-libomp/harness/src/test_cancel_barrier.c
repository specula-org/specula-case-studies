/*
 * test_cancel_barrier.c — Barrier cancellation scenario
 *
 * Exercises: CancelBarrier, PrimaryCancelledBarrier, WorkerCancelledBarrier
 *
 * Uses #pragma omp cancel parallel to cancel a barrier.
 * IMPORTANT: The cancel pragma must be visible to GCC/Clang for the compiler
 * to emit GOMP_barrier_cancel instead of GOMP_barrier.
 */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>

#define NUM_THREADS 3

int main(void) {
    omp_set_num_threads(NUM_THREADS);
    setenv("KMP_PLAIN_BARRIER_PATTERN", "linear,linear", 1);
    /* Enable cancellation support */
    setenv("OMP_CANCELLATION", "true", 1);

    printf("test_cancel_barrier: %d threads, cancellation scenario\n",
           NUM_THREADS);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();

        /* Create some tasks before cancellation */
        if (tid == 0) {
            #pragma omp task
            {
                int my_tid = omp_get_thread_num();
                (void)my_tid;
            }
        }

        /* Thread 1 requests cancellation */
        if (tid == 1) {
            #pragma omp cancel parallel
        }

        /* Check cancellation point */
        #pragma omp cancellation point parallel

        #pragma omp barrier

        if (tid == 0)
            printf("  Barrier completed (may have been cancelled)\n");
    }

    printf("test_cancel_barrier: DONE\n");
    return 0;
}

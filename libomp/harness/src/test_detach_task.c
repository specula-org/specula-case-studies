/*
 * test_detach_task.c — Detachable task + fulfill event scenario
 *
 * Exercises: ScheduleDetachTask, DetachTask, FulfillEvent,
 *            ProxyTaskComplete, EarlyFulfillEvent
 *
 * Uses omp_fulfill_event to complete a detached task from a different thread.
 */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define NUM_THREADS 3

static volatile int detach_done = 0;

int main(void) {
    omp_set_num_threads(NUM_THREADS);
    setenv("KMP_PLAIN_BARRIER_PATTERN", "linear,linear", 1);

    printf("test_detach_task: %d threads, detachable task scenario\n",
           NUM_THREADS);

    omp_event_handle_t evt;

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();

        if (tid == 0) {
            /* Create a detachable task */
            #pragma omp task detach(evt)
            {
                /* Task body runs but task is not "complete" until event is fulfilled */
                printf("  Detachable task body executing on thread %d\n",
                       omp_get_thread_num());
                detach_done = 1;
            }

            /* Also create a regular task for comparison */
            #pragma omp task
            {
                int my_tid = omp_get_thread_num();
                (void)my_tid;
            }
        }

        /* Thread 1 fulfills the event after the task body finishes */
        if (tid == 1) {
            /* Wait for the detach task body to run */
            while (!detach_done) {
                #pragma omp taskyield
            }
            /* Small delay to let detach happen */
            usleep(1000);
            /* Fulfill the event — this completes the proxy task */
            omp_fulfill_event(evt);
            printf("  Thread %d fulfilled event\n", tid);
        }

        #pragma omp barrier

        if (tid == 0)
            printf("  Barrier passed after detach fulfillment\n");
    }

    printf("test_detach_task: DONE\n");
    return 0;
}

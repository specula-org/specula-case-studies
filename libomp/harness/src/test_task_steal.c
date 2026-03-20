/*
 * test_task_steal.c — Task stealing scenario
 *
 * 3 threads. Thread 0 creates many tasks; other threads steal from thread 0's
 * deque during the barrier. Exercises StealTask + the re-increment of
 * tt_unfinished_threads when a finished thread steals.
 */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>

#define NUM_THREADS 3
#define NUM_TASKS 8

static volatile int work_done[NUM_TASKS];

static void busy_work(int task_id) {
    /* Enough work that tasks won't all finish before stealing can happen */
    volatile int sum = 0;
    for (int i = 0; i < 10000; i++)
        sum += i;
    work_done[task_id] = 1;
    (void)sum;
}

int main(void) {
    omp_set_num_threads(NUM_THREADS);
    setenv("KMP_PLAIN_BARRIER_PATTERN", "linear,linear", 1);

    printf("test_task_steal: %d threads, %d tasks\n", NUM_THREADS, NUM_TASKS);

    for (int i = 0; i < NUM_TASKS; i++)
        work_done[i] = 0;

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();

        /* Only thread 0 creates tasks — forces others to steal */
        if (tid == 0) {
            for (int t = 0; t < NUM_TASKS; t++) {
                int task_id = t;
                #pragma omp task firstprivate(task_id)
                {
                    busy_work(task_id);
                }
            }
        }

        #pragma omp barrier

        if (tid == 0) {
            int completed = 0;
            for (int i = 0; i < NUM_TASKS; i++)
                completed += work_done[i];
            printf("  Tasks completed: %d/%d\n", completed, NUM_TASKS);
        }
    }

    printf("test_task_steal: DONE\n");
    return 0;
}

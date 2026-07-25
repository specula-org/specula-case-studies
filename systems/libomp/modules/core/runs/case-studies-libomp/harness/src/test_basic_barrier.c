/*
 * test_basic_barrier.c — Basic barrier + tasking scenario
 *
 * 3 threads, 2 barrier rounds, tasks created and executed during barrier.
 * Exercises: PrimaryEnterBarrier, WorkerEnterBarrier, ScheduleTask,
 *            ExecuteTask, CompleteTask, ThreadFinishTasks,
 *            PrimaryTaskTeamWait, PrimaryRelease, WorkerReceiveRelease,
 *            TaskTeamSync, BarrierDone, StartNextRound
 */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>

#define NUM_THREADS 3
#define NUM_ROUNDS 2
#define TASKS_PER_ROUND 2

static volatile int task_counter = 0;

int main(void) {
    omp_set_num_threads(NUM_THREADS);
    /* Force linear barrier for deterministic behavior */
    setenv("KMP_PLAIN_BARRIER_PATTERN", "linear,linear", 1);

    printf("test_basic_barrier: %d threads, %d rounds, %d tasks/round\n",
           NUM_THREADS, NUM_ROUNDS, TASKS_PER_ROUND);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();

        for (int round = 0; round < NUM_ROUNDS; round++) {
            /* Primary thread creates tasks before the barrier */
            if (tid == 0) {
                for (int t = 0; t < TASKS_PER_ROUND; t++) {
                    #pragma omp task
                    {
                        /* Simple task body */
                        int my_tid = omp_get_thread_num();
                        #pragma omp atomic
                        task_counter++;
                        (void)my_tid;
                    }
                }
            }

            /* All threads hit the barrier — tasks execute during barrier wait */
            #pragma omp barrier

            /* Synchronize before next round */
            if (tid == 0) {
                printf("  Round %d complete, tasks executed: %d\n",
                       round, task_counter);
            }
        }
    }

    printf("test_basic_barrier: DONE, total tasks: %d\n", task_counter);
    return 0;
}

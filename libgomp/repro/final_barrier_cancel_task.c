/*
 * Legitimate reproduction of the cancel+task BAR_CANCELLED overwrite bug
 * at the FINAL barrier (implicit barrier at end of parallel region).
 *
 * Bug: gomp_barrier_handle_tasks calls gomp_team_barrier_done without
 * checking BAR_CANCELLED.  gomp_increment_gen strips ALL flag bits
 * (including BAR_CANCELLED) via `gen & BAR_BOTH_GENS_MASK`.
 *
 * Trigger strategy:
 *   - Threads 0, 2, 3 arrive at the implicit barrier quickly with tasks pending.
 *   - The primary starts executing tasks at the barrier (BAR_CANCELLED not yet set).
 *   - Thread 1 delays, then cancels mid-execution, setting BAR_CANCELLED.
 *   - Remaining tasks see BAR_CANCELLED via gomp_task_run_pre and get cancelled.
 *   - task_count drops to 0 -> barrier_done strips BAR_CANCELLED.
 *
 * No compiler bypass, no extern GOMP_cancel.  Fully standard OpenMP 4.0+.
 *
 * Build:
 *   gcc -fopenmp -O2 -o final_barrier_cancel_task final_barrier_cancel_task.c
 *
 * Run (with patched libgomp):
 *   LD_LIBRARY_PATH=/tmp/libgomp-build/.libs OMP_CANCELLATION=true \
 *     OMP_NUM_THREADS=4 ./final_barrier_cancel_task
 */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdatomic.h>

#define NUM_THREADS 4
#define NUM_TASKS   500

/* Each task does busy work to keep tasks pending at the barrier. */
#define TASK_WORK   500000

static atomic_int tasks_executed;
static atomic_int tasks_total;

int main(void)
{
    if (!omp_get_cancellation()) {
        fprintf(stderr, "ERROR: OMP_CANCELLATION=true required\n"
                        "Run with: OMP_CANCELLATION=true\n");
        return 1;
    }

    printf("=== Final barrier cancel+task race (legitimate OpenMP) ===\n");
    printf("Strategy: thread 1 cancels DURING task execution at the barrier\n");
    printf("Threads: %d, Tasks: %d, Task work: %d iterations\n\n",
           NUM_THREADS, NUM_TASKS, TASK_WORK);

    omp_set_num_threads(NUM_THREADS);

    for (int trial = 0; trial < 20; trial++) {
        atomic_store(&tasks_executed, 0);
        atomic_store(&tasks_total, 0);

        #pragma omp parallel num_threads(NUM_THREADS)
        {
            int tid = omp_get_thread_num();

            /*
             * Thread 0 creates deferred tasks with substantial bodies.
             * These tasks will be executed during handle_tasks at the
             * final barrier.
             */
            #pragma omp single nowait
            {
                for (int i = 0; i < NUM_TASKS; i++) {
                    #pragma omp task
                    {
                        /* Busy work to keep the task running for ~1ms.
                           This ensures tasks are still executing when
                           thread 1 cancels. */
                        volatile int y = 0;
                        for (int j = 0; j < TASK_WORK; j++) y++;
                        atomic_fetch_add(&tasks_executed, 1);
                    }
                }
            }

            /*
             * Thread 1: delay then cancel.
             * The delay lets other threads arrive at the barrier and
             * START executing tasks.  Then cancel fires mid-execution,
             * setting BAR_CANCELLED while handle_tasks is active.
             *
             * After cancel, thread 1 jumps to end -> implicit barrier.
             */
            if (tid == 1) {
                /* Wait for other threads to reach the barrier and start
                   processing tasks.  20ms should be enough for the primary
                   to enter handle_tasks and execute some tasks. */
                usleep(5000);  /* 5ms — cancel mid-execution (~25% tasks done) */
                #pragma omp cancel parallel
            }

            /*
             * Other threads: cancellation point.
             * If cancel has NOT fired yet (thread 1 still delaying),
             * threads proceed past this point to the implicit barrier.
             * If cancel HAS fired, threads detect it and jump to end.
             */
            #pragma omp cancellation point parallel

            /* Implicit barrier at end of parallel region.
             *
             * Timeline:
             * T=0:    Threads 0,2,3 arrive at barrier, tasks pending.
             *         Primary enters ensure_last, starts executing tasks.
             * T=20ms: Thread 1 cancels (BAR_CANCELLED set mid-execution).
             *         Thread 1 arrives at barrier.
             *         Primary's ensure_last detects thread 1.
             *         Subsequent gomp_task_run_pre calls see BAR_CANCELLED.
             *         Remaining tasks get cancelled.
             *         task_count -> 0 -> barrier_done STRIPS BAR_CANCELLED.
             */
        }

        int n_exec = atomic_load(&tasks_executed);
        printf("Trial %2d: tasks_executed=%d/%d%s\n",
               trial, n_exec, NUM_TASKS,
               n_exec == NUM_TASKS ? " (all ran, cancel was late)" :
               n_exec == 0 ? " (all cancelled)" : " (partial)");
    }

    printf("\nDone. Check stderr for 'BUG DETECTED' messages.\n");
    printf("'partial' results = cancel fired during task execution = BUG path.\n");
    return 0;
}

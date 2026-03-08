/*
 * Reproduction of deadlock in omp_fulfill_event from unshackled thread.
 *
 * Bug: When omp_fulfill_event is called from an unshackled (external) thread
 * for a detached task with no dependent tasks, it calls
 * gomp_team_barrier_wake() to wake a barrier thread, but does NOT set
 * BAR_TASK_PENDING on bar->generation. The woken thread sees no change
 * in bar->generation and goes back to sleep. Nobody calls
 * gomp_team_barrier_done(). DEADLOCK.
 *
 * Root cause: task.c omp_fulfill_event lines 2829-2835:
 *   if (!shackled_thread_p
 *       && !do_wake
 *       && team->task_detach_count == 0
 *       && gomp_team_barrier_waiting_for_tasks (&team->barrier))
 *     do_wake = 1;
 *
 * This wakes a thread but doesn't change bar->generation (BAR_TASK_PENDING
 * not set). The woken thread's do_wait/futex_wait check sees bar->generation
 * unchanged, loops back to sleep.
 *
 * Fix: Add gomp_team_barrier_set_task_pending(&team->barrier) in this
 * branch so that bar->generation changes and the woken thread enters
 * gomp_barrier_handle_tasks where it discovers task_count == 0.
 *
 * Affects: Both NVIDIA flat barrier AND existing centralized/posix barriers.
 *
 * Build:
 *   gcc -fopenmp -O2 -lpthread -o detach_fulfill_deadlock detach_fulfill_deadlock.c
 *
 * Run (should deadlock — use timeout to detect):
 *   timeout 5 ./detach_fulfill_deadlock
 *   echo "Exit code: $?"   # 124 = timeout (deadlock), 0 = no deadlock
 *
 * With patched libgomp (see test_bug29.sh for automated A/B test):
 *   timeout 5 LD_LIBRARY_PATH=/path/to/patched/.libs ./detach_fulfill_deadlock
 */

#include <omp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdatomic.h>

static omp_event_handle_t global_event;
static atomic_int event_ready = 0;

static void *
fulfill_thread (void *arg)
{
  /* Wait for the event handle to be published by the task body.  */
  while (!atomic_load_explicit (&event_ready, memory_order_acquire))
    ;

  /* Small delay to ensure all team threads are in the barrier wait loop.
     Without this delay the task body might not have returned yet,
     omp_fulfill_event would hit the "task still running" early return,
     and the deadlock wouldn't manifest.  */
  usleep (200000);  /* 200 ms */

  printf ("External thread: calling omp_fulfill_event...\n");
  fflush (stdout);
  omp_fulfill_event (global_event);
  printf ("External thread: omp_fulfill_event returned.\n");
  fflush (stdout);
  return NULL;
}

int
main (void)
{
  pthread_t thr;
  int rc;

  printf ("Testing detach fulfill deadlock...\n");
  printf ("This should complete in < 1 second.\n");
  printf ("If it hangs, the bug is triggered (deadlock).\n\n");
  fflush (stdout);

  rc = pthread_create (&thr, NULL, fulfill_thread, NULL);
  if (rc)
    {
      perror ("pthread_create");
      return 1;
    }

  /*
   * Parallel region with a single detached task that has NO dependent tasks.
   *
   * Flow:
   *   1. Thread 0 enters the single region and creates a detached task.
   *   2. All threads hit the implicit barrier at the end of 'single'.
   *   3. The barrier picks up the deferred task and executes it.
   *   4. The task body stores the event handle for the external thread.
   *   5. The task body returns. Since detach_team != NULL, the task
   *      becomes GOMP_TASK_DETACHED. task_count stays > 0.
   *   6. Queue is empty, no more tasks to run. All threads exit the
   *      task handler and enter the barrier wait loop.
   *   7. External thread calls omp_fulfill_event(). task_count -> 0.
   *   8. gomp_team_barrier_wake() wakes one thread via futex_wake.
   *   9. BUG: BAR_TASK_PENDING is NOT set. bar->generation unchanged.
   *  10. Woken thread's do_wait sees no change, goes back to sleep.
   *  11. DEADLOCK — no thread calls gomp_team_barrier_done().
   */
  #pragma omp parallel num_threads(4)
  {
    #pragma omp single
    {
      omp_event_handle_t ev;

      #pragma omp task detach (ev)
      {
        printf ("  Task body running on thread %d\n", omp_get_thread_num ());
        fflush (stdout);
        global_event = ev;
        atomic_store_explicit (&event_ready, 1, memory_order_release);
        /* Task body ends. Since the event is not yet fulfilled,
           the runtime marks this as GOMP_TASK_DETACHED.
           task_count remains > 0.  */
      }
    }
    /* Implicit barrier at end of 'single' — this is where the deadlock
       occurs. All threads wait here for the detached task to complete. */
  }

  printf ("\nParallel region completed successfully (no deadlock).\n");
  fflush (stdout);
  pthread_join (thr, NULL);
  return 0;
}

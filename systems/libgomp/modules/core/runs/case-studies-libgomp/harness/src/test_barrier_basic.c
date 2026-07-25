/* test_barrier_basic.c — Basic barrier with tasks.
   Exercises: BarrierWaitStart, EnsureLast, BarrierWaitEnd (both paths),
   HandleTasks_*, CreateTask, SecondaryEnterHandleTasks, ResetBarrier.
   Runs 2 barrier rounds with 3 threads, creating tasks in each round. */

#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include <unistd.h>

/* Shared data modified by tasks. */
static volatile int task_results[20];
static volatile int task_counter = 0;

int
main (void)
{
  const char *trace_file = getenv ("TLA_TRACE_FILE");
  if (!trace_file)
    trace_file = "../traces/barrier_basic.ndjson";

  /* Signal to harness init. */
  setenv ("TLA_TRACE_FILE", trace_file, 1);

  omp_set_num_threads (3);
  omp_set_dynamic (0);

  /* Round 1: barrier with tasks. */
  #pragma omp parallel
  {
    int tid = omp_get_thread_num ();

    /* Each thread creates a task. */
    #pragma omp task shared(task_results, task_counter)
    {
      int my_id;
      #pragma omp atomic capture
      my_id = task_counter++;
      task_results[my_id] = omp_get_thread_num () + 100;
    }

    /* Implicit barrier at end of parallel waits for tasks. */
  }

  /* Round 2: barrier with more tasks, including nested. */
  #pragma omp parallel
  {
    int tid = omp_get_thread_num ();

    if (tid == 0)
      {
	/* Primary creates multiple tasks. */
	for (int i = 0; i < 4; i++)
	  {
	    #pragma omp task shared(task_results, task_counter)
	    {
	      int my_id;
	      #pragma omp atomic capture
	      my_id = task_counter++;
	      task_results[my_id] = omp_get_thread_num () + 200;
	    }
	  }
      }

    /* All threads hit implicit barrier. */
  }

  /* Round 3: No tasks — exercises the fast no-tasks path. */
  #pragma omp parallel
  {
    int tid = omp_get_thread_num ();
    /* Just do some work, no tasks created. */
    volatile int x = tid * tid;
    (void) x;
    /* Implicit barrier. */
  }

  printf ("barrier_basic: %d tasks completed\n", task_counter);
  return 0;
}

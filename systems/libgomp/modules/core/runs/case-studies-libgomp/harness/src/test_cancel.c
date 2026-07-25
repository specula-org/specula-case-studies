/* test_cancel.c — Barrier cancellation scenario.
   Exercises: Cancel, BarrierWaitCancelEnd, Family 1 paths.
   3 threads, one triggers cancel while others are in barrier. */

#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include <unistd.h>

static volatile int cancel_fired = 0;

int
main (void)
{
  const char *trace_file = getenv ("TLA_TRACE_FILE");
  if (!trace_file)
    trace_file = "../traces/cancel.ndjson";

  setenv ("TLA_TRACE_FILE", trace_file, 1);
  setenv ("OMP_CANCELLATION", "true", 1);

  omp_set_num_threads (3);
  omp_set_dynamic (0);

  /* Scenario 1: cancel parallel with tasks pending. */
  #pragma omp parallel
  {
    int tid = omp_get_thread_num ();

    /* Create some tasks first. */
    #pragma omp single nowait
    {
      for (int i = 0; i < 3; i++)
	{
	  #pragma omp task
	  {
	    volatile int x = 0;
	    for (int j = 0; j < 100; j++)
	      x += j;
	    (void) x;
	  }
	}
    }

    /* Thread 1 fires cancellation. */
    if (tid == 1)
      {
	#pragma omp cancel parallel
	cancel_fired = 1;
      }

    /* Other threads hit cancellation point. */
    #pragma omp cancellation point parallel
  }

  /* Scenario 2: cancel after all tasks complete. */
  cancel_fired = 0;
  #pragma omp parallel
  {
    int tid = omp_get_thread_num ();

    #pragma omp single nowait
    {
      #pragma omp task
      {
	volatile int x = 42;
	(void) x;
      }
    }

    #pragma omp barrier

    if (tid == 2)
      {
	#pragma omp cancel parallel
	cancel_fired = 1;
      }
    #pragma omp cancellation point parallel
  }

  printf ("cancel: cancel_fired=%d\n", cancel_fired);
  return 0;
}

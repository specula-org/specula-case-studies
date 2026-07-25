/* test_barrier_tasks.c — Barrier with deferred tasks pending.
   Exercises:
     EnqueueTask + EnqueueTaskUnlock (when GOMP_task enqueues)
     BarrierLastReadTaskCount (task branch)
     HandleTasksLock, HandleTasksLastSetWaiting / HandleTasksEnterDrainLoop
     HandleTasksDequeueAndRun, HandleTasksFinishNormal,
     HandleTasksDrainComplete, HandleTasksEmptyExit  */

#include <omp.h>
#include <stdio.h>
#include <unistd.h>

static volatile int sink;

static void
work (int n)
{
  /* Small amount of CPU work — large enough to be deferred.  */
  for (int i = 0; i < 1000; ++i)
    sink += i * n;
}

int main (void)
{
  omp_set_num_threads (2);

  for (int round = 0; round < 3; ++round)
    {
      #pragma omp parallel
      {
	#pragma omp single
	{
	  /* Enqueue a handful of deferred tasks.  These ought to get
	     handed off to the other thread via the barrier handler.  */
	  for (int i = 0; i < 6; ++i)
	    {
	      #pragma omp task
	      work (i + 1);
	    }
	}
	/* Implicit barrier at end-of-parallel.  */
      }
    }

  printf ("test_barrier_tasks OK (sink=%d)\n", sink);
  return 0;
}

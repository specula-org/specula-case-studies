/* test_barrier_basic.c — Smoke test: 2-thread parallel barrier with no tasks.
   Exercises BarrierWaitStart, BarrierLastReadTaskCount (publish branch),
   BarrierPublishNoTask, BarrierWaitLoopAck(idle).  */

#include <omp.h>
#include <stdio.h>

int main (void)
{
  omp_set_num_threads (2);

  /* Several rounds back-to-back so we get many barrier crossings.  */
  for (int round = 0; round < 4; ++round)
    {
      #pragma omp parallel
      {
	int tid = omp_get_thread_num ();
	/* Trivial work so threads actually do something between barriers.  */
	volatile int x = tid * round;
	(void) x;
	#pragma omp barrier
	/* Force an implicit second barrier at end of parallel region too.  */
      }
    }

  printf ("test_barrier_basic OK\n");
  return 0;
}

/* test_cancel.c — Cancellable parallel region with explicit cancel
   barriers.  Exercises BarrierWaitCancelStart / Loop ack on the
   cancellation path plus the full Cancel* state machine.  */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main (void)
{
  /* Cancellation must be enabled.  */
  setenv ("OMP_CANCELLATION", "true", 1);
  omp_set_num_threads (2);

  for (int round = 0; round < 2; ++round)
    {
      #pragma omp parallel
      {
	int tid = omp_get_thread_num ();

	/* Thread 1 spins briefly so cancel + wait race in time.  */
	if (tid == 1)
	  {
	    volatile int x = 0;
	    for (int i = 0; i < 50000; ++i)
	      x += i;
	    (void) x;
	  }

	/* Each iteration of this loop has its own implicit barrier
	   (because of #pragma omp for), and the loop is cancellable,
	   so libgomp invokes the cancellable barrier variant.  */
	#pragma omp for nowait
	for (int i = 0; i < 4; ++i)
	  {
	    #pragma omp cancel for
	    /* If we get here, no cancel fired — do some work.  */
	    volatile int y = i;
	    (void) y;
	  }
	#pragma omp cancellation point parallel
	/* Trigger an explicit cancellable barrier afterwards.  */
	if (tid == 0)
	  {
	    #pragma omp cancel parallel
	  }
	#pragma omp cancellation point parallel
      }
    }

  printf ("test_cancel OK\n");
  return 0;
}

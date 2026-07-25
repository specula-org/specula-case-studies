/* test_multi_round.c — Multiple parallel regions on the same cached
   team.  Exercises PrimaryEndRegion / PrimaryStartNewRegion plus the
   team-region monotonic counter (Family 4 surface).  */

#include <omp.h>
#include <stdio.h>

static volatile int sink;

int main (void)
{
  omp_set_num_threads (2);

  /* Repeated short parallel regions.  The OpenMP thread pool keeps
     the team alive between calls (`pool->last_team` cache path).  */
  for (int round = 0; round < 6; ++round)
    {
      #pragma omp parallel
      {
	int tid = omp_get_thread_num ();
	sink += tid * round;
      }
    }

  printf ("test_multi_round OK (sink=%d)\n", sink);
  return 0;
}

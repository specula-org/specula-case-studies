/* test_detach.c — Detached task fulfilled from a non-team pthread.
   Exercises EnqueueTask with hasDetach=1 plus the FulfillLoadDetachTeam
   → FulfillFinish state machine on an ExtThread.

   Design: the orchestrator thread launches a dedicated external thread
   that will be the fulfiller, then enters an `omp parallel` whose body
   creates a deferred detached task.  A second OMP thread runs the
   task's empty body and parks it in DETACHED state.  The external
   thread observes the handle via a release-store from the worker (NOT
   from the master, which is blocked inside GOMP_task in the undeferred
   path).  */

#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>

static _Atomic(omp_event_handle_t) shared_evt;

static void *
external_fulfiller (void *unused)
{
  (void) unused;
  omp_event_handle_t evt;
  /* Spin until the OMP worker thread publishes the handle.  */
  while ((evt = atomic_load_explicit (&shared_evt, memory_order_acquire))
         == (omp_event_handle_t) 0)
    usleep (50);
  /* Brief wait so the task body finishes and the task is in DETACHED
     state on the team side before we fulfill.  */
  usleep (1000);
  omp_fulfill_event (evt);
  return NULL;
}

int main (void)
{
  omp_set_num_threads (2);

  for (int round = 0; round < 2; ++round)
    {
      atomic_store_explicit (&shared_evt, (omp_event_handle_t) 0,
			     memory_order_release);
      pthread_t pth;
      pthread_create (&pth, NULL, external_fulfiller, NULL);

      #pragma omp parallel
      {
	/* Worker (team_id == 1) creates the task so the master is free
	   to participate in the team's barrier without blocking inside
	   GOMP_task.  This also helps when libgomp's heuristics choose
	   the deferred path.  */
	int tid = omp_get_thread_num ();
	if (tid == 1)
	  {
	    omp_event_handle_t evt = (omp_event_handle_t) 0;
	    #pragma omp task detach(evt) if(1)
	    {
	      /* Empty body — completes immediately into DETACHED.  */
	    }
	    atomic_store_explicit (&shared_evt, evt, memory_order_release);
	  }
	/* Implicit end-of-parallel barrier waits for task_count==0 +
	   detach_count==0, which only happens after the external thread
	   fulfills.  */
      }
      pthread_join (pth, NULL);
    }

  printf ("test_detach OK\n");
  return 0;
}

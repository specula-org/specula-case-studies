/* test_task_regions.c — Task scheduling across barrier regions.
   Exercises Family 2 (PR122314) and Family 3 (PR122356) paths.
   Creates tasks, lets barrier advance, checks for cross-region issues. */

#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include <unistd.h>

static volatile int results[50];
static volatile int counter = 0;

int
main (void)
{
  const char *trace_file = getenv ("TLA_TRACE_FILE");
  if (!trace_file)
    trace_file = "../traces/task_regions.ndjson";

  setenv ("TLA_TRACE_FILE", trace_file, 1);

  omp_set_num_threads (3);
  omp_set_dynamic (0);

  /* Scenario: Multiple barrier rounds with tasks.
     Family 2: tasks created in region N should not be executed in region N+1.
     Family 3: task_count decrement should use atomic RELEASE. */

  for (int round = 0; round < 3; round++)
    {
      #pragma omp parallel
      {
	int tid = omp_get_thread_num ();

	/* Create tasks in this region. */
	#pragma omp single nowait
	{
	  for (int i = 0; i < 5; i++)
	    {
	      #pragma omp task shared(results, counter)
	      {
		int my_id;
		#pragma omp atomic capture
		my_id = counter++;
		if (my_id < 50)
		  results[my_id] = round * 100 + omp_get_thread_num ();
		/* Small work to create timing variance. */
		volatile int x = 0;
		for (int j = 0; j < 50; j++)
		  x += j;
		(void) x;
	      }
	    }
	}

	/* Implicit barrier — tasks must complete before next region. */
      }
    }

  /* Scenario 2: Taskwait path (Family 3 — non-atomic decrement). */
  #pragma omp parallel
  {
    int tid = omp_get_thread_num ();

    if (tid == 0)
      {
	for (int i = 0; i < 3; i++)
	  {
	    #pragma omp task shared(results, counter)
	    {
	      int my_id;
	      #pragma omp atomic capture
	      my_id = counter++;
	      if (my_id < 50)
		results[my_id] = 900 + omp_get_thread_num ();
	    }
	  }
	/* Taskwait uses non-atomic task_count-- (Family 3). */
	#pragma omp taskwait
      }

    /* Implicit barrier. */
  }

  printf ("task_regions: %d tasks completed across rounds\n", counter);
  return 0;
}

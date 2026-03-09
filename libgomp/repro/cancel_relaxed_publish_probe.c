#include <omp.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int trials = 20000;
static int nthreads = 16;
static unsigned seed = 0xC0FFEEu;

static void parse_args(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--trials") && i + 1 < argc) {
      trials = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--threads") && i + 1 < argc) {
      nthreads = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--seed") && i + 1 < argc) {
      seed = (unsigned)strtoul(argv[++i], NULL, 10);
    } else {
      fprintf(stderr, "usage: %s [--trials N] [--threads N] [--seed N]\n", argv[0]);
      exit(2);
    }
  }
}

int main(int argc, char **argv) {
  parse_args(argc, argv);
  srand(seed);
  omp_set_dynamic(0);

  for (int t = 0; t < trials; t++) {
    _Atomic int go = 0;

#pragma omp parallel num_threads(nthreads) shared(go)
    {
      int tid = omp_get_thread_num();
      if (tid == 0) {
        for (int k = 0; k < 64; k++) {
#pragma omp task
          {
            for (volatile int spin = 0; spin < 200 + (rand() & 255); spin++) {
            }
          }
        }

        usleep(50 + (rand() & 255));
        atomic_store_explicit(&go, 1, memory_order_relaxed);
#pragma omp cancel parallel
      } else {
        while (!atomic_load_explicit(&go, memory_order_relaxed)) {
#pragma omp cancellation point parallel
        }
      }
    }

    if ((t % 1000) == 0 && t != 0) {
      printf("trial=%d/%d\n", t, trials);
      fflush(stdout);
    }
  }

  printf("done: trials=%d nthreads=%d\n", trials, nthreads);
  return 0;
}

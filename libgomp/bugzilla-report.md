Product: gcc
Component: libgomp
Version: 11.0
Severity: normal
Title: [libgomp] Deadlock in omp_fulfill_event when called from unshackled thread without dependent tasks

---

`omp_fulfill_event` called from an unshackled (non-OpenMP) thread for a detached task with no dependent tasks (`new_tasks == 0`) causes a deadlock. All team threads sleep in the barrier and nobody calls `gomp_team_barrier_done`.

Root cause: task.c lines 2753-2759. The unshackled-thread path calls `gomp_team_barrier_wake` but does not set BAR_TASK_PENDING on `bar->generation`:

```c
if (!shackled_thread_p
    && !do_wake
    && team->task_detach_count == 0
    && gomp_team_barrier_waiting_for_tasks (&team->barrier))
  do_wake = 1;  // missing gomp_team_barrier_set_task_pending
```

The barrier wait loop (same in centralized/flat/POSIX) uses BAR_TASK_PENDING as the sole gate for entering `gomp_barrier_handle_tasks`. `futex_wake` wakes a thread, but `bar->generation` is unchanged. The woken thread sees no change, goes back to `futex_wait`. Nobody enters `gomp_barrier_handle_tasks` to call `gomp_team_barrier_done`. Deadlock.

The `new_tasks > 0` path already does this correctly (added in commit ba886d0c, May 2021). The symmetric `!shackled_thread_p` path (commit d656bfda, Feb 2021) is missing the same call.

Affects all GCC versions since 11.

Reproducer (standard OpenMP 5.0 + pthread, no patched libgomp needed):

```c
#include <omp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>
#include <unistd.h>

static omp_event_handle_t global_event;
static atomic_int event_ready = 0;

static void *fulfill_thread(void *arg) {
  while (!atomic_load_explicit(&event_ready, memory_order_acquire))
    ;
  usleep(200000);
  omp_fulfill_event(global_event);
  return NULL;
}

int main(void) {
  pthread_t thr;
  pthread_create(&thr, NULL, fulfill_thread, NULL);

  #pragma omp parallel num_threads(4)
  {
    #pragma omp single
    {
      omp_event_handle_t ev;
      #pragma omp task detach(ev)
      {
        global_event = ev;
        atomic_store_explicit(&event_ready, 1, memory_order_release);
      }
    }
  }

  pthread_join(thr, NULL);
  printf("OK\n");
  return 0;
}
```

Build and run:
```
gcc -fopenmp -O2 -lpthread -o repro repro.c
timeout 5 ./repro    # exit 124 = deadlock
```

Result: 5/5 deadlock unpatched, 5/5 pass patched.

Fix: add `gomp_team_barrier_set_task_pending` before `do_wake = 1` in the unshackled-thread path. Patch attached.

Title: [libomp] Orphaned proxy task in deactivated task team after omp_fulfill_event from external thread

`__kmpc_proxy_task_completed_ooo` enqueues a proxy task's bottom-half into a worker's deque, then decrements `td_incomplete_child_tasks` (ICC) to 0. If all threads see ICC=0 and mark `thread_finished` before any of them picks up the proxy, the primary sees `tt_unfinished_threads==0` and sets `tt_active=FALSE`. The proxy task is left orphaned in a deque of a deactivated task team.

### Race sequence

1. Thread 0 creates a detachable task. Task body returns without fulfilling → becomes proxy.
2. All threads enter barrier, scan deques, find nothing, break out of inner loop.
3. External pthread calls `omp_fulfill_event` → `__kmpc_proxy_task_completed_ooo`:
   - `__kmpc_give_task` enqueues proxy bottom-half to a worker's deque
   - `__kmp_second_top_half_finish_proxy` decrements ICC to 0
4. All threads check ICC=0, set `thread_finished=TRUE`, decrement `tt_unfinished_threads`.
5. Primary sees `unfinished_threads==0`, sets `tt_active=FALSE`.
6. Proxy task sits in worker's deque in a deactivated task team.

### Why the steal loop doesn't catch it

`__kmp_execute_tasks_template` (kmp_tasking.cpp:3296-3417) checks `th_task_team == NULL` but not `tt_active`. Workers retain their `th_task_team` pointer (only the primary clears it at line 4155), so the NULL check doesn't protect them. But by the time they loop back, the `thread_finished` / `unfinished_threads` gate has already triggered exit.

### Impact

- **Resource leak**: proxy's `__kmp_bottom_half_finish_proxy` never runs → leaked `kmp_taskdata_t` + dependency chain.
- **Use-after-free on task team reuse**: task teams are recycled. Next parallel region sees stale `td_deque_ntasks > 0`, dequeues a pointer to freed memory.
- **Barrier counter corruption**: if the orphaned task eventually executes, it decrements `td_allocated_child_tasks` on the wrong parallel region's implicit task.

### Reproducer

Requires libomp built with delay injection (`-DLIBOMP_REPRO_DELAY`) to widen the race window. Three delay points in `kmp_tasking.cpp`:
- 500μs between inner loop exit and ICC check (all threads)
- 10ms in steal loop for already-finished workers (prevents them from grabbing proxy before primary deactivates)
- Safety check after `tt_active=FALSE` that scans all deques and aborts if any has `ntasks > 0`

```c
#include <omp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <unistd.h>

static omp_event_handle_t g_event;
static atomic_int g_event_ready;

static void *fulfiller_fn(void *arg) {
    while (!atomic_load_explicit(&g_event_ready, memory_order_acquire))
        ;
    usleep(1000);
    omp_fulfill_event(g_event);
    return NULL;
}

int main(void) {
    omp_set_num_threads(4);
    for (int trial = 0; trial < 500; trial++) {
        atomic_store_explicit(&g_event_ready, 0, memory_order_relaxed);
        pthread_t thr;
        pthread_create(&thr, NULL, fulfiller_fn, NULL);

        #pragma omp parallel num_threads(4)
        {
            /* Dummy task to pre-allocate worker deques in this task team */
            volatile int dummy = 0;
            #pragma omp task firstprivate(dummy)
            { dummy = 1; }

            if (omp_get_thread_num() == 0) {
                omp_event_handle_t evt;
                #pragma omp task detach(evt)
                {
                    g_event = evt;
                    atomic_store_explicit(&g_event_ready, 1, memory_order_release);
                }
            }
            /* implicit barrier — proxy task orphaned here */
        }
        pthread_join(thr, NULL);
    }
    printf("Done.\n");
    return 0;
}
```

Build and run:
```
# Build libomp with delay injection
cmake -DCMAKE_C_FLAGS="-DLIBOMP_REPRO_DELAY" ...
make omp

# Compile and run
clang -fopenmp -O2 -lpthread -o repro repro.c
LD_LIBRARY_PATH=/path/to/built/lib timeout 30 ./repro
```

Output (5/5 runs):
```
*** BUG REPRODUCED: orphaned task after deactivation ***
  deque[1] has 1 task(s) in deactivated task team 0x...
  This is the steal-after-finish race.
```

Delay patch and full reproducer with signal handlers: https://github.com/specula-org/case-studies/tree/main/libomp/repro

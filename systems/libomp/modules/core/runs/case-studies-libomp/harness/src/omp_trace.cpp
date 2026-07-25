/*
 * omp_trace.cpp — Global trace writer instance for libomp TLA+ trace harness
 */

#ifdef LIBOMP_TRACE

#include "omp_trace.h"

/* Per-thread WorkerStartTasks guard */
int __omp_trace_worker_started[OMP_TRACE_MAX_THREADS] = {0};

/* Single global instance */
omp_trace_writer_t __omp_trace_writer = {
    /*.fp =*/ NULL,
    /*.lock =*/ PTHREAD_MUTEX_INITIALIZER,
    /*.enabled =*/ 0,
    /*.barrier_round =*/ 0,
    /*.task_ptrs =*/ {0},
    /*.task_ids =*/ {0},
    /*.task_map_count =*/ 0,
    /*.next_task_id =*/ 1,
};

#endif /* LIBOMP_TRACE */

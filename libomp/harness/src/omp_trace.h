/*
 * omp_trace.h — TLA+ trace emission for LLVM libomp barrier + tasking
 *
 * Emits NDJSON trace events for trace validation against the TLA+ spec.
 * Gated behind LIBOMP_TRACE compile flag and OMP_TRACE_FILE env var.
 */

#ifndef OMP_TRACE_H
#define OMP_TRACE_H

#ifdef LIBOMP_TRACE

#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ----- Global State ----- */

/* Per-thread flag to emit WorkerStartTasks only once per barrier visit */
#define OMP_TRACE_MAX_THREADS 256
extern int __omp_trace_worker_started[OMP_TRACE_MAX_THREADS];

typedef struct {
    FILE *fp;
    pthread_mutex_t lock;
    int enabled;
    atomic_int barrier_round;
    /* Task pointer -> sequential ID mapping */
    void *task_ptrs[256];
    int task_ids[256];
    int task_map_count;
    atomic_int next_task_id;
} omp_trace_writer_t;

extern omp_trace_writer_t __omp_trace_writer;

/* ----- Init / Shutdown ----- */

static inline void __omp_trace_init(void) {
    const char *path = getenv("OMP_TRACE_FILE");
    if (!path || !path[0]) {
        __omp_trace_writer.enabled = 0;
        return;
    }
    pthread_mutex_init(&__omp_trace_writer.lock, NULL);
    __omp_trace_writer.fp = fopen(path, "w");
    if (!__omp_trace_writer.fp) {
        __omp_trace_writer.enabled = 0;
        return;
    }
    __omp_trace_writer.enabled = 1;
    atomic_store(&__omp_trace_writer.barrier_round, 0);
    __omp_trace_writer.task_map_count = 0;
    atomic_store(&__omp_trace_writer.next_task_id, 1);
}

static inline void __omp_trace_shutdown(void) {
    if (__omp_trace_writer.fp) {
        fflush(__omp_trace_writer.fp);
        fclose(__omp_trace_writer.fp);
        __omp_trace_writer.fp = NULL;
    }
    __omp_trace_writer.enabled = 0;
}

static inline int __omp_trace_enabled(void) {
    return __omp_trace_writer.enabled && __omp_trace_writer.fp;
}

/* ----- Timestamp ----- */

static inline int64_t __omp_trace_timestamp_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

/* ----- Task ID Mapping ----- */

/* Map a task pointer to a stable string like "T1", "T2", ...
 * Returns the integer ID (1-based). */
static inline int __omp_trace_task_id(void *taskdata_ptr) {
    if (!taskdata_ptr)
        return 0;
    pthread_mutex_lock(&__omp_trace_writer.lock);
    /* Look up existing mapping */
    for (int i = 0; i < __omp_trace_writer.task_map_count; i++) {
        if (__omp_trace_writer.task_ptrs[i] == taskdata_ptr) {
            int id = __omp_trace_writer.task_ids[i];
            pthread_mutex_unlock(&__omp_trace_writer.lock);
            return id;
        }
    }
    /* Assign new ID */
    int id = atomic_fetch_add(&__omp_trace_writer.next_task_id, 1);
    if (__omp_trace_writer.task_map_count < 256) {
        int idx = __omp_trace_writer.task_map_count++;
        __omp_trace_writer.task_ptrs[idx] = taskdata_ptr;
        __omp_trace_writer.task_ids[idx] = id;
    }
    pthread_mutex_unlock(&__omp_trace_writer.lock);
    return id;
}

/* ----- Core Emit ----- */

/* Emit a raw NDJSON line. Caller must hold no trace lock.
 * The line is written atomically under the trace mutex. */
static inline void __omp_trace_emit_raw(const char *json_line) {
    if (!__omp_trace_enabled())
        return;
    pthread_mutex_lock(&__omp_trace_writer.lock);
    fprintf(__omp_trace_writer.fp, "%s\n", json_line);
    fflush(__omp_trace_writer.fp);
    pthread_mutex_unlock(&__omp_trace_writer.lock);
}

/* ----- Convenience Emitters ----- */

/* Emit a barrier/thread lifecycle event with standard state fields */
static inline void __omp_trace_emit_barrier_event(
    const char *event_name,
    int tid,
    const char *pc,
    int task_team_slot,
    int thread_finished,
    int barrier_round,
    int cancelled
) {
    if (!__omp_trace_enabled())
        return;
    char buf[1024];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"%s\","
        "\"tid\":%d,"
        "\"state\":{"
            "\"pc\":\"%s\","
            "\"taskTeamSlot\":%d,"
            "\"threadFinished\":%s,"
            "\"barrierRound\":%d,"
            "\"cancelled\":%s"
        "}}",
        (long long)__omp_trace_timestamp_ns(),
        event_name,
        tid,
        pc,
        task_team_slot,
        thread_finished ? "true" : "false",
        barrier_round,
        cancelled ? "true" : "false"
    );
    __omp_trace_emit_raw(buf);
}

/* Emit a task scheduling event */
static inline void __omp_trace_emit_schedule_task(
    const char *event_name,
    int tid,
    void *task_ptr,
    int detachable,
    void *parent_ptr
) {
    if (!__omp_trace_enabled())
        return;
    int task_id = __omp_trace_task_id(task_ptr);
    char buf[1024];
    if (parent_ptr) {
        int parent_id = __omp_trace_task_id(parent_ptr);
        snprintf(buf, sizeof(buf),
            "{\"tag\":\"trace\",\"ts\":%lld,"
            "\"event\":\"%s\","
            "\"tid\":%d,"
            "\"task\":\"T%d\","
            "\"taskDetachable\":%s,"
            "\"parentTask\":\"T%d\"}",
            (long long)__omp_trace_timestamp_ns(),
            event_name,
            tid,
            task_id,
            detachable ? "true" : "false",
            parent_id
        );
    } else {
        snprintf(buf, sizeof(buf),
            "{\"tag\":\"trace\",\"ts\":%lld,"
            "\"event\":\"%s\","
            "\"tid\":%d,"
            "\"task\":\"T%d\","
            "\"taskDetachable\":%s,"
            "\"parentTask\":null}",
            (long long)__omp_trace_timestamp_ns(),
            event_name,
            tid,
            task_id,
            detachable ? "true" : "false"
        );
    }
    __omp_trace_emit_raw(buf);
}

/* Emit a task execution/completion event */
static inline void __omp_trace_emit_task_event(
    const char *event_name,
    int tid,
    void *task_ptr
) {
    if (!__omp_trace_enabled())
        return;
    int task_id = __omp_trace_task_id(task_ptr);
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"%s\","
        "\"tid\":%d,"
        "\"task\":\"T%d\"}",
        (long long)__omp_trace_timestamp_ns(),
        event_name,
        tid,
        task_id
    );
    __omp_trace_emit_raw(buf);
}

/* Emit a steal event */
static inline void __omp_trace_emit_steal(
    int thief_tid,
    int victim_tid,
    void *task_ptr
) {
    if (!__omp_trace_enabled())
        return;
    int task_id = __omp_trace_task_id(task_ptr);
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"StealTask\","
        "\"tid\":%d,"
        "\"victim\":%d,"
        "\"task\":\"T%d\"}",
        (long long)__omp_trace_timestamp_ns(),
        thief_tid,
        victim_tid,
        task_id
    );
    __omp_trace_emit_raw(buf);
}

/* Emit ThreadFinishTasks event with unfinished count */
static inline void __omp_trace_emit_thread_finish(
    int tid,
    int unfinished_after,
    int task_team_slot
) {
    if (!__omp_trace_enabled())
        return;
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"ThreadFinishTasks\","
        "\"tid\":%d,"
        "\"state\":{"
            "\"unfinished\":%d,"
            "\"taskTeamSlot\":%d"
        "}}",
        (long long)__omp_trace_timestamp_ns(),
        tid,
        unfinished_after,
        task_team_slot
    );
    __omp_trace_emit_raw(buf);
}

/* Emit WorkerStartTasks — only once per barrier visit for each thread.
 * Call __omp_trace_reset_worker_started() at barrier entry to reset. */
static inline void __omp_trace_emit_worker_start_tasks(
    int tid,
    int task_team_slot,
    int thread_finished,
    int barrier_round
) {
    if (!__omp_trace_enabled())
        return;
    if (tid >= 0 && tid < OMP_TRACE_MAX_THREADS) {
        if (__omp_trace_worker_started[tid])
            return;  /* already emitted for this barrier visit */
        __omp_trace_worker_started[tid] = 1;
    }
    __omp_trace_emit_barrier_event("WorkerStartTasks", tid,
        "barrier_tasks", task_team_slot, thread_finished,
        barrier_round, 0);
}

static inline void __omp_trace_reset_worker_started(int tid) {
    if (tid >= 0 && tid < OMP_TRACE_MAX_THREADS)
        __omp_trace_worker_started[tid] = 0;
}

/* Emit a simple named event with just tid */
static inline void __omp_trace_emit_simple(
    const char *event_name,
    int tid
) {
    if (!__omp_trace_enabled())
        return;
    char buf[256];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"%s\","
        "\"tid\":%d}",
        (long long)__omp_trace_timestamp_ns(),
        event_name,
        tid
    );
    __omp_trace_emit_raw(buf);
}

/* Emit PrimaryTaskTeamWait with slot info */
static inline void __omp_trace_emit_primary_task_wait(int slot) {
    if (!__omp_trace_enabled())
        return;
    char buf[256];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"PrimaryTaskTeamWait\","
        "\"tid\":0,"
        "\"state\":{\"pc\":\"barrier_task_wait\",\"slot\":%d}}",
        (long long)__omp_trace_timestamp_ns(),
        slot
    );
    __omp_trace_emit_raw(buf);
}

/* Emit TaskTeamSync with new slot value */
static inline void __omp_trace_emit_task_team_sync(int tid, int new_slot) {
    if (!__omp_trace_enabled())
        return;
    char buf[256];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"TaskTeamSync\","
        "\"tid\":%d,"
        "\"state\":{\"taskTeamSlot\":%d}}",
        (long long)__omp_trace_timestamp_ns(),
        tid,
        new_slot
    );
    __omp_trace_emit_raw(buf);
}

/* Emit StartNextRound with new round number */
static inline void __omp_trace_emit_start_next_round(int new_round) {
    if (!__omp_trace_enabled())
        return;
    char buf[256];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"StartNextRound\","
        "\"state\":{\"barrierRound\":%d}}",
        (long long)__omp_trace_timestamp_ns(),
        new_round
    );
    __omp_trace_emit_raw(buf);
}

/* Emit FulfillEvent */
static inline void __omp_trace_emit_fulfill(
    const char *event_name,
    void *task_ptr,
    int fulfiller_tid
) {
    if (!__omp_trace_enabled())
        return;
    int task_id = __omp_trace_task_id(task_ptr);
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"%s\","
        "\"task\":\"T%d\","
        "\"tid\":%d}",
        (long long)__omp_trace_timestamp_ns(),
        event_name,
        task_id,
        fulfiller_tid
    );
    __omp_trace_emit_raw(buf);
}

/* Emit CompleteTask with parent child count */
static inline void __omp_trace_emit_complete_task(
    int tid,
    void *task_ptr,
    int parent_child_count
) {
    if (!__omp_trace_enabled())
        return;
    int task_id = __omp_trace_task_id(task_ptr);
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"tag\":\"trace\",\"ts\":%lld,"
        "\"event\":\"CompleteTask\","
        "\"tid\":%d,"
        "\"task\":\"T%d\","
        "\"childCount\":%d}",
        (long long)__omp_trace_timestamp_ns(),
        tid,
        task_id,
        parent_child_count
    );
    __omp_trace_emit_raw(buf);
}

/* ----- Guard Macro ----- */

#define OMP_TRACE_IF_ENABLED(expr) \
    do { if (__omp_trace_enabled()) { expr; } } while(0)

#ifdef __cplusplus
}
#endif

#else /* !LIBOMP_TRACE */

#define OMP_TRACE_IF_ENABLED(expr) ((void)0)

/* Stub all inline functions as no-ops */
static inline void __omp_trace_init(void) {}
static inline void __omp_trace_shutdown(void) {}
static inline int __omp_trace_enabled(void) { return 0; }

#endif /* LIBOMP_TRACE */

#endif /* OMP_TRACE_H */

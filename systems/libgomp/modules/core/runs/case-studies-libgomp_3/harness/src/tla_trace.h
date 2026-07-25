/* tla_trace.h — Per-thread NDJSON trace emission for libgomp_3 (Category B).

   Each team thread (and the single external fulfiller thread) opens its
   own trace file at startup and writes raw NDJSON lines with rdtsc
   `[start, end]` intervals.  No mutex on the hot path.  A post-processor
   merges the per-thread files, compresses timestamps, and emits the
   per-thread JSON structure consumed by Trace.tla.

   USAGE
     In exactly ONE translation unit (we pick `task.c`), define
     `TLA_TRACE_IMPL` before including this header to materialize the
     out-of-line definitions:

         #define TLA_TRACE_IMPL
         #include "tla_trace.h"

     All other translation units (`config/linux/bar.c`, `team.c`,
     `parallel.c`) just `#include "tla_trace.h"`.

   The trace directory is taken from `TLA_TRACE_DIR` (default `.`),
   tracing is enabled only when `TLA_TRACE_FILE` is set to a scenario
   name.  All per-thread files for the scenario then live at
   `${TLA_TRACE_DIR}/${TLA_TRACE_FILE}-thread-${tid}.ndjson`.  */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <pthread.h>

/* ------------------------------------------------------------------ */
/* Constants — must match config/linux/bar.h (BAR_INCR = 8)            */
/* ------------------------------------------------------------------ */

#define TLA_BAR_TASK_PENDING        1u
#define TLA_BAR_WAITING_FOR_TASK    2u
#define TLA_BAR_CANCELLED           4u
#define TLA_BAR_INCR                8u

/* ------------------------------------------------------------------ */
/* Globals — defined in the TLA_TRACE_IMPL TU                          */
/* ------------------------------------------------------------------ */

#ifdef TLA_TRACE_IMPL
  int  tla_trace_enabled                = 0;
  char tla_trace_dir[512]               = ".";
  char tla_trace_scenario[256]          = "trace";
  /* Monotonic shadow counter for region id.  */
  _Atomic unsigned int tla_team_region_counter = 0;
  /* External fulfiller assignment.  Initialized lazily.  */
  _Atomic unsigned int tla_next_ext_tid = 1;
#else
  extern int  tla_trace_enabled;
  extern char tla_trace_dir[512];
  extern char tla_trace_scenario[256];
  extern _Atomic unsigned int tla_team_region_counter;
  extern _Atomic unsigned int tla_next_ext_tid;
#endif

/* ------------------------------------------------------------------ */
/* Per-thread state                                                     */
/* ------------------------------------------------------------------ */

typedef struct {
  FILE *fp;
  char  tid[16];          /* "t1", "t2", ..., "e1", ... */
  int   initialized;
  int   lock_holder_is_self;
} tla_tls_t;

extern __thread tla_tls_t  tla_tls;

#ifdef TLA_TRACE_IMPL
  __thread tla_tls_t tla_tls = {NULL, "?", 0, 0};
#endif

/* ------------------------------------------------------------------ */
/* Timestamp (rdtsc with mfence — ~25 cycles)                          */
/* ------------------------------------------------------------------ */

static inline uint64_t
tla_rdtsc (void)
{
  unsigned lo, hi;
  __asm__ volatile (
      "mfence\n\t"
      "rdtsc"
      : "=a" (lo), "=d" (hi)
      ::
  );
  return ((uint64_t) hi << 32) | lo;
}

/* ------------------------------------------------------------------ */
/* Init / Shutdown                                                      */
/* ------------------------------------------------------------------ */

#ifdef TLA_TRACE_IMPL
__attribute__ ((constructor))
static void
tla_trace_env_init (void)
{
  const char *scn = getenv ("TLA_TRACE_FILE");
  const char *dir = getenv ("TLA_TRACE_DIR");
  if (scn && scn[0])
    {
      tla_trace_enabled = 1;
      snprintf (tla_trace_scenario, sizeof tla_trace_scenario, "%s", scn);
    }
  if (dir && dir[0])
    snprintf (tla_trace_dir, sizeof tla_trace_dir, "%s", dir);
}
#endif /* TLA_TRACE_IMPL */

/* Open a per-thread file.  `tid` is one of "t1", "t2", ..., or "e1" etc.
   Idempotent: subsequent calls in the same thread are no-ops.  */
static inline void
tla_trace_thread_open (const char *tid)
{
  if (!tla_trace_enabled || tla_tls.initialized)
    return;
  /* Avoid opening the file when no scenario set.  */
  if (!tid || !tid[0])
    return;
  char path[1024];
  snprintf (path, sizeof path, "%s/%s-thread-%s.ndjson",
            tla_trace_dir, tla_trace_scenario, tid);
  tla_tls.fp = fopen (path, "w");
  if (tla_tls.fp == NULL)
    return;
  snprintf (tla_tls.tid, sizeof tla_tls.tid, "%s", tid);
  tla_tls.initialized = 1;
  tla_tls.lock_holder_is_self = 0;
  /* Line-buffered to flush fast for crash resilience.  */
  setvbuf (tla_tls.fp, NULL, _IOLBF, 0);
}

static inline void
tla_trace_thread_close (void)
{
  if (tla_tls.fp)
    {
      fflush (tla_tls.fp);
      fclose (tla_tls.fp);
      tla_tls.fp = NULL;
    }
  tla_tls.initialized = 0;
}

/* Open a team-thread trace file based on gomp_thread()->ts.team_id.
   Mapping: team_id 0 -> "t1", 1 -> "t2", ...
   The caller passes the team_id directly to avoid coupling.  */
static inline void
tla_trace_team_thread_open (int team_id)
{
  char buf[16];
  snprintf (buf, sizeof buf, "t%d", team_id + 1);
  tla_trace_thread_open (buf);
}

/* Open an external (non-team) thread's trace file.  Assigns a fresh
   "eN" tag the first time the thread emits.  */
static inline void
tla_trace_ext_thread_open (void)
{
  unsigned id = atomic_fetch_add (&tla_next_ext_tid, 1u);
  char buf[16];
  snprintf (buf, sizeof buf, "e%u", id);
  tla_trace_thread_open (buf);
}

/* ------------------------------------------------------------------ */
/* Emit primitive                                                       */
/* ------------------------------------------------------------------ */

/* Write one NDJSON line to the thread-local file.  No mutex.  */
static inline void
tla_trace_writef (const char *fmt, ...)
{
  if (!tla_trace_enabled || !tla_tls.fp)
    return;
  va_list ap;
  va_start (ap, fmt);
  vfprintf (tla_tls.fp, fmt, ap);
  va_end (ap);
  fputc ('\n', tla_tls.fp);
}

/* Convenience: emit an event with no extra post fields.  */
static inline void
tla_trace_emit_bare (const char *event,
                     uint64_t t_start, uint64_t t_end)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"%s\",\"tid\":\"%s\","
                    "\"start\":%llu,\"end\":%llu,\"post\":{}}",
                    event, tla_tls.tid,
                    (unsigned long long) t_start,
                    (unsigned long long) t_end);
}

/* Decompose a raw generation word into its spec-level fields.  Returns
   counter (high bits / BAR_INCR) and flag bits.  */
static inline unsigned int
tla_gen_counter (unsigned int raw)
{
  return (raw & ~(TLA_BAR_INCR - 1u)) / TLA_BAR_INCR;
}

static inline int
tla_gen_cancelled (unsigned int raw)
{
  return (raw & TLA_BAR_CANCELLED) != 0;
}

static inline int
tla_gen_task_pending (unsigned int raw)
{
  return (raw & TLA_BAR_TASK_PENDING) != 0;
}

static inline int
tla_gen_waiting_for_task (unsigned int raw)
{
  return (raw & TLA_BAR_WAITING_FOR_TASK) != 0;
}

/* ------------------------------------------------------------------ */
/* High-level emit helpers per spec action                              */
/* ------------------------------------------------------------------ */

/* BarrierWaitStart: barCounter, barAwaited, barCancelled, wasLast */
static inline void
tla_emit_BarrierWaitStart (uint64_t ts_start, uint64_t ts_end,
                           unsigned int gen_raw, unsigned int awaited,
                           int was_last)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"BarrierWaitStart\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barCounter\":%u,\"barAwaited\":%u,"
                    "\"barCancelled\":%d,\"wasLast\":%d}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_gen_counter (gen_raw),
                    awaited,
                    tla_gen_cancelled (gen_raw),
                    was_last);
}

static inline void
tla_emit_BarrierWaitCancelStart (uint64_t ts_start, uint64_t ts_end,
                                 unsigned int gen_raw, unsigned int awaited,
                                 int was_last)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"BarrierWaitCancelStart\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barCounter\":%u,\"barAwaited\":%u,"
                    "\"barCancelled\":%d,\"wasLast\":%d}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_gen_counter (gen_raw),
                    awaited,
                    tla_gen_cancelled (gen_raw),
                    was_last);
}

/* BarrierLastReadTaskCount: taskCount, branch */
static inline void
tla_emit_BarrierLastReadTaskCount (uint64_t ts_start, uint64_t ts_end,
                                   unsigned int task_count,
                                   const char *branch)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"BarrierLastReadTaskCount\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"taskCount\":%u,\"branch\":\"%s\"}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    task_count, branch);
}

/* BarrierPublishNoTask / BarrierPublishCancellableNoTask */
static inline void
tla_emit_BarrierPublishNoTask (uint64_t ts_start, uint64_t ts_end,
                               unsigned int new_gen_raw)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"BarrierPublishNoTask\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barCounter\":%u,\"barCancelled\":%d,"
                    "\"barTaskPending\":%d,\"barWaitingForTask\":%d}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_gen_counter (new_gen_raw),
                    tla_gen_cancelled (new_gen_raw),
                    tla_gen_task_pending (new_gen_raw),
                    tla_gen_waiting_for_task (new_gen_raw));
}

static inline void
tla_emit_BarrierPublishCancellableNoTask (uint64_t ts_start, uint64_t ts_end,
                                          unsigned int new_gen_raw)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":"
                    "\"BarrierPublishCancellableNoTask\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barCounter\":%u,\"barCancelled\":%d,"
                    "\"barTaskPending\":%d,\"barWaitingForTask\":%d}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_gen_counter (new_gen_raw),
                    tla_gen_cancelled (new_gen_raw),
                    tla_gen_task_pending (new_gen_raw),
                    tla_gen_waiting_for_task (new_gen_raw));
}

/* BarrierWaitLoopAck: barGen (packed), nextStep
   `next_step` is one of "idle", "handle_tasks".  The "stay" branch must
   not emit any event — handled by skipping the call site. */
static inline void
tla_emit_BarrierWaitLoopAck (uint64_t ts_start, uint64_t ts_end,
                             unsigned int gen_raw,
                             const char *next_step)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"BarrierWaitLoopAck\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barGen\":%u,\"nextStep\":\"%s\"}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    gen_raw, next_step);
}

/* HandleTasksLock: lockHolder, teamRegion */
static inline void
tla_emit_HandleTasksLock (uint64_t ts_start, uint64_t ts_end,
                          unsigned int team_region)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"HandleTasksLock\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"lockHolder\":\"%s\",\"teamRegion\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_tls.tid, team_region);
}

/* HandleTasksCheckCompleted: earlyExit=1 */
static inline void
tla_emit_HandleTasksCheckCompleted (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"HandleTasksCheckCompleted\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"earlyExit\":1}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end);
}

/* HandleTasksLastNoTasks: barCounter, taskCount */
static inline void
tla_emit_HandleTasksLastNoTasks (uint64_t ts_start, uint64_t ts_end,
                                 unsigned int new_gen_raw,
                                 unsigned int task_count)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"HandleTasksLastNoTasks\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barCounter\":%u,\"taskCount\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_gen_counter (new_gen_raw), task_count);
}

/* HandleTasksLastSetWaiting: barWaitingForTask=1 */
static inline void
tla_emit_HandleTasksLastSetWaiting (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"HandleTasksLastSetWaiting\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barWaitingForTask\":1}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end);
}

static inline void
tla_emit_HandleTasksEnterDrainLoop (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_emit_bare ("HandleTasksEnterDrainLoop", ts_start, ts_end);
}

static inline void
tla_emit_HandleTasksDequeueAndRun (uint64_t ts_start, uint64_t ts_end,
                                   unsigned int task_running,
                                   unsigned int task_queued)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"HandleTasksDequeueAndRun\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"taskRunningCount\":%u,"
                    "\"taskQueuedCount\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    task_running, task_queued);
}

static inline void
tla_emit_HandleTasksDrainComplete (uint64_t ts_start, uint64_t ts_end,
                                   unsigned int new_gen_raw)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"HandleTasksDrainComplete\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barCounter\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_gen_counter (new_gen_raw));
}

static inline void
tla_emit_HandleTasksEmptyExit (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_emit_bare ("HandleTasksEmptyExit", ts_start, ts_end);
}

static inline void
tla_emit_HandleTasksFinishDetach (uint64_t ts_start, uint64_t ts_end,
                                  unsigned int detach_count,
                                  unsigned int running_count)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"HandleTasksFinishDetach\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"taskDetachCount\":%u,"
                    "\"taskRunningCount\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    detach_count, running_count);
}

static inline void
tla_emit_HandleTasksFinishNormal (uint64_t ts_start, uint64_t ts_end,
                                  unsigned int task_count,
                                  unsigned int running_count,
                                  const char *branch)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"HandleTasksFinishNormal\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"taskCount\":%u,\"taskRunningCount\":%u,"
                    "\"branch\":\"%s\"}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    task_count, running_count, branch);
}

/* EnqueueTask: taskCount, taskQueuedCount, taskId(int), hasDetach */
static inline void
tla_emit_EnqueueTask (uint64_t ts_start, uint64_t ts_end,
                      unsigned int task_count,
                      unsigned int task_queued,
                      uint64_t task_id_hash,
                      int has_detach)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"EnqueueTask\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"taskCount\":%u,\"taskQueuedCount\":%u,"
                    "\"taskId\":%llu,\"hasDetach\":%d}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    task_count, task_queued,
                    (unsigned long long) task_id_hash,
                    has_detach);
}

static inline void
tla_emit_EnqueueTaskUnlock (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_emit_bare ("EnqueueTaskUnlock", ts_start, ts_end);
}

static inline void
tla_emit_CancelRequest (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_emit_bare ("CancelRequest", ts_start, ts_end);
}

static inline void
tla_emit_CancelLockAcquire (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"CancelLockAcquire\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"lockHolder\":\"%s\"}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_tls.tid);
}

static inline void
tla_emit_CancelLoadGen (uint64_t ts_start, uint64_t ts_end,
                        unsigned int loaded_gen)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"CancelLoadGen\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"loadedCounter\":%u,\"loadedGen\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_gen_counter (loaded_gen), loaded_gen);
}

static inline void
tla_emit_CancelStoreGen (uint64_t ts_start, uint64_t ts_end,
                         unsigned int new_gen_raw,
                         int branch_early_return)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"CancelStoreGen\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"barCounter\":%u,\"barCancelled\":%d,"
                    "\"branchEarlyReturn\":%d}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_gen_counter (new_gen_raw),
                    tla_gen_cancelled (new_gen_raw),
                    branch_early_return);
}

static inline void
tla_emit_CancelUnlockAndWake (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_emit_bare ("CancelUnlockAndWake", ts_start, ts_end);
}

static inline void
tla_emit_FulfillLoadDetachTeam (uint64_t ts_start, uint64_t ts_end,
                                uint64_t task_id_hash,
                                unsigned int team_region)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"FulfillLoadDetachTeam\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"taskId\":%llu,\"teamPtr\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    (unsigned long long) task_id_hash, team_region);
}

static inline void
tla_emit_FulfillLockTeam (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"FulfillLockTeam\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"lockHolder\":\"%s\"}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    tla_tls.tid);
}

static inline void
tla_emit_FulfillBody (uint64_t ts_start, uint64_t ts_end,
                      unsigned int task_count,
                      unsigned int detach_count)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"FulfillBody\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"taskCount\":%u,\"taskDetachCount\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    task_count, detach_count);
}

static inline void
tla_emit_FulfillLastDetachGuard (uint64_t ts_start, uint64_t ts_end,
                                 int do_wake)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"FulfillLastDetachGuard\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"doWake\":%d}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    do_wake);
}

static inline void
tla_emit_FulfillNonShackledWakeThenUnlock (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_emit_bare ("FulfillNonShackledWakeThenUnlock", ts_start, ts_end);
}

static inline void
tla_emit_FulfillFinish (uint64_t ts_start, uint64_t ts_end)
{
  tla_trace_emit_bare ("FulfillFinish", ts_start, ts_end);
}

static inline void
tla_emit_PrimaryEndRegion (uint64_t ts_start, uint64_t ts_end,
                           unsigned int team_region)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"PrimaryEndRegion\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"teamRegion\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    team_region);
}

static inline void
tla_emit_PrimaryStartNewRegion (uint64_t ts_start, uint64_t ts_end,
                                unsigned int team_region,
                                unsigned int task_count)
{
  tla_trace_writef ("{\"tag\":\"trace\",\"event\":\"PrimaryStartNewRegion\","
                    "\"tid\":\"%s\",\"start\":%llu,\"end\":%llu,"
                    "\"post\":{\"teamRegion\":%u,\"taskCount\":%u}}",
                    tla_tls.tid,
                    (unsigned long long) ts_start,
                    (unsigned long long) ts_end,
                    team_region, task_count);
}

/* Stable task ID: keep low 32 bits of pointer & 0xfff so a couple of
   small bounded values fall out in tests.  Sufficient because the spec
   only uses taskId to thread it through Task constants.  */
static inline uint64_t
tla_task_hash (const void *ptr)
{
  uintptr_t x = (uintptr_t) ptr;
  /* Avalanche-like scramble, then mod a small constant so the result
     is a small TLA-friendly integer.  Trace.tla currently treats taskId
     as opaque (Task set), so any unique-per-task integer works.  */
  x ^= (x >> 33);
  x *= 0xff51afd7ed558ccdULL;
  x ^= (x >> 33);
  return (uint64_t) (x & 0xffffu);
}

#endif /* TLA_TRACE_H */

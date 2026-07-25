/* tla_trace.h — NDJSON trace emission for TLA+ trace validation.
   Thread-safe trace emitter for libgomp barrier instrumentation.

   Usage:
     In exactly ONE translation unit (task.c), define TLA_TRACE_IMPL
     before including this header:
       #define TLA_TRACE_IMPL
       #include "tla_trace.h"
     All other translation units just #include "tla_trace.h".

   The trace file is controlled by the TLA_TRACE_FILE env var.  */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

/* ------------------------------------------------------------------ */
/* Shared state — defined in the TLA_TRACE_IMPL translation unit      */
/* ------------------------------------------------------------------ */

#ifdef TLA_TRACE_IMPL
  FILE *tla_trace_fp = NULL;
  pthread_mutex_t tla_trace_mutex = PTHREAD_MUTEX_INITIALIZER;
  volatile int tla_task_lock_holder = -1;
  unsigned tla_next_task_id = 1;
  int tla_trace_enabled = 0;
  __thread const char *tla_thread_phase = "idle";
#else
  extern FILE *tla_trace_fp;
  extern pthread_mutex_t tla_trace_mutex;
  extern volatile int tla_task_lock_holder;
  extern unsigned tla_next_task_id;
  extern int tla_trace_enabled;
  extern __thread const char *tla_thread_phase;
#endif

/* ------------------------------------------------------------------ */
/* BAR_* constants (must match config/linux/bar.h)                     */
/* ------------------------------------------------------------------ */

#define TLA_BAR_TASK_PENDING      1
#define TLA_BAR_WAITING_FOR_TASK  2
#define TLA_BAR_CANCELLED         4
#define TLA_BAR_INCR              4096

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

static inline long long
tla_monotonic_ns (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (long long) ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static inline unsigned
tla_extract_generation (unsigned raw_gen)
{
  return raw_gen / TLA_BAR_INCR;
}

/* ------------------------------------------------------------------ */
/* Init / Shutdown                                                      */
/* ------------------------------------------------------------------ */

#ifdef TLA_TRACE_IMPL
__attribute__ ((constructor))
static void
tla_trace_auto_init (void)
{
  const char *path = getenv ("TLA_TRACE_FILE");
  if (!path || !path[0])
    return;

  pthread_mutex_lock (&tla_trace_mutex);
  if (tla_trace_fp)
    fclose (tla_trace_fp);
  tla_trace_fp = fopen (path, "w");
  if (tla_trace_fp)
    {
      tla_trace_enabled = 1;
      tla_task_lock_holder = -1;
      tla_next_task_id = 1;
    }
  pthread_mutex_unlock (&tla_trace_mutex);
}

__attribute__ ((destructor))
static void
tla_trace_auto_shutdown (void)
{
  pthread_mutex_lock (&tla_trace_mutex);
  tla_trace_enabled = 0;
  if (tla_trace_fp)
    {
      fflush (tla_trace_fp);
      fclose (tla_trace_fp);
      tla_trace_fp = NULL;
    }
  pthread_mutex_unlock (&tla_trace_mutex);
}
#endif /* TLA_TRACE_IMPL */

/* ------------------------------------------------------------------ */
/* Core emit function                                                   */
/* ------------------------------------------------------------------ */

static inline void
tla_emit (const char *event, int thread_id,
	  unsigned raw_gen, unsigned task_count,
	  const char *extra_json)
{
  if (!tla_trace_enabled)
    return;

  long long ts = tla_monotonic_ns ();
  unsigned generation = tla_extract_generation (raw_gen);
  int cancelled = (raw_gen & TLA_BAR_CANCELLED) ? 1 : 0;
  int task_pending = (raw_gen & TLA_BAR_TASK_PENDING) ? 1 : 0;
  int waiting_for_task = (raw_gen & TLA_BAR_WAITING_FOR_TASK) ? 1 : 0;
  const char *phase = tla_thread_phase;
  int lock_holder = tla_task_lock_holder;

  pthread_mutex_lock (&tla_trace_mutex);
  if (tla_trace_fp)
    {
      fprintf (tla_trace_fp,
	       "{\"tag\":\"barrier\",\"event\":\"%s\","
	       "\"thread\":%d,\"timestamp\":%lld,"
	       "\"state\":{"
	       "\"generation\":%u,"
	       "\"taskCount\":%u,"
	       "\"phase\":\"%s\","
	       "\"cancelled\":%s,"
	       "\"taskPending\":%s,"
	       "\"waitingForTask\":%s,"
	       "\"taskLockHolder\":%d"
	       "}",
	       event, thread_id, ts,
	       generation, task_count, phase,
	       cancelled ? "true" : "false",
	       task_pending ? "true" : "false",
	       waiting_for_task ? "true" : "false",
	       lock_holder);

      if (extra_json && extra_json[0])
	fprintf (tla_trace_fp, ",\"detail\":{%s}", extra_json);

      fprintf (tla_trace_fp, "}\n");
      fflush (tla_trace_fp);
    }
  pthread_mutex_unlock (&tla_trace_mutex);
}

/* Convenience wrapper: no extra detail. */
static inline void
tla_emit_simple (const char *event, int thread_id,
		 unsigned raw_gen, unsigned task_count)
{
  tla_emit (event, thread_id, raw_gen, task_count, NULL);
}

/* Emit a ResetBarrier event (synthesized by test harness). */
static inline void
tla_emit_reset (unsigned raw_gen)
{
  tla_emit ("ResetBarrier", 0, raw_gen, 0, NULL);
}

#endif /* TLA_TRACE_H */

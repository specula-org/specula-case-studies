/* SPDX-License-Identifier: BSD-3-Clause
 *
 * TLA+ trace emission for DPDK rte_ring (round 2).
 *
 * Category B (concurrent / lock-free) — uses the timebox approach:
 *   - Per-thread NDJSON files (no mutex on the hot path).
 *   - rdtsc-based [start, end] interval per event.
 *   - State snapshot captured *outside* the interval to keep it tight.
 *
 * All functions are guarded by DPDK_TLA_TRACE — when undefined, the emit
 * macros expand to nothing.
 *
 * Emitted line shape (per thread file):
 *   {"tag":"trace","name":"<event>","tid":<int>,
 *    "start":<rdtsc>,"end":<rdtsc>,
 *    "state":{...},
 *    "n":<int>?, "stage":<int>?, "ftoken":<int>?, "success":<int>?, ... }
 *
 * The harness's `merge_traces.py` post-processes these into a single JSON
 *   { "<tid>": [event...] }
 * compressed timestamps, ready for Trace.tla.
 */

#ifndef RTE_RING_TLA_TRACE_H
#define RTE_RING_TLA_TRACE_H

#ifdef DPDK_TLA_TRACE

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Wrap constants matching Trace.cfg.  The DPDK ring uses 32-bit unsigned
 * counters that effectively wrap at 2^32; the spec uses PosWrap=4,
 * CntWrap=2.  We emit (value % WRAP) so the trace lines up with the
 * spec's small wrap domain.  Tests are sized so live counters stay
 * within these wrap bounds; if a test exceeds them, set TRACE_POS_WRAP
 * larger at compile time. */
#ifndef TRACE_POS_WRAP
#define TRACE_POS_WRAP 4
#endif
#ifndef TRACE_CNT_WRAP
#define TRACE_CNT_WRAP 2
#endif

/* ---- rdtsc with mfence ----
 * mfence prevents CPU from reordering loads/stores around rdtsc; gives
 * a stable timestamp around the operation we're measuring (~25 cycles).
 */
static inline uint64_t
__tla_rdtsc(void)
{
	unsigned lo, hi;
	__asm__ __volatile__ ("mfence\n\trdtsc" : "=a"(lo), "=d"(hi) :: "memory");
	return ((uint64_t)hi << 32) | (uint64_t)lo;
}

/* ---- Per-lcore state ----
 *
 * The trace module is included into many translation units (DPDK
 * libraries via inline ring functions, test driver via direct include).
 * Cross-TU `__thread` storage doesn't link cleanly across .so files
 * (the symbols would have to appear in every export map).  Instead we
 * use a fixed-size array of `FILE*` indexed by the DPDK lcore id —
 * each thread writes only to its own slot, and the array itself is a
 * single ordinary global defined exactly once in soring.c.
 *
 * Lookups go through `rte_lcore_id()` (a thread-local that DPDK already
 * sets up).  The mapping from lcore id to TLA+ tid is captured at open
 * time via a parallel array.
 */
#define TLA_MAX_LCORE 256

extern FILE *__tla_lcore_fp[TLA_MAX_LCORE];
extern unsigned int __tla_lcore_tid[TLA_MAX_LCORE];

#include <rte_lcore.h>

static inline void
tla_trace_thread_open(const char *prefix, unsigned int tid)
{
	char path[256];
	if (!prefix || !prefix[0])
		return;
	unsigned int lc = rte_lcore_id();
	if (lc >= TLA_MAX_LCORE)
		return;
	snprintf(path, sizeof(path), "%s-thread-%u.ndjson", prefix, tid);
	__tla_lcore_fp[lc] = fopen(path, "w");
	__tla_lcore_tid[lc] = tid;
}

static inline void
tla_trace_thread_close(void)
{
	unsigned int lc = rte_lcore_id();
	if (lc >= TLA_MAX_LCORE)
		return;
	if (__tla_lcore_fp[lc]) {
		fflush(__tla_lcore_fp[lc]);
		fclose(__tla_lcore_fp[lc]);
		__tla_lcore_fp[lc] = NULL;
	}
}

/* Helpers — used by the emit functions below. */
static inline FILE *__tla_get_fp(void)
{
	unsigned int lc = rte_lcore_id();
	return (lc < TLA_MAX_LCORE) ? __tla_lcore_fp[lc] : NULL;
}

static inline unsigned int __tla_get_tid(void)
{
	unsigned int lc = rte_lcore_id();
	return (lc < TLA_MAX_LCORE) ? __tla_lcore_tid[lc] : 0;
}

/* ---- State capture helpers ----
 * Reads the ring's atomic head/tail counters with relaxed ordering.
 * The struct overlap (default vs HTS vs RTS) is handled in the helpers
 * below by dispatching on sync_type.
 */
struct rte_ring; /* fwd-decl: real def in rte_ring_core.h */

/* default mode (and HTS, since prod.tail and cons.tail are at the same
 * offset across the union members; for HTS the head field is at the
 * same offset too, but in RTS mode prod.head overlaps with rts_prod.tail.cnt
 * so we read the head from rts_prod.head.val.pos in that case). */
static inline void
__tla_snap_default(const struct rte_ring *r,
		   uint32_t *ph, uint32_t *pt,
		   uint32_t *ch, uint32_t *ct)
{
	*pt = rte_atomic_load_explicit(&r->prod.tail, rte_memory_order_relaxed);
	*ct = rte_atomic_load_explicit(&r->cons.tail, rte_memory_order_relaxed);
	*ph = rte_atomic_load_explicit(&r->prod.head, rte_memory_order_relaxed);
	*ch = rte_atomic_load_explicit(&r->cons.head, rte_memory_order_relaxed);
}

/* RTS-mode head snapshot — head/tail are 64-bit (pos, cnt) pairs. */
static inline void
__tla_snap_rts(const struct rte_ring *r,
	       uint32_t *ph_cnt, uint32_t *ph_pos,
	       uint32_t *pt_cnt, uint32_t *pt_pos,
	       uint32_t *ch_cnt, uint32_t *ch_pos,
	       uint32_t *ct_cnt, uint32_t *ct_pos)
{
	union __rte_ring_rts_poscnt v;
	v.raw = rte_atomic_load_explicit(&r->rts_prod.head.raw,
					 rte_memory_order_relaxed);
	*ph_cnt = v.val.cnt; *ph_pos = v.val.pos;
	v.raw = rte_atomic_load_explicit(&r->rts_prod.tail.raw,
					 rte_memory_order_relaxed);
	*pt_cnt = v.val.cnt; *pt_pos = v.val.pos;
	v.raw = rte_atomic_load_explicit(&r->rts_cons.head.raw,
					 rte_memory_order_relaxed);
	*ch_cnt = v.val.cnt; *ch_pos = v.val.pos;
	v.raw = rte_atomic_load_explicit(&r->rts_cons.tail.raw,
					 rte_memory_order_relaxed);
	*ct_cnt = v.val.cnt; *ct_pos = v.val.pos;
}

/* State snapshot for default/HTS/Peek events. */
struct tla_state_def {
	uint32_t ph, pt, ch, ct;
};
static inline void
__tla_snap_state_def(const struct rte_ring *r, struct tla_state_def *s)
{
	__tla_snap_default(r, &s->ph, &s->pt, &s->ch, &s->ct);
}

/* ---- Core emit: default mode (MT/ST/HTS/Peek) ----
 * Reads state at emit time.  For events that need a state snapshot
 * captured at a specific point in time (e.g., pre-CAS or post-CAS),
 * use __tla_emit_default_with_state instead.
 */
static inline void
__tla_emit_default(const char *event, const struct rte_ring *r,
		   uint64_t t_start, uint64_t t_end,
		   int has_n, unsigned int n,
		   int has_stage, unsigned int stage,
		   int has_extra, const char *extra)
{
	FILE *__tla_fp = __tla_get_fp();
	if (!__tla_fp)
		return;

	uint32_t ph, pt, ch, ct;
	__tla_snap_default(r, &ph, &pt, &ch, &ct);

	char buf[512];
	int off = 0;
	off += snprintf(buf + off, sizeof(buf) - off,
		"{\"tag\":\"trace\",\"name\":\"%s\",\"tid\":%u,"
		"\"start\":%llu,\"end\":%llu",
		event, __tla_get_tid(),
		(unsigned long long)t_start, (unsigned long long)t_end);

	if (has_n)
		off += snprintf(buf + off, sizeof(buf) - off,
			",\"n\":%u", n);
	if (has_stage)
		off += snprintf(buf + off, sizeof(buf) - off,
			",\"stage\":%u", stage);
	if (has_extra && extra)
		off += snprintf(buf + off, sizeof(buf) - off,
			",%s", extra);

	off += snprintf(buf + off, sizeof(buf) - off,
		",\"state\":{\"prodHead\":%u,\"prodTail\":%u,"
		"\"consHead\":%u,\"consTail\":%u}}\n",
		ph % TRACE_POS_WRAP, pt % TRACE_POS_WRAP,
		ch % TRACE_POS_WRAP, ct % TRACE_POS_WRAP);

	fwrite(buf, 1, (size_t)off, __tla_fp);
}

/* Variant that takes an explicit pre-captured state snapshot.  Use this
 * when the spec's expected state at emit time differs from the current
 * ring state — e.g., the spec's `ProdMoveHead_LoadHead` sees prodHead
 * unchanged, but the C code's move_head function returns AFTER
 * advancing prodHead via CAS.  Capture state pre-move then emit
 * LoadHead/LoadTail with that snapshot. */
static inline void
__tla_emit_default_with_state(const char *event,
		const struct tla_state_def *s,
		uint64_t t_start, uint64_t t_end,
		int has_n, unsigned int n)
{
	FILE *__tla_fp = __tla_get_fp();
	if (!__tla_fp)
		return;
	char buf[512];
	int off = snprintf(buf, sizeof(buf),
		"{\"tag\":\"trace\",\"name\":\"%s\",\"tid\":%u,"
		"\"start\":%llu,\"end\":%llu",
		event, __tla_get_tid(),
		(unsigned long long)t_start, (unsigned long long)t_end);
	if (has_n)
		off += snprintf(buf + off, sizeof(buf) - off,
			",\"n\":%u", n);
	off += snprintf(buf + off, sizeof(buf) - off,
		",\"state\":{\"prodHead\":%u,\"prodTail\":%u,"
		"\"consHead\":%u,\"consTail\":%u}}\n",
		s->ph % TRACE_POS_WRAP, s->pt % TRACE_POS_WRAP,
		s->ch % TRACE_POS_WRAP, s->ct % TRACE_POS_WRAP);
	fwrite(buf, 1, (size_t)off, __tla_fp);
}

/* RTS state snapshot. */
struct tla_state_rts {
	uint32_t phc, php, ptc, ptp, chc, chp, ctc, ctp;
};
static inline void
__tla_snap_state_rts(const struct rte_ring *r, struct tla_state_rts *s)
{
	__tla_snap_rts(r, &s->phc, &s->php, &s->ptc, &s->ptp,
		       &s->chc, &s->chp, &s->ctc, &s->ctp);
}
static inline void
__tla_emit_rts_with_state(const char *event,
		const struct tla_state_rts *s,
		uint64_t t_start, uint64_t t_end,
		int has_n, unsigned int n)
{
	FILE *__tla_fp = __tla_get_fp();
	if (!__tla_fp)
		return;
	char buf[768];
	int off = snprintf(buf, sizeof(buf),
		"{\"tag\":\"trace\",\"name\":\"%s\",\"tid\":%u,"
		"\"start\":%llu,\"end\":%llu",
		event, __tla_get_tid(),
		(unsigned long long)t_start, (unsigned long long)t_end);
	if (has_n)
		off += snprintf(buf + off, sizeof(buf) - off,
			",\"n\":%u", n);
	off += snprintf(buf + off, sizeof(buf) - off,
		",\"state\":{"
		"\"rtsProdHeadCnt\":%u,\"rtsProdHeadPos\":%u,"
		"\"rtsProdTailCnt\":%u,\"rtsProdTailPos\":%u,"
		"\"rtsConsHeadCnt\":%u,\"rtsConsHeadPos\":%u,"
		"\"rtsConsTailCnt\":%u,\"rtsConsTailPos\":%u,"
		"\"prodTail\":0,\"consTail\":0"
		"}}\n",
		s->phc % TRACE_CNT_WRAP, s->php % TRACE_POS_WRAP,
		s->ptc % TRACE_CNT_WRAP, s->ptp % TRACE_POS_WRAP,
		s->chc % TRACE_CNT_WRAP, s->chp % TRACE_POS_WRAP,
		s->ctc % TRACE_CNT_WRAP, s->ctp % TRACE_POS_WRAP);
	fwrite(buf, 1, (size_t)off, __tla_fp);
}

/* ---- Core emit: RTS mode (with cnt+pos pairs) ---- */
static inline void
__tla_emit_rts(const char *event, const struct rte_ring *r,
	       uint64_t t_start, uint64_t t_end,
	       int has_n, unsigned int n,
	       int has_extra, const char *extra)
{
	FILE *__tla_fp = __tla_get_fp();
	if (!__tla_fp)
		return;

	uint32_t phc, php, ptc, ptp, chc, chp, ctc, ctp;
	__tla_snap_rts(r, &phc, &php, &ptc, &ptp, &chc, &chp, &ctc, &ctp);

	char buf[768];
	int off = 0;
	off += snprintf(buf + off, sizeof(buf) - off,
		"{\"tag\":\"trace\",\"name\":\"%s\",\"tid\":%u,"
		"\"start\":%llu,\"end\":%llu",
		event, __tla_get_tid(),
		(unsigned long long)t_start, (unsigned long long)t_end);

	if (has_n)
		off += snprintf(buf + off, sizeof(buf) - off,
			",\"n\":%u", n);
	if (has_extra && extra)
		off += snprintf(buf + off, sizeof(buf) - off,
			",%s", extra);

	/* In RTS mode the spec's `prodTail` / `consTail` variables are never
	 * modified (RTS uses rtsProdTail{Cnt,Pos} instead), so they remain 0
	 * after Init.  The ring's hardware `r->cons.tail` overlaps with
	 * `rts_cons.tail.cnt` due to the union layout — we explicitly emit 0
	 * rather than that overlap to match the spec.
	 */
	off += snprintf(buf + off, sizeof(buf) - off,
		",\"state\":{"
		"\"rtsProdHeadCnt\":%u,\"rtsProdHeadPos\":%u,"
		"\"rtsProdTailCnt\":%u,\"rtsProdTailPos\":%u,"
		"\"rtsConsHeadCnt\":%u,\"rtsConsHeadPos\":%u,"
		"\"rtsConsTailCnt\":%u,\"rtsConsTailPos\":%u,"
		"\"prodTail\":0,\"consTail\":0"
		"}}\n",
		phc % TRACE_CNT_WRAP, php % TRACE_POS_WRAP,
		ptc % TRACE_CNT_WRAP, ptp % TRACE_POS_WRAP,
		chc % TRACE_CNT_WRAP, chp % TRACE_POS_WRAP,
		ctc % TRACE_CNT_WRAP, ctp % TRACE_POS_WRAP);

	fwrite(buf, 1, (size_t)off, __tla_fp);
}

/* ---- SORING events ----
 * SORING uses struct rte_soring (declared in rte_soring.h).  We emit a
 * minimal state snapshot using the producer/consumer head/tail of the
 * underlying default-mode ring plus stage[0]'s head/tail.
 */
struct rte_soring; /* fwd decl */

static inline void
__tla_emit_soring(const char *event, const struct rte_soring *r,
		  uint64_t t_start, uint64_t t_end,
		  int has_n, unsigned int n,
		  int has_stage, unsigned int stage,
		  unsigned int ftoken)
{
	FILE *__tla_fp = __tla_get_fp();
	if (!__tla_fp)
		return;

	/* The struct rte_soring layout starts with size/mask/capacity, then
	 * pointers, then nb_stage etc., and prod/cons headtails appear after
	 * cache guards.  To avoid a hard dependency on the rte_soring layout
	 * here, we don't snapshot — we emit minimal info and the test code
	 * captures shared state separately when needed. */
	char buf[512];
	int off = 0;
	off += snprintf(buf + off, sizeof(buf) - off,
		"{\"tag\":\"trace\",\"name\":\"%s\",\"tid\":%u,"
		"\"start\":%llu,\"end\":%llu",
		event, __tla_get_tid(),
		(unsigned long long)t_start, (unsigned long long)t_end);
	if (has_n)
		off += snprintf(buf + off, sizeof(buf) - off,
			",\"n\":%u", n);
	if (has_stage)
		off += snprintf(buf + off, sizeof(buf) - off,
			",\"stage\":%u", stage);
	if (ftoken)
		off += snprintf(buf + off, sizeof(buf) - off,
			",\"ftoken\":%u", ftoken % TRACE_POS_WRAP);
	off += snprintf(buf + off, sizeof(buf) - off,
		",\"state\":{}}\n");
	fwrite(buf, 1, (size_t)off, __tla_fp);
	(void)r;
}

/* Minimal SORING emit that doesn't need an rte_soring pointer (used by
 * __rte_soring_stage_finalize which only has the stage headtail). */
static inline void
__tla_emit_soring_min(const char *event, uint64_t t_start, uint64_t t_end,
		      unsigned int stage)
{
	FILE *__tla_fp = __tla_get_fp();
	if (!__tla_fp)
		return;
	char buf[256];
	int off = snprintf(buf, sizeof(buf),
		"{\"tag\":\"trace\",\"name\":\"%s\",\"tid\":%u,"
		"\"start\":%llu,\"end\":%llu,\"stage\":%u,\"state\":{}}\n",
		event, __tla_get_tid(),
		(unsigned long long)t_start, (unsigned long long)t_end,
		stage);
	fwrite(buf, 1, (size_t)off, __tla_fp);
}

/* ---- Default-mode events ---- */
#define TLA_EMIT_DEF(event, r, t_start, t_end) \
	__tla_emit_default((event), (r), (t_start), (t_end), 0, 0, 0, 0, 0, NULL)
#define TLA_EMIT_DEF_N(event, r, t_start, t_end, n) \
	__tla_emit_default((event), (r), (t_start), (t_end), 1, (n), 0, 0, 0, NULL)

/* ---- RTS-mode events ---- */
#define TLA_EMIT_RTS(event, r, t_start, t_end) \
	__tla_emit_rts((event), (r), (t_start), (t_end), 0, 0, 0, NULL)
#define TLA_EMIT_RTS_N(event, r, t_start, t_end, n) \
	__tla_emit_rts((event), (r), (t_start), (t_end), 1, (n), 0, NULL)

#else /* !DPDK_TLA_TRACE */

#define TLA_EMIT_DEF(event, r, t_start, t_end) ((void)0)
#define TLA_EMIT_DEF_N(event, r, t_start, t_end, n) ((void)0)
#define TLA_EMIT_RTS(event, r, t_start, t_end) ((void)0)
#define TLA_EMIT_RTS_N(event, r, t_start, t_end, n) ((void)0)

static inline void tla_trace_thread_open(const char *p, unsigned int t)
	{ (void)p; (void)t; }
static inline void tla_trace_thread_close(void) {}
static inline uint64_t __tla_rdtsc(void) { return 0; }
struct rte_soring;
static inline void __tla_emit_soring(const char *e, const struct rte_soring *r,
		uint64_t a, uint64_t b, int hn, unsigned n, int hs, unsigned s,
		unsigned ft) { (void)e; (void)r; (void)a; (void)b; (void)hn;
	(void)n; (void)hs; (void)s; (void)ft; }
static inline void __tla_emit_soring_min(const char *e, uint64_t a, uint64_t b,
		unsigned s) { (void)e; (void)a; (void)b; (void)s; }

#endif /* DPDK_TLA_TRACE */
#endif /* RTE_RING_TLA_TRACE_H */

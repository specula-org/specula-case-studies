/* SPDX-License-Identifier: BSD-3-Clause
 *
 * TLA+ trace harness for DPDK rte_ring (round 2).
 *
 * Generates one trace file per ring sync mode by exercising the public
 * rte_ring API with multiple lcores.  Each lcore writes its own
 * `<prefix>-thread-<tid>.ndjson` file (no mutex on the hot path —
 * Category B / timebox).  The merge_traces.py post-processor then
 * combines them into the per-tid JSON shape that Trace.tla expects.
 *
 * Build: see harness/run.sh
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ring.h>
#include <rte_ring_hts.h>
#include <rte_ring_rts.h>
#include <rte_soring.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_pause.h>
#include <rte_atomic.h>

/* The trace TLS storage `__tla_fp` / `__tla_tid` is defined inside
 * librte_ring.so (soring.c picks up DEFINE_STORAGE during apply.sh).
 * This test binary just declares them extern via the header — the
 * dynamic linker resolves both sides to the same TLS slot at load time.
 */
#include "rte_ring_tla_trace.h"

static const char *trace_dir = "../traces";

/* ----------------------------------------------------------------------
 * Sync barrier — make all lcores start at the same time.
 * ---------------------------------------------------------------------- */
static volatile RTE_ATOMIC(int) bar_cnt;
static volatile RTE_ATOMIC(int) bar_go;

static void
bar_reset(void)
{
	rte_atomic_store_explicit(&bar_cnt, 0, rte_memory_order_relaxed);
	rte_atomic_store_explicit(&bar_go, 0, rte_memory_order_relaxed);
}

static void
bar_wait(int total)
{
	if (rte_atomic_fetch_add_explicit(&bar_cnt, 1,
			rte_memory_order_acq_rel) == total - 1) {
		rte_atomic_store_explicit(&bar_go, 1,
				rte_memory_order_release);
	} else {
		while (!rte_atomic_load_explicit(&bar_go,
				rte_memory_order_acquire))
			rte_pause();
	}
}

/* ----------------------------------------------------------------------
 * Per-mode runner — set up trace files and collect available lcores.
 * ---------------------------------------------------------------------- */
struct lcore_args {
	struct rte_ring *r;
	struct rte_soring *sr;
	int tid;
	int n_iter;
	int n_workers;
	int role;          /* 0 = prod, 1 = cons, 2 = both */
};

static char trace_prefix[256];

static void
make_trace_prefix(const char *scenario)
{
	snprintf(trace_prefix, sizeof(trace_prefix),
		 "%s/%s", trace_dir, scenario);
}

/* ----------------------------------------------------------------------
 * Scenario: MT default mode — 2 producers + 1 consumer concurrent.
 *
 * Trace.cfg: Thread={t1,t2}, Capacity=2, Mode="MT", MaxBatch=1
 * Test uses 2 lcores; producer t1 enqueues, consumer t2 dequeues.
 * ---------------------------------------------------------------------- */
static int
mt_producer(void *arg)
{
	struct lcore_args *a = arg;
	tla_trace_thread_open(trace_prefix, a->tid);
	bar_wait(a->n_workers);
	for (int i = 0; i < a->n_iter; i++) {
		void *obj = (void *)(uintptr_t)(a->tid * 100 + i + 1);
		(void)rte_ring_mp_enqueue(a->r, obj);
	}
	tla_trace_thread_close();
	return 0;
}

static int
mt_consumer(void *arg)
{
	struct lcore_args *a = arg;
	tla_trace_thread_open(trace_prefix, a->tid);
	bar_wait(a->n_workers);
	for (int i = 0; i < a->n_iter; i++) {
		void *obj;
		int tries = 0;
		while (rte_ring_mc_dequeue(a->r, &obj) != 0 && tries++ < 1000)
			rte_pause();
	}
	tla_trace_thread_close();
	return 0;
}

static int
test_mt(unsigned int *workers, int n_workers)
{
	if (n_workers < 1) {
		printf("=== mt: SKIPPED (need at least 1 worker lcore) ===\n");
		return 0;
	}
	printf("=== mt ===\n");
	make_trace_prefix("trace_mt");

	struct rte_ring *r = rte_ring_create("mt_ring", 4, SOCKET_ID_ANY,
			RING_F_EXACT_SZ);
	if (!r) {
		fprintf(stderr, "rte_ring_create failed: %s\n",
			rte_strerror(rte_errno));
		return -1;
	}

	bar_reset();

	struct lcore_args prod = {.r = r, .tid = 1, .n_iter = 2,
				  .n_workers = 2, .role = 0};
	struct lcore_args cons = {.r = r, .tid = 2, .n_iter = 2,
				  .n_workers = 2, .role = 1};

	/* Main lcore = producer t1.  Worker = consumer t2. */
	rte_eal_remote_launch(mt_consumer, &cons, workers[0]);
	mt_producer(&prod);
	rte_eal_wait_lcore(workers[0]);

	rte_ring_free(r);
	printf("  mt done\n");
	return 0;
}

/* ----------------------------------------------------------------------
 * Scenario: HTS mode — single-producer / single-consumer
 *
 * HTS serialises access via head==tail spin; with 2 threads it still
 * exercises the head_wait + LoadStail + CAS + UpdateTail chain.
 * ---------------------------------------------------------------------- */
static int
hts_producer(void *arg)
{
	struct lcore_args *a = arg;
	tla_trace_thread_open(trace_prefix, a->tid);
	bar_wait(a->n_workers);
	for (int i = 0; i < a->n_iter; i++) {
		void *obj = (void *)(uintptr_t)(a->tid * 100 + i + 1);
		(void)rte_ring_enqueue(a->r, obj);
	}
	tla_trace_thread_close();
	return 0;
}

static int
hts_consumer(void *arg)
{
	struct lcore_args *a = arg;
	tla_trace_thread_open(trace_prefix, a->tid);
	bar_wait(a->n_workers);
	for (int i = 0; i < a->n_iter; i++) {
		void *obj;
		int tries = 0;
		while (rte_ring_dequeue(a->r, &obj) != 0 && tries++ < 1000)
			rte_pause();
	}
	tla_trace_thread_close();
	return 0;
}

static int
test_hts(unsigned int *workers, int n_workers)
{
	if (n_workers < 1) {
		printf("=== hts: SKIPPED ===\n");
		return 0;
	}
	printf("=== hts ===\n");
	make_trace_prefix("trace_hts");

	struct rte_ring *r = rte_ring_create("hts_ring", 4, SOCKET_ID_ANY,
			RING_F_EXACT_SZ |
			RING_F_MP_HTS_ENQ | RING_F_MC_HTS_DEQ);
	if (!r) {
		fprintf(stderr, "rte_ring_create HTS failed\n");
		return -1;
	}
	bar_reset();
	struct lcore_args prod = {.r = r, .tid = 1, .n_iter = 2, .n_workers = 2};
	struct lcore_args cons = {.r = r, .tid = 2, .n_iter = 2, .n_workers = 2};
	rte_eal_remote_launch(hts_consumer, &cons, workers[0]);
	hts_producer(&prod);
	rte_eal_wait_lcore(workers[0]);
	rte_ring_free(r);
	printf("  hts done\n");
	return 0;
}

/* ----------------------------------------------------------------------
 * Scenario: RTS mode — Family A target.
 *
 * Producer + consumer on RTS ring; exercises the relaxed-head load in
 * __rte_ring_rts_update_tail (Family A residual stale-head load).
 * ---------------------------------------------------------------------- */
static int
rts_producer(void *arg)
{
	struct lcore_args *a = arg;
	tla_trace_thread_open(trace_prefix, a->tid);
	bar_wait(a->n_workers);
	for (int i = 0; i < a->n_iter; i++) {
		void *obj = (void *)(uintptr_t)(a->tid * 100 + i + 1);
		(void)rte_ring_enqueue(a->r, obj);
	}
	tla_trace_thread_close();
	return 0;
}

static int
rts_consumer(void *arg)
{
	struct lcore_args *a = arg;
	tla_trace_thread_open(trace_prefix, a->tid);
	bar_wait(a->n_workers);
	for (int i = 0; i < a->n_iter; i++) {
		void *obj;
		int tries = 0;
		while (rte_ring_dequeue(a->r, &obj) != 0 && tries++ < 1000)
			rte_pause();
	}
	tla_trace_thread_close();
	return 0;
}

static int
test_rts(unsigned int *workers, int n_workers)
{
	if (n_workers < 1) {
		printf("=== rts: SKIPPED ===\n");
		return 0;
	}
	printf("=== rts ===\n");
	make_trace_prefix("trace_rts");

	struct rte_ring *r = rte_ring_create("rts_ring", 4, SOCKET_ID_ANY,
			RING_F_EXACT_SZ |
			RING_F_MP_RTS_ENQ | RING_F_MC_RTS_DEQ);
	if (!r) {
		fprintf(stderr, "rte_ring_create RTS failed\n");
		return -1;
	}
	bar_reset();
	struct lcore_args prod = {.r = r, .tid = 1, .n_iter = 2, .n_workers = 2};
	struct lcore_args cons = {.r = r, .tid = 2, .n_iter = 2, .n_workers = 2};
	rte_eal_remote_launch(rts_consumer, &cons, workers[0]);
	rts_producer(&prod);
	rte_eal_wait_lcore(workers[0]);
	rte_ring_free(r);
	printf("  rts done\n");
	return 0;
}

/* ----------------------------------------------------------------------
 * Scenario: SORING — Family D target.
 *
 * One stage; producer enqueues, worker acquires + releases, consumer
 * dequeues.  Exercises acquire/release/finalize chains.
 * ---------------------------------------------------------------------- */
static struct rte_soring *g_soring;

static int
soring_worker(void *arg)
{
	struct lcore_args *a = arg;
	tla_trace_thread_open(trace_prefix, a->tid);
	bar_wait(a->n_workers);

	/* Each iteration: enqueue, acquire, release, dequeue.  These
	 * cover the full SORING release/finalize chain. */
	for (int i = 0; i < a->n_iter; i++) {
		uint32_t obj_in = a->tid * 100 + i + 1;
		uint32_t obj_acq = 0;
		uint32_t free_space = 0, available = 0;
		uint32_t ftoken;

		/* Enqueue from prod side. */
		(void)rte_soring_enqueue_bulk(g_soring, &obj_in, 1,
					      &free_space);

		/* Acquire elem at stage 0. */
		uint32_t got = rte_soring_acquire_bulk(g_soring, &obj_acq,
				/*stage=*/0, /*num=*/1, &ftoken, &available);
		if (got != 0) {
			/* Release matching n. */
			rte_soring_release(g_soring, NULL, /*stage=*/0,
					   /*n=*/1, ftoken);
		}

		/* Dequeue. */
		uint32_t obj_out = 0;
		(void)rte_soring_dequeue_bulk(g_soring, &obj_out, 1, &available);
	}
	tla_trace_thread_close();
	return 0;
}

static int
test_soring(unsigned int *workers, int n_workers)
{
	if (n_workers < 1) {
		printf("=== soring: SKIPPED ===\n");
		return 0;
	}
	printf("=== soring ===\n");
	make_trace_prefix("trace_soring");

	struct rte_soring_param param = {
		.name = "soring_test",
		.elems = 4,
		.elem_size = sizeof(uint32_t),
		.stages = 1,
		.prod_synt = RTE_RING_SYNC_MT,
		.cons_synt = RTE_RING_SYNC_MT,
	};

	ssize_t sz = rte_soring_get_memsize(&param);
	if (sz < 0) {
		fprintf(stderr, "rte_soring_get_memsize failed\n");
		return -1;
	}
	g_soring = aligned_alloc(64, (size_t)sz);
	if (!g_soring)
		return -1;
	memset(g_soring, 0, (size_t)sz);
	if (rte_soring_init(g_soring, &param) != 0) {
		fprintf(stderr, "rte_soring_init failed\n");
		free(g_soring);
		return -1;
	}

	bar_reset();
	struct lcore_args w1 = {.tid = 1, .n_iter = 2, .n_workers = 2};
	struct lcore_args w2 = {.tid = 2, .n_iter = 2, .n_workers = 2};
	rte_eal_remote_launch(soring_worker, &w2, workers[0]);
	soring_worker(&w1);
	rte_eal_wait_lcore(workers[0]);

	free(g_soring);
	g_soring = NULL;
	printf("  soring done\n");
	return 0;
}

/* ----------------------------------------------------------------------
 * Scenario: Peek (ST mode) — Family E.
 *
 * Single-thread peek API on a ST-only ring.  Two threads not used
 * because peek is not safe on default MT.  We use one thread doing
 * peek_start + peek_finish loops.
 * ---------------------------------------------------------------------- */
static int
test_peek(void)
{
	printf("=== peek ===\n");
	make_trace_prefix("trace_peek");

	struct rte_ring *r = rte_ring_create("peek_ring", 4, SOCKET_ID_ANY,
			RING_F_EXACT_SZ | RING_F_SP_ENQ | RING_F_SC_DEQ);
	if (!r) {
		fprintf(stderr, "rte_ring_create ST failed\n");
		return -1;
	}

	tla_trace_thread_open(trace_prefix, 1);

	/* Use the public peek API to exercise PeekStart / PeekFinish. */
	for (int i = 0; i < 3; i++) {
		void *obj_in[1];
		obj_in[0] = (void *)(uintptr_t)(i + 1);
		uint32_t free = 0;
		uint32_t got = rte_ring_enqueue_bulk_start(r, 1, &free);
		if (got > 0) {
			/* Write to the slot via the user-pointer finish API. */
#ifdef DPDK_TLA_TRACE
			uint64_t __t0 = __tla_rdtsc();
#endif
			rte_ring_enqueue_finish(r, obj_in, 1);
#ifdef DPDK_TLA_TRACE
			uint64_t __t1 = __tla_rdtsc();
			__tla_emit_default("PeekFinish", r, __t0, __t1,
				1, got, 0, 0, 0, NULL);
#endif
		}

		void *obj_out[1];
		uint32_t avail = 0;
		got = rte_ring_dequeue_bulk_start(r, obj_out, 1, &avail);
		if (got > 0) {
#ifdef DPDK_TLA_TRACE
			uint64_t __t0 = __tla_rdtsc();
#endif
			rte_ring_dequeue_finish(r, 1);
#ifdef DPDK_TLA_TRACE
			uint64_t __t1 = __tla_rdtsc();
			__tla_emit_default("PeekFinish", r, __t0, __t1,
				1, got, 0, 0, 0, NULL);
#endif
		}
	}

	tla_trace_thread_close();
	rte_ring_free(r);
	printf("  peek done\n");
	return 0;
}

/* ---------------------------------------------------------------------- */
int
main(int argc, char *argv[])
{
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0) {
		fprintf(stderr, "EAL init failed: %s\n",
			rte_strerror(rte_errno));
		return 1;
	}
	argc -= ret;
	argv += ret;

	const char *env_dir = getenv("TRACE_DIR");
	if (env_dir)
		trace_dir = env_dir;

	printf("Trace output: %s/\n", trace_dir);
	printf("Lcores available: %u\n", rte_lcore_count());

	/* Collect available worker lcores. */
	unsigned int workers[8];
	int n_workers = 0;
	unsigned int lc;
	RTE_LCORE_FOREACH_WORKER(lc) {
		if (n_workers < 8)
			workers[n_workers++] = lc;
	}

	int rc = 0;
	rc |= test_mt(workers, n_workers);
	rc |= test_hts(workers, n_workers);
	rc |= test_rts(workers, n_workers);
	rc |= test_soring(workers, n_workers);
	rc |= test_peek();

	rte_eal_cleanup();
	return rc ? 1 : 0;
}

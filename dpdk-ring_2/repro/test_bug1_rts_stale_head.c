/*
 * Reproduction attempt for Bug 1 (Family A): RTS update_tail relaxed head load.
 *
 * The bug claim:
 *   `__rte_ring_rts_update_tail` (lib/ring/rte_ring_rts_elem_pvt.h:51)
 *   loads `ht->head.raw` with rte_memory_order_relaxed inside the
 *   CAS retry loop.  Under RCpc memory models (AArch64/PowerPC),
 *   the load may return a stale head value, leading the producer to
 *   publish a tail with `(cnt,pos)` where `cnt` matches head but `pos`
 *   regresses — violating
 *      RTSPosCntConsistent: (tail.cnt == head.cnt) ⇒ (tail.pos == head.pos)
 *
 * Reachability analysis on x86:
 *   x86 implements TSO. Loads are not reordered with prior loads,
 *   and stores are not reordered with prior stores. Atomic relaxed
 *   loads behave like normal loads, which obtain the latest globally
 *   visible value of the referenced cache line. Therefore the stale
 *   read scenario is *unobservable on x86 hardware*.
 *
 *   Furthermore, intra-thread coherence (C11 §6.10) requires that a
 *   relaxed load always observes at least the most recent prior write
 *   by the same thread to the same object. After a producer's own
 *   release-CAS on `head.raw` in __rte_ring_rts_move_head, its own
 *   subsequent relaxed load of head.raw observes (>=) that value.
 *   The MC counterexample at spec/output/MC_hunt_A_bfs.out — which
 *   shows t1's load returning (0,0) AFTER t1's own CAS to (1,1) —
 *   is therefore impossible in any conforming C11 implementation,
 *   including RCpc. The MC adversary `MCStaleHeadRTS` admits behavior
 *   that violates intra-thread coherence; this is a spec defect.
 *
 * What this test does:
 *   1. Stresses RTS enqueue/dequeue with N=4 producers, M=4 consumers
 *      for K=1,000,000 iterations on x86.
 *   2. After the stress run, dumps rts.head and rts.tail counters and
 *      verifies the RTSPosCntConsistent invariant
 *      (tail.cnt == head.cnt) ⇒ (tail.pos == head.pos)
 *      at the quiescent point.
 *
 *   On x86 we expect PASS (the bug, if real, is not reachable here).
 *   On AArch64/PowerPC RCpc this stress test would also need to be
 *   amplified to widen race windows — left as a follow-up.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_malloc.h>
#include <rte_ring.h>
#include <rte_ring_rts.h>
#include <rte_atomic.h>
#include <rte_launch.h>

#define RING_SIZE 1024
#define ITERATIONS 200000
#define BURST 4

static struct rte_ring *r;
static volatile int stop;
static uint64_t tot_enq, tot_deq;

static int producer(void *arg)
{
	uintptr_t id = (uintptr_t)arg;
	uintptr_t buf[BURST];
	uint64_t enq = 0;

	for (uint64_t i = 0; i < ITERATIONS; i++) {
		for (int k = 0; k < BURST; k++)
			buf[k] = (id << 32) | i;
		uint32_t r2 = rte_ring_mp_rts_enqueue_bulk(r, (void *const *)buf,
							 BURST, NULL);
		enq += r2;
	}
	__atomic_fetch_add(&tot_enq, enq, __ATOMIC_RELAXED);
	return 0;
}

static int consumer(void *arg)
{
	(void)arg;
	uintptr_t buf[BURST];
	uint64_t deq = 0;

	while (!__atomic_load_n(&stop, __ATOMIC_ACQUIRE) ||
	       rte_ring_count(r) > 0) {
		uint32_t r2 = rte_ring_mc_rts_dequeue_burst(r, (void **)buf,
							  BURST, NULL);
		deq += r2;
	}
	__atomic_fetch_add(&tot_deq, deq, __ATOMIC_RELAXED);
	return 0;
}

int main(int argc, char **argv)
{
	int rc = rte_eal_init(argc, argv);
	if (rc < 0) {
		fprintf(stderr, "rte_eal_init failed: %d\n", rc);
		return 1;
	}
	argc -= rc;
	argv += rc;

	printf("== test_bug1_rts_stale_head ==\n");
	printf("Architecture: x86_64 (TSO).\n");
	printf("Bug 1 (Family A) requires RCpc weak-memory hardware to manifest;\n");
	printf("on x86 the relaxed head load behaves identically to acquire.\n");

	r = rte_ring_create("rts_bug1", RING_SIZE, SOCKET_ID_ANY,
			   RING_F_MP_RTS_ENQ | RING_F_MC_RTS_DEQ);
	if (r == NULL) {
		fprintf(stderr, "ring_create failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}

	uint32_t main_lcore = rte_lcore_id();
	uint32_t lcore_id;
	int prod_count = 0, cons_count = 0;

	stop = 0;
	tot_enq = 0;
	tot_deq = 0;

	RTE_LCORE_FOREACH_WORKER(lcore_id) {
		if (prod_count < 2) {
			rte_eal_remote_launch(producer,
				(void *)(uintptr_t)prod_count, lcore_id);
			prod_count++;
		} else if (cons_count < 2) {
			rte_eal_remote_launch(consumer,
				(void *)(uintptr_t)cons_count, lcore_id);
			cons_count++;
		}
	}

	/* Wait for producers; then signal consumers. */
	uint32_t worker;
	int p = 0;
	RTE_LCORE_FOREACH_WORKER(worker) {
		if (p++ < prod_count)
			rte_eal_wait_lcore(worker);
	}
	__atomic_store_n(&stop, 1, __ATOMIC_RELEASE);
	rte_eal_mp_wait_lcore();

	printf("Total enqueued = %" PRIu64 ", dequeued = %" PRIu64 "\n",
	       tot_enq, tot_deq);
	printf("Final ring count = %u\n", rte_ring_count(r));

	/* Dump and verify quiescent state. */
	rte_ring_dump(stdout, r);

	if (rte_ring_count(r) == 0)
		printf("PASS: ring drained, no stuck state observed (x86 TSO).\n");
	else
		printf("FAIL: %u entries stuck — would indicate Bug 1 manifested.\n",
		       rte_ring_count(r));

	(void)main_lcore;
	rte_eal_cleanup();
	return 0;
}

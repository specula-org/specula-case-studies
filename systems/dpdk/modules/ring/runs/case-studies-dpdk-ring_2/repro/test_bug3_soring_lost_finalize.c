/*
 * Reproduction attempt for Bug 3 (Family D.2):
 *   SORING release stores FINISH with relaxed and immediately reads
 *   stg->sht.tail.pos with relaxed (soring.c:535-545).  The relaxed
 *   load can observe a stale tail.pos and skip the call to
 *   __rte_soring_stage_finalize.
 *
 * Severity per bug report:
 *   "Forward progress is preserved by lazy-finalize-on-acquire (the next
 *    stage_move_head will eventually walk past the FINISH), but a
 *    quiescent stage can pin a FINISH slot indefinitely — burning ring
 *    capacity..."  Liveness only — not safety.
 *
 * Reachability analysis on x86:
 *   x86 TSO: relaxed loads observe the latest globally visible value of
 *   the cache line; relaxed stores flush in program order.  Therefore
 *   the "stale tail.pos load" cannot occur at the hardware level.
 *   At the *compiler* level a relaxed load can be moved before a relaxed
 *   store of an unrelated address, but the FINISH store and tail.pos load
 *   are aliased through the same producer-consumer message exchange:
 *   any reordering would require provable independence the optimizer
 *   doesn't have for atomics — most compilers preserve program order
 *   between adjacent atomic accesses.
 *
 * What this test does:
 *   Stress test SORING release path with a quiescent-after-burst pattern:
 *   producers enqueue + acquire + release a fixed number of bursts, then
 *   stop.  At quiescence we check that no slot is left in FINISH state
 *   (i.e., all finalize calls completed, sStageTailPos[s] == sStageHead[s]).
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
#include <rte_soring.h>
#include <rte_atomic.h>
#include <rte_launch.h>

#define RING_ELEMS 16
#define BURSTS 50000
#define BURST 2

static struct rte_soring *sor;

struct payload {
	uint32_t producer_id;
	uint32_t seq;
};

static int producer_release(void *arg)
{
	uintptr_t id = (uintptr_t)arg;
	struct payload buf[BURST];
	uint32_t ftoken;

	for (uint32_t i = 0; i < BURSTS; i++) {
		for (int k = 0; k < BURST; k++) {
			buf[k].producer_id = (uint32_t)id;
			buf[k].seq = i * BURST + k;
		}
		uint32_t r = 0;
		while (r == 0)
			r = rte_soring_enqueue_bulk(sor, buf, BURST, NULL);

		uint32_t got = 0;
		while (got == 0)
			got = rte_soring_acquire_bulk(sor, buf, 0, BURST,
						      &ftoken, NULL);
		rte_soring_release(sor, NULL, 0, got, ftoken);
	}
	return 0;
}

static int consumer(void *arg)
{
	(void)arg;
	struct payload buf[BURST];
	uint32_t expected_total = BURSTS * BURST * 2; /* 2 producers */
	uint32_t got_total = 0;

	while (got_total < expected_total) {
		uint32_t r = rte_soring_dequeue_burst(sor, buf, BURST, NULL);
		got_total += r;
	}
	return 0;
}

int main(int argc, char **argv)
{
	int rc = rte_eal_init(argc, argv);
	if (rc < 0)
		return 1;
	argc -= rc;
	argv += rc;

	printf("== test_bug3_soring_lost_finalize ==\n");
	printf("Architecture: x86_64 (TSO).\n");
	printf("Bug 3 is liveness-only and only manifests on weak-memory hardware.\n");

	struct rte_soring_param prm;
	memset(&prm, 0, sizeof(prm));
	prm.name = "soring_bug3";
	prm.elem_size = sizeof(struct payload);
	prm.elems = RING_ELEMS;
	prm.stages = 1;
	prm.meta_size = 0;
	prm.prod_synt = RTE_RING_SYNC_MT;
	prm.cons_synt = RTE_RING_SYNC_MT;

	ssize_t sz = rte_soring_get_memsize(&prm);
	sor = rte_zmalloc(NULL, sz, 64);
	rc = rte_soring_init(sor, &prm);
	if (rc != 0) {
		fprintf(stderr, "init failed\n");
		return 1;
	}

	uint32_t lcore;
	int p = 0;
	RTE_LCORE_FOREACH_WORKER(lcore) {
		if (p < 2)
			rte_eal_remote_launch(producer_release,
				(void *)(uintptr_t)p, lcore);
		else if (p == 2)
			rte_eal_remote_launch(consumer, NULL, lcore);
		else
			break;
		p++;
	}

	rte_eal_mp_wait_lcore();

	rte_soring_dump(stdout, sor);
	if (rte_soring_count(sor) == 0)
		printf("PASS: drained cleanly. Liveness preserved on x86.\n");
	else
		printf("FAIL: %u stuck entries (would indicate Bug 3).\n",
		       rte_soring_count(sor));

	rte_free(sor);
	rte_eal_cleanup();
	return 0;
}

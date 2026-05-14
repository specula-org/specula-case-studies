/*
 * Reproduction for Bug 4 (D.3): SORING release-count mismatch silent corruption
 *
 * The bug:
 *   `soring_release` (lib/ring/soring.c:441-465) uses RTE_ASSERT
 *   to validate that the n passed by the caller equals the n stored
 *   at acquire time. RTE_ASSERT compiles out under NDEBUG (the default
 *   release-build setting). Without it, soring_verify_state only logs.
 *   The release proceeds and stores FINISH | wrong_n into state[idx].
 *   __rte_soring_stage_finalize then walks past `wrong_n` slots — corrupting
 *   the stage tail relative to the actual acquire range.
 *
 * Build:
 *   gcc -O2 test_bug4_wrong_release_n.c \
 *       -I.../dpdk/install/usr/local/include \
 *       -L.../dpdk/install/usr/local/lib/x86_64-linux-gnu \
 *       -Wl,--whole-archive -lrte_ring -lrte_eal -lrte_kvargs -lrte_log \
 *                            -lrte_telemetry -Wl,--no-whole-archive \
 *       -lpthread -lnuma -ldl -lm -latomic -o test_bug4
 *
 * Trigger plan (caller-misuse, no concurrency required):
 *   1. Build a SORING with 1 stage, capacity 8, MT/MT.
 *   2. Producer enqueues 4 elements via rte_soring_enqueue_bulk → input
 *      tail advances to 4.
 *   3. Acquire n=3 elements at stage 0 → ftoken_A=0; head[0] = 3.
 *   4. Release with the WRONG n (n=1, mismatch with acquired 3).
 *   5. The release path stores `FINISH | 1` into state[0] instead of
 *      `FINISH | 3`.  finalize() walks 1 slot, advancing tail[0] to 1
 *      instead of 3.  Subsequent dequeue sees only 1 entry available
 *      where the producer enqueued 4 (and 3 were acquired+released).
 *
 *   Observable anomaly:
 *      rte_soring_dequeue_bulk(num=3) returns 0 (or fewer than expected).
 *      Stage 0 tail.pos differs from head[0]; counts are inconsistent.
 *      A run on the unfixed library prints the "expected vs actual"
 *      stnum mismatch line emitted by soring_verify_state under NDEBUG —
 *      the same mismatch that RTE_ASSERT would have aborted on under
 *      a debug build.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_malloc.h>
#include <rte_soring.h>
#include <rte_ring.h>

#define CAPACITY  8
#define ELEM_SIZE sizeof(uint32_t)

static int
run_misuse_test(uint32_t acquire_n, uint32_t release_n, const char *label)
{
	struct rte_soring *sor = NULL;
	struct rte_soring_param prm;
	ssize_t sz;
	uint32_t i;
	uint32_t buf[CAPACITY];
	uint32_t acq_buf[CAPACITY];
	uint32_t deq_buf[CAPACITY];
	uint32_t ftoken = 0;
	uint32_t avail = 0;
	uint32_t free_space = 0;
	uint32_t enqueued = 0;
	uint32_t acquired = 0;
	uint32_t dequeued = 0;
	int rc;

	memset(&prm, 0, sizeof(prm));
	prm.name = label;
	prm.elem_size = ELEM_SIZE;
	prm.elems = CAPACITY;
	prm.stages = 1;
	prm.meta_size = 0;
	prm.prod_synt = RTE_RING_SYNC_MT;
	prm.cons_synt = RTE_RING_SYNC_MT;

	sz = rte_soring_get_memsize(&prm);
	if (sz <= 0) {
		fprintf(stderr, "[%s] rte_soring_get_memsize failed: %zd\n",
			label, sz);
		return -1;
	}

	sor = rte_zmalloc(NULL, sz, 64);
	if (sor == NULL) {
		fprintf(stderr, "[%s] rte_zmalloc(%zd) failed\n", label, sz);
		return -1;
	}

	rc = rte_soring_init(sor, &prm);
	if (rc != 0) {
		fprintf(stderr, "[%s] rte_soring_init failed: %d\n", label, rc);
		rte_free(sor);
		return -1;
	}

	printf("\n=== %s (acquire n=%u, release n=%u) ===\n",
	       label, acquire_n, release_n);

	/* Step 2: producer enqueues 4 elements (more than acquire_n). */
	for (i = 0; i < 4; i++)
		buf[i] = 0x1000 + i;
	enqueued = rte_soring_enqueue_bulk(sor, buf, 4, &free_space);
	printf("  enqueued=%u  free_space_after=%u\n", enqueued, free_space);

	/* Step 3: acquire `acquire_n` elements at stage 0. */
	acquired = rte_soring_acquire_bulk(sor, acq_buf, 0, acquire_n,
					   &ftoken, &avail);
	printf("  acquired=%u  ftoken=0x%x  avail_after=%u\n",
	       acquired, ftoken, avail);
	if (acquired != acquire_n) {
		fprintf(stderr, "  acquire failed (got %u, wanted %u)\n",
			acquired, acquire_n);
		rte_free(sor);
		return -1;
	}

	/* Step 4: release with WRONG n.  Real DPDK code would fire
	 * RTE_ASSERT under DEBUG, but with NDEBUG (the default)
	 * verify_state only logs and the release proceeds. */
	rte_soring_release(sor, NULL, 0, release_n, ftoken);
	printf("  released n=%u (acquire returned n=%u)%s\n",
	       release_n, acquire_n,
	       (release_n != acquire_n) ? "  <-- API CONTRACT VIOLATION" : "");

	/* Step 5: dump state, attempt to dequeue. */
	rte_soring_dump(stdout, sor);

	dequeued = rte_soring_dequeue_burst(sor, deq_buf, 4, &avail);
	printf("  dequeue_burst(4) returned=%u  remaining=%u\n",
	       dequeued, avail);
	for (i = 0; i < dequeued; i++)
		printf("    deq[%u]=0x%x\n", i, deq_buf[i]);

	printf("=== count=%u free_count=%u ===\n",
	       rte_soring_count(sor), rte_soring_free_count(sor));

	rte_free(sor);
	return 0;
}

int
main(int argc, char **argv)
{
	int rc = rte_eal_init(argc, argv);
	if (rc < 0) {
		fprintf(stderr, "rte_eal_init failed (rc=%d)\n", rc);
		return 1;
	}
	argc -= rc;
	argv += rc;

	printf("================================================================\n");
	printf("DPDK SORING wrong-release-n misuse reproduction (Bug 4 / D.3)\n");
	printf("Build expected to be NDEBUG (no RTE_SORING_DEBUG): RTE_ASSERT is\n");
	printf("compiled out, so verify_state only LOGS the mismatch.\n");
	printf("================================================================\n");

	/* Baseline: correct usage (n_release == n_acquire). */
	run_misuse_test(3, 3, "baseline_correct");

	/* Misuse 1: under-release (n_release < n_acquire) — leaks slots. */
	run_misuse_test(3, 1, "misuse_under_release");

	/* Misuse 2: over-release (n_release > n_acquire) — over-advances
	 * the stage tail past the head. */
	run_misuse_test(2, 3, "misuse_over_release");

	rte_eal_cleanup();
	return 0;
}

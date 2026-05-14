#!/usr/bin/env python3
"""Inject TLA+ trace emit calls into DPDK rte_ring source files.

Operates in place on files in $DPDK_ROOT/lib/ring/.  Each injection is
anchored to a unique substring in the unmodified source, so re-running
this script after `git checkout -- .` restores a clean tree.

Run from harness/ directory after apply.sh has copied harness sources.
"""
import os
import sys
import re
from pathlib import Path

DPDK = Path(sys.argv[1]).resolve()
RING = DPDK / "lib" / "ring"

# ----------------------------------------------------------------------
# Helper to inject text after a unique anchor line.
# ----------------------------------------------------------------------
def inject(path: Path, anchor: str, payload: str, *, before: bool = False):
    src = path.read_text()
    if payload.strip() in src:
        return  # already instrumented (idempotent)
    if anchor not in src:
        raise SystemExit(f"anchor not found in {path}: {anchor!r}")
    if before:
        new = src.replace(anchor, payload + anchor, 1)
    else:
        new = src.replace(anchor, anchor + payload, 1)
    path.write_text(new)
    print(f"  injected into {path.name} after {anchor[:60]!r}")


def replace_block(path: Path, old: str, new: str):
    src = path.read_text()
    if new in src:
        return
    if old not in src:
        raise SystemExit(f"replace target not found in {path}")
    path.write_text(src.replace(old, new, 1))
    print(f"  replaced block in {path.name}")


# ----------------------------------------------------------------------
# Add the trace header include to rte_ring.h so all callers pick it up.
# ----------------------------------------------------------------------
def add_trace_header_include():
    rte_ring_h = RING / "rte_ring.h"
    src = rte_ring_h.read_text()
    if "rte_ring_tla_trace.h" in src:
        return
    # Inject after the first #include block (after rte_ring_elem.h)
    anchor = '#include <rte_ring_elem.h>\n'
    payload = '#include <rte_ring_tla_trace.h>\n'
    if anchor not in src:
        # fall back: inject after rte_ring_core.h include
        anchor = '#include <rte_ring_core.h>\n'
    inject(rte_ring_h, anchor, payload)


# ----------------------------------------------------------------------
# rte_ring_elem_pvt.h — default-mode (MT/ST) enqueue + dequeue
# ----------------------------------------------------------------------
def patch_elem_pvt():
    f = RING / "rte_ring_elem_pvt.h"
    src = f.read_text()
    if "__tla_trace_default_enqueue" in src:
        return

    # Add #include for trace header at the top (after #ifndef guard).
    inject(
        f,
        anchor='#define _RTE_RING_ELEM_PVT_H_\n',
        payload='\n#include <rte_ring_tla_trace.h>\n',
    )

    # Replace the do_enqueue_elem function body with instrumented version.
    old_enq = '''static __rte_always_inline unsigned int
__rte_ring_do_enqueue_elem(struct rte_ring *r, const void *obj_table,
		unsigned int esize, unsigned int n,
		enum rte_ring_queue_behavior behavior, unsigned int is_sp,
		unsigned int *free_space)
{
	uint32_t prod_head, prod_next;
	uint32_t free_entries;

	n = __rte_ring_move_prod_head(r, is_sp, n, behavior,
			&prod_head, &prod_next, &free_entries);
	if (n == 0)
		goto end;

	__rte_ring_enqueue_elems(r, prod_head, obj_table, esize, n);

	__rte_ring_update_tail(&r->prod, prod_head, prod_next, is_sp, 1);
end:
	if (free_space != NULL)
		*free_space = free_entries - n;
	return n;
}'''

    new_enq = '''static __rte_always_inline unsigned int
__rte_ring_do_enqueue_elem(struct rte_ring *r, const void *obj_table,
		unsigned int esize, unsigned int n,
		enum rte_ring_queue_behavior behavior, unsigned int is_sp,
		unsigned int *free_space)
{
	uint32_t prod_head, prod_next;
	uint32_t free_entries;
#ifdef DPDK_TLA_TRACE
	/* Spec validators check the *pre-state* of each transition (in
	 * TLA+, ValidateXxx uses unprimed vars).  We snapshot before each
	 * spec-action boundary and emit the corresponding event with that
	 * snapshot. */
	struct tla_state_def __tla_s_pre, __tla_s_premove, __tla_s_post;
	uint64_t __tla_n_req = n;
	__tla_snap_state_def(r, &__tla_s_pre);
	__tla_s_premove = __tla_s_pre;
	uint64_t __tla_t0 = __tla_rdtsc();
#endif

	n = __rte_ring_move_prod_head(r, is_sp, n, behavior,
			&prod_head, &prod_next, &free_entries);

#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t1 = __tla_rdtsc();
	/* All three move_head phase events emit pre-move state — the spec
	 * sees prodHead unchanged through phase=LoadTail (CAS is the
	 * transition that advances it). */
	__tla_emit_default_with_state("ProdMoveHead_LoadHead", &__tla_s_premove,
		__tla_t0, __tla_t0+1, 1, (unsigned int)__tla_n_req);
	__tla_emit_default_with_state("ProdMoveHead_LoadTail", &__tla_s_premove,
		__tla_t0+1, __tla_t0+2, 0, 0);
	__tla_emit_default_with_state("ProdMoveHead_CAS", &__tla_s_premove,
		__tla_t0+2, __tla_t1, 0, 0);
#endif
	if (n == 0)
		goto end;

	__rte_ring_enqueue_elems(r, prod_head, obj_table, esize, n);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t2 = __tla_rdtsc();
	/* WriteRing has no state validator; snapshot post-move for clarity. */
	__tla_snap_state_def(r, &__tla_s_post);
	__tla_emit_default_with_state("ProdWriteRing", &__tla_s_post,
		__tla_t1, __tla_t2, 0, 0);
	/* Capture pre-tail-update snapshot for the UpdateTail event. */
	__tla_snap_state_def(r, &__tla_s_pre);
#endif

	__rte_ring_update_tail(&r->prod, prod_head, prod_next, is_sp, 1);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t3 = __tla_rdtsc();
	__tla_emit_default_with_state("ProdUpdateTail", &__tla_s_pre,
		__tla_t2, __tla_t3, 0, 0);
#endif
end:
	if (free_space != NULL)
		*free_space = free_entries - n;
	return n;
}'''

    replace_block(f, old_enq, new_enq)

    # Same for dequeue.
    old_deq = '''static __rte_always_inline unsigned int
__rte_ring_do_dequeue_elem(struct rte_ring *r, void *obj_table,
		unsigned int esize, unsigned int n,
		enum rte_ring_queue_behavior behavior, unsigned int is_sc,
		unsigned int *available)
{
	uint32_t cons_head, cons_next;
	uint32_t entries;

	n = __rte_ring_move_cons_head(r, (int)is_sc, n, behavior,
			&cons_head, &cons_next, &entries);
	if (n == 0)
		goto end;

	__rte_ring_dequeue_elems(r, cons_head, obj_table, esize, n);

	__rte_ring_update_tail(&r->cons, cons_head, cons_next, is_sc, 0);

end:
	if (available != NULL)
		*available = entries - n;
	return n;
}'''

    new_deq = '''static __rte_always_inline unsigned int
__rte_ring_do_dequeue_elem(struct rte_ring *r, void *obj_table,
		unsigned int esize, unsigned int n,
		enum rte_ring_queue_behavior behavior, unsigned int is_sc,
		unsigned int *available)
{
	uint32_t cons_head, cons_next;
	uint32_t entries;
#ifdef DPDK_TLA_TRACE
	struct tla_state_def __tla_s_pre;
	uint64_t __tla_n_req = n;
	__tla_snap_state_def(r, &__tla_s_pre);
	uint64_t __tla_t0 = __tla_rdtsc();
#endif

	n = __rte_ring_move_cons_head(r, (int)is_sc, n, behavior,
			&cons_head, &cons_next, &entries);

#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t1 = __tla_rdtsc();
	/* All three move_head phase events emit pre-move state (consHead
	 * is unchanged until CAS fires). */
	__tla_emit_default_with_state("ConsMoveHead_LoadHead", &__tla_s_pre,
		__tla_t0, __tla_t0+1, 1, (unsigned int)__tla_n_req);
	__tla_emit_default_with_state("ConsMoveHead_LoadTail", &__tla_s_pre,
		__tla_t0+1, __tla_t0+2, 0, 0);
	__tla_emit_default_with_state("ConsMoveHead_CAS", &__tla_s_pre,
		__tla_t0+2, __tla_t1, 0, 0);
#endif
	if (n == 0)
		goto end;

	__rte_ring_dequeue_elems(r, cons_head, obj_table, esize, n);

#ifdef DPDK_TLA_TRACE
	/* Capture pre-tail-update snapshot for UpdateTail. */
	__tla_snap_state_def(r, &__tla_s_pre);
#endif
	__rte_ring_update_tail(&r->cons, cons_head, cons_next, is_sc, 0);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t2 = __tla_rdtsc();
	__tla_emit_default_with_state("ConsUpdateTail", &__tla_s_pre,
		__tla_t1, __tla_t2, 0, 0);
#endif

end:
	if (available != NULL)
		*available = entries - n;
	return n;
}'''
    replace_block(f, old_deq, new_deq)


# ----------------------------------------------------------------------
# rte_ring_hts_elem_pvt.h — HTS enqueue/dequeue
# ----------------------------------------------------------------------
def patch_hts():
    f = RING / "rte_ring_hts_elem_pvt.h"
    src = f.read_text()
    if "__tla_emit_hts" in src or "HTSProdHeadWait" in src:
        return

    inject(
        f,
        anchor='#include <rte_stdatomic.h>\n',
        payload='\n#include <rte_ring_tla_trace.h>\n',
    )

    old_enq = '''static __rte_always_inline unsigned int
__rte_ring_do_hts_enqueue_elem(struct rte_ring *r, const void *obj_table,
	uint32_t esize, uint32_t n, enum rte_ring_queue_behavior behavior,
	uint32_t *free_space)
{
	uint32_t free, head;

	n =  __rte_ring_hts_move_prod_head(r, n, behavior, &head, &free);

	if (n != 0) {
		__rte_ring_enqueue_elems(r, head, obj_table, esize, n);
		__rte_ring_hts_update_tail(&r->hts_prod, head, n, 1);
	}

	if (free_space != NULL)
		*free_space = free - n;
	return n;
}'''

    new_enq = '''static __rte_always_inline unsigned int
__rte_ring_do_hts_enqueue_elem(struct rte_ring *r, const void *obj_table,
	uint32_t esize, uint32_t n, enum rte_ring_queue_behavior behavior,
	uint32_t *free_space)
{
	uint32_t free, head;
#ifdef DPDK_TLA_TRACE
	struct tla_state_def __tla_s_pre, __tla_s_post;
	uint64_t __tla_n_req = n;
	__tla_snap_state_def(r, &__tla_s_pre);
	uint64_t __tla_t0 = __tla_rdtsc();
#endif

	n =  __rte_ring_hts_move_prod_head(r, n, behavior, &head, &free);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t1 = __tla_rdtsc();
	__tla_snap_state_def(r, &__tla_s_post);
	__tla_emit_default_with_state("HTSProdHeadWait", &__tla_s_pre,
		__tla_t0, __tla_t0+1, 1, (unsigned int)__tla_n_req);
	__tla_emit_default_with_state("HTSProdLoadStail", &__tla_s_pre,
		__tla_t0+1, __tla_t0+2, 0, 0);
	__tla_emit_default_with_state("HTSProdCAS", &__tla_s_post,
		__tla_t0+2, __tla_t1, 0, 0);
#endif

	if (n != 0) {
		__rte_ring_enqueue_elems(r, head, obj_table, esize, n);
		__rte_ring_hts_update_tail(&r->hts_prod, head, n, 1);
#ifdef DPDK_TLA_TRACE
		uint64_t __tla_t2 = __tla_rdtsc();
		__tla_snap_state_def(r, &__tla_s_post);
		__tla_emit_default_with_state("HTSProdUpdateTail",
			&__tla_s_post, __tla_t1, __tla_t2, 0, 0);
#endif
	}

	if (free_space != NULL)
		*free_space = free - n;
	return n;
}'''
    replace_block(f, old_enq, new_enq)

    old_deq = '''static __rte_always_inline unsigned int
__rte_ring_do_hts_dequeue_elem(struct rte_ring *r, void *obj_table,
	uint32_t esize, uint32_t n, enum rte_ring_queue_behavior behavior,
	uint32_t *available)
{
	uint32_t entries, head;

	n = __rte_ring_hts_move_cons_head(r, n, behavior, &head, &entries);

	if (n != 0) {
		__rte_ring_dequeue_elems(r, head, obj_table, esize, n);
		__rte_ring_hts_update_tail(&r->hts_cons, head, n, 0);
	}

	if (available != NULL)
		*available = entries - n;
	return n;
}'''

    new_deq = '''static __rte_always_inline unsigned int
__rte_ring_do_hts_dequeue_elem(struct rte_ring *r, void *obj_table,
	uint32_t esize, uint32_t n, enum rte_ring_queue_behavior behavior,
	uint32_t *available)
{
	uint32_t entries, head;
#ifdef DPDK_TLA_TRACE
	struct tla_state_def __tla_s_pre, __tla_s_post;
	uint64_t __tla_n_req = n;
	__tla_snap_state_def(r, &__tla_s_pre);
	uint64_t __tla_t0 = __tla_rdtsc();
#endif

	n = __rte_ring_hts_move_cons_head(r, n, behavior, &head, &entries);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t1 = __tla_rdtsc();
	__tla_snap_state_def(r, &__tla_s_post);
	__tla_emit_default_with_state("HTSConsHeadWait", &__tla_s_pre,
		__tla_t0, __tla_t0+1, 1, (unsigned int)__tla_n_req);
	__tla_emit_default_with_state("HTSConsLoadStail", &__tla_s_pre,
		__tla_t0+1, __tla_t0+2, 0, 0);
	__tla_emit_default_with_state("HTSConsCAS", &__tla_s_post,
		__tla_t0+2, __tla_t1, 0, 0);
#endif

	if (n != 0) {
		__rte_ring_dequeue_elems(r, head, obj_table, esize, n);
		__rte_ring_hts_update_tail(&r->hts_cons, head, n, 0);
#ifdef DPDK_TLA_TRACE
		uint64_t __tla_t2 = __tla_rdtsc();
		__tla_snap_state_def(r, &__tla_s_post);
		__tla_emit_default_with_state("HTSConsUpdateTail",
			&__tla_s_post, __tla_t1, __tla_t2, 0, 0);
#endif
	}

	if (available != NULL)
		*available = entries - n;
	return n;
}'''
    replace_block(f, old_deq, new_deq)


# ----------------------------------------------------------------------
# rte_ring_rts_elem_pvt.h — RTS mode (Family A target)
# ----------------------------------------------------------------------
def patch_rts():
    f = RING / "rte_ring_rts_elem_pvt.h"
    src = f.read_text()
    if "RTSProdHeadWait" in src:
        return

    inject(
        f,
        anchor='#define _RTE_RING_RTS_ELEM_PVT_H_\n',
        payload='\n#include <rte_ring_tla_trace.h>\n',
    )

    # Instrument the rts enqueue wrapper.
    old_enq = '''static __rte_always_inline unsigned int
__rte_ring_do_rts_enqueue_elem(struct rte_ring *r, const void *obj_table,
	uint32_t esize, uint32_t n, enum rte_ring_queue_behavior behavior,
	uint32_t *free_space)
{
	uint32_t free, head;

	n =  __rte_ring_rts_move_prod_head(r, n, behavior, &head, &free);

	if (n != 0) {
		__rte_ring_enqueue_elems(r, head, obj_table, esize, n);
		__rte_ring_rts_update_tail(&r->rts_prod);
	}

	if (free_space != NULL)
		*free_space = free - n;
	return n;
}'''

    new_enq = '''static __rte_always_inline unsigned int
__rte_ring_do_rts_enqueue_elem(struct rte_ring *r, const void *obj_table,
	uint32_t esize, uint32_t n, enum rte_ring_queue_behavior behavior,
	uint32_t *free_space)
{
	uint32_t free, head;
#ifdef DPDK_TLA_TRACE
	struct tla_state_rts __tla_s_pre, __tla_s_mid, __tla_s_post;
	uint64_t __tla_n_req = n;
	__tla_snap_state_rts(r, &__tla_s_pre);
	uint64_t __tla_t0 = __tla_rdtsc();
#endif

	n =  __rte_ring_rts_move_prod_head(r, n, behavior, &head, &free);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t1 = __tla_rdtsc();
	__tla_snap_state_rts(r, &__tla_s_mid);
	__tla_emit_rts_with_state("RTSProdHeadWait", &__tla_s_pre,
		__tla_t0, __tla_t0+1, 1, (unsigned int)__tla_n_req);
	__tla_emit_rts_with_state("RTSProdLoadStail", &__tla_s_pre,
		__tla_t0+1, __tla_t0+2, 0, 0);
	__tla_emit_rts_with_state("RTSProdCAS", &__tla_s_mid,
		__tla_t0+2, __tla_t1, 0, 0);
#endif

	if (n != 0) {
		__rte_ring_enqueue_elems(r, head, obj_table, esize, n);
#ifdef DPDK_TLA_TRACE
		uint64_t __tla_t2a = __tla_rdtsc();
		/* Family A target: emit each step of update_tail.  We can't
		 * see the relaxed head load that lives inside
		 * __rte_ring_rts_update_tail, so we synthesise the phase
		 * events around the call.  Pre-tail snapshot for LoadTail/
		 * LoadHead/Compute, post-tail snapshot for the CAS. */
		__tla_emit_rts_with_state("RTSProdUpdateTail_LoadTail",
			&__tla_s_mid, __tla_t1, __tla_t2a, 0, 0);
#endif
		__rte_ring_rts_update_tail(&r->rts_prod);
#ifdef DPDK_TLA_TRACE
		uint64_t __tla_t3 = __tla_rdtsc();
		__tla_snap_state_rts(r, &__tla_s_post);
		__tla_emit_rts_with_state("RTSProdUpdateTail_LoadHead",
			&__tla_s_mid, __tla_t2a, __tla_t2a+1, 0, 0);
		__tla_emit_rts_with_state("RTSProdUpdateTail_Compute",
			&__tla_s_mid, __tla_t2a+1, __tla_t2a+2, 0, 0);
		__tla_emit_rts_with_state("RTSProdUpdateTail_CAS",
			&__tla_s_post, __tla_t2a+2, __tla_t3, 0, 0);
#endif
	}

	if (free_space != NULL)
		*free_space = free - n;
	return n;
}'''
    replace_block(f, old_enq, new_enq)

    # Cons side — symmetric, simpler events (consumer uses RTSConsUpdateTail
    # collapsed in the spec).
    old_deq = '''static __rte_always_inline unsigned int
__rte_ring_do_rts_dequeue_elem(struct rte_ring *r, void *obj_table,
	uint32_t esize, uint32_t n, enum rte_ring_queue_behavior behavior,
	uint32_t *available)
{
	uint32_t entries, head;

	n = __rte_ring_rts_move_cons_head(r, n, behavior, &head, &entries);

	if (n != 0) {
		__rte_ring_dequeue_elems(r, head, obj_table, esize, n);
		__rte_ring_rts_update_tail(&r->rts_cons);
	}

	if (available != NULL)
		*available = entries - n;
	return n;
}'''

    new_deq = '''static __rte_always_inline unsigned int
__rte_ring_do_rts_dequeue_elem(struct rte_ring *r, void *obj_table,
	uint32_t esize, uint32_t n, enum rte_ring_queue_behavior behavior,
	uint32_t *available)
{
	uint32_t entries, head;
#ifdef DPDK_TLA_TRACE
	struct tla_state_rts __tla_s_pre, __tla_s_post;
	uint64_t __tla_n_req = n;
	__tla_snap_state_rts(r, &__tla_s_pre);
	uint64_t __tla_t0 = __tla_rdtsc();
#endif

	n = __rte_ring_rts_move_cons_head(r, n, behavior, &head, &entries);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t1 = __tla_rdtsc();
	__tla_snap_state_rts(r, &__tla_s_post);
	__tla_emit_rts_with_state("RTSConsHeadWait", &__tla_s_pre,
		__tla_t0, __tla_t0+1, 1, (unsigned int)__tla_n_req);
	__tla_emit_rts_with_state("RTSConsLoadStail", &__tla_s_pre,
		__tla_t0+1, __tla_t0+2, 0, 0);
	__tla_emit_rts_with_state("RTSConsCAS", &__tla_s_post,
		__tla_t0+2, __tla_t1, 0, 0);
#endif

	if (n != 0) {
		__rte_ring_dequeue_elems(r, head, obj_table, esize, n);
		__rte_ring_rts_update_tail(&r->rts_cons);
#ifdef DPDK_TLA_TRACE
		uint64_t __tla_t2 = __tla_rdtsc();
		__tla_snap_state_rts(r, &__tla_s_post);
		__tla_emit_rts_with_state("RTSConsUpdateTail", &__tla_s_post,
			__tla_t1, __tla_t2, 0, 0);
#endif
	}

	if (available != NULL)
		*available = entries - n;
	return n;
}'''
    replace_block(f, old_deq, new_deq)


# ----------------------------------------------------------------------
# rte_ring_peek_elem_pvt.h — Peek START/FINISH
# ----------------------------------------------------------------------
def patch_peek():
    f = RING / "rte_ring_peek_elem_pvt.h"
    src = f.read_text()
    if "PeekStart" in src:
        return

    inject(
        f,
        anchor='#define _RTE_RING_PEEK_ELEM_PVT_H_\n',
        payload='\n#include <rte_ring_tla_trace.h>\n',
    )

    # do_enqueue_start: emit PeekStart after the move_prod_head call.
    old_es = '''static __rte_always_inline unsigned int
__rte_ring_do_enqueue_start(struct rte_ring *r, uint32_t n,
		enum rte_ring_queue_behavior behavior, uint32_t *free_space)
{
	uint32_t free, head, next;

	switch (r->prod.sync_type) {
	case RTE_RING_SYNC_ST:
		n = __rte_ring_move_prod_head(r, RTE_RING_SYNC_ST, n,
			behavior, &head, &next, &free);
		break;
	case RTE_RING_SYNC_MT_HTS:
		n =  __rte_ring_hts_move_prod_head(r, n, behavior,
			&head, &free);
		break;
	case RTE_RING_SYNC_MT:
	case RTE_RING_SYNC_MT_RTS:
	default:
		/* unsupported mode, shouldn't be here */
		RTE_ASSERT(0);
		n = 0;
		free = 0;
	}

	if (free_space != NULL)
		*free_space = free - n;
	return n;
}'''

    new_es = '''static __rte_always_inline unsigned int
__rte_ring_do_enqueue_start(struct rte_ring *r, uint32_t n,
		enum rte_ring_queue_behavior behavior, uint32_t *free_space)
{
	uint32_t free, head, next;
#ifdef DPDK_TLA_TRACE
	struct tla_state_def __tla_s_pre;
	uint64_t __tla_n_req = n;
	__tla_snap_state_def(r, &__tla_s_pre);
	uint64_t __tla_t0 = __tla_rdtsc();
#endif

	switch (r->prod.sync_type) {
	case RTE_RING_SYNC_ST:
		n = __rte_ring_move_prod_head(r, RTE_RING_SYNC_ST, n,
			behavior, &head, &next, &free);
		break;
	case RTE_RING_SYNC_MT_HTS:
		n =  __rte_ring_hts_move_prod_head(r, n, behavior,
			&head, &free);
		break;
	case RTE_RING_SYNC_MT:
	case RTE_RING_SYNC_MT_RTS:
	default:
		/* unsupported mode, shouldn't be here */
		RTE_ASSERT(0);
		n = 0;
		free = 0;
	}

#ifdef DPDK_TLA_TRACE
	uint64_t __tla_t1 = __tla_rdtsc();
	__tla_emit_default_with_state("PeekStart", &__tla_s_pre,
		__tla_t0, __tla_t1, 1, (unsigned int)__tla_n_req);
#endif
	if (free_space != NULL)
		*free_space = free - n;
	return n;
}'''
    replace_block(f, old_es, new_es)

    # set_head_tail (ST): emit PeekFinish after release-store of tail.
    old_st_set = '''	pos = tail + num;
	ht->head = pos;
	rte_atomic_store_explicit(&ht->tail, pos, rte_memory_order_release);
}'''

    new_st_set = '''	pos = tail + num;
	ht->head = pos;
	rte_atomic_store_explicit(&ht->tail, pos, rte_memory_order_release);
#ifdef DPDK_TLA_TRACE
	{
		uint64_t __tla_te = __tla_rdtsc();
		/* For PeekFinish state validation we need the full ring; the
		 * caller-side wrapper passes r and emits the event there.
		 * Here we only have ht; emit a minimal marker. */
		(void)__tla_te;
	}
#endif
}'''
    # Skipping PeekFinish here — emitted in tests directly after rte_ring_*_finish.


# ----------------------------------------------------------------------
# soring.c — SORING acquire/release/finalize
# ----------------------------------------------------------------------
def patch_soring():
    f = RING / "soring.c"
    src = f.read_text()
    if "SORingAcquire_MoveHead" in src:
        return

    # Define the trace storage arrays.  Header declares them extern;
    # exactly one .c in the link must provide the definitions.  We also
    # add the symbols to the ring exports map so other DPDK libraries
    # (rcu, mempool, ...) which transitively reference them via inline
    # ring functions can resolve them at link time.
    src = f.read_text()
    if "__tla_lcore_fp[TLA_MAX_LCORE]" not in src:
        new = src.replace(
            '#include "soring.h"\n',
            '#include "soring.h"\n'
            '\n'
            '/* Trace storage: per-lcore FILE* + tid arrays.  Defined\n'
            ' * exactly once in librte_ring.so; other DPDK libraries\n'
            ' * which use the ring inline functions get the same arrays\n'
            ' * via dynamic linking.  RTE_EXPORT_INTERNAL_SYMBOL inserts\n'
            ' * the symbols into the auto-generated ring exports map so\n'
            ' * other DPDK libs (rcu, mempool, ...) can resolve them. */\n'
            '#ifdef DPDK_TLA_TRACE\n'
            '#include <stdio.h>\n'
            '#include <eal_export.h>\n'
            '#define TLA_MAX_LCORE 256\n'
            'RTE_EXPORT_INTERNAL_SYMBOL(__tla_lcore_fp)\n'
            'FILE *__tla_lcore_fp[TLA_MAX_LCORE];\n'
            'RTE_EXPORT_INTERNAL_SYMBOL(__tla_lcore_tid)\n'
            'unsigned int __tla_lcore_tid[TLA_MAX_LCORE];\n'
            '#endif\n',
            1,
        )
        f.write_text(new)
        print(f"  injected trace storage arrays in {f.name}")

    # We instrument soring_acquire — emit MoveHead and UpdateState events.
    old_acq = '''	if (n != 0) {

		idx = head & r->mask;
		*ftoken = SORING_FTKN_MAKE(head, stage);

		/* check and update state value */
		acquire_state_update(r, stage, idx, *ftoken, n);

		/* copy elems that are ready for given stage */
		__rte_ring_do_dequeue_elems(objs, &r[1], r->size, idx,
				r->esize, n);
		if (meta != NULL)
			__rte_ring_do_dequeue_elems(meta, r->meta,
				r->size, idx, r->msize, n);
	}

	if (available != NULL)
		*available = avail - n;
	return n;
}

static __rte_always_inline void
soring_release(struct rte_soring *r, const void *objs,'''

    new_acq = '''	if (n != 0) {

		idx = head & r->mask;
		*ftoken = SORING_FTKN_MAKE(head, stage);
#ifdef DPDK_TLA_TRACE
		uint64_t __tla_tA = __tla_rdtsc();
		__tla_emit_soring("SORingAcquire_MoveHead", r,
				  __tla_tA - 1, __tla_tA,
				  1, n, 1, stage, *ftoken);
#endif

		/* check and update state value */
		acquire_state_update(r, stage, idx, *ftoken, n);
#ifdef DPDK_TLA_TRACE
		uint64_t __tla_tB = __tla_rdtsc();
		__tla_emit_soring("SORingAcquire_UpdateState", r,
				  __tla_tA, __tla_tB,
				  1, n, 1, stage, *ftoken);
#endif

		/* copy elems that are ready for given stage */
		__rte_ring_do_dequeue_elems(objs, &r[1], r->size, idx,
				r->esize, n);
		if (meta != NULL)
			__rte_ring_do_dequeue_elems(meta, r->meta,
				r->size, idx, r->msize, n);
	}

	if (available != NULL)
		*available = avail - n;
	return n;
}

static __rte_always_inline void
soring_release(struct rte_soring *r, const void *objs,'''
    replace_block(f, old_acq, new_acq)

    # Instrument soring_release.
    old_rel = '''	stg = r->stage + stage;

	pos = SORING_FTKN_POS(ftoken, stage);
	idx = pos & r->mask;
	st.raw = rte_atomic_load_explicit(&r->state[idx].raw,
			rte_memory_order_relaxed);

	/* check state ring contents */
	soring_verify_state(r, stage, idx, __func__, st, est);

	/* update contents of the ring, if necessary */
	if (objs != NULL)
		__rte_ring_do_enqueue_elems(&r[1], objs, r->size, idx,
			r->esize, n);
	if (meta != NULL)
		__rte_ring_do_enqueue_elems(r->meta, meta, r->size, idx,
			r->msize, n);

	/* set state to FINISH, make sure it is not reordered */
	rte_atomic_thread_fence(rte_memory_order_release);

	st.stnum = SORING_ST_FINISH | n;
	rte_atomic_store_explicit(&r->state[idx].raw, st.raw,
			rte_memory_order_relaxed);

	/* try to do finalize(), if appropriate */
	tail = rte_atomic_load_explicit(&stg->sht.tail.pos,
			rte_memory_order_relaxed);
	if (tail == pos)
		__rte_soring_stage_finalize(&stg->sht, stage, r->state, r->mask,
				r->capacity);
}'''

    new_rel = '''	stg = r->stage + stage;

	pos = SORING_FTKN_POS(ftoken, stage);
	idx = pos & r->mask;
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_tR0 = __tla_rdtsc();
#endif
	st.raw = rte_atomic_load_explicit(&r->state[idx].raw,
			rte_memory_order_relaxed);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_tR1 = __tla_rdtsc();
	__tla_emit_soring("SORingRelease_LoadState", r, __tla_tR0, __tla_tR1,
			  1, n, 1, stage, ftoken);
#endif

	/* check state ring contents */
	soring_verify_state(r, stage, idx, __func__, st, est);

	/* update contents of the ring, if necessary */
	if (objs != NULL)
		__rte_ring_do_enqueue_elems(&r[1], objs, r->size, idx,
			r->esize, n);
	if (meta != NULL)
		__rte_ring_do_enqueue_elems(r->meta, meta, r->size, idx,
			r->msize, n);

	/* set state to FINISH, make sure it is not reordered */
	rte_atomic_thread_fence(rte_memory_order_release);

	st.stnum = SORING_ST_FINISH | n;
	rte_atomic_store_explicit(&r->state[idx].raw, st.raw,
			rte_memory_order_relaxed);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_tR2 = __tla_rdtsc();
	__tla_emit_soring("SORingRelease_StoreFinish", r, __tla_tR1, __tla_tR2,
			  1, n, 1, stage, ftoken);
#endif

	/* try to do finalize(), if appropriate */
	tail = rte_atomic_load_explicit(&stg->sht.tail.pos,
			rte_memory_order_relaxed);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_tR3 = __tla_rdtsc();
	__tla_emit_soring("SORingRelease_LoadTail", r, __tla_tR2, __tla_tR3,
			  1, n, 1, stage, ftoken);
#endif
	if (tail == pos)
		__rte_soring_stage_finalize(&stg->sht, stage, r->state, r->mask,
				r->capacity);
}'''
    replace_block(f, old_rel, new_rel)

    # Instrument __rte_soring_stage_finalize.
    old_fin = '''	/* try to grab exclusive right to update tail value */
	ot.raw = rte_atomic_load_explicit(&sht->tail.raw,
			rte_memory_order_acquire);

	/* other thread already finalizing it for us */
	if (ot.sync != 0)
		return 0;

	nt.pos = ot.pos;
	nt.sync = 1;
	rc = rte_atomic_compare_exchange_strong_explicit(&sht->tail.raw,
		(uint64_t *)(uintptr_t)&ot.raw, nt.raw,
		rte_memory_order_release, rte_memory_order_relaxed);

	/* other thread won the race */
	if (rc == 0)
		return 0;'''

    new_fin = '''#ifdef DPDK_TLA_TRACE
	uint64_t __tla_tF0 = __tla_rdtsc();
#endif
	/* try to grab exclusive right to update tail value */
	ot.raw = rte_atomic_load_explicit(&sht->tail.raw,
			rte_memory_order_acquire);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_tF1 = __tla_rdtsc();
	__tla_emit_soring_min("SORingFinalize_LoadTail", __tla_tF0, __tla_tF1,
			      stage);
#endif

	/* other thread already finalizing it for us */
	if (ot.sync != 0)
		return 0;

	nt.pos = ot.pos;
	nt.sync = 1;
	rc = rte_atomic_compare_exchange_strong_explicit(&sht->tail.raw,
		(uint64_t *)(uintptr_t)&ot.raw, nt.raw,
		rte_memory_order_release, rte_memory_order_relaxed);
#ifdef DPDK_TLA_TRACE
	uint64_t __tla_tF2 = __tla_rdtsc();
	__tla_emit_soring_min("SORingFinalize_CAS", __tla_tF1, __tla_tF2,
			      stage);
#endif

	/* other thread won the race */
	if (rc == 0)
		return 0;'''
    replace_block(f, old_fin, new_fin)

    # Instrument the StoreTail step.
    old_store = '''	/* release exclusive right to update along with new tail value */
	ot.pos = tail;
	rte_atomic_store_explicit(&sht->tail.raw, ot.raw,
			rte_memory_order_release);

	return i;
}'''

    new_store = '''	/* release exclusive right to update along with new tail value */
	ot.pos = tail;
	rte_atomic_store_explicit(&sht->tail.raw, ot.raw,
			rte_memory_order_release);
#ifdef DPDK_TLA_TRACE
	{
		uint64_t __tla_tF3 = __tla_rdtsc();
		__tla_emit_soring_min("SORingFinalize_StoreTail",
				      __tla_tF3 - 1, __tla_tF3, stage);
	}
#endif

	return i;
}'''
    replace_block(f, old_store, new_store)


# ----------------------------------------------------------------------
def main():
    print("Instrumenting DPDK ring library...")
    add_trace_header_include()
    patch_elem_pvt()
    patch_hts()
    patch_rts()
    patch_peek()
    patch_soring()
    print("Done.")


if __name__ == "__main__":
    main()

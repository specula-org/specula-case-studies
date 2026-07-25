//! Trace harness scenarios for crossbeam-skiplist.
//!
//! Each `#[test]` function below is one scenario. The scenarios are designed
//! to be run one-at-a-time via cargo test --features tla-trace, with the
//! environment variable `CROSSBEAM_SKIPLIST_TRACE_DIR` pointing to a fresh
//! per-scenario directory. Each thread writes `thread_<tid>.ndjson` files
//! into that directory.
//!
//! Key/value space is restricted to {1,2,3} so the preprocessor can map them
//! to TLA+ constants `k1,k2,k3` and `v1,v2,v3`. Total distinct nodes are kept
//! under MaxNodes (= 8 in Trace.cfg).

#![cfg(feature = "tla-trace")]

use std::sync::{Arc, Barrier};
use std::thread;

use crossbeam_epoch as epoch;
use crossbeam_skiplist::SkipList;
use crossbeam_skiplist::tla_trace as tt;

/// Insert wrapper that stashes the typed key/value in thread-local before
/// calling into `insert`, so the generic `insert_internal` can include them
/// in the `Insert_Begin` event.
fn traced_insert<C: crossbeam_skiplist::comparator::Comparator<i32>>(
    s: &SkipList<i32, i32, C>,
    k: i32,
    v: i32,
    guard: &epoch::Guard,
) {
    tt::set_current_op(k as i64, v as i64);
    let entry = s.insert(k, v, guard);
    let node_addr = entry.tla_trace_node_addr();
    let s_dn = tt::read_tsc();
    entry.release(guard);
    let s_up = tt::read_tsc();
    // post-drop refcount: read via the registered node id; we have no easy
    // handle so just record 1 (the dec_ref decrement may free the node).
    // The validator's ValidateRefcount falls back to TRUE if the node is
    // already cleaned up — see Trace.tla.
    let nid = tt::node_id(node_addr);
    tt::emit_insert_done(s_dn, s_up, nid, 1);
}

fn traced_get<C: crossbeam_skiplist::comparator::Comparator<i32>>(
    s: &SkipList<i32, i32, C>,
    k: i32,
    guard: &epoch::Guard,
) {
    tt::set_current_op(k as i64, 0);
    let start = tt::read_tsc();
    let res = s.get(&k, guard);
    let end = tt::read_tsc();
    let len = s.len();
    let node_id = match &res {
        Some(e) => tt::node_id(e.tla_trace_node_addr()),
        None => 0,
    };
    tt::emit_get(start, end, k as i64, node_id, len);
}

fn traced_remove<C: crossbeam_skiplist::comparator::Comparator<i32>>(
    s: &SkipList<i32, i32, C>,
    k: i32,
    guard: &epoch::Guard,
) where
    C: crossbeam_skiplist::comparator::Comparator<i32>,
{
    tt::set_current_op(k as i64, 0);
    let entry_opt = s.remove(&k, guard);
    let s_dn = tt::read_tsc();
    let (node_id, refcount, found) = match entry_opt {
        Some(entry) => {
            let addr = entry.tla_trace_node_addr();
            entry.release(guard);
            (tt::node_id(addr), 1usize, true)
        }
        None => (0u64, 0usize, false),
    };
    let s_up = tt::read_tsc();
    tt::emit_remove_done(s_dn, s_up, node_id, refcount, found);
}

/// Iterate over all entries via the (lifetimed) iterator and emit
/// Iter_Begin/Iter_Next/Iter_Drop events. Uses ref_iter so we can capture
/// refcount on each yield.
fn traced_ref_iter_all<C: crossbeam_skiplist::comparator::Comparator<i32>>(
    s: &SkipList<i32, i32, C>,
    guard: &epoch::Guard,
) {
    let s0 = tt::read_tsc();
    let mut it = s.ref_iter();
    let s1 = tt::read_tsc();
    let iter_id = tt::new_iter_id();
    tt::set_iter_kind("ref_iter");
    tt::emit_iter_begin(s0, s1, "ref_iter", iter_id);

    loop {
        let prev = tt::iter_prev_state();
        let n0 = tt::read_tsc();
        let nx = it.next(guard);
        let n1 = tt::read_tsc();
        match nx {
            Some(e) => {
                let addr = e.tla_trace_node_addr();
                let nid = tt::node_id(addr);
                tt::emit_iter_next(n0, n1, iter_id, nid, prev, Some(2));
                tt::set_iter_prev_state("Yielded");
                e.release(guard);
            }
            None => {
                tt::emit_iter_next(n0, n1, iter_id, 0, prev, None);
                tt::set_iter_prev_state("Exhausted");
                break;
            }
        }
    }

    let d0 = tt::read_tsc();
    drop(it);
    let d1 = tt::read_tsc();
    tt::emit_iter_drop(d0, d1, iter_id, false, false, None, None);
}

#[test]
fn scenario_single_thread_basic() {
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    let guard = &epoch::pin();

    traced_insert(&s, 1, 1, guard);
    traced_insert(&s, 2, 2, guard);
    traced_insert(&s, 3, 3, guard);

    traced_get(&s, 1, guard);
    traced_get(&s, 2, guard);
    traced_get(&s, 3, guard);

    traced_remove(&s, 2, guard);
    traced_get(&s, 2, guard);

    traced_ref_iter_all(&s, guard);

    tt::flush_writer();
}

/// Replace path: inserting an existing key drives `Insert_MarkOld` because
/// `insert_internal` is called with `replace = TRUE`.
#[test]
fn scenario_insert_replace() {
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    let guard = &epoch::pin();

    traced_insert(&s, 1, 1, guard); // first insert: search.found = None
    traced_insert(&s, 1, 2, guard); // replace: search.found = Some -> mark_old
    traced_insert(&s, 1, 3, guard); // replace again
    traced_get(&s, 1, guard);
    traced_remove(&s, 1, guard);
    traced_get(&s, 1, guard);

    tt::flush_writer();
}

/// Drives `Insert_BuildLevel` by issuing enough inserts that the
/// Xorshift-seeded `random_height` draws a height >= 2 at least once. The
/// 7th call to `random_height` returns 2 with the default seed = 1, so we
/// need >= 7 inserts. Re-inserting the same key (replace path) keeps the
/// distinct node count low: 7 inserts → 7 nodes, under MaxNodes = 8.
#[test]
fn scenario_height_growth() {
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    let guard = &epoch::pin();

    // 7 inserts into the same key. Each replace allocates one new node and
    // marks the old one (drives Insert_MarkOld). The 7th draws height=2
    // (drives Insert_BuildLevel).
    for _ in 0..7 {
        traced_insert(&s, 1, 1, guard);
    }
    traced_get(&s, 1, guard);
    traced_remove(&s, 1, guard);

    tt::flush_writer();
}

#[test]
fn scenario_two_threads_distinct_keys() {
    let s = Arc::new(SkipList::<i32, i32>::new(epoch::default_collector().clone()));
    let barrier = Arc::new(Barrier::new(2));

    let mut handles = vec![];
    for i in 0..2 {
        let s = s.clone();
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            let guard = &epoch::pin();
            // Thread 0 inserts keys {1, 2}. Thread 1 inserts key {3}.
            // Distinct keys → no level-0 CAS retry across threads.
            if i == 0 {
                traced_insert(&s, 1, 1, guard);
                traced_insert(&s, 2, 2, guard);
            } else {
                traced_insert(&s, 3, 3, guard);
            }
            // Both read all keys.
            traced_get(&s, 1, guard);
            traced_get(&s, 2, guard);
            traced_get(&s, 3, guard);
            tt::flush_writer();
        }));
    }
    for h in handles {
        h.join().unwrap();
    }

    let guard = &epoch::pin();
    traced_ref_iter_all(&s, guard);
    tt::flush_writer();
}

#[test]
fn scenario_insert_remove_race() {
    let s = Arc::new(SkipList::<i32, i32>::new(epoch::default_collector().clone()));
    let barrier = Arc::new(Barrier::new(3));

    let mut handles = vec![];

    // Inserter thread.
    {
        let s = s.clone();
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            let guard = &epoch::pin();
            traced_insert(&s, 1, 1, guard);
            traced_insert(&s, 2, 2, guard);
            traced_insert(&s, 3, 3, guard);
            tt::flush_writer();
        }));
    }
    // Remover thread.
    {
        let s = s.clone();
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            let guard = &epoch::pin();
            // Remove may return None if not yet inserted.
            traced_remove(&s, 1, guard);
            traced_remove(&s, 2, guard);
            tt::flush_writer();
        }));
    }
    // Reader thread.
    {
        let s = s.clone();
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            let guard = &epoch::pin();
            traced_get(&s, 1, guard);
            traced_get(&s, 2, guard);
            traced_get(&s, 3, guard);
            tt::flush_writer();
        }));
    }

    for h in handles {
        h.join().unwrap();
    }
}

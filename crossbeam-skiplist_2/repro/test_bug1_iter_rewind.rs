// Reproduction for Bug 1: Iterator Rewind After Exhaustion in `crossbeam-skiplist`
//
// The MC counterexample (spec/bug-report.md, MC_hunt_family1_iter_rewind.cfg) shows
// that after `Iter::next` (and `Iter::next_back`, `Range::next`, `Range::next_back`)
// returns None due to exhaustion (or cross-over with the back cursor), the next
// invocation rewinds to the front (or back) of the structure instead of remaining
// exhausted, violating Rust's `FusedIterator` semantics.
//
// Root cause (base.rs, lines 2098-2120):
//   self.head = match self.head {
//       Some(n) => next_node(n.as_tower(), Excluded(&n.key), guard),
//       None    => next_node(parent.head.as_tower(), Unbounded, guard),  // REWIND
//   };
// After cross-over (`h.key >= t.key`), `self.head = None; self.tail = None;`. On the
// next invocation, the `None` arm re-enters `next_node` from the head sentinel and
// returns the front node, restarting the traversal.
//
// This file is meant to be dropped into
// `artifact/crossbeam/crossbeam-skiplist/tests/` and run with:
//   cargo test --test test_bug1_iter_rewind -- --nocapture
//
// Each test asserts that, after the iterator becomes exhausted, subsequent calls
// continue to return None. With the bug present, the iterator REWINDS — returning
// the front/back node again — which the assertion catches.

#![allow(clippy::redundant_clone)]

use std::ops::Bound;

use crossbeam_epoch as epoch;
use crossbeam_skiplist::SkipList;

// ---------------------------------------------------------------------------
// Sub-bug 1a: `Iter::next` rewinds after exhaustion
// ---------------------------------------------------------------------------
#[test]
fn iter_next_rewinds_after_single_element_exhaustion() {
    let guard = &epoch::pin();
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    s.insert(42, 1, guard).release(guard);

    let mut it = s.iter(guard);
    let first = it.next().expect("first call should yield k=42");
    assert_eq!(*first.key(), 42);

    let exhausted = it.next();
    assert!(exhausted.is_none(), "second call should yield None");

    // FusedIterator semantics: once None is returned, all subsequent calls
    // must continue to return None. With the rewind bug, the iterator's
    // internal `head` was reset to None, so the `None` arm of the match
    // re-enters `next_node(parent.head, Unbounded, ...)` and yields k=42
    // again.
    let after_exhausted = it.next();
    assert!(
        after_exhausted.is_none(),
        "after exhaustion, Iter::next should keep yielding None, but got Some(k={:?}) — REWIND BUG triggered",
        after_exhausted.as_ref().map(|e| *e.key()),
    );
}

// ---------------------------------------------------------------------------
// Sub-bug 1b: `Iter::next` rewinds after a head-tail crossover
// ---------------------------------------------------------------------------
#[test]
fn iter_next_rewinds_after_crossover() {
    let guard = &epoch::pin();
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    for k in &[1, 2, 3, 4, 5] {
        s.insert(*k, *k * 10, guard).release(guard);
    }

    let mut it = s.iter(guard);
    // Force head-tail crossover by alternating ends.
    assert_eq!(*it.next_back().unwrap().key(), 5);   // tail = 5
    assert_eq!(*it.next().unwrap().key(), 1);        // head = 1
    assert_eq!(*it.next_back().unwrap().key(), 4);   // tail = 4
    assert_eq!(*it.next().unwrap().key(), 2);        // head = 2
    assert_eq!(*it.next().unwrap().key(), 3);        // head = 3
    // Next call: head moves to 4, but 4 >= tail(4), so cross-over fires:
    // `self.head = None; self.tail = None;` and returns None.
    assert!(it.next().is_none());

    // Now both head and tail are None; the iterator is supposed to be
    // exhausted, but the `None` arm of next() will re-enter
    // `next_node(parent.head, Unbounded, ...)` and yield k=1 again.
    let after_exhausted = it.next();
    assert!(
        after_exhausted.is_none(),
        "after crossover, Iter::next should keep yielding None, but got Some(k={:?}) — REWIND BUG triggered",
        after_exhausted.as_ref().map(|e| *e.key()),
    );
}

// ---------------------------------------------------------------------------
// Sub-bug 1c: `Iter::next_back` rewinds after exhaustion
// ---------------------------------------------------------------------------
#[test]
fn iter_next_back_rewinds_after_exhaustion() {
    let guard = &epoch::pin();
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    s.insert(42, 1, guard).release(guard);

    let mut it = s.iter(guard);
    let first = it.next_back().expect("first call should yield k=42");
    assert_eq!(*first.key(), 42);

    let exhausted = it.next_back();
    assert!(exhausted.is_none(), "second call should yield None");

    let after_exhausted = it.next_back();
    assert!(
        after_exhausted.is_none(),
        "after exhaustion, Iter::next_back should keep yielding None, but got Some(k={:?}) — REWIND BUG triggered",
        after_exhausted.as_ref().map(|e| *e.key()),
    );
}

// ---------------------------------------------------------------------------
// Sub-bug 1d: `Range::next` rewinds after exhaustion (covered by PR #1252)
// ---------------------------------------------------------------------------
#[test]
fn range_next_rewinds_after_exhaustion() {
    let guard = &epoch::pin();
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    s.insert(5, 1, guard).release(guard);
    s.insert(10, 1, guard).release(guard);
    s.insert(15, 1, guard).release(guard);

    // Range fully containing the list. Exhaust forward.
    let mut r = s.range::<i32, _>(.., guard);
    assert_eq!(*r.next().unwrap().key(), 5);
    assert_eq!(*r.next().unwrap().key(), 10);
    assert_eq!(*r.next().unwrap().key(), 15);
    assert!(r.next().is_none()); // returns None, head set to None

    let after_exhausted = r.next();
    assert!(
        after_exhausted.is_none(),
        "after exhaustion, Range::next should keep yielding None, but got Some(k={:?}) — REWIND BUG triggered",
        after_exhausted.as_ref().map(|e| *e.key()),
    );
}

// ---------------------------------------------------------------------------
// Sub-bug 1e: `Range::next_back` rewinds after exhaustion (NOT covered by PR #1252)
// ---------------------------------------------------------------------------
#[test]
fn range_next_back_rewinds_after_exhaustion() {
    let guard = &epoch::pin();
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    s.insert(5, 1, guard).release(guard);
    s.insert(10, 1, guard).release(guard);
    s.insert(15, 1, guard).release(guard);

    let mut r = s.range::<i32, _>(.., guard);
    assert_eq!(*r.next_back().unwrap().key(), 15);
    assert_eq!(*r.next_back().unwrap().key(), 10);
    assert_eq!(*r.next_back().unwrap().key(), 5);
    assert!(r.next_back().is_none());

    let after_exhausted = r.next_back();
    assert!(
        after_exhausted.is_none(),
        "after exhaustion, Range::next_back should keep yielding None, but got Some(k={:?}) — REWIND BUG triggered",
        after_exhausted.as_ref().map(|e| *e.key()),
    );
}

// ---------------------------------------------------------------------------
// Sub-bug 1f: `Range::next` with bounds rewinds to start_bound after crossover
// ---------------------------------------------------------------------------
#[test]
fn range_next_rewinds_to_start_bound_after_crossover() {
    let guard = &epoch::pin();
    let s = SkipList::<i32, i32>::new(epoch::default_collector().clone());
    for k in &[1, 2, 3, 4, 5, 6, 7] {
        s.insert(*k, *k * 10, guard).release(guard);
    }

    // Range over [3, 6).
    let mut r = s.range::<i32, _>((Bound::Included(&3), Bound::Excluded(&6)), guard);
    // Force crossover.
    assert_eq!(*r.next_back().unwrap().key(), 5); // tail = 5
    assert_eq!(*r.next().unwrap().key(), 3);      // head = 3
    assert_eq!(*r.next().unwrap().key(), 4);      // head = 4
    assert!(r.next().is_none());                  // crossover, head/tail set to None

    let after_exhausted = r.next();
    assert!(
        after_exhausted.is_none(),
        "after crossover, Range::next should keep yielding None, but got Some(k={:?}) — REWIND BUG triggered (rewinds to start_bound=3)",
        after_exhausted.as_ref().map(|e| *e.key()),
    );
}

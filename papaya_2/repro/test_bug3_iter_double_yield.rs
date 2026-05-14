// Bug 3 reproduction: Iterator yields the same key twice when a key is removed
// from a slot the iter has passed and re-inserted into a slot the iter has not
// yet reached.
//
// Setup:
//   - Use a constant hasher so all keys hash to the same probe-start (slot 0).
//   - Insert key K at slot 0.
//   - Begin iter; advance once (yields K from slot 0; iter.i == 1).
//   - Remove K (slot 0 -> meta::TOMBSTONE; entry NULL).
//   - Re-insert K. Insertion probes from slot 0; meta::TOMBSTONE != EMPTY and
//     != h2(K), so the probe advances to slot 1 (or later) and the new entry
//     lands there.
//   - Resume iter. Slot 1 has meta = h2(K), so iter loads the entry and yields
//     K a second time.
//
// At no point did the map contain two live K entries simultaneously, yet a
// single iteration reports K twice. This is the IterNoDoubleYield invariant
// that the model checker reported as violated.

use papaya::HashMap;
use std::hash::{BuildHasher, Hasher};

#[derive(Default, Clone)]
struct ZeroHasher;

impl Hasher for ZeroHasher {
    fn finish(&self) -> u64 {
        0
    }
    fn write(&mut self, _: &[u8]) {}
}

#[derive(Default, Clone)]
struct ZeroBuildHasher;

impl BuildHasher for ZeroBuildHasher {
    type Hasher = ZeroHasher;
    fn build_hasher(&self) -> ZeroHasher {
        ZeroHasher
    }
}

#[test]
fn iter_double_yield_via_insert_remove_reinsert() {
    let map: HashMap<u64, u64, ZeroBuildHasher> = HashMap::builder()
        .capacity(8)
        .hasher(ZeroBuildHasher)
        .build();

    let guard = map.guard();

    // Insert K=1 (lands in slot 0 since all keys hash to 0).
    assert!(map.insert(1u64, 100, &guard).is_none());

    // Begin iteration.
    let mut iter = map.iter(&guard);

    // First yield: K=1 from slot 0.
    let first = iter.next();
    assert_eq!(first, Some((&1u64, &100u64)),
        "expected first iter.next() to yield (1, 100), got {:?}", first);
    eprintln!("iter.next() #1 -> {:?}", first);

    // Remove K=1. Slot 0 becomes meta::TOMBSTONE, entry NULL.
    let removed = map.remove(&1u64, &guard);
    assert_eq!(removed, Some(&100u64));
    eprintln!("remove(1) -> {:?}", removed);

    // Re-insert K=1 with a different value. Probe from slot 0; meta is
    // TOMBSTONE (not EMPTY), so the insert path skips slot 0 and the entry
    // lands at slot 1 (the next probe step).
    assert!(map.insert(1u64, 200, &guard).is_none());
    eprintln!("insert(1, 200) — re-inserted in a fresh slot");

    // Continue iterating. We expect either None (no more entries from this
    // iteration) or values that do NOT include K=1 again. If the iterator
    // yields K=1 a second time, the bug is reproduced.
    let mut second_yield: Option<(u64, u64)> = None;
    while let Some((k, v)) = iter.next() {
        eprintln!("iter.next() -> ({}, {})", k, v);
        if *k == 1u64 {
            second_yield = Some((*k, *v));
            break;
        }
    }

    match second_yield {
        Some((k, v)) => {
            // BUG REPRODUCED: same key yielded twice in a single iteration.
            panic!(
                "BUG 3 REPRODUCED: iterator yielded key {} twice (second yield: ({}, {})) \
                 even though the map never held two live entries with that key simultaneously",
                k, k, v
            );
        }
        None => {
            panic!(
                "Bug 3 NOT triggered: iterator did not yield K=1 a second time. \
                 (Expected the re-inserted K=1 in a later slot to be visited; \
                 either the probe placement differs from expected or the iter ended early.)"
            );
        }
    }
}

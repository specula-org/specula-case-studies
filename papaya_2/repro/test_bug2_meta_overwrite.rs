// BUG-1 Reproduction: Metadata Overwrite Race in papaya HashMap
//
// This test reproduces the race condition where InsertStoreMeta overwrites
// a concurrent RemoveStoreMeta's TOMBSTONE with h2(key), leaving stale metadata.
//
// The race requires 3 threads:
//   t_insert: InsertCASNew succeeds (entry = key_ptr, meta still EMPTY)
//   t_fixup:  InsertCASNewFail — meta fixup writes meta = h2(key)
//   t_remove: RemoveReadMeta finds meta = h2(key), removes entry, stores TOMBSTONE
//   t_insert: InsertStoreMeta writes h2(key) — OVERWRITES TOMBSTONE
//
// Level 3 modification: A yield loop is added between InsertCASNew and
// InsertStoreMeta (src/raw/mod.rs, insert_at function) to widen the race window.
// Detection: after InsertStoreMeta, check if the entry was concurrently modified.
//
// To run: cargo test --test repro_bug1_meta_overwrite -- --nocapture
// (This file is also stored in tests/repro_bug1_meta_overwrite.rs)

use papaya::HashMap;
use std::sync::atomic::Ordering;
use std::sync::Arc;

#[test]
fn bug1_meta_overwrite_race() {
    papaya::META_OVERWRITE_BUG_COUNT.store(0, Ordering::SeqCst);

    let map = Arc::new(HashMap::<u64, u64>::new());
    let iterations = 5_000;

    std::thread::scope(|s| {
        // 3 inserter threads — one will CAS successfully, others will do meta fixup
        for t in 0..3 {
            let map = map.clone();
            s.spawn(move || {
                for i in 0..iterations {
                    map.pin().insert(42u64, (t * iterations + i) as u64);
                }
            });
        }

        // 3 remover threads — will find entries via meta fixup and tombstone them
        for _ in 0..3 {
            let map = map.clone();
            s.spawn(move || {
                for _ in 0..iterations {
                    map.pin().remove(&42u64);
                }
            });
        }
    });

    let count = papaya::META_OVERWRITE_BUG_COUNT.load(Ordering::SeqCst);
    eprintln!(
        "BUG-1 Meta overwrite detections: {} (across {} iterations x 6 threads)",
        count, iterations
    );
    assert!(
        count > 0,
        "BUG-1 was not triggered — increase iterations or thread count"
    );
}

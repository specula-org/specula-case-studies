/// Reproduction test for crossbeam-skiplist bug #1142:
/// Guard-based iterators (Iter, Range) restart from the beginning after exhaustion.
///
/// The bug: `base::Iter` and `base::Range` use `None` for both "not started" and
/// "exhausted" states. After the iterator is fully consumed (returns None), calling
/// next() again restarts iteration from the beginning instead of continuing to
/// return None.
///
/// This test uses only public APIs (SkipList::iter, SkipList::range).
/// The ref-counted variants (RefIter, RefRange) are NOT affected because they
/// preserve `self.head` on exhaustion rather than resetting it to None.
///
/// Note: SkipMap::iter() and SkipMap::range() wrap RefIter/RefRange respectively,
/// so the high-level SkipMap/SkipSet APIs are NOT affected. The bug is only
/// reachable through the lower-level SkipList API (pub mod base).
use crossbeam_epoch as epoch;
use crossbeam_skiplist::SkipList;

fn main() {
    let mut failures = 0;
    let mut tests = 0;

    // ===== Test 1: Iter exhaustion restart =====
    tests += 1;
    print!("Test 1: Iter restarts after exhaustion ... ");
    {
        let list: SkipList<i32, &str> = SkipList::new(epoch::default_collector().clone());
        let guard = epoch::pin();
        list.insert(1, "one", &guard);
        list.insert(2, "two", &guard);
        list.insert(3, "three", &guard);

        let mut iter = list.iter(&guard);

        // Drain the iterator completely
        let mut count = 0;
        while iter.next().is_some() {
            count += 1;
        }
        assert_eq!(count, 3, "should have 3 elements");

        // Iterator is now exhausted — next() should return None
        let after_exhaustion = iter.next();
        if after_exhaustion.is_some() {
            println!("BUG CONFIRMED");
            println!("  iter.next() returned Some({}) after exhaustion (should be None)",
                     after_exhaustion.unwrap().key());
            failures += 1;
        } else {
            println!("NOT REPRODUCED (iter stays exhausted)");
        }
    }

    // ===== Test 2: Range exhaustion restart =====
    tests += 1;
    print!("Test 2: Range restarts after exhaustion ... ");
    {
        let list: SkipList<i32, &str> = SkipList::new(epoch::default_collector().clone());
        let guard = epoch::pin();
        list.insert(1, "one", &guard);
        list.insert(2, "two", &guard);
        list.insert(3, "three", &guard);
        list.insert(4, "four", &guard);
        list.insert(5, "five", &guard);

        let mut range = list.range(2..=4, &guard);

        // Drain the range iterator completely
        let mut keys = vec![];
        while let Some(entry) = range.next() {
            keys.push(*entry.key());
        }
        assert_eq!(keys, vec![2, 3, 4], "range should yield [2, 3, 4]");

        // Range is now exhausted — next() should return None
        let after_exhaustion = range.next();
        if after_exhaustion.is_some() {
            println!("BUG CONFIRMED");
            println!("  range.next() returned Some({}) after exhaustion (should be None)",
                     after_exhaustion.unwrap().key());
            failures += 1;
        } else {
            println!("NOT REPRODUCED (range stays exhausted)");
        }
    }

    // ===== Test 3: Iter next_back exhaustion restart =====
    tests += 1;
    print!("Test 3: Iter::next_back restarts after exhaustion ... ");
    {
        let list: SkipList<i32, &str> = SkipList::new(epoch::default_collector().clone());
        let guard = epoch::pin();
        list.insert(1, "one", &guard);
        list.insert(2, "two", &guard);
        list.insert(3, "three", &guard);

        let mut iter = list.iter(&guard);

        // Drain from the back
        let mut count = 0;
        while iter.next_back().is_some() {
            count += 1;
        }
        assert_eq!(count, 3, "should have 3 elements from back");

        // Exhausted — next_back() should return None
        let after_exhaustion = iter.next_back();
        if after_exhaustion.is_some() {
            println!("BUG CONFIRMED");
            println!("  iter.next_back() returned Some({}) after exhaustion",
                     after_exhaustion.unwrap().key());
            failures += 1;
        } else {
            println!("NOT REPRODUCED");
        }
    }

    // ===== Test 4: Mixed forward/backward exhaustion =====
    tests += 1;
    print!("Test 4: Mixed next/next_back causes premature exhaustion then restart ... ");
    {
        let list: SkipList<i32, &str> = SkipList::new(epoch::default_collector().clone());
        let guard = epoch::pin();
        for i in 1..=10 {
            list.insert(i, "val", &guard);
        }

        let mut iter = list.iter(&guard);

        // Advance from front to key=5
        for _ in 0..5 {
            iter.next();
        }
        // Advance from back to key=6
        for _ in 0..5 {
            iter.next_back();
        }
        // Now head >= tail, both set to None → exhausted
        let none_check = iter.next();
        assert!(none_check.is_none(), "should be exhausted after meeting in middle");

        // Now call next() again — bug would restart from beginning
        let after_exhaustion = iter.next();
        if after_exhaustion.is_some() {
            println!("BUG CONFIRMED");
            println!("  iter.next() returned Some({}) after forward/backward exhaustion",
                     after_exhaustion.unwrap().key());
            failures += 1;
        } else {
            println!("NOT REPRODUCED");
        }
    }

    // ===== Test 5: Verify RefIter (used by SkipMap) is NOT affected =====
    tests += 1;
    print!("Test 5: RefIter (SkipMap::iter) does NOT restart ... ");
    {
        use crossbeam_skiplist::SkipMap;
        let map: SkipMap<i32, &str> = SkipMap::new();
        map.insert(1, "one");
        map.insert(2, "two");
        map.insert(3, "three");

        let mut iter = map.iter();

        // Drain completely
        let mut count = 0;
        while iter.next().is_some() {
            count += 1;
        }
        assert_eq!(count, 3);

        // Should stay exhausted
        let after_exhaustion = iter.next();
        if after_exhaustion.is_some() {
            println!("UNEXPECTED — RefIter also has the bug!");
            failures += 1;
        } else {
            println!("OK (RefIter stays exhausted, as expected)");
        }
    }

    // ===== Summary =====
    println!("\n=== Summary ===");
    println!("Tests run: {}", tests);
    println!("Bugs triggered: {}", failures);

    if failures > 0 {
        println!("\nBug #1142 REPRODUCED: guard-based iterators restart after exhaustion.");
        println!("Affected types: base::Iter, base::Range (via SkipList::iter/range)");
        println!("NOT affected: RefIter, RefRange (via SkipMap::iter/range)");
        std::process::exit(1);
    } else {
        println!("\nBug #1142 NOT reproduced in current code.");
        std::process::exit(0);
    }
}

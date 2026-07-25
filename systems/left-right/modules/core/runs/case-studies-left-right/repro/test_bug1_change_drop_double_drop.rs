/// Reproduction test for CR-1: Aliased::change_drop() missing mem::forget(self)
///
/// Bug: When change_drop() is called on an Aliased<T, DoDrop>, it does ptr::read
/// on self.aliased to create the return value, but then self is dropped at function
/// exit. Since D::DO_DROP is true for the source type, self's Drop impl calls
/// drop_in_place on the inner T. The returned Aliased now holds a dangling reference
/// to already-freed memory.
///
/// This test demonstrates:
/// 1. DoDrop -> NoDrop: inner T is dropped during change_drop (premature drop)
/// 2. DoDrop -> DoDrop: inner T is dropped TWICE (double-free / UAF)
///
/// The safety comment says "It is always safe to change an Aliased from a dropping D
/// to a non-dropping D" -- but the implementation is unsound in this direction.

use left_right::aliasing::{Aliased, DropBehavior};
use std::sync::atomic::{AtomicUsize, Ordering};

static DROP_COUNT: AtomicUsize = AtomicUsize::new(0);

#[derive(Debug)]
struct TrackedValue {
    value: i32,
    // Use a heap allocation so UAF is detectable (not just stack reuse)
    _heap: Box<[u8; 64]>,
}

impl TrackedValue {
    fn new(v: i32) -> Self {
        TrackedValue {
            value: v,
            _heap: Box::new([0xAA; 64]),
        }
    }
}

impl Drop for TrackedValue {
    fn drop(&mut self) {
        let count = DROP_COUNT.fetch_add(1, Ordering::SeqCst) + 1;
        eprintln!(
            "  TrackedValue({}) dropped (total drop count = {})",
            self.value, count
        );
        // Poison the memory on drop so UAF is more visible
        self.value = -999;
        self._heap.fill(0xDD);
    }
}

struct DoDrop;
impl DropBehavior for DoDrop {
    const DO_DROP: bool = true;
}

struct NoDrop;
impl DropBehavior for NoDrop {
    const DO_DROP: bool = false;
}

fn main() {
    let mut bugs_found = 0;

    // =========================================================================
    // Test 1: DoDrop -> NoDrop (premature drop)
    // The safety comment says this direction is "always safe" but it's not.
    // =========================================================================
    eprintln!("=== Test 1: DoDrop -> NoDrop (premature drop) ===");
    DROP_COUNT.store(0, Ordering::SeqCst);

    {
        // Create an Aliased<TrackedValue, DoDrop>.
        // When this Aliased is dropped, it WILL drop the inner TrackedValue.
        let aliased: Aliased<TrackedValue, DoDrop> = Aliased::from(TrackedValue::new(42));
        eprintln!(
            "  Before change_drop: drop_count = {}",
            DROP_COUNT.load(Ordering::SeqCst)
        );
        assert_eq!(DROP_COUNT.load(Ordering::SeqCst), 0);

        // SAFETY: This is the buggy call. The safety comment says DoDrop->NoDrop
        // is "always safe", but the implementation drops self without mem::forget.
        let result: Aliased<TrackedValue, NoDrop> = unsafe { aliased.change_drop() };

        let count_after = DROP_COUNT.load(Ordering::SeqCst);
        eprintln!("  After change_drop: drop_count = {}", count_after);

        if count_after > 0 {
            eprintln!("  BUG CONFIRMED: Inner value was dropped during change_drop!");
            eprintln!("  The returned Aliased now holds a dangling reference.");
            bugs_found += 1;

            // Demonstrate UAF: read through the dangling reference
            // The value should be 42, but it was poisoned to -999 by Drop
            let val = result.value;
            eprintln!(
                "  UAF read: value = {} (expected 42, got {} because memory was poisoned by drop)",
                val, val
            );
            if val != 42 {
                eprintln!("  USE-AFTER-FREE CONFIRMED: read poisoned value {}", val);
            }
        } else {
            eprintln!("  No premature drop detected (bug may have been fixed).");
        }

        // result (NoDrop) goes out of scope here -- inner T is NOT dropped again
        // because NoDrop::DO_DROP = false
    }

    eprintln!();

    // =========================================================================
    // Test 2: DoDrop -> DoDrop (double-free)
    // Both the source self and the returned value will try to drop the inner T.
    // =========================================================================
    eprintln!("=== Test 2: DoDrop -> DoDrop (double-free) ===");
    DROP_COUNT.store(0, Ordering::SeqCst);

    {
        let aliased: Aliased<TrackedValue, DoDrop> = Aliased::from(TrackedValue::new(99));
        eprintln!(
            "  Before change_drop: drop_count = {}",
            DROP_COUNT.load(Ordering::SeqCst)
        );

        let result: Aliased<TrackedValue, DoDrop> = unsafe { aliased.change_drop() };

        let count_after = DROP_COUNT.load(Ordering::SeqCst);
        eprintln!("  After change_drop: drop_count = {}", count_after);

        if count_after > 0 {
            eprintln!("  BUG CONFIRMED: First drop happened during change_drop!");
        }

        // Now drop result -- this will call drop_in_place AGAIN on the same T
        // In a real program this would be a double-free (heap corruption)
        eprintln!("  About to drop result (DoDrop) -- this is the second drop...");
        drop(result);

        let final_count = DROP_COUNT.load(Ordering::SeqCst);
        eprintln!("  After dropping result: drop_count = {}", final_count);

        if final_count >= 2 {
            eprintln!(
                "  DOUBLE-FREE CONFIRMED: Inner value dropped {} times!",
                final_count
            );
            bugs_found += 1;
        }
    }

    eprintln!();

    // =========================================================================
    // Test 3: NoDrop -> DoDrop (the safe direction used in practice)
    // This should work correctly -- no premature drop.
    // =========================================================================
    eprintln!("=== Test 3: NoDrop -> DoDrop (control -- should be safe) ===");
    DROP_COUNT.store(0, Ordering::SeqCst);

    {
        let aliased: Aliased<TrackedValue, NoDrop> = Aliased::from(TrackedValue::new(7));
        eprintln!(
            "  Before change_drop: drop_count = {}",
            DROP_COUNT.load(Ordering::SeqCst)
        );

        let result: Aliased<TrackedValue, DoDrop> = unsafe { aliased.change_drop() };

        let count_after = DROP_COUNT.load(Ordering::SeqCst);
        eprintln!("  After change_drop: drop_count = {}", count_after);
        assert_eq!(
            count_after, 0,
            "NoDrop source should NOT drop inner T during change_drop"
        );

        // Access the value -- should be fine
        assert_eq!(result.value, 7, "Value should be intact");
        eprintln!("  Value intact: {}", result.value);

        drop(result);
        let final_count = DROP_COUNT.load(Ordering::SeqCst);
        eprintln!("  After dropping result: drop_count = {}", final_count);
        assert_eq!(final_count, 1, "DoDrop result should drop inner T exactly once");
        eprintln!("  CORRECT: Dropped exactly once.");
    }

    eprintln!();

    // =========================================================================
    // Summary
    // =========================================================================
    if bugs_found > 0 {
        eprintln!("RESULT: {} bug(s) reproduced successfully.", bugs_found);
        eprintln!("  - change_drop() from DoDrop source is unsound due to missing mem::forget(self)");
        eprintln!("  - Safety comment at aliasing.rs:209 is incorrect for DoDrop->NoDrop direction");
        std::process::exit(1);
    } else {
        eprintln!("RESULT: No bugs reproduced. change_drop() may have been fixed.");
        std::process::exit(0);
    }
}

//! Stress tests that, when paired with reverted memory-ordering fixes in
//! `src/strategy/hybrid.rs` or `src/debt/mod.rs`, expose historical UAFs
//! reported in arc-swap issues #76, #156, #198, #200, #204 and PR #195.
//!
//! Run under miri:
//!     MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=39" \
//!         cargo +nightly miri test --test uaf_stress
//!
//! These tests are expected to PASS on the current (post-fix) code with
//! every memory ordering at SC where the source has SC. They expose UAF
//! only when one of the named ordering fixes is reverted.

use std::sync::Arc;
use std::thread;

use arc_swap::ArcSwap;

/// Exercises the fast confirm-load path (issue #76).
/// Multiple readers do plain `load()` while writers swap.
#[test]
fn fast_path_load_swap() {
    const ITERS: usize = 30;
    const READER_THREADS: usize = 3;
    const WRITER_THREADS: usize = 2;
    let shared = ArcSwap::<usize>::from_pointee(0);
    let shared = &shared;
    thread::scope(|scope| {
        for _ in 0..READER_THREADS {
            scope.spawn(move || {
                for _ in 0..ITERS {
                    let g = shared.load();
                    let _v = **g;
                }
            });
        }
        for w in 0..WRITER_THREADS {
            scope.spawn(move || {
                for i in 0..ITERS {
                    shared.store(Arc::new((w + 1) * 1000 + i));
                }
            });
        }
    });
}

/// Exercises the rcu retry path (#195 / #204) which goes through `Debt::pay`
/// failure leg under contention.
#[test]
fn rcu_under_contention() {
    const ITERS: usize = 20;
    const THREADS: usize = 4;
    let shared = ArcSwap::<usize>::from_pointee(0);
    let shared = &shared;
    thread::scope(|scope| {
        for _ in 0..THREADS {
            scope.spawn(move || {
                for _ in 0..ITERS {
                    shared.rcu(|old| **old + 1);
                }
            });
        }
    });
    assert_eq!(THREADS * ITERS, **shared.load());
}

/// Exercises a mix of swap, load, and store. Useful for the LIST_HEAD downgrade
/// (#164 family) since it forces multi-thread node creation.
#[test]
fn mixed_load_store_rcu() {
    const ITERS: usize = 15;
    const THREADS: usize = 4;
    let shared = ArcSwap::<usize>::from_pointee(0);
    let shared = &shared;
    thread::scope(|scope| {
        for tid in 0..THREADS {
            scope.spawn(move || {
                for i in 0..ITERS {
                    if (tid + i) % 3 == 0 {
                        let g = shared.load();
                        let _v = **g;
                    } else if (tid + i) % 3 == 1 {
                        shared.store(Arc::new(tid * 100 + i));
                    } else {
                        let _old = shared.swap(Arc::new(tid * 100 + i));
                    }
                }
            });
        }
    });
}

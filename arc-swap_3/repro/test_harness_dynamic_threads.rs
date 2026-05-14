//! Stress test: spawn threads dynamically while writers swap, to force the
//! debt list to grow concurrently. Useful for #164 family (LIST_HEAD load).

use std::sync::Arc;
use std::thread;

use arc_swap::ArcSwap;

#[test]
fn dynamic_thread_spawn() {
    const ROUNDS: usize = 4;
    const READERS_PER_ROUND: usize = 3;
    let shared = ArcSwap::<usize>::from_pointee(0);
    let shared = &shared;

    thread::scope(|scope| {
        // Continuous writer
        scope.spawn(move || {
            for i in 0..(ROUNDS * 8) {
                shared.store(Arc::new(i + 1));
                std::thread::yield_now();
            }
        });
        // Continuous reader using rcu (forces fallback path with helping)
        scope.spawn(move || {
            for _ in 0..(ROUNDS * 4) {
                shared.rcu(|old| **old + 1);
            }
        });
        // Spawn fresh reader threads in waves so new nodes get prepended
        for _round in 0..ROUNDS {
            let mut handles = Vec::new();
            for _ in 0..READERS_PER_ROUND {
                handles.push(scope.spawn(move || {
                    for _ in 0..3 {
                        let g = shared.load();
                        let _v = **g;
                    }
                }));
            }
            for h in handles {
                h.join().unwrap();
            }
        }
    });
}

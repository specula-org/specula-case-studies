// Trace-collection harness for crossbeam-epoch.
//
// Each scenario is run in its own process (separate `cargo run --example`
// invocation) so the global default collector starts fresh. Run as:
//
//     cargo run --release --example tla_harness -- <scenario> <trace_dir>
//
// The harness writes per-thread NDJSON shards into <trace_dir>/trace-tN.ndjson.
// `preprocess.py` then merges + compresses timestamps into the per-thread JSON
// object that Trace.tla loads.
//
// All multi-threaded scenarios use:
//   - A scenario-local Collector (no shared global state)
//   - A start barrier (so threads pin at roughly the same time, producing
//     genuinely overlapping intervals for the timebox machinery)
//   - An end barrier (so no thread's LocalHandle is dropped — and no `Local`
//     gets finalized — while another thread is still iterating the locals
//     list in try_advance; otherwise the iterator's "finalize tagged
//     element" path emits Defer events the test never asked for)

use std::env;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Barrier};

use crossbeam_epoch::{tla_trace, Atomic, Collector, Owned, Shared};

fn main() {
    let mut args = env::args().skip(1);
    let scenario = args.next().expect("usage: tla_harness <scenario> <dir>");
    let dir = args.next().expect("usage: tla_harness <scenario> <dir>");

    std::fs::create_dir_all(&dir).expect("create trace dir");

    match scenario.as_str() {
        "basic" => run_basic(&dir),
        "concurrent_defer" => run_concurrent_defer(&dir),
        "repin_panic" => run_repin_panic(&dir),
        "nested_pin" => run_nested_pin(&dir),
        other => {
            eprintln!("unknown scenario: {}", other);
            std::process::exit(2);
        }
    }

    eprintln!("scenario '{}' complete; traces in {}", scenario, dir);
}

// --- Scenario 1: basic two-thread pin/publish/unlink/defer/flush ---
//
// Two threads each pin, publish a node, read+deref it, unlink, defer-destroy,
// unpin, and flush. Exercises Pin*, Unpin*, Defer, PushBag, CollectScan,
// BagDrop, PublishObject, UnlinkObject, ReadAndDeref. End barrier prevents
// the cross-thread "finalize tagged Local" defer.
fn run_basic(dir: &str) {
    let collector = Arc::new(Collector::new());
    let bar_start = Arc::new(Barrier::new(2));
    let bar_end = Arc::new(Barrier::new(2));
    let shared = Arc::new(Atomic::<i32>::null());

    std::thread::scope(|s| {
        for (tid_idx, obj_id) in [(1u64, 1u64), (2u64, 2u64)] {
            let tid_str = format!("t{}", tid_idx);
            let dir_t = dir.to_string();
            let c = Arc::clone(&collector);
            let bs = Arc::clone(&bar_start);
            let be = Arc::clone(&bar_end);
            let sh = Arc::clone(&shared);

            s.spawn(move || {
                tla_trace::init_thread(&tid_str, &dir_t);
                let handle = c.register();
                bs.wait();

                let g = handle.pin();
                unsafe {
                    let owned = Owned::new(7i32 + obj_id as i32);
                    let p: Shared<'_, i32> = owned.into_shared(&g);

                    let s_p = tla_trace::rdtsc();
                    sh.store(p, Ordering::Release);
                    let e_p = tla_trace::rdtsc();
                    tla_trace::emit_publish_object(s_p, e_p, obj_id);

                    let s_r = tla_trace::rdtsc();
                    let q = sh.load(Ordering::Acquire, &g);
                    let _ = q.as_ref();
                    let e_r = tla_trace::rdtsc();
                    tla_trace::emit_read_and_deref(s_r, e_r, obj_id);

                    let s_u = tla_trace::rdtsc();
                    let old = sh.swap(Shared::null(), Ordering::AcqRel, &g);
                    let e_u = tla_trace::rdtsc();
                    tla_trace::emit_unlink_object(s_u, e_u, obj_id);

                    tla_trace::set_defer_obj(obj_id);
                    g.defer_destroy(old);
                }
                drop(g);

                let g2 = handle.pin();
                g2.flush();
                drop(g2);

                be.wait();
                tla_trace::shutdown_thread();
                drop(handle);
            });
        }
    });

    drop(shared);
}

// --- Scenario 2: concurrent defer + flush + repin ---
//
// Two threads run concurrent defers and a repin in between. The Repin event
// is otherwise uncovered by the basic scenario, so this fills that gap.
// Both objects are reused across rounds, but only after the previous round's
// reclaim cycle so the spec's "obj not already retired" precondition holds.
fn run_concurrent_defer(dir: &str) {
    let collector = Arc::new(Collector::new());
    let bar_start = Arc::new(Barrier::new(2));
    let bar_end = Arc::new(Barrier::new(2));

    std::thread::scope(|s| {
        for (tid_idx, obj_id) in [(1u64, 1u64), (2u64, 2u64)] {
            let tid_str = format!("t{}", tid_idx);
            let dir_t = dir.to_string();
            let c = Arc::clone(&collector);
            let bs = Arc::clone(&bar_start);
            let be = Arc::clone(&bar_end);

            s.spawn(move || {
                tla_trace::init_thread(&tid_str, &dir_t);
                let handle = c.register();
                bs.wait();

                // Defer + repin + flush.
                let mut g = handle.pin();
                unsafe {
                    tla_trace::set_defer_obj(obj_id);
                    g.defer_unchecked(move || {});
                }
                g.repin();
                g.flush();
                drop(g);

                be.wait();
                tla_trace::shutdown_thread();
                drop(handle);
            });
        }
    });
}

// --- Scenario 3: F4 — repin_after with panicking closure ---
//
// Single worker. `repin_after(|| panic!())` inside `catch_unwind`. ScopeGuard
// must re-pin even when the closure panics. The trace decomposes into:
//   Pin*  (initial pin)
//   UnpinDec, UnpinPublish  (repin_after's local.unpin())
//   PinIncGuardCount, PinLoadGlobal, PinPublish, PinMaybeCollect
//                           (ScopeGuard::drop's mem::forget(local.pin()))
//   UnpinDec, UnpinPublish  (final drop of `g`)
fn run_repin_panic(dir: &str) {
    let collector = Arc::new(Collector::new());
    let bar_start = Arc::new(Barrier::new(2));
    let bar_end = Arc::new(Barrier::new(2));

    std::thread::scope(|s| {
        // Worker thread t1 runs the repin_panic logic.
        let dir_t = dir.to_string();
        let c = Arc::clone(&collector);
        let bs = Arc::clone(&bar_start);
        let be = Arc::clone(&bar_end);
        s.spawn(move || {
            tla_trace::init_thread("t1", &dir_t);
            let handle = c.register();
            bs.wait();

            let mut g = handle.pin();
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                g.repin_after(|| {
                    panic!("intentional repin_after panic");
                })
            }));
            assert!(result.is_err(), "expected the panic to propagate");
            drop(g);

            be.wait();
            tla_trace::shutdown_thread();
            drop(handle);
        });

        // Idle thread t2 — registers a Local so the spec's
        // Cardinality(AliveLocals) matches the impl's iteration count, but
        // emits no trace events. Held alive across both barriers.
        let c2 = Arc::clone(&collector);
        let bs2 = Arc::clone(&bar_start);
        let be2 = Arc::clone(&bar_end);
        s.spawn(move || {
            let handle = c2.register();
            bs2.wait();
            be2.wait();
            drop(handle);
        });
    });
}

// --- Scenario 4: F1 — reentrant pin from a deferred fn ---
//
// One thread defers a closure that itself calls pin(). After flush, Bag::drop
// runs the closure → re-entrant pin. The library's Bag::drop instrumentation
// enters suppress mode while running the deferred fn, so the re-entrant pin
// events do not appear in the trace; the spec models them via silent
// InDeferCallbackPin/Unpin transitions.
fn run_nested_pin(dir: &str) {
    let collector = Arc::new(Collector::new());
    let bar_start = Arc::new(Barrier::new(2));
    let bar_end = Arc::new(Barrier::new(2));

    std::thread::scope(|s| {
        let dir_t = dir.to_string();
        let c = Arc::clone(&collector);
        let bs = Arc::clone(&bar_start);
        let be = Arc::clone(&bar_end);
        s.spawn(move || {
            tla_trace::init_thread("t1", &dir_t);
            let handle = c.register();
            bs.wait();

            let g = handle.pin();
            unsafe {
                tla_trace::set_defer_obj(1);
                let h2 = Arc::clone(&c);
                g.defer_unchecked(move || {
                    // Re-entrant pin inside a deferred fn — F1 path. The
                    // inner pin is suppressed (see Bag::drop instrumentation).
                    let inner = h2.register().pin();
                    drop(inner);
                });
            }
            g.flush();
            drop(g);

            be.wait();
            tla_trace::shutdown_thread();
            drop(handle);
        });

        // Idle t2 — registers a Local so AliveLocals cardinality matches.
        let c2 = Arc::clone(&collector);
        let bs2 = Arc::clone(&bar_start);
        let be2 = Arc::clone(&bar_end);
        s.spawn(move || {
            let handle = c2.register();
            bs2.wait();
            be2.wait();
            drop(handle);
        });
    });
}

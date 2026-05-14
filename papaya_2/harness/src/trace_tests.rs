// Round-2 trace test scenarios for papaya lock-free hash map.
//
// These exercise the round-2 spec actions defined in
// .specula-output/spec/instrumentation-spec.md, with focus on the
// previously-uncovered families:
//
//   * Family 6 (Adversarial Caller — iter + modify + resize)
//   * Family 7 (Slot Recycling / META Overwrite)
//   * Family 3 (Parker / Unpark Routing — D2-1)
//
// Keys are restricted to {k1, k2} matching Trace.cfg's `Key` constant.
// Threads are named by the trace module as t1, t2, t3 (in spawn order). The
// test main thread is t1 — it is responsible for capturing the eager
// `init_table` event emitted at HashMap construction.

use papaya::{HashMap, ResizeMode};
use std::sync::{Arc, Barrier};
use std::thread;

fn trace_dir() -> String {
    std::env::var("TLA_TRACE_DIR").unwrap_or_else(|_| "traces".to_string())
}

/// Install the iter key formatter for HashMap<String, String>.
fn install_string_iter_fmt() {
    papaya::tla_trace::set_iter_key_fmt(|addr| {
        let s = unsafe { &*(addr as *const String) };
        s.clone()
    });
}

fn traced_insert(map: &HashMap<String, String>, k: &str, v: &str, guard: &impl papaya::Guard) {
    papaya::tla_trace::set_pending_key(k);
    papaya::tla_trace::set_pending_val(v);
    map.insert(k.to_string(), v.to_string(), guard);
    papaya::tla_trace::clear_pending();
}

fn traced_remove(map: &HashMap<String, String>, k: &str, guard: &impl papaya::Guard) {
    papaya::tla_trace::set_pending_key(k);
    let _ = map.remove(&k.to_string(), guard);
    papaya::tla_trace::clear_pending();
}

fn raw_get(map: &HashMap<String, String>, k: &str, guard: &impl papaya::Guard) {
    let _ = map.get(&k.to_string(), guard);
}

/// Build a HashMap, capturing the eager `init_table` event in the main
/// thread's trace file (whichever thread was assigned t1 first).
fn build_map(scenario: &str, dir: &str, capacity: usize, mode: ResizeMode) -> Arc<HashMap<String, String>> {
    papaya::tla_trace::init(dir, scenario);
    // Main thread becomes t1, captures the eager init_table emit on build().
    papaya::tla_trace::thread_init();
    let map = HashMap::builder()
        .capacity(capacity)
        .resize_mode(mode)
        .build();
    Arc::new(map)
}

fn finish() {
    papaya::tla_trace::thread_shutdown();
    papaya::tla_trace::shutdown();
}

// ================================================================
// Scenario 1: Adversarial iter + modify + resize (Family 6)
// ================================================================
#[test]
fn trace_iter_modify_resize() {
    let dir = trace_dir();
    std::fs::create_dir_all(&dir).ok();

    let map = build_map("iter_modify_resize", &dir, 2, ResizeMode::Blocking);
    let barrier = Arc::new(Barrier::new(3));

    let handles: Vec<_> = (0..3)
        .map(|i| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                papaya::tla_trace::thread_init();
                install_string_iter_fmt();
                barrier.wait();

                let guard = map.guard();

                match i {
                    0 => {
                        for round in 0..6 {
                            let k = if round % 2 == 0 { "k1" } else { "k2" };
                            traced_insert(&map, k, "v1", &guard);
                            for (_k, _v) in map.iter(&guard) {}
                            raw_get(&map, k, &guard);
                        }
                    }
                    1 => {
                        for round in 0..8 {
                            let k = if round % 2 == 0 { "k2" } else { "k1" };
                            traced_remove(&map, k, &guard);
                            traced_insert(&map, k, "v2", &guard);
                        }
                    }
                    _ => {
                        for (_k, _v) in map.iter(&guard) {}
                        for round in 0..8 {
                            let k = if round % 2 == 0 { "k1" } else { "k2" };
                            let v = format!("v{}", round);
                            papaya::tla_trace::set_pending_key(k);
                            papaya::tla_trace::set_pending_val(&v);
                            map.insert(k.to_string(), v, &guard);
                            papaya::tla_trace::clear_pending();
                        }
                    }
                }

                papaya::tla_trace::clear_iter_key_fmt();
                papaya::tla_trace::thread_shutdown();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    finish();
}

// ================================================================
// Scenario 2: META Overwrite Window (Family 7 — D2-4)
// ================================================================
#[test]
fn trace_meta_overwrite_race() {
    let dir = trace_dir();
    std::fs::create_dir_all(&dir).ok();

    let map = build_map("meta_overwrite_race", &dir, 2, ResizeMode::Blocking);
    let barrier = Arc::new(Barrier::new(2));

    let handles: Vec<_> = (0..2)
        .map(|i| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                papaya::tla_trace::thread_init();
                install_string_iter_fmt();
                barrier.wait();

                let guard = map.guard();

                if i == 0 {
                    for round in 0..15 {
                        let v = if round % 2 == 0 { "v1" } else { "v2" };
                        traced_insert(&map, "k1", v, &guard);
                    }
                } else {
                    for _ in 0..15 {
                        traced_remove(&map, "k1", &guard);
                        traced_insert(&map, "k1", "v2", &guard);
                    }
                }

                papaya::tla_trace::clear_iter_key_fmt();
                papaya::tla_trace::thread_shutdown();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    finish();
}

// ================================================================
// Scenario 3: Blocking resize with parker contention (Family 3 — D2-1)
//
// Tiny initial capacity + a wide range of unique keys forces resizes and
// makes parker contention likely under blocking mode.
// ================================================================
#[test]
fn trace_blocking_resize_parkers() {
    let dir = trace_dir();
    std::fs::create_dir_all(&dir).ok();

    let map = build_map("blocking_resize_parkers", &dir, 2, ResizeMode::Blocking);
    let barrier = Arc::new(Barrier::new(3));

    let handles: Vec<_> = (0..3)
        .map(|i| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                papaya::tla_trace::thread_init();
                install_string_iter_fmt();
                barrier.wait();

                let guard = map.guard();

                let keys = ["k1", "k2"];
                for round in 0..14 {
                    let k = keys[(i + round) % 2];
                    let v = format!("v{}_{}", i, round);
                    papaya::tla_trace::set_pending_key(k);
                    papaya::tla_trace::set_pending_val(&v);
                    map.insert(k.to_string(), v, &guard);
                    papaya::tla_trace::clear_pending();

                    if round % 3 == 0 {
                        traced_remove(&map, k, &guard);
                    }
                }

                papaya::tla_trace::clear_iter_key_fmt();
                papaya::tla_trace::thread_shutdown();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    finish();
}

// ================================================================
// Scenario 4: Incremental resize + iter (mixed paths)
// ================================================================
#[test]
fn trace_incremental_resize_iter() {
    let dir = trace_dir();
    std::fs::create_dir_all(&dir).ok();

    let map = build_map("incremental_resize_iter", &dir, 2, ResizeMode::Incremental(1));
    let barrier = Arc::new(Barrier::new(3));

    let handles: Vec<_> = (0..3)
        .map(|i| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                papaya::tla_trace::thread_init();
                install_string_iter_fmt();
                barrier.wait();

                let guard = map.guard();

                if i == 0 {
                    for _ in 0..6 {
                        for (_k, _v) in map.iter(&guard) {}
                    }
                } else {
                    let keys = ["k1", "k2"];
                    for round in 0..10 {
                        let k = keys[(i + round) % 2];
                        let v = format!("v{}_{}", i, round);
                        papaya::tla_trace::set_pending_key(k);
                        papaya::tla_trace::set_pending_val(&v);
                        map.insert(k.to_string(), v, &guard);
                        papaya::tla_trace::clear_pending();
                        if round % 2 == 1 {
                            traced_remove(&map, k, &guard);
                        }
                    }
                }

                papaya::tla_trace::clear_iter_key_fmt();
                papaya::tla_trace::thread_shutdown();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    finish();
}

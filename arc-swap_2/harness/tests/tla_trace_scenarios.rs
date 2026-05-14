//! TLA+ trace harness scenarios for arc-swap.
//!
//! Each `#[test]` writes a separate `<scenario>.ndjson` file under
//! `$ARC_SWAP_TRACE_OUT` (default `/tmp/arc-swap-traces`).
//!
//! Run with:
//!   ARC_SWAP_TRACE_OUT=/path/to/traces \
//!     cargo test --test tla_trace_scenarios -- --test-threads=1
//!
//! Each scenario should be invoked in its own cargo-test process so that the
//! global LIST_HEAD starts empty.
//!
//! NOTE on coverage: the *main* test thread is not registered with the trace
//! module, so any spec-action emit it triggers (e.g. `ArcSwap::Drop` →
//! `DropArcSwap`) is silently suppressed.  Test scenarios therefore avoid
//! dropping the ArcSwap explicitly; trailing teardown is done by a worker
//! thread that owns the unique handle.

use std::sync::{Arc, Barrier};

use arc_swap::{tla_trace, ArcSwap};

fn out_dir() -> std::path::PathBuf {
    let p = std::env::var("ARC_SWAP_TRACE_OUT")
        .unwrap_or_else(|_| "/tmp/arc-swap-traces".to_string());
    std::fs::create_dir_all(&p).expect("create trace dir");
    std::path::PathBuf::from(p)
}

fn trace_path(name: &str) -> String {
    out_dir().join(format!("{name}.ndjson")).to_string_lossy().into_owned()
}

fn arc_addr<T: ?Sized>(a: &Arc<T>) -> usize {
    Arc::as_ptr(a) as *const () as usize
}

/// Scenario: 1 reader + 1 writer with an explicit barrier separating phases
/// (reader load completes, then writer swaps).  Sequential operations make
/// this the easiest trace to validate first.
#[test]
fn basic_read_write() {
    let path = trace_path("basic_read_write");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    let arcswap = Arc::new(ArcSwap::from(init_arc));
    let barr = Arc::new(Barrier::new(3));

    let reader = {
        let arcswap = Arc::clone(&arcswap);
        let barr = Arc::clone(&barr);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load()); // warm-up so this thread's node is claimed
            barr.wait();          // released after main calls enable()
            // -- traced region --
            let g = arcswap.load();
            std::hint::black_box(**g);
            drop(g);
            barr.wait();          // signal writer that read is done
        })
    };

    let writer = {
        let arcswap = Arc::clone(&arcswap);
        let barr = Arc::clone(&barr);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load()); // warm-up
            barr.wait();          // released after main calls enable()
            barr.wait();          // wait for reader to finish
            // -- traced region: the swap --
            let new_arc = Arc::new(42u64);
            let old = arcswap.swap(new_arc);
            drop(old);
            tla_trace::emit_writer_return();
        })
    };

    // Spectator t3 just claims its node so the spec's Thread = {t1, t2, t3}
    // corresponds to three real LocalNodes.  This thread does no traced work.
    let spectator = {
        let arcswap = Arc::clone(&arcswap);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
        })
    };

    spectator.join().expect("spectator");

    // Enable tracing only after spectator warm-up has completed.
    tla_trace::enable();
    barr.wait(); // releases reader+writer to do their warm-up→barr.wait
    barr.wait(); // releases writer to swap after reader finishes

    reader.join().expect("reader");
    writer.join().expect("writer");

    tla_trace::disable();
    tla_trace::shutdown();

    // Drop the test-local Arc<ArcSwap> at scope end — main thread is not
    // registered, so this drop is intentionally silent in the trace.

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

/// Scenario: 2 readers + 1 writer running concurrently from a barrier so
/// reader and writer events overlap in real time.
#[test]
fn concurrent_readers_writer() {
    let path = trace_path("concurrent_readers_writer");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    let arcswap = Arc::new(ArcSwap::from(init_arc));
    let barr = Arc::new(Barrier::new(4));

    let r1 = {
        let arcswap = Arc::clone(&arcswap);
        let barr = Arc::clone(&barr);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load()); // warm-up
            barr.wait();
            for _ in 0..2 {
                let g = arcswap.load();
                std::hint::black_box(**g);
                drop(g);
            }
        })
    };

    let r2 = {
        let arcswap = Arc::clone(&arcswap);
        let barr = Arc::clone(&barr);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load()); // warm-up
            barr.wait();
            for _ in 0..2 {
                let g = arcswap.load();
                std::hint::black_box(**g);
                drop(g);
            }
        })
    };

    let writer = {
        let arcswap = Arc::clone(&arcswap);
        let barr = Arc::clone(&barr);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load()); // warm-up
            barr.wait();
            // Single swap, so we use only addresses a1 (initial) + a2 (new).
            let new_arc = Arc::new(7u64);
            let old = arcswap.swap(new_arc);
            drop(old);
            tla_trace::emit_writer_return();
        })
    };

    tla_trace::enable();
    barr.wait();

    r1.join().expect("r1");
    r2.join().expect("r2");
    writer.join().expect("writer");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

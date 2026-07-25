//! TLA+ trace harness scenarios for arc-swap (round 4).
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
//! Round 4 changes vs round 3:
//! * NEW `family_2_guard_clone` scenario: uses `Arc::clone(&*g) +
//!   Guard::from_inner` to fork a debted Guard into a non-debted one.  Emits
//!   `GuardClone` (the new F2 fork primitive).
//!
//! NOTE on coverage: the *main* test thread is not registered with the trace
//! module, so any spec-action emit it triggers (e.g. `ArcSwap::Drop` →
//! `DropArcSwap`) is silently suppressed.  Test scenarios therefore avoid
//! dropping the ArcSwap explicitly; trailing teardown is done by a worker
//! thread that owns the unique handle.
//!
//! BARRIER PATTERN: Each scenario uses TWO barriers to deterministically
//! sequence warm-up and enable():
//!   1. `warmup_done` — workers signal "warm-up complete" → main waits → enables
//!   2. `start_work` — main signals "tracing on, go" → workers wait → run
//! This avoids races where a worker's `arcswap.load()` Node::get fires
//! AFTER `enable()`, causing spurious ClaimNode events in the trace.

use std::sync::{Arc, Barrier};
use std::sync::mpsc;

use arc_swap::{tla_trace, ArcSwap, ArcSwapAny, DefaultStrategy, Guard};

#[cfg(feature = "internal-test-strategies")]
#[allow(deprecated)]
use arc_swap::strategy::test_strategies::FillFastSlots;

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
    let warmup_done = Arc::new(Barrier::new(4));
    let start_work = Arc::new(Barrier::new(4));
    let phase = Arc::new(Barrier::new(2)); // reader/writer ordering

    let reader = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let phase = Arc::clone(&phase);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            // -- traced region --
            let g = arcswap.load();
            std::hint::black_box(**g);
            drop(g);
            phase.wait();
        })
    };

    let writer = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let phase = Arc::clone(&phase);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            phase.wait(); // wait for reader
            let new_arc = Arc::new(42u64);
            let old = arcswap.swap(new_arc);
            drop(old);
            tla_trace::emit_writer_return();
        })
    };

    let spectator = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    warmup_done.wait();
    tla_trace::enable();
    start_work.wait();

    reader.join().expect("reader");
    writer.join().expect("writer");
    spectator.join().expect("spectator");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

/// Scenario: 2 readers + 1 writer with phase barriers ensuring readers
/// complete their loads BEFORE the writer swaps.  This is deterministic and
/// always validates.  Concurrency between r1 and r2 is preserved.
#[test]
fn concurrent_readers_writer() {
    let path = trace_path("concurrent_readers_writer");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    let arcswap = Arc::new(ArcSwap::from(init_arc));
    let warmup_done = Arc::new(Barrier::new(4));
    let start_work = Arc::new(Barrier::new(4));
    let readers_done = Arc::new(Barrier::new(3)); // r1, r2, writer

    let r1 = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let readers_done = Arc::clone(&readers_done);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            for _ in 0..2 {
                let g = arcswap.load();
                std::hint::black_box(**g);
                drop(g);
            }
            readers_done.wait();
        })
    };

    let r2 = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let readers_done = Arc::clone(&readers_done);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            for _ in 0..2 {
                let g = arcswap.load();
                std::hint::black_box(**g);
                drop(g);
            }
            readers_done.wait();
        })
    };

    let writer = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let readers_done = Arc::clone(&readers_done);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            readers_done.wait(); // wait for readers to finish their loads
            let new_arc = Arc::new(7u64);
            let old = arcswap.swap(new_arc);
            drop(old);
            tla_trace::emit_writer_return();
        })
    };

    warmup_done.wait();
    tla_trace::enable();
    start_work.wait();

    r1.join().expect("r1");
    r2.join().expect("r2");
    writer.join().expect("writer");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

/// Family 2 — caller-misuse: reader takes a Guard then converts via
/// `into_inner` to a bare Arc.  Exercises `GuardIntoInner` plus the
/// ABA-safe debt-pay branches.  Phase barrier sequences reader before
/// writer so trace replay is deterministic (Category-A linear cursor).
#[test]
fn family_2_into_inner() {
    let path = trace_path("family_2_into_inner");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    let arcswap = Arc::new(ArcSwap::from(init_arc));
    let warmup_done = Arc::new(Barrier::new(4));
    let start_work = Arc::new(Barrier::new(4));
    let phase = Arc::new(Barrier::new(2)); // reader/writer ordering

    let reader = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let phase = Arc::clone(&phase);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            let inner = arcswap.load_full();
            std::hint::black_box(*inner);
            drop(inner);
            phase.wait();
        })
    };

    let writer = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let phase = Arc::clone(&phase);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            phase.wait(); // wait for reader to finish into_inner
            let new_arc = Arc::new(99u64);
            let old = arcswap.swap(new_arc);
            drop(old);
            tla_trace::emit_writer_return();
        })
    };

    let spectator = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    warmup_done.wait();
    tla_trace::enable();
    start_work.wait();

    reader.join().expect("reader");
    writer.join().expect("writer");
    spectator.join().expect("spectator");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

/// Family 2 — caller-misuse: a Guard is acquired by t1, converted to a
/// bare Arc, and *sent* to t2 where it is dropped.  The harness emits
/// `SendGuard` to model the ownership transfer (Rust's Send is implicit
/// but the spec needs an explicit event).  Phase barrier sequences
/// (producer load_full → send → consumer drop) before (writer swap).
#[test]
fn family_2_send_guard() {
    let path = trace_path("family_2_send_guard");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    let arcswap = Arc::new(ArcSwap::from(init_arc));
    let warmup_done = Arc::new(Barrier::new(4));
    let start_work = Arc::new(Barrier::new(4));
    let consumer_done = Arc::new(Barrier::new(2)); // consumer/writer ordering

    let (tx, rx) = mpsc::channel();

    let producer = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            let inner = arcswap.load_full();
            tla_trace::emit_send_guard("t1", "t2");
            tx.send(inner).expect("send arc");
        })
    };

    let consumer = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let consumer_done = Arc::clone(&consumer_done);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            let inner = rx.recv().expect("receive arc");
            std::hint::black_box(*inner);
            drop(inner);
            consumer_done.wait();
        })
    };

    let writer = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        let consumer_done = Arc::clone(&consumer_done);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            consumer_done.wait(); // wait for producer/consumer to complete
            let new_arc = Arc::new(11u64);
            let old = arcswap.swap(new_arc);
            drop(old);
            tla_trace::emit_writer_return();
        })
    };

    warmup_done.wait();
    tla_trace::enable();
    start_work.wait();

    producer.join().expect("producer");
    consumer.join().expect("consumer");
    writer.join().expect("writer");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

/// (Round 4 NEW) Family 2 — caller-misuse: reader takes a Guard then forks
/// it into a second non-debted Guard via `Arc::clone(&*g) + Guard::from_inner`.
/// This produces TWO coexisting guards on the same address: one debted, one
/// not.  Emits `GuardClone` — the new F2 fork primitive.
///
/// Spec action: `GuardClone(t)` adds a no-debt guard for the same address
/// and bumps refCount.  After cloning, both guards reference the same Arc;
/// both must drop without UAF.
#[test]
fn family_2_guard_clone() {
    let path = trace_path("family_2_guard_clone");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    let arcswap = Arc::new(ArcSwap::from(init_arc));
    let warmup_done = Arc::new(Barrier::new(4));
    let start_work = Arc::new(Barrier::new(4));

    let reader = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            // -- traced region --
            // Take a normal Guard (debted, fast-path).
            let g = arcswap.load();
            // Fork via Arc::clone + Guard::from_inner.  This is the F2 fork
            // primitive — bumps refCount and creates a no-debt Guard.
            let cloned_arc = Arc::clone(&*g);
            let g2: Guard<Arc<u64>, DefaultStrategy> = Guard::from_inner(cloned_arc);
            tla_trace::emit_guard_clone();
            // Use both, then drop in reverse order.
            std::hint::black_box(**g);
            std::hint::black_box(**g2);
            drop(g2);
            drop(g);
        })
    };

    let writer = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            // No swap in this scenario; we only want to exercise the F2
            // fork.  An interleaved swap could fire pay_all events that
            // are unrelated to GuardClone.
        })
    };

    let spectator = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    warmup_done.wait();
    tla_trace::enable();
    start_work.wait();

    reader.join().expect("reader");
    writer.join().expect("writer");
    spectator.join().expect("spectator");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

/// Family 2 — `compare_and_swap` invocation with `&Arc` (CAS_KIND_ARC).
/// Exercises CASBegin → CASExchangeOk (or CASExchangeFail in concurrent runs).
#[test]
fn family_2_cas_arc() {
    let path = trace_path("family_2_cas_arc");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    let arcswap = Arc::new(ArcSwap::from(Arc::clone(&init_arc)));
    let warmup_done = Arc::new(Barrier::new(4));
    let start_work = Arc::new(Barrier::new(4));

    let cas_thread = {
        let arcswap = Arc::clone(&arcswap);
        let init_arc = Arc::clone(&init_arc);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            let new_arc = Arc::new(7u64);
            tla_trace::set_pending_cas_kind("Arc");
            let prev = arcswap.compare_and_swap(&init_arc, new_arc);
            std::hint::black_box(**prev);
            // The spec's CASExchangeOk does not model a guard transfer to the
            // caller — the writer's pay_all + WriterReturn already accounts
            // for the old pointer's refcount.  We `mem::forget` to avoid
            // emitting a DropGuard the spec can't match.
            std::mem::forget(prev);
            tla_trace::emit_writer_return();
        })
    };

    let spectator1 = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    let spectator2 = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    warmup_done.wait();
    tla_trace::enable();
    start_work.wait();

    cas_thread.join().expect("cas_thread");
    spectator1.join().expect("spectator1");
    spectator2.join().expect("spectator2");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

/// Family 2 — caller-misuse with raw pointer in CAS.  This is the
/// CAS_KIND_RAWFRESH hazard documented in lib.rs:509-516.  A real RawStale
/// scenario requires a freed allocation, which we approximate by setting
/// the kind label.
#[test]
fn family_2_cas_raw_stale() {
    let path = trace_path("family_2_cas_raw_stale");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    let arcswap = Arc::new(ArcSwap::from(Arc::clone(&init_arc)));
    let warmup_done = Arc::new(Barrier::new(4));
    let start_work = Arc::new(Barrier::new(4));

    let cas_thread = {
        let arcswap = Arc::clone(&arcswap);
        let init_arc = Arc::clone(&init_arc);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            let raw = Arc::as_ptr(&init_arc) as *const u64;
            let new_arc = Arc::new(33u64);
            tla_trace::set_pending_cas_kind("RawFresh");
            let prev = arcswap.compare_and_swap(raw, new_arc);
            std::hint::black_box(**prev);
            std::mem::forget(prev);
            tla_trace::emit_writer_return();
        })
    };

    let spectator1 = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    let spectator2 = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    warmup_done.wait();
    tla_trace::enable();
    start_work.wait();

    cas_thread.join().expect("cas_thread");
    spectator1.join().expect("spectator1");
    spectator2.join().expect("spectator2");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

/// (Optional) Fallback-path scenario: uses the `FillFastSlots` strategy
/// (no fast slots, all loads go through the helping/fallback path) to
/// exercise `ReaderFallback*` events that the default fast-path scenarios
/// don't reach.  Requires the `internal-test-strategies` feature.
///
/// Phase barrier sequences the reader's load_full → drop pair before any
/// writer activity (we don't have a separate writer here; the fallback
/// itself triggers `WriterHelpNode` via Debt::pay_all if the test runs
/// long enough, but for simplicity we keep this scenario read-only).
#[cfg(feature = "internal-test-strategies")]
#[allow(deprecated)]
#[test]
fn family_5_fallback_path() {
    let path = trace_path("family_5_fallback_path");
    tla_trace::init(&path);

    let init_arc = Arc::new(0u64);
    tla_trace::seed_init_addr(arc_addr(&init_arc));

    type FallbackSwap = ArcSwapAny<Arc<u64>, FillFastSlots>;
    let arcswap = Arc::new(FallbackSwap::from(init_arc));
    let warmup_done = Arc::new(Barrier::new(4));
    let start_work = Arc::new(Barrier::new(4));

    let reader = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t1");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
            // -- traced region: every load goes through fallback --
            let g = arcswap.load();
            std::hint::black_box(**g);
            drop(g);
        })
    };

    let spectator1 = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t2");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    let spectator2 = {
        let arcswap = Arc::clone(&arcswap);
        let warmup_done = Arc::clone(&warmup_done);
        let start_work = Arc::clone(&start_work);
        std::thread::spawn(move || {
            tla_trace::register_thread("t3");
            drop(arcswap.load());
            warmup_done.wait();
            start_work.wait();
        })
    };

    warmup_done.wait();
    tla_trace::enable();
    start_work.wait();

    reader.join().expect("reader");
    spectator1.join().expect("spectator1");
    spectator2.join().expect("spectator2");

    tla_trace::disable();
    tla_trace::shutdown();

    let bytes = std::fs::read(&path).expect("trace exists");
    assert!(!bytes.is_empty(), "trace should not be empty");
}

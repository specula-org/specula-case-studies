#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-9/worktree"
TMP_ROOT="${TMPDIR:-/tmp}/litebox-mc9-repro-$$"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/src"

cat > "$TMP_ROOT/Cargo.toml" <<EOF
[package]
name = "litebox_mc9_repro"
version = "0.1.0"
edition = "2024"

[dependencies]
litebox = { path = "$WORKTREE/litebox", features = ["tla_trace"] }
litebox_platform_linux_userland = { path = "$WORKTREE/litebox_platform_linux_userland" }
litebox_tla_trace = { path = "$WORKTREE/litebox_tla_trace" }
EOF

cat > "$TMP_ROOT/src/main.rs" <<'RS'
use litebox::event::wait::{WaitError, WaitState};
use litebox::platform::{RawConstPointer, RawPointerProvider};
use litebox::sync::futex::{FutexError, FutexManager};
use litebox::LiteBox;
use litebox_platform_linux_userland::LinuxUserland;
use std::num::NonZeroU32;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

type Platform = LinuxUserland;
type FutexPtr = <Platform as RawPointerProvider>::RawMutPointer<u32>;

fn futex_ptr(word: &AtomicU32) -> FutexPtr {
    <FutexPtr as RawConstPointer<u32>>::from_usize(word.as_ptr() as usize)
}

fn result_name(result: &Result<(), FutexError>) -> &'static str {
    match result {
        Ok(()) => "Ok",
        Err(FutexError::ImmediatelyWokenBecauseValueMismatch) => {
            "ImmediatelyWokenBecauseValueMismatch"
        }
        Err(FutexError::WaitError(WaitError::TimedOut)) => "TimedOut",
        Err(FutexError::WaitError(WaitError::Interrupted)) => "Interrupted",
        Err(FutexError::NotAligned) => "NotAligned",
        Err(FutexError::Fault) => "Fault",
    }
}

fn is_mismatch(result: &Result<(), FutexError>) -> bool {
    matches!(
        result,
        Err(FutexError::ImmediatelyWokenBecauseValueMismatch)
    )
}

fn is_timeout(result: &Result<(), FutexError>) -> bool {
    matches!(result, Err(FutexError::WaitError(WaitError::TimedOut)))
}

fn level0_probe(platform: &'static Platform) -> bool {
    let mut observed = false;
    let iterations = 64;
    for _ in 0..iterations {
        let manager = Arc::new(FutexManager::<Platform>::new());
        let word = Arc::new(AtomicU32::new(0));
        let start = Arc::new(Barrier::new(3));

        let first = {
            let manager = Arc::clone(&manager);
            let word = Arc::clone(&word);
            let start = Arc::clone(&start);
            thread::spawn(move || {
                let wait_state = WaitState::new(platform);
                start.wait();
                manager.wait(
                    &wait_state
                        .context()
                        .with_timeout(Duration::from_millis(3)),
                    futex_ptr(&word),
                    0,
                    None,
                )
            })
        };

        let second = {
            let manager = Arc::clone(&manager);
            let word = Arc::clone(&word);
            let start = Arc::clone(&start);
            thread::spawn(move || {
                let wait_state = WaitState::new(platform);
                start.wait();
                manager.wait(
                    &wait_state
                        .context()
                        .with_timeout(Duration::from_millis(3)),
                    futex_ptr(&word),
                    0,
                    None,
                )
            })
        };

        start.wait();
        thread::yield_now();
        word.store(1, Ordering::SeqCst);
        let woken = manager
            .wake(futex_ptr(&word), NonZeroU32::new(1).unwrap(), None)
            .unwrap();
        let first = first.join().unwrap();
        let second = second.join().unwrap();

        if woken == 1
            && ((is_mismatch(&first) && is_timeout(&second))
                || (is_mismatch(&second) && is_timeout(&first)))
        {
            observed = true;
            break;
        }
    }
    println!(
        "LEVEL0: iterations={iterations} observed_quota_loss={observed}"
    );
    observed
}

fn level1_timing_repro(platform: &'static Platform) -> bool {
    litebox_tla_trace::reset_model();
    litebox_tla_trace::configure_pause_after_insert("t0");

    let manager = Arc::new(FutexManager::<Platform>::new());
    let word = Arc::new(AtomicU32::new(0));

    let first_waiter = {
        let manager = Arc::clone(&manager);
        let word = Arc::clone(&word);
        thread::spawn(move || {
            litebox_tla_trace::init_thread(
                "mc9_futex_unvalidated_quota",
                "t0",
                &[
                    "FutexManagerWaitInsert",
                    "FutexManagerWaitCompareMismatch",
                    "FutexManagerWaitReturn",
                ],
            );
            let wait_state = WaitState::new(platform);
            let result = manager.wait(
                &wait_state
                    .context()
                    .with_timeout(Duration::from_secs(2)),
                futex_ptr(&word),
                0,
                None,
            );
            litebox_tla_trace::shutdown();
            result
        })
    };

    litebox_tla_trace::wait_for_phase("t0", "inserted_unvalidated");
    println!("LEVEL1: first_waiter_phase=inserted_unvalidated");

    let second_waiter = {
        let manager = Arc::clone(&manager);
        let word = Arc::clone(&word);
        thread::spawn(move || {
            litebox_tla_trace::init_thread(
                "mc9_futex_unvalidated_quota",
                "t1",
                &[
                    "FutexManagerWaitInsert",
                    "FutexManagerWaitCompareMatch",
                    "FutexManagerWaitReturn",
                ],
            );
            let wait_state = WaitState::new(platform);
            let result = manager.wait(
                &wait_state
                    .context()
                    .with_timeout(Duration::from_millis(250)),
                futex_ptr(&word),
                0,
                None,
            );
            litebox_tla_trace::shutdown();
            result
        })
    };

    litebox_tla_trace::wait_for_phase("t1", "validated_waiting");
    println!("LEVEL1: second_waiter_phase=validated_waiting");

    word.store(1, Ordering::SeqCst);

    litebox_tla_trace::init_thread(
        "mc9_futex_unvalidated_quota",
        "t2",
        &[
            "FutexManagerWakeBegin",
            "FutexManagerWakeSelect",
            "FutexManagerWakeComplete",
        ],
    );
    let woken = manager
        .wake(futex_ptr(&word), NonZeroU32::new(1).unwrap(), None)
        .unwrap();
    litebox_tla_trace::shutdown();
    println!("LEVEL1: wake_return={woken}");

    litebox_tla_trace::release_after_insert("t0");

    let first_result = first_waiter.join().unwrap();
    let second_result = second_waiter.join().unwrap();

    println!("LEVEL1: first_waiter_result={}", result_name(&first_result));
    println!("LEVEL1: second_waiter_result={}", result_name(&second_result));

    let triggered = woken == 1 && is_mismatch(&first_result) && is_timeout(&second_result);
    println!("BUG_TRIGGERED: {triggered}");
    triggered
}

fn main() {
    let platform = Platform::new(None);
    let _litebox = LiteBox::new(platform);

    let level0 = level0_probe(platform);
    let level1 = level1_timing_repro(platform);

    println!("SUMMARY: level0_triggered={level0} level1_triggered={level1}");
    if !level1 {
        std::process::exit(1);
    }
}
RS

cd "$WORKTREE"
LITEBOX_TLA_RAW_DIR="$TMP_ROOT/traces" timeout 5m cargo run --quiet --manifest-path "$TMP_ROOT/Cargo.toml"

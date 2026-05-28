// Repro for T3: closed oneshot::Receiver mishandling in BatchRequester
// (consensus/src/quorum_store/batch_requester.rs:172-183).
//
// Source pattern (excerpt):
//
//     loop {
//         tokio::select! {
//             _ = interval.tick() => { ... }
//             Some(response) = futures.next() => { ... }
//             result = &mut subscriber_rx => {
//                 match result {
//                     Ok(persisted_value) => { return Ok(...) }
//                     Err(err) => {
//                         debug!("channel closed: {}", err);
//                         // <-- falls through; loop continues
//                     }
//                 };
//             },
//         }
//     }
//
// `tokio::sync::oneshot::Receiver` is a oneshot Future: once it returns
// `Poll::Ready`, calling `.poll()` again is a contract violation. In
// tokio 1.35.x (the workspace version) the second poll returns
// `Ready(Err)` repeatedly — the select! branch re-fires every iteration,
// producing a hot busy-loop until the interval ticks. In tokio 1.52+,
// the second poll panics with "called after complete", crashing the
// spawned request_batch task.
//
// Trigger in production: BatchStore::clear_expired_payload runs while an
// in-flight get_or_fetch_batch is waiting on subscriber_rx. It removes
// the per-digest entry from `persist_subscribers`, dropping every tx.
// The waiting request_batch task observes RecvError on subscriber_rx,
// debug-logs, then re-polls subscriber_rx every loop iteration.
//
// Level 0 — pure tokio black-box reproduction of the same select! pattern.

use std::time::{Duration, Instant};
use tokio::sync::oneshot;
use tokio::time::interval;
use futures::stream::FuturesUnordered;
use futures::StreamExt;

const ITER_BUDGET: u32 = 50_000;
const TIME_BUDGET_MS: u64 = 1_500;

async fn batch_requester_inner_loop(
    mut subscriber_rx: oneshot::Receiver<u64>,
) -> Result<(u32, Duration), String> {
    let mut interval = interval(Duration::from_millis(1_000));
    let mut futures = FuturesUnordered::<
        std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>,
    >::new();
    let mut iter: u32 = 0;
    let mut err_count: u32 = 0;
    let start = Instant::now();

    loop {
        iter += 1;
        if iter > ITER_BUDGET {
            return Ok((err_count, start.elapsed()));
        }
        if start.elapsed() > Duration::from_millis(TIME_BUDGET_MS) {
            return Ok((err_count, start.elapsed()));
        }
        tokio::select! {
            _ = interval.tick() => { }
            Some(_) = futures.next(), if !futures.is_empty() => {}
            result = &mut subscriber_rx => {
                match result {
                    Ok(_v) => {
                        return Err("unexpected Ok".into());
                    }
                    Err(_err) => {
                        err_count += 1;
                        // Falls through, loop continues — mirrors batch_requester.rs:179-181.
                    }
                };
            },
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    println!("=== T3 repro: BatchRequester subscriber_rx mishandling after sender drop ===");

    // Step 1 — show the panic-after-complete contract violation on whichever
    // tokio version is in use. The match below makes the test pass on either
    // 1.35.x (busy-spin) or 1.52+ (panic).

    let (subscriber_tx, subscriber_rx) = oneshot::channel::<u64>();
    drop(subscriber_tx); // simulates BatchStore::clear_expired_payload

    let handle = tokio::spawn(batch_requester_inner_loop(subscriber_rx));
    let result = handle.await;

    match result {
        Ok(Ok((err_count, elapsed))) => {
            // Bug variant #1: tokio 1.35.x busy-spin.
            // A correct implementation would have err_count == 1
            // (or, equivalently, would have broken out of the loop).
            let rate_per_sec = err_count as f64 / elapsed.as_secs_f64().max(0.001);
            println!(
                "iters_hit_err_branch: {}  elapsed: {:?}  rate: {:.0}/s",
                err_count, elapsed, rate_per_sec
            );
            if err_count > 1_000 {
                println!("BUG REPRODUCED (variant: busy-spin):");
                println!(
                    "  After subscriber_tx drop, &mut subscriber_rx re-fires the Err branch"
                );
                println!(
                    "  {} times in {:?} ({:.0}/s) instead of the expected 1.",
                    err_count, elapsed, rate_per_sec
                );
                println!(
                    "  In production this wastes CPU and floods debug logs until either"
                );
                println!(
                    "  retry_limit is reached or interval ticks dominate the schedule."
                );
                std::process::exit(0);
            } else if err_count <= 1 {
                println!("UNEXPECTED: only {} Err observed — bug NOT reproduced.", err_count);
                std::process::exit(1);
            } else {
                println!("PARTIAL: {} Err observed — possibly fixed.", err_count);
                std::process::exit(2);
            }
        }
        Ok(Err(e)) => {
            println!("UNEXPECTED: loop returned Err({}) — bug NOT reproduced.", e);
            std::process::exit(1);
        }
        Err(join_err) => {
            if join_err.is_panic() {
                let payload = join_err.into_panic();
                let panic_msg = if let Some(s) = payload.downcast_ref::<&str>() {
                    s.to_string()
                } else if let Some(s) = payload.downcast_ref::<String>() {
                    s.clone()
                } else {
                    "<opaque>".into()
                };
                println!("BUG REPRODUCED (variant: panic):");
                println!("  Task panicked with: {}", panic_msg);
                println!(
                    "  In tokio 1.52+, polling a oneshot::Receiver after it returned Ready"
                );
                println!(
                    "  is a contract violation that panics. BatchRequester's select! loop"
                );
                println!(
                    "  hits this on its second iteration after subscriber_tx is dropped."
                );
                std::process::exit(0);
            } else {
                println!("UNEXPECTED: task cancelled, not panicked.");
                std::process::exit(1);
            }
        }
    }
}

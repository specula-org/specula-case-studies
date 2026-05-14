//! TLA+ trace harness scenarios for tokio::sync::broadcast.
//!
//! Each scenario sets up a broadcast channel and exercises distinct code paths
//! (caller misuse, slot reuse, mixed close+drop, memory ordering on slot
//! publication). Trace events are emitted to a per-scenario NDJSON file.
//!
//! Built as a tokio integration test (`cargo test --test tla_harness`). Each
//! `#[test]` function maps to one trace file in `traces/`.

#![cfg(feature = "sync")]

use std::env;
use std::time::Duration;

use tokio::sync::broadcast;
use tokio::sync::tla_trace as tla;

const TRACE_DIR_ENV: &str = "TLA_TRACE_DIR";

fn trace_path(scenario: &str) -> String {
    let dir = env::var(TRACE_DIR_ENV).unwrap_or_else(|_| "traces".to_string());
    format!("{}/{}.ndjson", dir, scenario)
}

/// Helper: run an async block as actor `name`, with the thread-local actor
/// flag set for the duration. Uses current_thread runtime so the thread-local
/// is stable (no work-stealing across OS threads).
fn run_as<F, Fut>(name: &str, fut: F)
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let _g = tla::ActorGuard::new(name.to_string());
    let _ = futures_dummy::block_on_local(fut());
}

mod futures_dummy {
    use std::future::Future;
    use tokio::runtime::Builder;

    pub fn block_on_local<F: Future>(fut: F) -> F::Output {
        let rt = Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(fut)
    }
}

// ===== Scenario 1: subscribe-while-send (Family 2 — caller misuse) =====
//
// One sender, one initial receiver. While the sender is interleaving sends,
// new receivers subscribe in between sends, then drop in arbitrary order.
// Exercises: Subscribe (with reopened=false), Send_*, Recv_HitFastPath,
// RxDrop_*, TxClone, TxDrop_*.
#[test]
fn scenario_subscribe_while_send() {
    let trace_file = trace_path("subscribe_while_send");
    tla::init(&trace_file);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        let (tx, mut rx1) = {
            let _g = tla::ActorGuard::new("s1".to_string());
            broadcast::channel::<i32>(4)
        };
        // The receiver returned by channel() is r1.
        // Send v1 — only rx1 is subscribed.
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            tx.send(1).unwrap();
        }
        // r1 receives v1.
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            let v = rx1.recv().await.unwrap();
            assert_eq!(v, 1);
        }
        // r2 subscribes mid-stream.
        let mut rx2 = {
            let _g = tla::ActorGuard::new("r2".to_string());
            tx.subscribe()
        };
        // Send v2 — both subscribed.
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            tx.send(2).unwrap();
        }
        // r1 then r2 receive v2.
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            let v = rx1.recv().await.unwrap();
            assert_eq!(v, 2);
        }
        {
            let _g = tla::ActorGuard::new("r2".to_string());
            let v = rx2.recv().await.unwrap();
            assert_eq!(v, 2);
        }
        // r3 subscribes after a send → rx_cnt jumps but they don't see v2.
        let mut rx3 = {
            let _g = tla::ActorGuard::new("r3".to_string());
            tx.subscribe()
        };
        // Send v3 — all three subscribed.
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            tx.send(3).unwrap();
        }
        // r1, r2, r3 all receive v3.
        for (actor, rx) in &mut [
            ("r1", &mut rx1),
            ("r2", &mut rx2),
            ("r3", &mut rx3),
        ]
        .iter_mut()
        {
            let actor = actor.to_string();
            let _g = tla::ActorGuard::new(actor);
            let v = rx.recv().await.unwrap();
            assert_eq!(v, 3);
        }
        // Drop in non-FIFO order.
        {
            let _g = tla::ActorGuard::new("r2".to_string());
            drop(rx2);
        }
        {
            let _g = tla::ActorGuard::new("r3".to_string());
            drop(rx3);
        }
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            drop(rx1);
        }
        // Drop sender; channel closes (last sender drop).
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            drop(tx);
        }
    });

    tla::shutdown();
}

// ===== Scenario 2: slot reuse / lagged classifier (Family 5) =====
//
// A small-capacity channel where one receiver lags. Exercises slot wrap-around
// and the Lagged fast-forward path.
#[test]
fn scenario_lagged_receiver() {
    let trace_file = trace_path("lagged_receiver");
    tla::init(&trace_file);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        let (tx, mut rx) = {
            let _g = tla::ActorGuard::new("s1".to_string());
            broadcast::channel::<i32>(2)
        };
        // Send three values without recv → wraps once, rx will lag.
        for v in 1..=3 {
            let _g = tla::ActorGuard::new("s1".to_string());
            tx.send(v).unwrap();
        }
        // First recv should report Lagged(1).
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            let r = rx.recv().await;
            assert!(matches!(
                r,
                Err(broadcast::error::RecvError::Lagged(_))
            ));
            // Subsequent recvs catch up.
            let v = rx.recv().await.unwrap();
            assert_eq!(v, 2);
            let v = rx.recv().await.unwrap();
            assert_eq!(v, 3);
        }
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            drop(rx);
        }
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            drop(tx);
        }
    });

    tla::shutdown();
}

// ===== Scenario 3: parked receiver wake (Family 1 — close/drop races) =====
//
// rx is parked (no value yet), then sender sends, waking rx. Exercises
// Recv_ParkAsWaiter, NotifyRx_DrainStep_Take, NotifyRx_WakeOne, and the
// Acquire load in Recv::drop.
#[test]
fn scenario_park_and_wake() {
    let trace_file = trace_path("park_and_wake");
    tla::init(&trace_file);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        let (tx, mut rx) = {
            let _g = tla::ActorGuard::new("s1".to_string());
            broadcast::channel::<i32>(4)
        };
        // Spawn the receiver in a task so it can park.
        let recv_task = tokio::spawn(async move {
            let _g = tla::ActorGuard::new("r1".to_string());
            let v = rx.recv().await.unwrap();
            assert_eq!(v, 42);
            // Drop rx by scope end.
            drop(rx);
        });
        // Yield to let the receiver park.
        tokio::time::sleep(Duration::from_millis(10)).await;
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            tx.send(42).unwrap();
        }
        // Wait for receiver to finish.
        recv_task.await.unwrap();
        // Drop sender.
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            drop(tx);
        }
    });

    tla::shutdown();
}

// ===== Scenario 4: mixed close + drop (Family 1) =====
//
// All senders drop while a receiver is parked. Exercises the close path:
// TxDrop_FetchSub (wasLast=true), TxDrop_CloseChannelEnter, TxDrop_NotifyEnter,
// NotifyRx_*, and Recv_EmptyClosed.
#[test]
fn scenario_close_with_parked_receiver() {
    let trace_file = trace_path("close_with_parked_receiver");
    tla::init(&trace_file);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        let (tx, mut rx) = {
            let _g = tla::ActorGuard::new("s1".to_string());
            broadcast::channel::<i32>(4)
        };
        let recv_task = tokio::spawn(async move {
            let _g = tla::ActorGuard::new("r1".to_string());
            let r = rx.recv().await;
            assert!(matches!(r, Err(broadcast::error::RecvError::Closed)));
            drop(rx);
        });
        // Yield to let the receiver park.
        tokio::time::sleep(Duration::from_millis(10)).await;
        // Drop the only sender — this triggers close.
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            drop(tx);
        }
        recv_task.await.unwrap();
    });

    tla::shutdown();
}

// ===== Scenario 5: clone-and-drop senders (Family 2 + 4) =====
//
// Two senders (clone), interleaved sends, drop both. Exercises TxClone,
// TxDrop_FetchSub on the non-last drop, and TxDrop_FetchSub + close path on
// the last.
#[test]
fn scenario_clone_drop_senders() {
    let trace_file = trace_path("clone_drop_senders");
    tla::init(&trace_file);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        let (tx1, mut rx) = {
            let _g = tla::ActorGuard::new("s1".to_string());
            broadcast::channel::<i32>(4)
        };
        let tx2 = {
            let _g = tla::ActorGuard::new("s2".to_string());
            tx1.clone()
        };
        // Interleaved sends.
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            tx1.send(10).unwrap();
        }
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            let v = rx.recv().await.unwrap();
            assert_eq!(v, 10);
        }
        {
            let _g = tla::ActorGuard::new("s2".to_string());
            tx2.send(20).unwrap();
        }
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            let v = rx.recv().await.unwrap();
            assert_eq!(v, 20);
        }
        // Drop tx2 first (not last sender).
        {
            let _g = tla::ActorGuard::new("s2".to_string());
            drop(tx2);
        }
        // Send via tx1 — still has receivers.
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            tx1.send(30).unwrap();
        }
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            let v = rx.recv().await.unwrap();
            assert_eq!(v, 30);
        }
        // Drop the receiver.
        {
            let _g = tla::ActorGuard::new("r1".to_string());
            drop(rx);
        }
        // Drop tx1 (last sender; channel closes).
        {
            let _g = tla::ActorGuard::new("s1".to_string());
            drop(tx1);
        }
    });

    tla::shutdown();
}

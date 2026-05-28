//! Trace-collecting end-to-end scenario.
//!
//! Reuses the existing `honest_members_agree_on_batches` shape from
//! `testing::crash` but drives the trace emitter for the duration of the
//! run.  Activated by setting the `TLA_TRACE_FILE` environment variable
//! before invoking `cargo test`.
//!
//! The scenarios here are intentionally close to the production-style
//! integration tests so the resulting trace exercises the real consensus,
//! alerter, backup-saver, dissemination, dag, and extender code paths.

use crate::{
    testing::{init_log, spawn_honest_member, HonestMember},
    tla_trace, NodeCount, SpawnHandle,
};
use aleph_bft_mock::{DataProvider, Router, Spawner, UnreliableHook};
use futures::StreamExt;
use serial_test::serial;

async fn run_honest_scenario(
    n_members: NodeCount,
    n_alive: NodeCount,
    n_batches: usize,
    network_reliability: Option<f64>,
) {
    init_log();

    // Reset trace shadow counters between runs so per-node accounting starts
    // from zero each test even when many scenarios share one cargo run.
    for ix in n_members.into_iterator() {
        tla_trace::reset_counters(ix);
    }

    let spawner = Spawner::new();
    let mut exits = Vec::new();
    let mut handles = Vec::new();
    let mut batch_rxs = Vec::new();
    let (mut net_hub, networks) = Router::new(n_members);
    if let Some(reliability) = network_reliability {
        net_hub.add_hook(UnreliableHook::new(reliability));
    }
    spawner.spawn("network-hub", net_hub);

    for (network, _) in networks {
        let ix = network.index();
        if n_alive.into_range().contains(&ix) {
            let HonestMember {
                finalization_rx,
                exit_tx,
                handle,
                ..
            } = spawn_honest_member(
                spawner,
                ix,
                n_members,
                vec![],
                DataProvider::new(),
                network,
            );
            batch_rxs.push(finalization_rx);
            exits.push(exit_tx);
            handles.push(handle);
        }
    }

    let mut batches = vec![];
    for mut rx in batch_rxs.drain(..) {
        let mut batches_per_ix = vec![];
        for _ in 0..n_batches {
            let batch = rx.next().await.unwrap();
            batches_per_ix.push(batch);
        }
        batches.push(batches_per_ix);
    }

    for node_ix in n_alive.into_iterator().skip(1) {
        assert_eq!(batches[0], batches[node_ix.0]);
    }
    for exit in exits {
        let _ = exit.send(());
    }
    for handle in handles {
        let _ = handle.await;
    }
}

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn trace_four_honest_all_alive() {
    if std::env::var("TLA_TRACE_FILE").is_err() {
        eprintln!("TLA_TRACE_FILE unset, skipping trace_four_honest_all_alive");
        return;
    }
    run_honest_scenario(4.into(), 4.into(), 5, None).await;
}

#[tokio::test(flavor = "multi_thread")]
#[serial]
async fn trace_four_honest_one_crash() {
    if std::env::var("TLA_TRACE_FILE").is_err() {
        eprintln!("TLA_TRACE_FILE unset, skipping trace_four_honest_one_crash");
        return;
    }
    run_honest_scenario(4.into(), 3.into(), 5, None).await;
}

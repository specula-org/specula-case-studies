mod fixtures;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use async_raft::Config;
use tokio::time::sleep;

use fixtures::RaftRouter;

/// Basic consensus test: 3-node cluster, election, client writes, replication.
///
/// Exercises: Timeout, HandleRequestVoteRequest, HandleRequestVoteResponse,
/// BecomeLeader, ClientRequest, SendReplicateEntries/SendHeartbeat,
/// HandleAppendEntriesRequest, HandleAppendEntriesResponse, AdvanceCommitIndex.
///
/// Run: RUST_LOG=async_raft=trace TLA_TRACE_FILE=../traces/basic_consensus.ndjson \
///      cargo test -p async-raft --test tla_trace_scenario -- basic_consensus --nocapture
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn basic_consensus() -> Result<()> {
    let trace_file = match std::env::var("TLA_TRACE_FILE") {
        Ok(f) => f,
        Err(_) => {
            eprintln!("TLA_TRACE_FILE not set, skipping trace test");
            return Ok(());
        }
    };

    // Skip init_tracing() — the tracing-subscriber used by async-raft has
    // regex feature issues. We don't need tracing output for trace collection.

    // Build server mapping: 0 -> "s1", 1 -> "s2", 2 -> "s3"
    let mut server_map = HashMap::new();
    server_map.insert(0, "s1".to_string());
    server_map.insert(1, "s2".to_string());
    server_map.insert(2, "s3".to_string());
    async_raft::tla_trace::init(&trace_file, server_map);

    // Setup a 3-node cluster with short timeouts for faster convergence.
    let config = Arc::new(
        Config::build("test".into())
            .election_timeout_min(300)
            .election_timeout_max(500)
            .heartbeat_interval(100)
            .validate()
            .expect("failed to build Raft config"),
    );
    let router = Arc::new(RaftRouter::new(config.clone()));
    router.new_raft_node(0).await;
    router.new_raft_node(1).await;
    router.new_raft_node(2).await;

    // Wait for pristine state.
    sleep(Duration::from_millis(500)).await;

    // Initialize the cluster from node 0 — this triggers election.
    tracing::info!("--- initializing cluster");
    router.initialize_from_single_node(0).await?;

    // Wait for election + initial leader entry.
    sleep(Duration::from_secs(5)).await;

    // Verify a leader was elected.
    let leader = router.leader().await.expect("leader not found");
    tracing::info!("--- leader elected: {}", leader);

    // Send a few client write requests.
    tracing::info!("--- sending client writes");
    router.client_request(leader, "client1", 0).await;
    router.client_request(leader, "client1", 1).await;
    router.client_request(leader, "client1", 2).await;

    // Wait for replication.
    sleep(Duration::from_secs(3)).await;

    tracing::info!("--- basic_consensus test complete");
    Ok(())
}

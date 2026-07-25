/// Bug #32 reproduction: client_read quorum formula uses N/2 instead of (N+1)/2
///
/// In handle_client_read_request (core/client.rs), the quorum threshold is computed as:
///
///     c0_needed = if (len_members % 2) == 0 { (len_members / 2) - 1 } else { len_members / 2 }
///
/// For a 3-node cluster this gives c0_needed = 3/2 = 1. The leader always counts itself
/// as one confirmation (c0_confirmed starts at 1), so c0_confirmed >= c0_needed is
/// immediately true. This means a fully-isolated leader can self-confirm reads without
/// any follower acknowledgment — violating the Raft §8 requirement that a leader must
/// exchange heartbeats with a **majority** of the cluster before serving read-only requests.
///
/// Correct formula: c0_needed = (len_members + 1) / 2, giving c0_needed = 2 for 3 nodes.
/// The leader's self-vote (1) would then NOT satisfy the threshold, and it would need at
/// least one follower response — which it cannot get while isolated.
///
/// This test:
/// 1. Creates a 3-node cluster and elects a leader.
/// 2. Isolates the leader from all followers.
/// 3. Calls client_read on the isolated leader.
/// 4. Asserts that client_read SUCCEEDS — demonstrating the bug.
///    (A correct implementation would return an error.)
///
/// Run with:
///   cd case-studies/async-raft/artifact/async-raft
///   RUST_LOG=async_raft=trace cargo test -p async-raft --test bug32_quorum_off_by_one -- --nocapture

mod fixtures;

use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use async_raft::Config;
use tokio::time::sleep;

use fixtures::RaftRouter;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn bug32_isolated_leader_self_confirms_read() -> Result<()> {
    fixtures::init_tracing();

    // Step 1: Create a 3-node cluster.
    let config = Arc::new(
        Config::build("test".into())
            .validate()
            .expect("failed to build Raft config"),
    );
    let router = Arc::new(RaftRouter::new(config.clone()));
    router.new_raft_node(0).await;
    router.new_raft_node(1).await;
    router.new_raft_node(2).await;

    // Wait for nodes to start up in non-voter state.
    sleep(Duration::from_secs(5)).await;
    router.assert_pristine_cluster().await;

    // Step 2: Initialize and elect a leader.
    tracing::info!("--- initializing cluster");
    router.initialize_from_single_node(0).await?;
    sleep(Duration::from_secs(5)).await;
    router.assert_stable_cluster(Some(1), Some(1)).await;

    let leader = router.leader().await.expect("leader not found");
    assert_eq!(leader, 0, "expected node 0 to be leader, got {}", leader);

    // Sanity check: client_read works on the connected leader.
    router
        .client_read(leader)
        .await
        .expect("client_read should succeed on connected leader");

    // Step 3: Fully isolate the leader from all followers.
    tracing::info!("--- isolating leader node {}", leader);
    router.isolate_node(leader).await;

    // Give a moment for isolation to take effect. The leader doesn't know it's
    // isolated yet — it still thinks it's the leader.
    sleep(Duration::from_millis(500)).await;

    // Step 4: Call client_read on the isolated leader.
    // BUG: This succeeds because c0_needed=1 and the leader's self-count satisfies it.
    // CORRECT BEHAVIOR: This should fail — the leader cannot get heartbeat confirmation
    // from a majority (needs 2 out of 3, but can only reach itself).
    tracing::info!("--- calling client_read on isolated leader");
    let read_result = router.client_read(leader).await;

    // The bug: client_read succeeds on a fully-isolated leader.
    // In a correct implementation, this would be Err(...).
    assert!(
        read_result.is_ok(),
        "BUG DEMONSTRATION FAILED: expected client_read to succeed on isolated leader \
         (showing the quorum off-by-one bug), but it returned an error: {:?}. \
         This means the bug may have been fixed.",
        read_result.err()
    );

    tracing::info!(
        "BUG CONFIRMED: client_read succeeded on a fully-isolated leader! \
         The leader self-confirmed the read without any follower acknowledgment. \
         This violates Raft §8 (leader must exchange heartbeats with a majority)."
    );

    Ok(())
}

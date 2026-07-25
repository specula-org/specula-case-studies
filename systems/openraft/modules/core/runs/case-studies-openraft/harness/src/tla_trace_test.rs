use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use maplit::btreeset;
use openraft::Config;

use crate::fixtures::RaftRouter;
use crate::fixtures::ut_harness;

fn timeout() -> Option<Duration> {
    Some(Duration::from_millis(5_000))
}

/// Basic consensus: 3-node cluster, leader election, log replication.
///
/// Expected trace events:
///   Elect, HandleVoteRequest, HandleVoteResponse, EstablishLeader,
///   ClientRequest, ReplicateEntries, HandleAppendEntries,
///   HandleAppendEntriesResponse, AdvanceCommitIndex
#[tracing::instrument]
#[test_harness::test(harness = ut_harness)]
async fn tla_trace_basic_consensus() -> Result<()> {
    let trace_file = std::env::var("TLA_TRACE_FILE")
        .unwrap_or_else(|_| "../../traces/basic_consensus.ndjson".to_string());
    openraft::tla_trace::init(&trace_file);

    let config = Arc::new(
        Config {
            enable_heartbeat: false,
            ..Default::default()
        }
        .validate()?,
    );

    let mut router = RaftRouter::new(config.clone());

    tracing::info!("--- init 3-node cluster");
    let mut log_index = router.new_cluster(btreeset! {0, 1, 2}, btreeset! {}).await?;

    tracing::info!(log_index, "--- write 5 client entries");
    log_index += router.client_request_many(0, "client", 5).await?;

    tracing::info!(log_index, "--- wait for all nodes to commit");
    for id in [0u64, 1, 2] {
        router
            .wait(&id, timeout())
            .applied_index(Some(log_index), "all entries applied")
            .await?;
    }

    tracing::info!(log_index, "--- basic_consensus trace complete");
    Ok(())
}

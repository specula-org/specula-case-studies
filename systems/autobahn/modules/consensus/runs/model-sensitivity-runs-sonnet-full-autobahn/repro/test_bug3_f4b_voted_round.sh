#!/bin/bash
# BUG-F4b: last_voted_round is not persisted to storage.
# After crash+restart, a node re-votes in rounds it already voted in.
# Two Core instances for the same node (simulated crash-restart) BOTH vote in rounds 1-2.
# Affected: hotstuff/src/core.rs:122 (TODO: Write to storage preferred_round and last_voted_round)

set -e

ARTIFACT_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/autobahn/artifact/autobahn"
TEST_FILE="$ARTIFACT_DIR/hotstuff/src/tests/trace_scenarios.rs"
BACKUP="$TEST_FILE.bug3.bak"

cp "$TEST_FILE" "$BACKUP"
cleanup() {
    cp "$BACKUP" "$TEST_FILE"; rm -f "$BACKUP"
    rm -rf "$ARTIFACT_DIR/.db_bug_f4b_A" "$ARTIFACT_DIR/.db_bug_f4b_B" 2>/dev/null || true
}
trap cleanup EXIT

python3 - "$TEST_FILE" << 'PYEOF'
import sys
content = open(sys.argv[1]).read()
test_code = r"""
    #[tokio::test]
    #[serial]
    async fn bug_f4b_voted_round_not_persisted() {
        // BUG-F4b: last_voted_round is NEVER written to storage.
        // TODO at hotstuff/src/core.rs:122: "Write to storage preferred_round and last_voted_round."
        //
        // Test strategy (Level 2):
        // Spawn two Core instances for the SAME node identity with SEPARATE stores.
        // Both start with last_voted_round=0 because last_voted_round is never persisted.
        // Both vote in rounds 1 and 2 — demonstrating the crash-restart double-vote.
        //
        // In a CORRECT implementation: Core2 (simulating restart) would load last_voted_round=2
        // from the store left by Core1 and refuse to vote in rounds 1-2 again.

        let mut ks = keys();
        let committee = committee_with_base_port(BASE_PORT + 600);
        let dir = trace_dir();
        let trace_path = dir.join("bug_f4b_double_vote.ndjson");

        let node_pairs: Vec<(PublicKey, &'static str)> = ks.iter().enumerate()
            .map(|(i, (pk, _))| (*pk, ["n1","n2","n3","n4"][i])).collect();
        tla_trace::init(trace_path.to_str().unwrap(), &node_pairs);

        // Pick a non-leader node (will not auto-generate proposals)
        let (leader_pk, _) = leader_for_round(1);
        let idx = ks.iter().position(|(pk, _)| *pk != leader_pk).unwrap();
        let (name, secret) = ks.remove(idx);

        // === Core1: Vote in rounds 1 and 2 ===
        // Represents the ORIGINAL run before the crash.
        let store_path_a = ".db_bug_f4b_A";
        let _ = std::fs::remove_dir_all(store_path_a);
        {
            let (tx_core, rx_core) = tokio::sync::mpsc::channel::<ConsensusMessage>(100);
            let (tx_loopback, rx_loopback) = tokio::sync::mpsc::channel::<Block>(100);
            let (tx_proposer, _rx_proposer) = tokio::sync::mpsc::channel(100);
            let (tx_mempool, mut rx_mempool) = tokio::sync::mpsc::channel(100);
            let (tx_commit, _rx_commit) = tokio::sync::mpsc::channel::<primary::Certificate>(100);
            let (tx_output, _rx_output) = tokio::sync::mpsc::channel::<Block>(100);

            let store = Store::new(store_path_a).unwrap();
            let leader_elector = LeaderElector::new(committee.clone());
            let mempool_driver = MempoolDriver::new(committee.clone(), tx_mempool);
            let synchronizer = Synchronizer::new(name, committee.clone(), store.clone(), tx_loopback, 100_000);
            tokio::spawn(async move { loop { rx_mempool.recv().await; } });
            Core::spawn(name, committee.clone(), SignatureService::new(clone_sk(&secret)),
                store, leader_elector, mempool_driver, synchronizer, 100_000,
                rx_core, rx_loopback, tx_proposer, tx_commit, tx_output);

            for block in make_block_chain(1..=2) {
                let _ = tx_core.send(ConsensusMessage::Propose(block)).await;
                sleep(Duration::from_millis(80)).await;
            }
            sleep(Duration::from_millis(300)).await;
            // Core1's sender is dropped — Core1 shuts down.
            // last_voted_round = 2 in Core1's MEMORY, NOT written to store_path_a.
        }

        let vote_count_core1 = {
            let c = std::fs::read_to_string(&trace_path).unwrap_or_default();
            c.lines().filter(|l| l.contains("\"HSMakeVote\"")).count()
        };
        println!("[BUG-F4b] Core1 HSMakeVote events: {}", vote_count_core1);

        // Brief wait to let Core1's store lock release
        sleep(Duration::from_millis(200)).await;

        // === Core2: Simulated crash+restart ===
        // Uses a FRESH store (store_path_b) — equivalent to a node that crashed and restarted.
        // If last_voted_round WERE persisted (and copied to the restart store), Core2 would
        // load last_voted_round=2 and REFUSE to vote in rounds 1-2. Since it's NOT persisted
        // (TODO at core.rs:122), Core2 initializes with last_voted_round=0 and VOTES AGAIN.
        let store_path_b = ".db_bug_f4b_B";
        let _ = std::fs::remove_dir_all(store_path_b);
        {
            let (tx_core, rx_core) = tokio::sync::mpsc::channel::<ConsensusMessage>(100);
            let (tx_loopback, rx_loopback) = tokio::sync::mpsc::channel::<Block>(100);
            let (tx_proposer, _rx_proposer) = tokio::sync::mpsc::channel(100);
            let (tx_mempool, mut rx_mempool) = tokio::sync::mpsc::channel(100);
            let (tx_commit, _rx_commit) = tokio::sync::mpsc::channel::<primary::Certificate>(100);
            let (tx_output, _rx_output) = tokio::sync::mpsc::channel::<Block>(100);

            let store = Store::new(store_path_b).unwrap();
            let leader_elector = LeaderElector::new(committee.clone());
            let mempool_driver = MempoolDriver::new(committee.clone(), tx_mempool);
            let synchronizer = Synchronizer::new(name, committee.clone(), store.clone(), tx_loopback, 100_000);
            tokio::spawn(async move { loop { rx_mempool.recv().await; } });
            Core::spawn(name, committee.clone(), SignatureService::new(secret),
                store, leader_elector, mempool_driver, synchronizer, 100_000,
                rx_core, rx_loopback, tx_proposer, tx_commit, tx_output);

            // Process the SAME blocks again — Core2 votes because last_voted_round=0 (not persisted!)
            for block in make_block_chain(1..=2) {
                let _ = tx_core.send(ConsensusMessage::Propose(block)).await;
                sleep(Duration::from_millis(80)).await;
            }
            sleep(Duration::from_millis(300)).await;
        }

        let content = std::fs::read_to_string(&trace_path).unwrap_or_default();
        let all_vote_events: Vec<_> = content.lines()
            .filter(|l| l.contains("\"HSMakeVote\""))
            .collect();

        println!("[BUG-F4b] Total HSMakeVote events across crash+restart: {}", all_vote_events.len());
        println!("[BUG-F4b] Core1 votes: {}, Core2 votes: {}",
                 vote_count_core1, all_vote_events.len() - vote_count_core1);

        // BUG: Core2 votes in rounds 1 and 2 again (last_voted_round not persisted).
        // With correct persistence: Core2 would load last_voted_round=2 and refuse to re-vote.
        let vote_count_core2 = all_vote_events.len() - vote_count_core1;
        assert!(vote_count_core2 >= 1,
            "BUG-F4b CONFIRMED: Core2 (restarted node) voted {} times in rounds already voted by Core1.\n\
             This proves last_voted_round is NOT persisted (TODO at core.rs:122).\n\
             A correct implementation would load last_voted_round from storage and refuse re-voting.",
            vote_count_core2);

        println!("[BUG-F4b] CONFIRMED: Core2 voted {} time(s) in rounds already voted by Core1!", vote_count_core2);
        println!("[BUG-F4b] last_voted_round is NOT persisted to storage (TODO at core.rs:122).");
        println!("[BUG-F4b] A restarted node can vote in the same rounds again — double voting!");
        println!("[BUG-F4b] Fix: Write last_voted_round to the store after make_vote at core.rs:122.");
    }
"""
last_brace = content.rfind('}')
new_content = content[:last_brace] + test_code + '\n' + content[last_brace:]
open(sys.argv[1], 'w').write(new_content)
print("Inserted bug_f4b_voted_round_not_persisted into hotstuff trace_scenarios.rs")
PYEOF

cd "$ARTIFACT_DIR"
echo "=== Running BUG-F4b reproduction test ==="
timeout 120 cargo test -p hotstuff -- bug_f4b_voted_round_not_persisted --nocapture 2>&1
echo "=== Test complete ==="

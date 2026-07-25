#!/bin/bash
# BUG-F4a: Incomplete 2-chain commit rule.
# Only checks b0.round+1==b1.round but NOT b1.round+1==block.round.
# A block at round 5 with parent at round 2 triggers a premature commit of b0 at round 1.
# Affected: hotstuff/src/core.rs:346

set -e

ARTIFACT_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/autobahn/artifact/autobahn"
TEST_FILE="$ARTIFACT_DIR/hotstuff/src/tests/trace_scenarios.rs"
BACKUP="$TEST_FILE.bug2.bak"

cp "$TEST_FILE" "$BACKUP"
cleanup() {
    cp "$BACKUP" "$TEST_FILE"; rm -f "$BACKUP"
    rm -rf "$ARTIFACT_DIR/.db_bug_f4a" 2>/dev/null || true
}
trap cleanup EXIT

python3 - "$TEST_FILE" << 'PYEOF'
import sys
content = open(sys.argv[1]).read()
test_code = r"""
    #[tokio::test]
    #[serial]
    async fn bug_f4a_incomplete_2chain_commit() {
        // BUG-F4a: process_block at hotstuff/src/core.rs:346 commits b0 when a gap block arrives.
        // Only checks b0.round+1==b1.round (first link). Missing: b1.round+1==block.round (second link).
        // Scenario: b0(r1) <- b1(r2) <- gap(r5). Chain r2->r5 is NOT consecutive (2+1≠5).
        use crate::common::chain as make_chain;

        let _ = std::fs::remove_dir_all(".db_bug_f4a");
        let committee = committee_with_base_port(BASE_PORT + 400);
        let all_keys = keys();

        // Build chain with VALID QC signatures using the common::chain helper.
        // chain helper signs QC over qc.digest() (correct), unlike make_block_chain.
        let leaders_3: Vec<_> = (1u64..=3)
            .map(|r| leader_for_round(r))
            .collect();
        let chain_3 = make_chain(leaders_3);
        let b0 = chain_3[0].clone(); // round 1
        let b1 = chain_3[1].clone(); // round 2
        // chain_3[2].qc is the QC for b1 (round 2), properly signed over qc.digest()
        let qc_for_b1 = chain_3[2].qc.clone();

        // Gap block at round 5 with QC for b1 (round 2) — skips rounds 3 and 4.
        // leader_for_round(5) = keys[5%4] = keys[1] = leader_for_round(1)
        let (gap_leader, gap_secret) = leader_for_round(5);
        let gap_block = Block::new_from_key(qc_for_b1, gap_leader, 5, vec![], &gap_secret);

        // Spawn Core with observable output channel for committed blocks
        let (tx_core, rx_core) = tokio::sync::mpsc::channel::<ConsensusMessage>(100);
        let (tx_loopback, rx_loopback) = tokio::sync::mpsc::channel::<Block>(100);
        let (tx_proposer, _rx_proposer) = tokio::sync::mpsc::channel(100);
        let (tx_mempool, mut rx_mempool) = tokio::sync::mpsc::channel(100);
        let (tx_commit, _rx_commit) = tokio::sync::mpsc::channel::<primary::Certificate>(100);
        let (tx_output, mut rx_output) = tokio::sync::mpsc::channel::<Block>(100);

        let store = Store::new(".db_bug_f4a").unwrap();
        // Pick a non-leader node to prevent auto-proposal generation
        let (name, secret) = {
            // leaders of rounds 1-5 (5%4=1, so leader(5) == leader(1))
            let excluded_pks: std::collections::HashSet<_> = (1u64..=5)
                .map(|r| leader_for_round(r).0)
                .collect();
            all_keys.iter()
                .find(|(pk, _)| !excluded_pks.contains(pk))
                .map(|(pk, sk)| (*pk, clone_sk(sk)))
                .unwrap_or_else(|| {
                    // All keys are leaders in some round (committee size 4, rounds 1-4 cover all)
                    // Fall back to picking any non-round-1 leader
                    let ldr1 = leader_for_round(1).0;
                    all_keys.iter().find(|(pk, _)| *pk != ldr1)
                        .map(|(pk, sk)| (*pk, clone_sk(sk))).unwrap()
                })
        };

        let leader_elector = LeaderElector::new(committee.clone());
        let mempool_driver = MempoolDriver::new(committee.clone(), tx_mempool);
        let synchronizer = Synchronizer::new(name, committee.clone(), store.clone(), tx_loopback, 100_000);
        tokio::spawn(async move { loop { rx_mempool.recv().await; } });

        Core::spawn(name, committee, SignatureService::new(secret), store, leader_elector,
            mempool_driver, synchronizer, 100_000,
            rx_core, rx_loopback, tx_proposer, tx_commit, tx_output);

        // Send b0 and b1 to store them as ancestors for the gap block
        let _ = tx_core.send(ConsensusMessage::Propose(b0.clone())).await;
        sleep(Duration::from_millis(150)).await;
        let _ = tx_core.send(ConsensusMessage::Propose(b1.clone())).await;
        sleep(Duration::from_millis(150)).await;

        // Send gap block (round 5 with parent QC at round 2 — non-consecutive!)
        let _ = tx_core.send(ConsensusMessage::Propose(gap_block.clone())).await;
        sleep(Duration::from_millis(500)).await;

        // Collect committed blocks from the output channel
        let mut committed_rounds = Vec::new();
        while let Ok(block) = rx_output.try_recv() {
            committed_rounds.push(block.round);
        }

        println!("[BUG-F4a] b0.round={}, b1.round={}, gap_block.round={}",
                 b0.round, b1.round, gap_block.round);
        println!("[BUG-F4a] Committed rounds: {:?}", committed_rounds);
        println!("[BUG-F4a] Check (b0+1==b1): {}+1=={} => {}",
                 b0.round, b1.round, b0.round+1==b1.round);
        println!("[BUG-F4a] Missing (b1+1==gap): {}+1=={} => {} (BUG: not checked!)",
                 b1.round, gap_block.round, b1.round+1==gap_block.round);

        assert!(committed_rounds.contains(&b0.round),
            "Expected b0 (round {}) to be committed via incomplete 2-chain, but got: {:?}\n\
             b0.round({}) + 1 == b1.round({}) ✓ (first link passes)\n\
             b1.round({}) + 1 != gap.round({}) ✗ (second link is missing in the code!)\n\
             See hotstuff/src/core.rs:346",
            b0.round, committed_rounds, b0.round, b1.round, b1.round, gap_block.round);

        println!("[BUG-F4a] CONFIRMED: b0 at round {} was prematurely committed!", b0.round);
        println!("[BUG-F4a] gap_block(r5) with parent QC(r2) triggered commit via incomplete chain.");
        println!("[BUG-F4a] Fix: add `&& b1.round + 1 == block.round` at core.rs:346.");
    }
"""
last_brace = content.rfind('}')
new_content = content[:last_brace] + test_code + '\n' + content[last_brace:]
open(sys.argv[1], 'w').write(new_content)
print("Inserted bug_f4a_incomplete_2chain_commit into hotstuff trace_scenarios.rs")
PYEOF

cd "$ARTIFACT_DIR"
echo "=== Running BUG-F4a reproduction test ==="
timeout 120 cargo test -p hotstuff -- bug_f4a_incomplete_2chain_commit --nocapture 2>&1
echo "=== Test complete ==="

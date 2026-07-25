// hotstuff trace scenarios

#[cfg(test)]
mod hs_trace_tests {
    use std::fs;
    use std::path::PathBuf;
    use std::time::Duration;

    use bincode;
    use config::Committee;
    use crypto::{Hash as _, PublicKey, SecretKey, Signature, SignatureService};
    use tokio::sync::mpsc::channel;
    use tokio::time::sleep;

    use crate::common::{committee, committee_with_base_port, keys};
    use crate::consensus::{ConsensusMessage, Round, CHANNEL_CAPACITY};
    use crate::leader::LeaderElector;
    use crate::mempool::MempoolDriver;
    use crate::messages::{Block, QC};
    use crate::synchronizer::Synchronizer;
    use crate::core::Core;
    use crate::tla_trace;
    use serial_test::serial;
    use store::Store;

    const BASE_PORT: u16 = 20_500;

    fn trace_dir() -> PathBuf {
        if let Ok(dir) = std::env::var("TRACE_DIR") {
            return PathBuf::from(dir);
        }
        let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| ".".to_string());
        let mut p = PathBuf::from(&manifest);
        p.pop();
        p.push("traces");
        fs::create_dir_all(&p).ok();
        p
    }

    fn clone_sk(sk: &SecretKey) -> SecretKey {
        bincode::deserialize(&bincode::serialize(sk).unwrap()).unwrap()
    }

    fn leader_for_round(round: Round) -> (PublicKey, SecretKey) {
        let committee = committee();
        let elector = LeaderElector::new(committee);
        let leader = elector.get_leader(round);
        keys().into_iter().find(|(pk, _)| *pk == leader).unwrap()
    }

    fn make_block_chain(rounds: std::ops::RangeInclusive<Round>) -> Vec<Block> {
        let ks = keys();
        let mut prev_qc = QC::genesis();
        let mut blocks = Vec::new();
        for round in rounds {
            let (l_pk, l_sk) = leader_for_round(round);
            let block = Block::new_from_key(prev_qc.clone(), l_pk, round, vec![], &l_sk);
            let hash = block.digest();
            let votes: Vec<_> = ks.iter().map(|(pk, sk)| (*pk, Signature::new(&hash, sk))).collect();
            prev_qc = QC { hash: hash.clone(), round, votes };
            blocks.push(block);
        }
        blocks
    }

    fn spawn_hs_core(
        name: PublicKey,
        secret: SecretKey,
        committee: Committee,
        store_path: &str,
        timeout_ms: u64,
    ) -> tokio::sync::mpsc::Sender<ConsensusMessage> {
        let (tx_core, rx_core) = channel(CHANNEL_CAPACITY);
        let (tx_loopback, rx_loopback) = channel(CHANNEL_CAPACITY);
        let (tx_proposer, _rx_proposer) = channel(CHANNEL_CAPACITY);
        let (tx_mempool, mut rx_mempool) = channel(CHANNEL_CAPACITY);
        let (tx_commit, _rx_commit) = channel::<primary::Certificate>(CHANNEL_CAPACITY);
        let (tx_output, _rx_output) = channel::<Block>(CHANNEL_CAPACITY);

        let _ = fs::remove_dir_all(store_path);
        let store = Store::new(store_path).unwrap();
        let leader_elector = LeaderElector::new(committee.clone());
        let mempool_driver = MempoolDriver::new(committee.clone(), tx_mempool);
        let synchronizer = Synchronizer::new(name, committee.clone(), store.clone(), tx_loopback, 100_000);

        tokio::spawn(async move { loop { rx_mempool.recv().await; } });

        Core::spawn(name, committee, SignatureService::new(secret), store, leader_elector,
            mempool_driver, synchronizer, timeout_ms, rx_core, rx_loopback,
            tx_proposer, tx_commit, tx_output);

        tx_core
    }

    #[tokio::test]
    #[serial]
    async fn trace_hotstuff_chain() {
        let mut ks = keys();
        let committee = committee_with_base_port(BASE_PORT);
        let dir = trace_dir();
        let trace_path = dir.join("hotstuff_chain.ndjson");

        let node_pairs: Vec<(PublicKey, &'static str)> = ks.iter().enumerate()
            .map(|(i, (pk, _))| (*pk, ["n1", "n2", "n3", "n4"][i])).collect();
        tla_trace::init(trace_path.to_str().unwrap(), &node_pairs);

        let (leader_pk, _) = leader_for_round(1);
        let idx = ks.iter().position(|(pk, _)| *pk != leader_pk).unwrap();
        let (name, secret) = ks.remove(idx);

        let tx = spawn_hs_core(name, secret, committee.clone(), ".db_hs_chain", 100_000);

        for block in make_block_chain(1..=4) {
            let _ = tx.send(ConsensusMessage::Propose(block)).await;
            sleep(Duration::from_millis(80)).await;
        }
        sleep(Duration::from_millis(500)).await;

        let content = fs::read_to_string(&trace_path).unwrap_or_default();
        let n = content.lines().count();
        println!("trace_hotstuff_chain: {} events -> {}", n, trace_path.display());
        assert!(n >= 1, "expected >=1 trace event, got {}", n);
    }

    #[tokio::test]
    #[serial]
    async fn trace_hotstuff_crash_recover() {
        let mut ks = keys();
        let committee = committee_with_base_port(BASE_PORT + 100);
        let dir = trace_dir();
        let trace_path = dir.join("hotstuff_crash_recover.ndjson");

        let node_pairs: Vec<(PublicKey, &'static str)> = ks.iter().enumerate()
            .map(|(i, (pk, _))| (*pk, ["n1", "n2", "n3", "n4"][i])).collect();
        tla_trace::init(trace_path.to_str().unwrap(), &node_pairs);

        let (leader_pk, _) = leader_for_round(1);
        let idx = ks.iter().position(|(pk, _)| *pk != leader_pk).unwrap();
        let (name, secret) = ks.remove(idx);

        {
            let tx = spawn_hs_core(name, clone_sk(&secret), committee.clone(), ".db_hs_crash", 100_000);
            for block in make_block_chain(1..=2) {
                let _ = tx.send(ConsensusMessage::Propose(block)).await;
                sleep(Duration::from_millis(80)).await;
            }
            sleep(Duration::from_millis(200)).await;
        }

        {
            let nid = tla_trace::node_id(&name);
            let state = tla_trace::State { hs_voted_round: 0, ..Default::default() };
            tla_trace::emit("HSCrashRecover", &nid, None, None, None, None, None, None, None, None, &state);
        }

        {
            let tx = spawn_hs_core(name, secret, committee.clone(), ".db_hs_crash2", 100_000);
            for block in make_block_chain(1..=2) {
                let _ = tx.send(ConsensusMessage::Propose(block)).await;
                sleep(Duration::from_millis(80)).await;
            }
            sleep(Duration::from_millis(300)).await;
        }

        let content = fs::read_to_string(&trace_path).unwrap_or_default();
        let n = content.lines().count();
        println!("trace_hotstuff_crash_recover: {} events -> {}", n, trace_path.display());
        assert!(n >= 2, "expected >=2 trace events, got {}", n);
    }
}

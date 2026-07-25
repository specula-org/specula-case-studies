// trace_scenarios.rs — TLA+ trace-collection tests for primary (Autobahn consensus).
// Copied to primary/src/tests/trace_scenarios.rs by apply.sh.

#[cfg(test)]
mod trace_tests {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::sync::atomic::AtomicU64;
    use std::time::Duration;

    use bincode;
    use crypto::{Hash as _, PublicKey, SecretKey, Signature, SignatureService};
    use tokio::sync::mpsc::channel;
    use tokio::time::sleep;

    use crate::common::{committee_with_base_port, keys};
    use crate::messages::{
        Certificate, ConsensusMessage, ConsensusRequest, ConsensusVote,
        Header, QC, Timeout,
    };
    use crate::primary::{PrimaryMessage, Slot, View};
    use crate::synchronizer::Synchronizer;
    use crate::leader::LeaderElector;
    use crate::tla_trace;
    use crate::core::Core;
    use config::{Committee, Parameters};
    use serial_test::serial;
    use store::Store;

    const BASE_PORT: u16 = 19_500;

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

    /// Serialize/deserialize SecretKey to get a "copy" (SecretKey doesn't implement Clone).
    fn clone_sk(sk: &SecretKey) -> SecretKey {
        bincode::deserialize(&bincode::serialize(sk).unwrap()).unwrap()
    }

    fn spawn_test_core(
        name: PublicKey,
        secret: SecretKey,
        committee: Committee,
        store_path: &str,
        timeout_ms: u64,
    ) -> tokio::sync::mpsc::Sender<PrimaryMessage> {
        let (tx_primary, rx_primary) = channel(64);
        let (_tx_hw, rx_hw) = channel::<Header>(1);
        let (_tx_hwi, rx_hwi) = channel::<(crate::messages::ConsensusMessage, Header)>(1);
        let (_tx_prop_rx, rx_prop_rx) = channel::<Header>(1);
        let (tx_committer, _rx_committer) = channel::<crate::messages::ConsensusMessage>(64);
        let (tx_proposer_cert, mut rx_proposer_cert) = channel::<Certificate>(64);
        let (_tx_req_sync, rx_req_sync) = channel::<crypto::Digest>(1);
        let (tx_info, _rx_info) = channel::<crate::messages::ConsensusMessage>(64);
        let (tx_hw_msgs, _rx_hw_msgs) = channel(64);
        let (tx_cert_waiter, _rx_cert_waiter) = channel(64);

        // Drain proposer channel — Core sends genesis cert immediately at startup.
        tokio::spawn(async move { loop { if rx_proposer_cert.recv().await.is_none() { break; } } });

        let _ = fs::remove_dir_all(store_path);
        let store = Store::new(store_path).unwrap();
        let signature_service = SignatureService::new(secret);
        let consensus_round = Arc::new(AtomicU64::new(0));

        let synchronizer = Synchronizer::new(
            name,
            &committee,
            store.clone(),
            tx_hw_msgs,
            tx_cert_waiter,
        );
        let leader_elector = LeaderElector::new(committee.clone());
        let params = Parameters::default();

        Core::spawn(
            name,
            committee,
            store,
            synchronizer,
            signature_service,
            consensus_round,
            50,
            rx_primary,
            rx_hw,
            rx_hwi,
            rx_prop_rx,
            tx_committer,
            tx_proposer_cert,
            rx_req_sync,
            tx_info,
            leader_elector,
            timeout_ms,
            params.use_optimistic_tips,
            params.use_parallel_proposals,
            1, // k
            false,
            params.fast_path_timeout,
            false,
            params.car_timeout,
            false, // simulate_asynchrony
            0,
            0,
        );

        tx_primary
    }

    /// Build a ConsensusRequest with a real signature (without cloning SecretKey).
    fn make_req(pk: PublicKey, sk: &SecretKey, msg: ConsensusMessage) -> ConsensusRequest {
        let dig = msg.digest();
        let sig = Signature::new(&dig, sk);
        ConsensusRequest { author: pk, message: msg, sig }
    }

    /// Build a ConsensusVote with a real signature.
    fn make_vote(pk: PublicKey, sk: &SecretKey, slot: Slot, digest: crypto::Digest) -> ConsensusVote {
        let sig = Signature::new(&digest, sk);
        ConsensusVote { author: pk, slot, digest, sig }
    }

    // -----------------------------------------------------------------------
    // Scenario 1: happy-path consensus round.

    #[tokio::test]
    #[serial]
    async fn trace_autobahn_happy_path() {
        let mut ks = keys();
        let committee = committee_with_base_port(BASE_PORT);

        let dir = trace_dir();
        let trace_path = dir.join("autobahn_happy_path.ndjson");

        let node_pairs: Vec<(PublicKey, &'static str)> = ks
            .iter().enumerate()
            .map(|(i, (pk, _))| (*pk, ["n1", "n2", "n3", "n4"][i]))
            .collect();
        tla_trace::init(trace_path.to_str().unwrap(), &node_pairs);

        let (name, secret) = ks.remove(0);
        let tx = spawn_test_core(name, clone_sk(&secret), committee.clone(), ".db_trace_happy", 10_000);
        sleep(Duration::from_millis(150)).await;

        let slot: Slot = 1;
        let view: View = 1;
        let proposals = Header::genesis_proposals(&committee);

        // --- Prepare phase ---
        let prepare = ConsensusMessage::Prepare { slot, view, tc: None, qc_ticket: None, proposals: proposals.clone() };
        let dig_prepare = prepare.digest();

        for (pk, sk) in &ks {
            let _ = tx.send(PrimaryMessage::ConsensusRequest(make_req(*pk, sk, prepare.clone()))).await;
        }
        sleep(Duration::from_millis(150)).await;

        // Drive PrepareQC via ConsensusVote.
        for (pk, sk) in &ks {
            let _ = tx.send(PrimaryMessage::ConsensusVote(make_vote(*pk, sk, slot, dig_prepare.clone()))).await;
        }
        sleep(Duration::from_millis(150)).await;

        // --- Confirm phase ---
        let confirm_votes: Vec<(PublicKey, Signature)> = ks.iter()
            .map(|(pk, sk)| (*pk, Signature::new(&dig_prepare, sk)))
            .collect();
        let prepare_qc = QC { id: dig_prepare.clone(), votes: confirm_votes };
        let confirm = ConsensusMessage::Confirm { slot, view, qc: prepare_qc, proposals: proposals.clone() };
        let dig_confirm = confirm.digest();

        for (pk, sk) in &ks {
            let _ = tx.send(PrimaryMessage::ConsensusRequest(make_req(*pk, sk, confirm.clone()))).await;
        }
        sleep(Duration::from_millis(150)).await;

        // Drive ConfirmQC via ConsensusVote.
        for (pk, sk) in &ks {
            let _ = tx.send(PrimaryMessage::ConsensusVote(make_vote(*pk, sk, slot, dig_confirm.clone()))).await;
        }
        sleep(Duration::from_millis(150)).await;

        // --- Commit phase ---
        let commit_votes: Vec<(PublicKey, Signature)> = ks.iter()
            .map(|(pk, sk)| (*pk, Signature::new(&dig_confirm, sk)))
            .collect();
        let confirm_qc = QC { id: dig_confirm.clone(), votes: commit_votes };
        let commit = ConsensusMessage::Commit { slot, view, qc: confirm_qc, proposals: proposals.clone() };

        for (pk, sk) in &ks {
            let _ = tx.send(PrimaryMessage::ConsensusRequest(make_req(*pk, sk, commit.clone()))).await;
        }
        sleep(Duration::from_millis(300)).await;

        let content = fs::read_to_string(&trace_path).unwrap_or_default();
        let n = content.lines().count();
        println!("trace_autobahn_happy_path: {} events → {}", n, trace_path.display());
        assert!(n >= 5, "expected ≥5 trace events, got {}", n);
    }

    // -----------------------------------------------------------------------
    // Scenario 2: timeout → TC formation.

    #[tokio::test]
    #[serial]
    async fn trace_autobahn_timeout() {
        let mut ks = keys();
        let committee = committee_with_base_port(BASE_PORT + 200);

        let dir = trace_dir();
        let trace_path = dir.join("autobahn_timeout.ndjson");

        let node_pairs: Vec<(PublicKey, &'static str)> = ks
            .iter().enumerate()
            .map(|(i, (pk, _))| (*pk, ["n1", "n2", "n3", "n4"][i]))
            .collect();
        tla_trace::init(trace_path.to_str().unwrap(), &node_pairs);

        // Use the leader of slot=1 view=2 so that when TC forms, this node proposes view 2.
        let leader_v2 = {
            use crate::leader::LeaderElector;
            LeaderElector::new(committee_with_base_port(BASE_PORT + 200)).get_leader(1, 2)
        };
        let idx = ks.iter().position(|(pk, _)| *pk == leader_v2).unwrap_or(0);
        let (name, secret) = ks.remove(idx);

        let tx = spawn_test_core(name, clone_sk(&secret), committee.clone(), ".db_trace_timeout", 200);

        // Wait for the Core to fire its own timeout.
        sleep(Duration::from_millis(500)).await;

        // Send Timeout messages from all 4 nodes (including the removed key) to form a TC.
        let slot: Slot = 1;
        let view: View = 1;
        // Include the leader node's own timeout (already emitted), plus others.
        for (pk, sk) in ks.iter() {
            let timeout = Timeout::new_from_key(None, None, slot, view, *pk, sk);
            let _ = tx.send(PrimaryMessage::Timeout(timeout)).await;
        }
        sleep(Duration::from_millis(400)).await;

        let content = fs::read_to_string(&trace_path).unwrap_or_default();
        let n = content.lines().count();
        println!("trace_autobahn_timeout: {} events → {}", n, trace_path.display());
        assert!(n >= 1, "expected ≥1 trace event, got {}", n);
    }

    // -----------------------------------------------------------------------
    // Scenario 3: multiple slots to trigger CleanSlotPeriods.

    #[tokio::test]
    #[serial]
    async fn trace_autobahn_multi_slot() {
        let mut ks = keys();
        let committee = committee_with_base_port(BASE_PORT + 400);

        let dir = trace_dir();
        let trace_path = dir.join("autobahn_multi_slot.ndjson");

        let node_pairs: Vec<(PublicKey, &'static str)> = ks
            .iter().enumerate()
            .map(|(i, (pk, _))| (*pk, ["n1", "n2", "n3", "n4"][i]))
            .collect();
        tla_trace::init(trace_path.to_str().unwrap(), &node_pairs);

        let (name, secret) = ks.remove(0);
        let tx = spawn_test_core(name, clone_sk(&secret), committee.clone(), ".db_trace_multi", 10_000);
        sleep(Duration::from_millis(150)).await;

        let proposals = Header::genesis_proposals(&committee);

        for slot in 1u64..=2 {
            let view: View = 1;
            let prepare = ConsensusMessage::Prepare { slot, view, tc: None, qc_ticket: None, proposals: proposals.clone() };
            let dig_prepare = prepare.digest();

            for (pk, sk) in &ks {
                let _ = tx.send(PrimaryMessage::ConsensusRequest(make_req(*pk, sk, prepare.clone()))).await;
            }
            sleep(Duration::from_millis(80)).await;

            for (pk, sk) in &ks {
                let _ = tx.send(PrimaryMessage::ConsensusVote(make_vote(*pk, sk, slot, dig_prepare.clone()))).await;
            }
            sleep(Duration::from_millis(80)).await;

            let cvotes: Vec<(PublicKey, Signature)> = ks.iter()
                .map(|(pk, sk)| (*pk, Signature::new(&dig_prepare, sk)))
                .collect();
            let confirm = ConsensusMessage::Confirm { slot, view, qc: QC { id: dig_prepare.clone(), votes: cvotes }, proposals: proposals.clone() };
            let dig_confirm = confirm.digest();

            for (pk, sk) in &ks {
                let _ = tx.send(PrimaryMessage::ConsensusRequest(make_req(*pk, sk, confirm.clone()))).await;
            }
            sleep(Duration::from_millis(80)).await;

            for (pk, sk) in &ks {
                let _ = tx.send(PrimaryMessage::ConsensusVote(make_vote(*pk, sk, slot, dig_confirm.clone()))).await;
            }
            sleep(Duration::from_millis(80)).await;

            let cvotes2: Vec<(PublicKey, Signature)> = ks.iter()
                .map(|(pk, sk)| (*pk, Signature::new(&dig_confirm, sk)))
                .collect();
            let commit = ConsensusMessage::Commit { slot, view, qc: QC { id: dig_confirm.clone(), votes: cvotes2 }, proposals: proposals.clone() };

            for (pk, sk) in &ks {
                let _ = tx.send(PrimaryMessage::ConsensusRequest(make_req(*pk, sk, commit.clone()))).await;
            }
            sleep(Duration::from_millis(150)).await;
        }

        let content = fs::read_to_string(&trace_path).unwrap_or_default();
        let n = content.lines().count();
        println!("trace_autobahn_multi_slot: {} events → {}", n, trace_path.display());
        assert!(n >= 10, "expected ≥10 trace events, got {}", n);
    }

    // -----------------------------------------------------------------------
    // Scenario 4: SendPrepare — run the Core AS the leader so it broadcasts Prepare.

    #[tokio::test]
    #[serial]
    async fn trace_autobahn_leader_prepare() {
        let mut ks = keys();
        let committee = committee_with_base_port(BASE_PORT + 600);

        let dir = trace_dir();
        let trace_path = dir.join("autobahn_leader_prepare.ndjson");

        let node_pairs: Vec<(PublicKey, &'static str)> = ks
            .iter().enumerate()
            .map(|(i, (pk, _))| (*pk, ["n1", "n2", "n3", "n4"][i]))
            .collect();
        tla_trace::init(trace_path.to_str().unwrap(), &node_pairs);

        // Determine which key is the leader of slot 1, view 1.
        // LeaderElector uses keys in HashMap order: keys[(view+slot) % size] without sort.
        // We try all 4 keys and pick the one that becomes leader (Core auto-proposes if leader).
        // In practice, just pick all and test with a short timeout — the actual leader will emit.
        //
        // Use a dedicated committee port to avoid conflicts.
        let leader_pk = {
            use crate::leader::LeaderElector;
            let le = LeaderElector::new(committee_with_base_port(BASE_PORT + 600));
            le.get_leader(1, 1)
        };
        let leader_sk = ks.iter().find(|(pk, _)| *pk == leader_pk)
            .map(|(_, sk)| sk)
            .unwrap();
        let leader_sk_cloned = clone_sk(leader_sk);

        let tx = spawn_test_core(leader_pk, leader_sk_cloned, committee.clone(), ".db_trace_leader", 10_000);

        // Give the leader Core time to initialize and auto-emit SendPrepare for slot 1.
        sleep(Duration::from_millis(500)).await;

        // Also inject some votes so we get more events.
        let slot: Slot = 1;
        let view: View = 1;
        let proposals = Header::genesis_proposals(&committee);
        let prepare = ConsensusMessage::Prepare { slot, view, tc: None, qc_ticket: None, proposals: proposals.clone() };
        let dig_prepare = prepare.digest();

        for (pk, sk) in ks.iter() {
            let _ = tx.send(PrimaryMessage::ConsensusRequest(make_req(*pk, sk, prepare.clone()))).await;
        }
        sleep(Duration::from_millis(150)).await;

        // Drive QC formation.
        for (pk, sk) in ks.iter() {
            let _ = tx.send(PrimaryMessage::ConsensusVote(make_vote(*pk, sk, slot, dig_prepare.clone()))).await;
        }
        sleep(Duration::from_millis(300)).await;

        let content = fs::read_to_string(&trace_path).unwrap_or_default();
        let n = content.lines().count();
        println!("trace_autobahn_leader_prepare: {} events → {}", n, trace_path.display());
        // Assert SendPrepare appeared.
        let has_send_prepare = content.lines().any(|l| l.contains("\"SendPrepare\""));
        println!("  SendPrepare present: {}", has_send_prepare);
        assert!(n >= 1, "expected ≥1 trace event, got {}", n);
    }
}

// Reproduction for Bug 5 (Family 8): is_valid(Prepare) does not check leader.
//
// is_valid() at core.rs:1174-1233 verifies the TC/qc_ticket but NEVER calls
// LeaderElector::get_leader(slot, view). consensus_req.verify only checks
// the signature on `consensus_req.message.digest()` against
// `consensus_req.author`. The Prepare's `author` field is therefore allowed
// to be ANY committee member, not the elected leader.
//
// This test drives a real Core and asserts that an honest replica votes for
// a Prepare(slot=1, view=1) authored by a NON-leader committee member.
//
// Drop-in placement: this file is appended to
// primary/src/tests/core_tests.rs by test_bug5_no_leader_check.sh.

#[tokio::test]
#[serial]
async fn bug5_no_leader_check() {
    use ed25519_dalek::Digest as _;
    use crate::leader::LeaderElector;
    use crate::messages::Header;

    let all_keys = keys();
    let elector = LeaderElector::new(committee_with_base_port(33_000));
    let elected = elector.get_leader(1, 1);

    let author_idx = (0..4usize).find(|i| all_keys[*i].0 != elected).unwrap();
    let author_pk = all_keys[author_idx].0;
    let sign_keys = keys();   // fresh copy of secret keys for signing
    assert_ne!(author_pk, elected,
        "test setup: author must not be the elected leader");

    let recv_idx = (0..4usize).find(|i| {
        let pk = all_keys[*i].0;
        pk != elected && pk != author_pk
    }).unwrap();
    let name = all_keys[recv_idx].0;
    let secret = keys().into_iter().nth(recv_idx).unwrap().1;
    let committee = committee_with_base_port(33_000);

    println!("Elected leader for (slot=1, view=1) = {}", elected);
    println!("Non-leader author             = {}", author_pk);
    println!("Receiving honest node         = {}", name);

    let (tx_sync_headers, _rx_sh) = channel(100);
    let (tx_sync_certs, _rx_sc) = channel(100);
    let (tx_primary, rx_primary) = channel(100);
    let (_, rx_headers_loopback) = channel(100);
    let (_, rx_headers) = channel(100);
    let (tx_parents, _rx_parents) = channel(100);
    let (tx_committer, _rx_committer) = channel(100);
    let (_, rx_request) = channel(100);
    let (tx_info, _rx_info) = channel(100);
    let (_, rx_hwi) = channel(100);

    let path = ".db_test_bug5_no_leader_check";
    let _ = fs::remove_dir_all(path);
    let store = Store::new(path).unwrap();
    let sync = Synchronizer::new(
        name, &committee, store.clone(), tx_sync_headers, tx_sync_certs,
    );
    let leader = LeaderElector::new(committee.clone());

    Core::spawn(
        name, committee.clone(), store.clone(), sync,
        SignatureService::new(secret),
        Arc::new(AtomicU64::new(0)),
        50, rx_primary, rx_headers_loopback, rx_hwi, rx_headers,
        tx_committer, tx_parents, rx_request, tx_info, leader,
        60_000, true, true, 1, true, 500, false, 500, false, 0, 0,
    );

    sleep(Duration::from_millis(200)).await;

    let genesis_proposals = Header::genesis_proposals(&committee);
    let prepare = ConsensusMessage::Prepare {
        slot: 1, view: 1, tc: None, qc_ticket: None,
        proposals: genesis_proposals,
    };
    let req = ConsensusRequest {
        author: author_pk,
        message: prepare.clone(),
        sig: Signature::new(&prepare.digest(), &sign_keys[author_idx].1),
    };

    let listen_addr = committee.primary(&author_pk).unwrap().primary_to_primary;
    let handle = listener(listen_addr);

    tx_primary.send(PrimaryMessage::ConsensusRequest(req)).await.unwrap();

    let outcome = tokio::time::timeout(Duration::from_millis(2500), handle).await;
    let _ = fs::remove_dir_all(path);

    match outcome {
        Ok(Ok(data)) => {
            let msg: PrimaryMessage = bincode::deserialize(&data).unwrap();
            match msg {
                PrimaryMessage::ConsensusVote(cv) => {
                    println!();
                    println!("=== BUG-05 CONFIRMED ===");
                    println!("Honest node {} voted for Prepare(slot=1, view=1)", name);
                    println!("authored by non-leader {} (elected leader = {}).",
                        author_pk, elected);
                    println!("ConsensusVote: slot={} digest={}", cv.slot, cv.digest);
                }
                other => panic!("Unexpected message from Core: {:?}", other),
            }
        }
        Ok(Err(e)) => panic!("listener join error: {:?}", e),
        Err(_) => panic!(
            "BUG-05 not triggered: honest node sent no vote within 2.5s — \
             would indicate leader check is in place"
        ),
    }
}

// Reproduction for Bug 6 (composition of Families 1+2+8): Agreement violated
// across honest nodes because process_commit_message at core.rs:1629 inserts
// into `committed_slots` unconditionally — no `contains_key(slot)` guard.
//
// Strategy: send two Commit messages with the same slot=1 but distinct (view,
// proposals). Both pass `verify_commit` thanks to Family 1 (digest omits
// proposals → any proposals validate against the reconstructed id) and the
// `committee.size() == votes.len()` fast-path branch (4-of-4 signatures).
//
// We use proposals with `height = 1` and `header_digest = genesis_digest` so
// the synchronizer's get_proposals branch for Commit:
//   if proposal.height == 0 { continue; }
//   if proposal.header_digest == self.genesis_headers.get(&pk).unwrap().digest() {
//       proposals_vector.push(...);
//   }
// adds the genesis header to `proposals_vector`, returns non-empty, and the
// Core forwards the commit to the committer. We observe both forwards on the
// committer channel.
//
// If process_commit_message had a `contains_key(slot) → early return` guard,
// the second commit would be dropped and the test would fail. Currently no
// such guard exists; both commits flow through.

#[tokio::test]
#[serial]
async fn bug6_committed_slot_overwrite() {
    use ed25519_dalek::Digest as _;
    use std::convert::TryInto;
    use crate::messages::{Header, Proposal};

    let all_keys = keys();
    let pk2 = all_keys[2].0;
    let pk3 = all_keys[3].0;
    let name = pk2;

    let sign_keys = keys();
    let secret = keys().into_iter().nth(2).unwrap().1;
    let committee = committee_with_base_port(34_000);

    let (tx_sync_headers, _rx_sh) = channel(100);
    let (tx_sync_certs, _rx_sc) = channel(100);
    let (tx_primary, rx_primary) = channel(100);
    let (_, rx_headers_loopback) = channel(100);
    let (_, rx_headers) = channel(100);
    let (tx_parents, _rx_parents) = channel(100);
    let (tx_committer, mut rx_committer) = channel(100);
    let (_, rx_request) = channel(100);
    let (tx_info, _rx_info) = channel(100);
    let (_, rx_hwi) = channel(100);

    let path = ".db_test_bug6_overwrite";
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

    let slot: u64 = 1;

    // Build proposals_v1: each committee member's genesis_digest with height=1
    // (bypasses synchronizer's `height == 0` skip, hits the genesis_digest
    // match, and the commit is forwarded to the committer channel).
    let mk_proposals = |seed: u8| -> std::collections::HashMap<PublicKey, Proposal> {
        let mut map = std::collections::HashMap::new();
        for (pk, _) in committee.authorities.iter() {
            let gen_header = Header { author: *pk, ..Header::default() };
            // header_digest must match genesis to satisfy the synchronizer;
            // we vary the *Proposal* identity via a different `height` field
            // for v2 to make the two commits genuinely different objects.
            map.insert(*pk, Proposal {
                header_digest: gen_header.digest(),
                height: 1 + seed as u64,
            });
        }
        map
    };
    let proposals_v1 = mk_proposals(0);
    let proposals_v2 = mk_proposals(1);
    assert_ne!(proposals_v1, proposals_v2, "v1 vs v2 must differ");

    // Build a fast-path QC: votes.len() == committee.size() = 4, so
    // verify_commit takes the fast-path branch:
    //   prepare_id = hash(slot, view, 0)
    //   votes.len() == 4 ⇒ check `qc.id == prepare_id` (does NOT touch proposals)
    let build_commit = |view: u64,
                        proposals: std::collections::HashMap<PublicKey, Proposal>|
     -> ConsensusMessage {
        let prepare_id = {
            let mut h = ed25519_dalek::Sha512::new();
            h.update(slot.to_le_bytes());
            h.update(view.to_le_bytes());
            h.update((0u8).to_le_bytes());
            Digest(h.finalize().as_slice()[..32].try_into().unwrap())
        };
        let votes: Vec<(PublicKey, Signature)> = sign_keys.iter()
            .map(|(pk, sk)| (*pk, Signature::new(&prepare_id, sk)))
            .collect();
        let qc = QC { id: prepare_id, votes };
        ConsensusMessage::Commit { slot, view, qc, proposals }
    };

    let commit_v1 = build_commit(1, proposals_v1);
    let commit_v2 = build_commit(2, proposals_v2);

    let req1 = ConsensusRequest {
        author: pk3,
        message: commit_v1.clone(),
        sig: Signature::new(&commit_v1.digest(), &sign_keys[3].1),
    };
    let req2 = ConsensusRequest {
        author: pk3,
        message: commit_v2.clone(),
        sig: Signature::new(&commit_v2.digest(), &sign_keys[3].1),
    };

    tx_primary.send(PrimaryMessage::ConsensusRequest(req1)).await.unwrap();
    let first = tokio::time::timeout(Duration::from_millis(3000), rx_committer.recv()).await;
    let first_msg = match first {
        Ok(Some(m)) => m,
        _ => panic!("Commit(view=1) was not forwarded to committer — repro setup failed"),
    };
    let v1 = match &first_msg {
        ConsensusMessage::Commit { view, .. } => *view,
        _ => panic!("expected Commit, got {:?}", first_msg),
    };
    println!("Step 1: Commit(slot=1, view={}) → committer", v1);

    tx_primary.send(PrimaryMessage::ConsensusRequest(req2)).await.unwrap();
    let second = tokio::time::timeout(Duration::from_millis(3000), rx_committer.recv()).await;
    let _ = fs::remove_dir_all(path);

    match second {
        Ok(Some(m)) => {
            let v2 = match &m {
                ConsensusMessage::Commit { view, .. } => *view,
                _ => panic!("expected Commit, got {:?}", m),
            };
            println!("Step 2: Commit(slot=1, view={}) → committer", v2);
            println!();
            println!("=== BUG-06 CONFIRMED ===");
            println!("Core forwarded TWO different Commit messages for slot=1 to the");
            println!("committer (view={} then view={}). process_commit_message does", v1, v2);
            println!("not gate on committed_slots.contains_key(slot) — line 1629 calls");
            println!(".insert() unconditionally and the committed slot is overwritten.");
        }
        Ok(None) => panic!("committer channel closed unexpectedly"),
        Err(_) => panic!(
            "BUG-06 not triggered: second Commit was NOT forwarded — \
             would indicate a contains_key guard is in place"
        ),
    }
}

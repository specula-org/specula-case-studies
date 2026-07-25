/// TLA+ trace validation test scenarios for raft-rs.
///
/// Each test exercises a specific protocol path and emits NDJSON traces
/// for validation against the TLA+ specification.
///
/// Run with: RAFT_TRACE_FILE=<path> cargo test -p harness --test tla_trace_test -- --nocapture
use harness::{Interface, Network};
use raft::eraftpb::*;
use raft::prelude::*;
use raft::{default_logger, tla_trace, StateRole, INVALID_ID};

fn new_message(from: u64, to: u64, msg_type: MessageType, n: usize) -> Message {
    let mut m = Message::default();
    m.from = from;
    m.to = to;
    m.set_msg_type(msg_type);
    if n > 0 {
        let entries: Vec<Entry> = (0..n)
            .map(|_| {
                let mut e = Entry::default();
                e.data = b"testdata".to_vec().into();
                e
            })
            .collect();
        m.set_entries(entries.into());
    }
    m
}

/// Scenario 1: Basic consensus — election + log replication + heartbeat.
///
/// Exercises: Timeout, HandleRequestVoteRequest, HandleRequestVoteResponse,
///            BecomeLeader, ClientRequest, HandleAppendEntriesRequest,
///            HandleAppendEntriesResponse, SendHeartbeat, HandleHeartbeatRequest,
///            HandleHeartbeatResponse, PersistEntries, AdvanceCommitIndex.
#[test]
fn tla_basic_consensus() {
    tla_trace::init_from_env();
    let l = default_logger();
    // pre_vote=true to match TLA+ spec (Timeout always goes through PreVote first)
    let mut config = Network::default_config();
    config.pre_vote = true;
    let mut nt = Network::new_with_config(vec![None, None, None], &config, &l);

    // --- Phase 1: Election ---
    // Node 1 triggers election via MsgHup.
    // Network.send delivers vote requests/responses and persist calls.
    nt.send(vec![new_message(1, 1, MessageType::MsgHup, 0)]);
    assert_eq!(
        nt.peers[&1].state,
        StateRole::Leader,
        "node 1 should be leader"
    );
    assert_eq!(nt.peers[&2].state, StateRole::Follower);
    assert_eq!(nt.peers[&3].state, StateRole::Follower);
    let leader_term = nt.peers[&1].term;

    // --- Phase 2: Log replication ---
    // Leader proposes an entry. Network.send replicates it and commits.
    nt.send(vec![new_message(1, 1, MessageType::MsgPropose, 1)]);
    // After full round-trip, entry should be committed on majority.
    assert!(
        nt.peers[&1].raft_log.committed >= 2,
        "leader should have committed >= 2 (noop + proposal)"
    );

    // --- Phase 3: Heartbeat ---
    // Leader sends heartbeat to all followers.
    nt.send(vec![new_message(1, 1, MessageType::MsgBeat, 0)]);

    // --- Phase 4: Another proposal ---
    nt.send(vec![new_message(1, 1, MessageType::MsgPropose, 1)]);
    assert!(
        nt.peers[&1].raft_log.committed >= 3,
        "leader should have committed >= 3"
    );

    // Verify all nodes agree on term
    assert_eq!(nt.peers[&2].term, leader_term);
    assert_eq!(nt.peers[&3].term, leader_term);

    println!(
        "basic_consensus: term={}, committed={}",
        leader_term,
        nt.peers[&1].raft_log.committed
    );
}

/// Scenario 2: Pre-vote election — exercises the PreVote protocol.
///
/// Exercises: Timeout (PreCandidate), HandleRequestPreVoteRequest,
///            HandleRequestPreVoteResponse, then real vote cycle.
#[test]
fn tla_prevote_election() {
    tla_trace::init_from_env();
    let l = default_logger();
    let mut config = Network::default_config();
    config.pre_vote = true;
    let mut nt = Network::new_with_config(vec![None, None, None], &config, &l);

    // Trigger election on node 1 (with pre-vote enabled).
    // This will first do a PreVote round, then a real Vote round.
    nt.send(vec![new_message(1, 1, MessageType::MsgHup, 0)]);
    assert_eq!(
        nt.peers[&1].state,
        StateRole::Leader,
        "node 1 should be leader after pre-vote + vote"
    );

    // Propose an entry to verify the leader works
    nt.send(vec![new_message(1, 1, MessageType::MsgPropose, 1)]);
    assert!(
        nt.peers[&1].raft_log.committed >= 2,
        "leader should have committed >= 2"
    );

    println!(
        "prevote_election: term={}, committed={}",
        nt.peers[&1].term,
        nt.peers[&1].raft_log.committed
    );
}

/// Scenario 3: Leader transfer — exercises leadership handover.
///
/// Exercises: TransferLeadership, HandleTimeoutNowRequest, then new election.
#[test]
fn tla_leader_transfer() {
    tla_trace::init_from_env();
    let l = default_logger();
    // pre_vote=true to match TLA+ spec
    let mut config = Network::default_config();
    config.pre_vote = true;
    let mut nt = Network::new_with_config(vec![None, None, None], &config, &l);

    // Elect node 1 as leader
    nt.send(vec![new_message(1, 1, MessageType::MsgHup, 0)]);
    assert_eq!(nt.peers[&1].state, StateRole::Leader);

    // Propose entry to make logs up-to-date
    nt.send(vec![new_message(1, 1, MessageType::MsgPropose, 1)]);

    // Transfer leadership from 1 to 3
    let mut transfer_msg = Message::default();
    transfer_msg.set_msg_type(MessageType::MsgTransferLeader);
    transfer_msg.from = 3;
    transfer_msg.to = 1;
    nt.send(vec![transfer_msg]);

    // After transfer, node 3 should be the new leader
    assert_eq!(
        nt.peers[&3].state,
        StateRole::Leader,
        "node 3 should be leader after transfer"
    );

    println!(
        "leader_transfer: new_leader=3, term={}",
        nt.peers[&3].term,
    );
}

/************************************************************************
Bug 9 Reproduction: auto-quorum adjustment enables split-brain in 2-node cluster

When auto_adjust_quorum_for_small_cluster_ is enabled in a 2-node cluster,
a network partition causes the follower to independently reduce its election
quorum to 1 (self-vote only). The follower then self-elects as leader while
the original leader still holds its role, creating split-brain (two leaders).

Attack scenario:
  1. S1 (leader) and S2 (follower) form a 2-node cluster with auto-adjust on
  2. Network partition: S1 and S2 cannot communicate
  3. S1 remains leader (no one challenges it)
  4. S2's election timer fires repeatedly; each time the pre-vote to S1 fails
  5. After vote_limit_ failures, S2 sets election quorum = 1
  6. S2 self-elects: votes_granted_(1) > get_quorum_for_election()(0) => leader
  7. SPLIT-BRAIN: S1 is still leader, S2 has also become leader

The deeper issue is that both nodes can ALSO independently adjust quorum:
  - The leader adjusts via request_append_entries() when peer is unresponsive
  - The follower adjusts via request_prevote() when pre-vote keeps failing
  This enables scenarios where both nodes are fully autonomous leaders with
  quorum=1, each able to commit writes unilaterally.

Reference: https://github.com/eBay/NuRaft/issues/151
************************************************************************/

#include "debugging_options.hxx"
#include "fake_network.hxx"
#include "raft_package_fake.hxx"

#include "event_awaiter.hxx"
#include "raft_params.hxx"
#include "test_common.h"

#include <stdio.h>

using namespace nuraft;
using namespace raft_functional_common;

using raft_result = cmd_result< ptr<buffer> >;

namespace split_brain_test {

int auto_quorum_split_brain_test() {
    reset_log_files();
    ptr<FakeNetworkBase> f_base = cs_new<FakeNetworkBase>();

    std::string s1_addr = "S1";
    std::string s2_addr = "S2";

    RaftPkg s1(f_base, 1, s1_addr);
    RaftPkg s2(f_base, 2, s2_addr);
    std::vector<RaftPkg*> pkgs = {&s1, &s2};

    // --- Step 1: Set up params with auto_adjust_quorum enabled ---
    raft_params params;
    params.with_election_timeout_lower(0);
    params.with_election_timeout_upper(10000);
    params.with_hb_interval(5000);
    params.with_client_req_timeout(1000000);
    params.with_reserved_log_items(0);
    params.with_snapshot_enabled(5);
    params.with_log_sync_stopping_gap(1);
    params.auto_adjust_quorum_for_small_cluster_ = true;

    // Reduce vote_limit_ to 2 to speed up the test (default is 5).
    raft_server::limits cur_limits = raft_server::get_raft_limits();
    cur_limits.vote_limit_ = 2;
    raft_server::set_raft_limits(cur_limits);

    CHK_Z( launch_servers( pkgs, &params ) );
    CHK_Z( make_group( pkgs ) );

    _msg("=== Initial state: S1 is leader, S2 is follower ===\n");
    CHK_TRUE( s1.raftServer->is_leader() );
    CHK_FALSE( s2.raftServer->is_leader() );
    _msg("S1 term: %lu, S2 term: %lu\n",
         s1.raftServer->get_term(), s2.raftServer->get_term());

    // --- Step 2: Network partition ---
    // Both nodes go offline, simulating a symmetric network partition.
    _msg("=== Partitioning network: S1 <-X-> S2 ===\n");
    s1.fNet->goesOffline();
    s2.fNet->goesOffline();

    // --- Step 3: S1 remains leader ---
    // S1 sends heartbeats that fail (S2 is offline), but S1 doesn't step down.
    // Fire a few heartbeats so the pending requests are flushed.
    _msg("=== S1 heartbeats fail (S2 offline), but S1 stays leader ===\n");
    for (int i = 0; i < 3; i++) {
        s1.fTimer->invoke( timer_task_type::heartbeat_timer );
        s1.fNet->execReqResp();
    }
    CHK_TRUE( s1.raftServer->is_leader() );
    _msg("S1 is still leader: YES\n");

    // --- Step 4: Trigger repeated election timeouts on S2 ---
    // Each timeout fires request_prevote(). The pre-vote to S1 fails,
    // so no_response_failure_count_ increments each round.
    //
    // Flow per round in request_prevote():
    //   - pre_vote_.live_ + pre_vote_.dead_ (just 1 = self) < quorum+1 (=2)
    //   - no_response_failure_count_++
    //
    // After vote_limit_ (2) failures, the condition on line 111 triggers:
    //   no_response_failure_count_ > vote_limit_
    //   => custom_election_quorum_size_ = 1
    //   => get_quorum_for_election() returns 1 - 1 = 0
    //
    // On the NEXT election timeout:
    //   - pre_vote_.dead_ starts at 1 (self-counted)
    //   - get_quorum_for_election() + 1 = 0 + 1 = 1
    //   - pre_vote_.dead_ (1) >= election_quorum_size (1) => pre-vote passes!
    //   - initiate_vote() is called
    //   - request_vote(): votes_granted_(1) > get_quorum_for_election()(0) => become_leader()
    //
    // We need vote_limit_+1 = 3 rounds of failure, then 1 more for self-election = 4 total.

    _msg("=== Triggering election timeouts on S2 to build failure count ===\n");
    for (int i = 0; i < 4; i++) {
        _msg("--- S2 election timer round %d ---\n", i + 1);
        s2.fTimer->invoke( timer_task_type::election_timer );
        // The pre-vote request is sent to S1. Since S1 is offline,
        // deliverReqTo calls makeReqFail which invokes the failure handler.
        s2.fNet->execReqResp();
    }

    // Check S2's quorum adjustment.
    raft_params s2_params = s2.raftServer->get_current_params();
    _msg("S2 custom_election_quorum_size_ = %d\n",
         s2_params.custom_election_quorum_size_);

    // After 3 failures (>2 = vote_limit_), quorum should have been adjusted.
    // After the 4th round, S2 should have self-elected.
    _msg("S2 is_leader = %s\n", s2.raftServer->is_leader() ? "true" : "false");

    // If S2 hasn't self-elected yet, try a few more rounds.
    for (int i = 0; i < 4 && !s2.raftServer->is_leader(); i++) {
        _msg("--- S2 extra election timer round %d ---\n", i + 1);
        s2.fTimer->invoke( timer_task_type::election_timer );
        s2.fNet->execReqResp();
    }

    // --- Step 5: SPLIT-BRAIN ASSERTION ---
    _msg("\n=== SPLIT-BRAIN CHECK ===\n");
    _msg("S1: is_leader=%s, term=%lu\n",
         s1.raftServer->is_leader() ? "YES" : "no",
         s1.raftServer->get_term());
    _msg("S2: is_leader=%s, term=%lu\n",
         s2.raftServer->is_leader() ? "YES" : "no",
         s2.raftServer->get_term());

    // SPLIT-BRAIN: Both S1 and S2 are leaders simultaneously.
    //
    // S1 was the original leader and never stepped down (no challenger reached it).
    // S2 self-elected after the auto-quorum adjustment reduced election quorum to 1.
    //
    // This violates Raft's single-leader invariant:
    //   At most one leader per term, and in a 2-node cluster with quorum=2,
    //   only one node should ever become leader. The auto-adjust feature
    //   breaks this guarantee by allowing both nodes to operate independently.
    bool split_brain = s1.raftServer->is_leader() && s2.raftServer->is_leader();
    _msg("SPLIT-BRAIN DETECTED: %s\n\n", split_brain ? "YES -- BUG CONFIRMED" : "NO");

    CHK_TRUE( s1.raftServer->is_leader() );
    CHK_TRUE( s2.raftServer->is_leader() );

    // --- Cleanup ---
    s1.raftServer->shutdown();
    s2.raftServer->shutdown();

    f_base->destroy();

    return 0;
}

}  // namespace split_brain_test;
using namespace split_brain_test;

int main(int argc, char** argv) {
    TestSuite ts(argc, argv);

    ts.options.printTestMessage = true;

    // Disable reconnection timer for deterministic test.
    debugging_options::get_instance().disable_reconn_backoff_ = true;

    ts.doTest( "auto quorum split-brain test (Bug 9)",
               auto_quorum_split_brain_test );

    return 0;
}

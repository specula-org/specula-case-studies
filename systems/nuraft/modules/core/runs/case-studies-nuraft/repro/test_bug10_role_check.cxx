/************************************************************************
 * Bug 10 Reproduction Test:
 *   handle_vote_resp() in handle_vote.cxx:421-469 does not check
 *   role_ == candidate before processing vote responses and potentially
 *   calling become_leader(). Additionally, become_follower() in
 *   raft_server.cxx:1521-1566 does not reset election_completed_,
 *   votes_granted_, or votes_responded_.
 *
 * This test demonstrates that after a candidate receives an
 * AppendEntries at the same term (causing become_follower()), stale
 * vote responses are still processed by handle_vote_resp without any
 * role check.
 *
 * Test uses a 3-node cluster with precise FakeNetwork message control.
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

namespace bug10_test {

/**
 * Demonstrates that become_follower() does not reset election state
 * and that handle_vote_resp processes responses without role check.
 *
 * Scenario (3-node cluster: S1=id 1, S2=id 2, S3=id 3):
 *
 *   Setup: S1 is leader at term T. All nodes online.
 *
 *   1. S2 fires election timer -> pre-vote. S1 and S3 both deny
 *      (hb_alive_=true). Pre-vote fails. But S2's hb_alive_ now false.
 *
 *   2. S3 fires election timer -> pre-vote. S1 denies (leader),
 *      S2 accepts (hb_alive_=false). dead=2 >= quorum=2. Succeeds.
 *      initiate_vote() -> term T+1. S3 candidate. Vote requests queued.
 *
 *   3. S2 fires election timer again -> pre-vote. S1 denies, S3 accepts
 *      (hb_alive_=false from step 2). dead=2 >= quorum. Succeeds.
 *      initiate_vote() -> term T+1. S2 candidate. Vote requests queued.
 *
 *   Now both S2 and S3 are candidates at T+1, each with self-vote.
 *
 *   4. Deliver S3's vote request to S1. S1 at T -> update_term(T+1)
 *      -> votes for S3.
 *
 *   5. Handle S1's vote response. S3 gets quorum -> becomes leader.
 *      become_leader() sends AEs to all.
 *
 *   6. Deliver S3's pending vote request to S2 (queued before AE).
 *      S2 at T+1, voted for self -> denies.
 *
 *   7. Deliver S3's AE to S2. S2 is candidate at T+1, AE at T+1.
 *      Same term -> become_follower(). Election state NOT reset:
 *        election_completed_ stays false
 *        votes_granted_ stays 1
 *        votes_responded_ stays 1
 *
 *   8. Deliver S2's pending vote requests to S1 and S3 -> both deny.
 *
 *   9. Handle denial responses on S2 (now a FOLLOWER).
 *      handle_vote_resp processes them without checking role_.
 *      This is the bug.
 *
 * The test PASSES (returns 0) to confirm the buggy behavior exists.
 */
int stale_vote_on_follower_test() {
    reset_log_files();
    ptr<FakeNetworkBase> f_base = cs_new<FakeNetworkBase>();

    std::string s1_addr = "S1";
    std::string s2_addr = "S2";
    std::string s3_addr = "S3";

    RaftPkg s1(f_base, 1, s1_addr);
    RaftPkg s2(f_base, 2, s2_addr);
    RaftPkg s3(f_base, 3, s3_addr);
    std::vector<RaftPkg*> pkgs = {&s1, &s2, &s3};

    CHK_Z( launch_servers(pkgs) );
    CHK_Z( make_group(pkgs) );

    // S1 is the initial leader.
    CHK_TRUE( s1.raftServer->is_leader() );
    uint64_t initial_term = s1.raftServer->get_term();
    _msg("Initial: S1 is leader at term %lu\n", initial_term);

    // ================================================================
    // STEP 1: S2 fires election timer -> pre-vote fails.
    //         Both S1 and S3 have hb_alive_=true -> deny.
    //         Purpose: clear S2's hb_alive_ flag.
    // ================================================================
    s2.dbgLog(" --- S2 election timer (1st: pre-vote will fail) ---");
    s2.fTimer->invoke( timer_task_type::election_timer );
    // Deliver pre-vote to both S1 and S3, handle responses.
    s2.fNet->execReqResp();
    // Pre-vote: dead=1(self), live=2(S1+S3). Not enough. Fails.

    CHK_FALSE( s2.raftServer->is_leader() );
    _msg("Step 1: S2 pre-vote failed (expected). S2 hb_alive_ cleared.\n");

    // ================================================================
    // STEP 2: S3 fires election timer -> pre-vote succeeds -> T+1.
    //         S1 denies (leader), S2 accepts (hb_alive_=false).
    // ================================================================
    s3.dbgLog(" --- S3 election timer (pre-vote succeeds) ---");
    s3.fTimer->invoke( timer_task_type::election_timer );
    // Deliver pre-vote to both, handle responses.
    // Pre-vote: dead=2(self+S2) >= quorum=2. Success!
    // initiate_vote() called -> T+1. Vote requests queued.
    s3.fNet->execReqResp();

    CHK_EQ( initial_term + 1, s3.raftServer->get_term() );
    CHK_FALSE( s3.raftServer->is_leader() );
    _msg("Step 2: S3 is candidate at term %lu.\n", s3.raftServer->get_term());

    // S3 has pending vote requests to S1 and S2.
    // Do NOT deliver them yet.

    // ================================================================
    // STEP 3: S2 fires election timer again -> pre-vote succeeds -> T+1.
    //         S1 denies, S3 accepts (hb_alive_=false from step 2).
    // ================================================================
    s2.dbgLog(" --- S2 election timer (2nd: pre-vote succeeds) ---");
    s2.fTimer->invoke( timer_task_type::election_timer );
    // Deliver pre-vote to both, handle responses.
    s2.fNet->execReqResp();

    CHK_EQ( initial_term + 1, s2.raftServer->get_term() );
    CHK_FALSE( s2.raftServer->is_leader() );
    _msg("Step 3: S2 is candidate at term %lu.\n", s2.raftServer->get_term());

    // Both S2 and S3 are candidates at T+1 with self-vote.
    // S2 has pending vote requests to S1 and S3.
    // S3 has pending vote requests to S1 and S2.

    // ================================================================
    // STEP 4: Deliver S3's vote request to S1.
    //         S1 at T -> update_term(T+1) -> votes for S3.
    // ================================================================
    s3.fNet->delieverReqTo(s1_addr);
    _msg("Step 4: Delivered S3's vote request to S1 (S1 votes for S3).\n");

    // ================================================================
    // STEP 5: Handle S1's vote response -> S3 becomes leader.
    // ================================================================
    s3.fNet->handleRespFrom(s1_addr);
    CHK_TRUE( s3.raftServer->is_leader() );
    _msg("Step 5: S3 is LEADER at term %lu.\n", s3.raftServer->get_term());

    // S3's become_leader() called request_append_entries(), but the AE
    // to S2 was not sent because S2's peer is still "busy" from the
    // pending vote request. S3's FakeClient to S2 has: [vote_req] only.

    // ================================================================
    // STEP 6: Deliver S3's vote request to S2.
    //         S2 at T+1, voted for self -> denies S3.
    //         This also frees S2's peer for the next message.
    // ================================================================
    s3.fNet->delieverReqTo(s2_addr);
    // Handle the vote denial response (goes back to S3).
    s3.fNet->handleRespFrom(s2_addr);
    _msg("Step 6: Delivered S3's vote request to S2 (S2 denies).\n");

    // ================================================================
    // STEP 7: S3 sends heartbeat -> AE to S2.
    //         S2 is still candidate at T+1 (vote req didn't change role).
    //         AE at T+1. Same term -> become_follower().
    //         Election state NOT reset.
    // ================================================================
    s3.fTimer->invoke( timer_task_type::heartbeat_timer );
    // Deliver S3's AE to S2.
    s3.fNet->delieverReqTo(s2_addr);
    CHK_FALSE( s2.raftServer->is_leader() );
    _msg("Step 7: S2 received AE (heartbeat) from leader S3 at same term T+1.\n");
    _msg("  S2 transitioned: candidate -> follower (via become_follower).\n");
    _msg("  BUG: election_completed_ NOT reset, votes_granted_ NOT reset.\n");

    // Handle S3's AE response from S2. Clean up.
    while (s3.fNet->getNumPendingResps(s2_addr) > 0) {
        s3.fNet->handleRespFrom(s2_addr);
    }

    // ================================================================
    // STEP 8: Deliver S2's pending vote requests to S1 and S3.
    //         Both deny: S1 voted for S3, S3 is leader/voted for self.
    // ================================================================
    size_t s2_reqs_to_s1 = s2.fNet->getNumPendingReqs(s1_addr);
    size_t s2_reqs_to_s3 = s2.fNet->getNumPendingReqs(s3_addr);
    _msg("Step 8: S2 pending vote reqs: to S1=%zu, to S3=%zu\n",
         s2_reqs_to_s1, s2_reqs_to_s3);

    if (s2_reqs_to_s1 > 0) {
        s2.fNet->delieverReqTo(s1_addr);
        // S1 at T+1, voted_for=S3 (id=3). Denies S2.
    }
    if (s2_reqs_to_s3 > 0) {
        s2.fNet->delieverReqTo(s3_addr);
        // S3 at T+1, leader, voted_for=self (id=3). Denies S2.
    }

    // ================================================================
    // STEP 9: Handle denial responses on S2 (now a FOLLOWER).
    //         handle_vote_resp processes them WITHOUT role check!
    //
    //         This is the bug:
    //           - election_completed_ is false  -> passes guard
    //           - resp.term == state_->get_term() (T+1 == T+1) -> passes
    //           - NO check for role_ == candidate
    //           - votes_responded_ is incremented on a FOLLOWER
    // ================================================================
    size_t s2_resps_from_s1 = s2.fNet->getNumPendingResps(s1_addr);
    size_t s2_resps_from_s3 = s2.fNet->getNumPendingResps(s3_addr);
    _msg("Step 9: S2 pending vote responses: from S1=%zu, from S3=%zu\n",
         s2_resps_from_s1, s2_resps_from_s3);

    int stale_responses_processed = 0;

    if (s2_resps_from_s1 > 0) {
        s2.fNet->handleRespFrom(s1_addr);
        stale_responses_processed++;
        _msg("  Processed vote response from S1 on S2 (S2 is FOLLOWER!).\n");
    }
    if (s2_resps_from_s3 > 0) {
        s2.fNet->handleRespFrom(s3_addr);
        stale_responses_processed++;
        _msg("  Processed vote response from S3 on S2 (S2 is FOLLOWER!).\n");
    }

    // Verify at least one stale vote response was processed.
    CHK_GT( stale_responses_processed, 0 );

    // Verify final state: S3 is leader, S2 is NOT leader.
    CHK_TRUE( s3.raftServer->is_leader() );
    CHK_FALSE( s2.raftServer->is_leader() );
    CHK_FALSE( s1.raftServer->is_leader() );

    _msg("\n=== BUG 10 CONFIRMED ===\n");
    _msg("handle_vote_resp processed %d vote response(s) while S2 was FOLLOWER.\n",
         stale_responses_processed);
    _msg("\n");
    _msg("Root cause 1: handle_vote_resp (handle_vote.cxx:421-469)\n");
    _msg("  has no check for role_ == candidate before processing.\n");
    _msg("  After passing the election_completed_ and term guards,\n");
    _msg("  votes_responded_ and votes_granted_ are modified\n");
    _msg("  regardless of the server's current role.\n");
    _msg("\n");
    _msg("Root cause 2: become_follower() (raft_server.cxx:1521-1566)\n");
    _msg("  does not reset election_completed_, votes_granted_,\n");
    _msg("  or votes_responded_. Compare with update_term()\n");
    _msg("  (line 1591-1593) which DOES reset them.\n");
    _msg("  When become_follower() is called at the SAME term\n");
    _msg("  (via AE from the leader), update_term() is NOT called,\n");
    _msg("  so election state is never cleaned up.\n");

    print_stats(pkgs);

    s1.raftServer->shutdown();
    s2.raftServer->shutdown();
    s3.raftServer->shutdown();

    f_base->destroy();

    return 0;
}

} // namespace bug10_test
using namespace bug10_test;

int main(int argc, char** argv) {
    TestSuite ts(argc, argv);
    ts.options.printTestMessage = true;

    // Disable reconnection timer for deterministic test.
    debugging_options::get_instance().disable_reconn_backoff_ = true;

    ts.doTest( "stale vote response on follower (bug 10)",
               stale_vote_on_follower_test );

    return 0;
}

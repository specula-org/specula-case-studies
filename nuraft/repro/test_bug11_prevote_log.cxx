/************************************************************************
 * Bug 11 Reproduction Test:
 *   handle_prevote_req() in handle_vote.cxx:471-528 grants pre-votes
 *   based solely on hb_alive_ status, without checking log
 *   up-to-dateness. Per Ongaro Section 9.6, pre-vote should check
 *   "would I vote for this candidate?" which includes log freshness.
 *
 *   The request carries last_log_term and last_log_idx, and the
 *   handler even LOGS them, but never compares them against the
 *   granting node's own log.
 *
 * This test demonstrates that a stale node (old log) can win a
 * pre-vote from a node with a much more up-to-date log, as long as
 * the granting node's hb_alive_ is false.
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

namespace bug11_test {

/**
 * Demonstrates that handle_prevote_req grants pre-votes without
 * checking log freshness.
 *
 * Scenario (3-node cluster: S1=id 1, S2=id 2, S3=id 3):
 *
 *   Setup: S1 is leader. All nodes in sync.
 *
 *   1. Partition S3 (goesOffline).
 *
 *   2. Append 10 entries via S1 -> replicate to S2 only.
 *      Now S1 and S2 have log index ~N+10, S3 stuck at ~N.
 *
 *   3. Bring S3 back online.
 *
 *   4. Partition S1 (goesOffline) so S1 cannot send heartbeats.
 *
 *   5. S2 fires election timer -> its hb_alive_ cleared to false.
 *      Pre-vote fails (S3's hb_alive_ is still true from the setup
 *      phase). Purpose: clear S2's hb_alive_.
 *
 *   6. S3 fires election timer -> request_prevote().
 *      Sends pre-vote request to S2 carrying S3's stale log info.
 *
 *   7. Deliver S3's pre-vote request to S2.
 *      S2's handle_prevote_req checks ONLY hb_alive_ (false) ->
 *      GRANTS pre-vote despite S3's log being stale.
 *
 *   8. ASSERT: S2's response has accepted=true.
 *      This confirms the bug.
 *
 *   Compare with handle_vote_req (line 354-357) which correctly
 *   checks log freshness:
 *     bool log_okay =
 *       req.get_last_log_term() > log_store_->last_entry()->get_term() ||
 *       (req.get_last_log_term() == log_store_->last_entry()->get_term() &&
 *        log_store_->next_slot() - 1 <= req.get_last_log_idx());
 *
 * The test PASSES (returns 0) to confirm the buggy behavior exists.
 */
int prevote_no_log_check_test() {
    reset_log_files();
    ptr<FakeNetworkBase> f_base = cs_new<FakeNetworkBase>();

    std::string s1_addr = "S1";
    std::string s2_addr = "S2";
    std::string s3_addr = "S3";

    RaftPkg s1(f_base, 1, s1_addr);
    RaftPkg s2(f_base, 2, s2_addr);
    RaftPkg s3(f_base, 3, s3_addr);
    std::vector<RaftPkg*> pkgs = {&s1, &s2, &s3};

    raft_params custom_params;
    custom_params.election_timeout_lower_bound_ = 0;
    custom_params.election_timeout_upper_bound_ = 1000;
    custom_params.heart_beat_interval_ = 500;
    custom_params.client_req_timeout_ = 1000000;
    custom_params.reserved_log_items_ = 0;
    custom_params.snapshot_distance_ = 100;
    custom_params.log_sync_stop_gap_ = 1;
    CHK_Z( launch_servers( pkgs, &custom_params ) );
    CHK_Z( make_group( pkgs ) );

    // S1 is the initial leader.
    CHK_TRUE( s1.raftServer->is_leader() );

    // Switch to async mode for append_entries.
    for (auto& entry: pkgs) {
        RaftPkg* pp = entry;
        raft_params param = pp->raftServer->get_current_params();
        param.return_method_ = raft_params::async_handler;
        pp->raftServer->update_params(param);
    }

    // Record the initial log index (includes config changes from make_group).
    uint64_t base_log_idx = s1.raftServer->get_last_log_idx();
    _msg("Initial: S1 is leader, all nodes at log index %lu\n", base_log_idx);

    // ================================================================
    // STEP 1: Partition S3 so it misses future entries.
    // ================================================================
    s3.fNet->goesOffline();
    _msg("Step 1: S3 goes offline.\n");

    // ================================================================
    // STEP 2: Append entries via S1 -> replicate to S2 only.
    // ================================================================
    const size_t NUM_ENTRIES = 10;
    std::list< ptr< cmd_result< ptr<buffer> > > > handlers;
    for (size_t ii = 0; ii < NUM_ENTRIES; ++ii) {
        std::string test_msg = "test" + std::to_string(ii);
        ptr<buffer> msg = buffer::alloc(test_msg.size() + 1);
        msg->put(test_msg);
        ptr< cmd_result< ptr<buffer> > > ret =
            s1.raftServer->append_entries( {msg} );
        CHK_TRUE( ret->get_accepted() );
        handlers.push_back(ret);
    }

    // Replicate to S2 (S3 is offline, requests to it fail).
    // Pre-commit.
    s1.fNet->execReqResp();
    // Commit.
    s1.fNet->execReqResp();
    // Wait for commit.
    CHK_Z( wait_for_sm_exec(pkgs, COMMIT_TIMEOUT_SEC) );

    // One more round to ensure everything is settled.
    s1.fNet->execReqResp();
    s1.fNet->execReqResp();
    CHK_Z( wait_for_sm_exec(pkgs, COMMIT_TIMEOUT_SEC) );

    // Verify S1 and S2 have the new entries, S3 does not.
    uint64_t s1_log_idx = s1.raftServer->get_last_log_idx();
    uint64_t s2_log_idx = s2.raftServer->get_last_log_idx();
    uint64_t s3_log_idx = s3.raftServer->get_last_log_idx();

    _msg("Step 2: After appending %zu entries:\n", NUM_ENTRIES);
    _msg("  S1 log index: %lu\n", s1_log_idx);
    _msg("  S2 log index: %lu\n", s2_log_idx);
    _msg("  S3 log index: %lu (stale)\n", s3_log_idx);

    CHK_GT( s1_log_idx, base_log_idx );
    CHK_GT( s2_log_idx, base_log_idx );
    // S3 should still be at or near the base (it missed the entries).
    CHK_GT( s2_log_idx, s3_log_idx );

    uint64_t s2_last_log_term = s2.raftServer->get_last_log_term();

    // ================================================================
    // STEP 3: Bring S3 back online.
    // ================================================================
    s3.fNet->goesOnline();
    _msg("Step 3: S3 back online (but still has stale log at index %lu).\n",
         s3_log_idx);

    // ================================================================
    // STEP 4: Partition S1 so no more heartbeats are sent.
    // ================================================================
    s1.fNet->goesOffline();
    _msg("Step 4: S1 goes offline (no more heartbeats).\n");

    // ================================================================
    // STEP 5: S2 fires election timer -> hb_alive_ cleared.
    //         Pre-vote will fail because S3 still has hb_alive_=true
    //         (it just came back). But the purpose is to clear S2's
    //         hb_alive_ flag.
    // ================================================================
    s2.dbgLog(" --- S2 election timer (to clear hb_alive_) ---");
    s2.fTimer->invoke( timer_task_type::election_timer );
    // Send pre-vote requests. S1 is offline (fails), S3 has hb_alive_
    // true (denies). Pre-vote fails. But S2's hb_alive_ is now false.
    s2.fNet->execReqResp();
    _msg("Step 5: S2 election timer fired. S2's hb_alive_ is now false.\n");

    // ================================================================
    // STEP 6: S3 fires election timer -> request_prevote().
    //         S3's pre-vote request carries its stale log info.
    // ================================================================
    s3.dbgLog(" --- S3 election timer (pre-vote with stale log) ---");
    s3.fTimer->invoke( timer_task_type::election_timer );
    _msg("Step 6: S3 fires election timer. Pre-vote requests queued.\n");

    // S3's pre-vote request now has:
    //   last_log_idx = s3_log_idx (stale, e.g., ~base_log_idx)
    //   last_log_term = s3's last log term
    // S2's log has:
    //   last_log_idx = s2_log_idx (much higher)
    //   last_log_term = s2_last_log_term

    uint64_t s3_last_log_term_now = s3.raftServer->get_last_log_term();
    uint64_t s3_log_idx_now = s3.raftServer->get_last_log_idx();
    _msg("  S3's pre-vote carries: last_log_idx=%lu, last_log_term=%lu\n",
         s3_log_idx_now, s3_last_log_term_now);
    _msg("  S2 has:                last_log_idx=%lu, last_log_term=%lu\n",
         s2_log_idx, s2_last_log_term);

    // Verify S3's log is indeed stale compared to S2.
    // For a correct implementation, S2 should DENY the pre-vote because
    // S3's log is not at least as up-to-date as S2's.
    bool s3_log_is_stale =
        (s3_last_log_term_now < s2_last_log_term) ||
        (s3_last_log_term_now == s2_last_log_term &&
         s3_log_idx_now < s2_log_idx);
    CHK_TRUE( s3_log_is_stale );
    _msg("  Confirmed: S3's log IS stale relative to S2's.\n");

    // ================================================================
    // STEP 7: Deliver S3's pre-vote request to S2.
    //         S2's handle_prevote_req checks ONLY hb_alive_ (false)
    //         -> grants without checking log freshness.
    // ================================================================
    s3.fNet->delieverReqTo(s2_addr);
    _msg("Step 7: Delivered S3's pre-vote request to S2.\n");

    // ================================================================
    // STEP 8: Handle the response. If S2 accepted the pre-vote,
    //         S3's handle_prevote_resp will increment pre_vote_.dead_.
    //         If enough dead votes, S3 will initiate a real vote,
    //         bumping its term. We check S3's term before/after.
    //
    //         Also handle S3's pre-vote to S1 (offline → fails).
    // ================================================================
    s3.fNet->makeReqFailAll(s1_addr);  // S1 offline

    // S3's pre_vote state: dead_ = 1 (self). If S2 accepts, dead_ → 2.
    // quorum for election = 3/2 = 1, election_quorum_size = 2.
    // If dead_ (2) >= 2 → pre-vote succeeds → initiate_vote() called → term bumps.
    uint64_t s3_term_before = s3.raftServer->get_term();
    _msg("Step 8: S3 term before handling response: %lu\n", s3_term_before);

    // Handle S2's response (the pre-vote reply).
    size_t pending = s3.fNet->getNumPendingResps(s2_addr);
    _msg("  Pending responses from S2: %zu\n", pending);
    CHK_GT( pending, (size_t)0 );
    s3.fNet->handleRespFrom(s2_addr);

    uint64_t s3_term_after = s3.raftServer->get_term();
    _msg("  S3 term after handling response: %lu\n", s3_term_after);

    // THE BUG: S2 accepted S3's pre-vote despite S3 having a stale log.
    // This caused pre_vote_.dead_ >= quorum, triggering initiate_vote(),
    // which incremented S3's term. If pre-vote was denied, term stays same.
    //
    // In handle_prevote_req (handle_vote.cxx:507-509):
    //   if (!hb_alive_ || state_->is_catching_up()) {
    //       resp->accept(log_store_->next_slot());
    //   }
    //
    // There is NO log comparison like handle_vote_req has (line 354-357).
    bool prevote_accepted = (s3_term_after > s3_term_before);
    _msg("  Pre-vote accepted by S2 (inferred from term bump): %s\n",
         prevote_accepted ? "TRUE" : "FALSE");
    CHK_TRUE( prevote_accepted );

    _msg("\n=== BUG 11 CONFIRMED ===\n");
    _msg("handle_prevote_req (handle_vote.cxx:471-528) grants pre-votes\n");
    _msg("based solely on hb_alive_ status, without checking log freshness.\n");
    _msg("\n");
    _msg("S2 granted pre-vote to S3 even though:\n");
    _msg("  S3 last_log_idx = %lu, S2 last_log_idx = %lu\n",
         s3_log_idx_now, s2_log_idx);
    _msg("  S3 last_log_term = %lu, S2 last_log_term = %lu\n",
         s3_last_log_term_now, s2_last_log_term);
    _msg("\n");
    _msg("Per Ongaro Section 9.6, pre-vote should check 'would I vote\n");
    _msg("for this candidate?' which includes log up-to-dateness.\n");
    _msg("The request message carries last_log_term and last_log_idx,\n");
    _msg("and the handler even LOGS them (lines 479-489), but never\n");
    _msg("compares them against the local log.\n");

    print_stats(pkgs);

    s1.raftServer->shutdown();
    s2.raftServer->shutdown();
    s3.raftServer->shutdown();

    f_base->destroy();

    return 0;
}

} // namespace bug11_test
using namespace bug11_test;

int main(int argc, char** argv) {
    TestSuite ts(argc, argv);
    ts.options.printTestMessage = true;

    // Disable reconnection timer for deterministic test.
    debugging_options::get_instance().disable_reconn_backoff_ = true;

    ts.doTest( "prevote grants without log freshness check (bug 11)",
               prevote_no_log_check_test );

    return 0;
}

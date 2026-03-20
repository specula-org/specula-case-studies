/************************************************************************
Bug 13 Reproduction: join_cluster_request unconditionally resets voted_for

In handle_join_cluster_req (handle_join_leave.cxx:270), the code
unconditionally sets voted_for = -1 before setting the term (line 271).
If the join request arrives at the SAME term as the receiver, the term
set on line 271 is a no-op, but the voted_for reset on line 270 erases
the current term's vote. This violates the Raft "vote once per term"
invariant.

Reproduction:
1. Create a single-node cluster S1 (server id=1). S1 becomes leader.
2. Record S1's term T and voted_for (should be 1 = self).
3. Craft a join_cluster_request at term T from a fake server id=2.
4. Deliver the request directly to S1 via process_req.
5. Assert: S1's voted_for is now -1 (was 1 before).
6. Assert: S1's term is unchanged (same term T).
************************************************************************/

#include "debugging_options.hxx"
#include "fake_network.hxx"
#include "raft_package_fake.hxx"

#include "event_awaiter.hxx"
#include "raft_params.hxx"
#include "test_common.h"

#include <cinttypes>
#include <stdio.h>

using namespace nuraft;
using namespace raft_functional_common;

using raft_result = cmd_result< ptr<buffer> >;

namespace bug13_repro {

int join_cluster_resets_voted_for_test() {
    reset_log_files();
    ptr<FakeNetworkBase> f_base = cs_new<FakeNetworkBase>();

    std::string s1_addr = "S1";

    RaftPkg s1(f_base, 1, s1_addr);
    std::vector<RaftPkg*> pkgs = {&s1};

    // ================================================================
    // STEP 1: Launch S1 as a single-node cluster. Fire election timer
    //         so it becomes leader.
    // ================================================================
    CHK_Z( launch_servers(pkgs) );

    // For a single-node cluster, firing the election timer makes S1
    // the leader immediately (wins election with only its own vote).
    CHK_TRUE( s1.raftServer->is_leader() );

    // ================================================================
    // STEP 2: Record S1's term and voted_for.
    // ================================================================
    ulong term_before = s1.raftServer->get_term();

    // Access voted_for through the state manager.
    ptr<srv_state> state_before = s1.getTestMgr()->read_state();
    CHK_NONNULL( state_before.get() );

    int voted_for_before = state_before->get_voted_for();
    ulong term_from_state_before = state_before->get_term();

    _msg("Before join request:\n");
    _msg("  S1 term = %" PRIu64 "\n", term_before);
    _msg("  S1 voted_for = %d (from state_mgr)\n", voted_for_before);
    _msg("  S1 term from state_mgr = %" PRIu64 "\n", term_from_state_before);

    // S1 should have voted for itself (id=1).
    CHK_EQ(1, voted_for_before);
    CHK_EQ(term_before, term_from_state_before);

    // ================================================================
    // STEP 3: Craft a join_cluster_request at the SAME term T from
    //         a fake server id=2.
    //
    //         This simulates what invite_srv_to_join_cluster() sends:
    //         - msg_type::join_cluster_request
    //         - term = sender's term
    //         - src = sender's id (2)
    //         - dst = receiver's id (1)
    //         - log_entries: one entry with a serialized cluster_config
    // ================================================================

    // Create a cluster config that the "sender" (server 2) would have.
    // It just needs to be a valid config. We create one with server 2.
    ptr<srv_config> fake_srv2_config =
        cs_new<srv_config>(2, 1, "S2", "server 2", false, 50);
    ptr<cluster_config> fake_config = cs_new<cluster_config>();
    fake_config->get_servers().push_back(fake_srv2_config);

    ptr<req_msg> join_req = cs_new<req_msg>(
        term_before,                        // same term as S1
        msg_type::join_cluster_request,
        2,                                  // src = server 2
        1,                                  // dst = server 1
        0L,                                 // last_log_term
        0L,                                 // last_log_idx
        0L                                  // commit_idx
    );

    // Attach the cluster config as a log entry (as invite_srv_to_join_cluster does).
    join_req->log_entries().push_back(
        cs_new<log_entry>(
            term_before,
            fake_config->serialize(),
            log_val_type::conf
        )
    );

    // ================================================================
    // STEP 4: Deliver the join_cluster_request to S1.
    //         We use FakeNetwork::gotMsg which calls process_req.
    // ================================================================
    _msg("Sending join_cluster_request to S1 at term %" PRIu64
         " from fake server 2...\n", term_before);

    ptr<resp_msg> resp = s1.fNet->gotMsg(join_req);
    CHK_NONNULL( resp.get() );

    _msg("Response: accepted=%s\n", resp->get_accepted() ? "true" : "false");

    // ================================================================
    // STEP 5: Check S1's state after processing the join request.
    // ================================================================
    ptr<srv_state> state_after = s1.getTestMgr()->read_state();
    CHK_NONNULL( state_after.get() );

    int voted_for_after = state_after->get_voted_for();
    ulong term_after = state_after->get_term();

    _msg("\nAfter join request:\n");
    _msg("  S1 term = %" PRIu64 "\n", term_after);
    _msg("  S1 voted_for = %d (from state_mgr)\n", voted_for_after);

    // ================================================================
    // STEP 6: Assert the bug.
    //
    //   The join request was at the SAME term as S1. Line 271:
    //       state_->set_term(req.get_term())
    //   is effectively a no-op (same term). But line 270:
    //       state_->set_voted_for(-1)
    //   unconditionally clears voted_for.
    //
    //   This violates Raft's "vote once per term" invariant: S1 had
    //   voted for itself at term T, and now voted_for is -1 at the
    //   same term T. A subsequent RequestVote at term T could cause
    //   S1 to vote again, creating a split-brain.
    // ================================================================

    // The term should be unchanged (same term request).
    CHK_EQ(term_before, term_after);

    // BUG: voted_for was reset from 1 to -1 at the same term.
    CHK_EQ(-1, voted_for_after);

    _msg("\n=== BUG 13 CONFIRMED ===\n");
    _msg("handle_join_cluster_req (handle_join_leave.cxx:270) unconditionally\n");
    _msg("sets voted_for = -1 before setting the term (line 271).\n");
    _msg("\n");
    _msg("When the join request arrives at the SAME term:\n");
    _msg("  - Line 270: voted_for reset from %d to -1\n", voted_for_before);
    _msg("  - Line 271: term set from %" PRIu64 " to %" PRIu64 " (no-op)\n",
         term_before, term_after);
    _msg("\n");
    _msg("This erases S1's vote at term %" PRIu64 ", violating the Raft\n",
         term_before);
    _msg("\"vote once per term\" invariant. S1 could now grant a vote to\n");
    _msg("another candidate at the same term, enabling split-brain.\n");

    s1.raftServer->shutdown();
    f_base->destroy();

    return 0;
}

}  // namespace bug13_repro

int main(int argc, char** argv) {
    TestSuite ts(argc, argv);

    ts.options.printTestMessage = true;

    // Disable reconnection timer for deterministic test.
    debugging_options::get_instance().disable_reconn_backoff_ = true;

    ts.doTest( "join_cluster_request resets voted_for at same term (Bug 13)",
               bug13_repro::join_cluster_resets_voted_for_test );

    return 0;
}

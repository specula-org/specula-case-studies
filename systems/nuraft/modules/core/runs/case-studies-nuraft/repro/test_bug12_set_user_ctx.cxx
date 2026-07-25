/************************************************************************
Bug 12 Reproduction: set_user_ctx() has no leadership check

set_user_ctx() in raft_server.cxx:1782-1800 is a public API that creates
a config log entry and appends it to the log without checking if the
server is the leader. A follower calling this function will create a
divergent config log entry in its local log.

Reproduction strategy:
1. Set up a 3-node cluster {S1, S2, S3}. S1 is leader.
2. Commit all pending config entries (heartbeat + execReqResp).
3. Record S2's last log index (should match S1's).
4. Call s2.raftServer->set_user_ctx("follower_ctx") on S2 (a FOLLOWER).
5. Verify S2's last log index increased by 1.
6. Verify S2's new log entry is a config entry (log_val_type::conf).
7. Verify S1's last log index did NOT increase.
8. This shows a follower can create a local divergent config entry.
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

namespace bug12_repro {

int set_user_ctx_no_leadership_check_test() {
    reset_log_files();
    ptr<FakeNetworkBase> f_base = cs_new<FakeNetworkBase>();

    std::string s1_addr = "S1";
    std::string s2_addr = "S2";
    std::string s3_addr = "S3";

    RaftPkg s1(f_base, 1, s1_addr);
    RaftPkg s2(f_base, 2, s2_addr);
    RaftPkg s3(f_base, 3, s3_addr);
    std::vector<RaftPkg*> pkgs = {&s1, &s2, &s3};

    CHK_Z( launch_servers( pkgs ) );
    CHK_Z( make_group( pkgs ) );

    // S1 is the leader.
    CHK_TRUE( s1.raftServer->is_leader() );
    CHK_FALSE( s2.raftServer->is_leader() );

    // Ensure all pending entries are committed by doing extra heartbeats.
    for (int i = 0; i < 3; i++) {
        s1.fTimer->invoke( timer_task_type::heartbeat_timer );
        s1.fNet->execReqResp();
        s1.fNet->execReqResp();
    }
    CHK_Z( wait_for_sm_exec(pkgs, COMMIT_TIMEOUT_SEC) );

    // Record log indices before the bug trigger.
    uint64_t s1_last_idx_before = s1.raftServer->get_last_log_idx();
    uint64_t s2_last_idx_before = s2.raftServer->get_last_log_idx();

    _msg("Before set_user_ctx:\n");
    _msg("  S1 (leader)   last_log_idx = %" PRIu64 "\n", s1_last_idx_before);
    _msg("  S2 (follower) last_log_idx = %" PRIu64 "\n", s2_last_idx_before);

    // Both should be in sync.
    CHK_EQ(s1_last_idx_before, s2_last_idx_before);

    // --- BUG TRIGGER: Call set_user_ctx on a FOLLOWER ---
    _msg("\nCalling set_user_ctx(\"follower_ctx\") on S2 (a FOLLOWER)...\n");
    s2.raftServer->set_user_ctx("follower_ctx");

    // Check S2's log after the call.
    uint64_t s2_last_idx_after = s2.raftServer->get_last_log_idx();
    uint64_t s1_last_idx_after = s1.raftServer->get_last_log_idx();

    _msg("\nAfter set_user_ctx:\n");
    _msg("  S1 (leader)   last_log_idx = %" PRIu64 "\n", s1_last_idx_after);
    _msg("  S2 (follower) last_log_idx = %" PRIu64 "\n", s2_last_idx_after);

    // BUG MANIFESTATION 1: S2's log index increased by 1.
    // A follower should not be able to append entries to its own log.
    CHK_EQ(s2_last_idx_before + 1, s2_last_idx_after);

    // BUG MANIFESTATION 2: The new entry on S2 is a config entry.
    ptr<log_store> s2_log = s2.raftServer->get_log_store();
    ptr<log_entry> new_entry = s2_log->entry_at(s2_last_idx_after);
    CHK_EQ(static_cast<byte>(log_val_type::conf),
            static_cast<byte>(new_entry->get_val_type()));
    _msg("  S2's new log entry at index %" PRIu64 " is a CONFIG entry.\n",
         s2_last_idx_after);

    // BUG MANIFESTATION 3: S1's log did NOT increase -- the entry is
    // purely local to S2, creating log divergence.
    CHK_EQ(s1_last_idx_before, s1_last_idx_after);
    _msg("  S1's log index is unchanged (no replication from follower).\n");

    // Logs have diverged: S2 has one more entry than S1.
    CHK_GT(s2_last_idx_after, s1_last_idx_after);

    _msg("\n=== BUG 12 CONFIRMED ===\n");
    _msg("set_user_ctx() has no leadership check. A follower (S2) was able to\n");
    _msg("append a config log entry to its local log, creating divergence with\n");
    _msg("the leader (S1). S2 now has %" PRIu64 " log entries while S1 has %"
         PRIu64 ".\n", s2_last_idx_after, s1_last_idx_after);

    s1.raftServer->shutdown();
    s2.raftServer->shutdown();
    s3.raftServer->shutdown();

    f_base->destroy();

    return 0;
}

}  // namespace bug12_repro

int main(int argc, char** argv) {
    TestSuite ts(argc, argv);

    ts.options.printTestMessage = true;

    // Disable reconnection timer for deterministic test.
    debugging_options::get_instance().disable_reconn_backoff_ = true;

    ts.doTest( "set_user_ctx no leadership check (Bug 12)",
               bug12_repro::set_user_ctx_no_leadership_check_test );

    return 0;
}

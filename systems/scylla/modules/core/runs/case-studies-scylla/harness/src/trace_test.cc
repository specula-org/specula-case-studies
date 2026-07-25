/*
 * TLA+ Trace Generation Tests for ScyllaDB Raft
 *
 * These tests exercise core Raft protocol paths with tracing enabled,
 * generating NDJSON trace files for TLA+ trace validation.
 *
 * Each test writes to a separate trace file via SCYLLA_TLA_TRACE env var.
 * Build with -DSCYLLA_TLA_TRACE_ENABLED.
 */

#include "raft/raft.hh"

#define BOOST_TEST_MODULE raft_trace
#include "test/raft/helpers.hh"

#ifdef SCYLLA_TLA_TRACE_ENABLED
#include "raft/tla_trace.hh"
#endif

using namespace raft;

namespace {

// Deterministic server IDs for trace validation.
// These produce s1, s2, s3 in the ServerMap (UUID low bits 1, 2, 3).
const server_id S1{utils::UUID(0, 1)};
const server_id S2{utils::UUID(0, 2)};
const server_id S3{utils::UUID(0, 3)};

void init_trace(const char* env_trace_path) {
#ifdef SCYLLA_TLA_TRACE_ENABLED
    if (env_trace_path) {
        setenv("SCYLLA_TLA_TRACE", env_trace_path, 1);
    }
    tla_trace::init();
    // Pre-register servers in deterministic order
    tla_trace::ServerMap::instance().register_server(1);  // s1
    tla_trace::ServerMap::instance().register_server(2);  // s2
    tla_trace::ServerMap::instance().register_server(3);  // s3
#endif
}

void shutdown_trace() {
#ifdef SCYLLA_TLA_TRACE_ENABLED
    tla_trace::shutdown();
#endif
}

// Helper: create a 3-node cluster config
raft::configuration make_config_3() {
    return config_from_ids({S1, S2, S3});
}

// Helper: create an fsm_debug instance
fsm_debug make_follower(server_id sid, raft::configuration cfg,
                         raft::failure_detector& fd) {
    raft::log log{raft::snapshot_descriptor{.config = cfg}};
    return fsm_debug(sid, raft::term_t{}, raft::server_id{}, std::move(log), fd, fsm_cfg);
}

// Helper: run election timeout on a follower until it becomes a candidate
void force_election(raft::fsm& fsm) {
    while (fsm.is_follower()) {
        fsm.tick();
    }
}

} // anonymous namespace

/*
 * Scenario 1: basic_consensus
 *
 * 3-node cluster, leader election, client request, full replication.
 * Exercises: Timeout, HandleRequestVoteRequest, HandleRequestVoteResponse,
 *            BecomeLeader, ClientRequest, AppendEntries,
 *            HandleAppendEntriesRequest, HandleAppendEntriesResponse, MaybeCommit
 */
BOOST_AUTO_TEST_CASE(test_trace_basic_consensus) {
    const char* trace_path = std::getenv("SCYLLA_TRACE_BASIC");
    if (!trace_path) trace_path = "/tmp/scylla_trace_basic.ndjson";
    init_trace(trace_path);

    discrete_failure_detector fd;
    auto cfg = make_config_3();

    auto fsm1 = make_follower(S1, cfg, fd);
    auto fsm2 = make_follower(S2, cfg, fd);
    auto fsm3 = make_follower(S3, cfg, fd);

    // 1. S1 triggers election
    fd.mark_all_dead();
    force_election(fsm1);
    BOOST_CHECK(fsm1.is_candidate());

    // 2. Get vote requests from S1
    auto output1 = fsm1.get_output();
    BOOST_CHECK(output1.term_and_vote);
    auto current_term = output1.term_and_vote->first;

    // 3. Deliver vote requests to S2 and S3
    for (auto& [to, msg] : output1.messages) {
        if (to == S2) {
            std::visit([&](auto&& m) { fsm2.step(S1, std::move(m)); }, std::move(msg));
        } else if (to == S3) {
            std::visit([&](auto&& m) { fsm3.step(S1, std::move(m)); }, std::move(msg));
        }
    }

    // 4. Get vote replies from S2 and S3
    auto output2 = fsm2.get_output();
    for (auto& [to, msg] : output2.messages) {
        if (to == S1) {
            std::visit([&](auto&& m) { fsm1.step(S2, std::move(m)); }, std::move(msg));
        }
    }
    // S1 should now be leader (got vote from S2, quorum = 2 of 3)
    BOOST_CHECK(fsm1.is_leader());

    // 5. Get leader output (dummy entry + AppendEntries)
    output1 = fsm1.get_output();

    // 6. Deliver initial AppendEntries to followers
    for (auto& [to, msg] : output1.messages) {
        if (to == S2) {
            std::visit([&](auto&& m) { fsm2.step(S1, std::move(m)); }, std::move(msg));
        } else if (to == S3) {
            std::visit([&](auto&& m) { fsm3.step(S1, std::move(m)); }, std::move(msg));
        }
    }

    // 7. Get replies from followers
    output2 = fsm2.get_output();
    for (auto& [to, msg] : output2.messages) {
        if (to == S1) {
            std::visit([&](auto&& m) { fsm1.step(S2, std::move(m)); }, std::move(msg));
        }
    }
    auto output3 = fsm3.get_output();
    for (auto& [to, msg] : output3.messages) {
        if (to == S1) {
            std::visit([&](auto&& m) { fsm1.step(S3, std::move(m)); }, std::move(msg));
        }
    }

    // 8. Leader should have committed the dummy entry
    BOOST_CHECK(fsm1.commit_idx() > index_t{0});

    // 9. Add a client request
    fsm1.add_entry(create_command(1));

    // 10. Replicate client request via communicate
    communicate(fsm1, fsm2, fsm3);

    // Verify all servers committed
    BOOST_CHECK(fsm1.commit_idx() >= index_t{2});

    shutdown_trace();
}

/*
 * Scenario 2: leader_change
 *
 * Leader elected, then failure detector marks leader dead, new election.
 * Exercises: Timeout (twice), UpdateTerm, election handoff.
 */
BOOST_AUTO_TEST_CASE(test_trace_leader_change) {
    const char* trace_path = std::getenv("SCYLLA_TRACE_LEADER_CHANGE");
    if (!trace_path) trace_path = "/tmp/scylla_trace_leader_change.ndjson";
    init_trace(trace_path);

    discrete_failure_detector fd;
    auto cfg = make_config_3();

    auto fsm1 = make_follower(S1, cfg, fd);
    auto fsm2 = make_follower(S2, cfg, fd);
    auto fsm3 = make_follower(S3, cfg, fd);

    // 1. Elect S1 as leader
    fd.mark_all_dead();
    force_election(fsm1);
    auto output1 = fsm1.get_output();
    auto term1 = output1.term_and_vote->first;

    // Deliver votes
    for (auto& [to, msg] : output1.messages) {
        if (to == S2) {
            std::visit([&](auto&& m) { fsm2.step(S1, std::move(m)); }, std::move(msg));
        }
    }
    auto out2 = fsm2.get_output();
    for (auto& [to, msg] : out2.messages) {
        if (to == S1) {
            std::visit([&](auto&& m) { fsm1.step(S2, std::move(m)); }, std::move(msg));
        }
    }
    BOOST_CHECK(fsm1.is_leader());

    // 2. Replicate dummy entry
    communicate(fsm1, fsm2, fsm3);

    // 3. Now mark S1 as dead, let S2 timeout and start election
    fd.mark_dead(S1);

    // Advance S2's election timeout
    force_election(fsm2);
    BOOST_CHECK(fsm2.is_candidate());

    // 4. S3 votes for S2
    output1 = fsm2.get_output();
    for (auto& [to, msg] : output1.messages) {
        if (to == S3) {
            std::visit([&](auto&& m) { fsm3.step(S2, std::move(m)); }, std::move(msg));
        }
    }
    auto out3 = fsm3.get_output();
    for (auto& [to, msg] : out3.messages) {
        if (to == S2) {
            std::visit([&](auto&& m) { fsm2.step(S3, std::move(m)); }, std::move(msg));
        }
    }
    BOOST_CHECK(fsm2.is_leader());

    // 5. Replicate under new leader
    fd.mark_alive(S1);
    communicate(fsm1, fsm2, fsm3);

    shutdown_trace();
}

/*
 * Scenario 3: commit_and_replicate
 *
 * Leader appends multiple entries, replicates to followers, exercises
 * the full AppendEntries/Response/MaybeCommit cycle.
 */
BOOST_AUTO_TEST_CASE(test_trace_commit_and_replicate) {
    const char* trace_path = std::getenv("SCYLLA_TRACE_COMMIT");
    if (!trace_path) trace_path = "/tmp/scylla_trace_commit.ndjson";
    init_trace(trace_path);

    discrete_failure_detector fd;
    auto cfg = make_config_3();

    auto fsm1 = make_follower(S1, cfg, fd);
    auto fsm2 = make_follower(S2, cfg, fd);
    auto fsm3 = make_follower(S3, cfg, fd);

    // Elect S1
    fd.mark_all_dead();
    force_election(fsm1);
    auto output1 = fsm1.get_output();
    // Get S2's vote
    for (auto& [to, msg] : output1.messages) {
        if (to == S2) {
            std::visit([&](auto&& m) { fsm2.step(S1, std::move(m)); }, std::move(msg));
        }
    }
    auto out2 = fsm2.get_output();
    for (auto& [to, msg] : out2.messages) {
        if (to == S1) {
            std::visit([&](auto&& m) { fsm1.step(S2, std::move(m)); }, std::move(msg));
        }
    }
    BOOST_CHECK(fsm1.is_leader());

    // Replicate dummy entry
    communicate(fsm1, fsm2, fsm3);

    // Add 3 client entries
    fsm1.add_entry(create_command(100));
    fsm1.add_entry(create_command(200));
    fsm1.add_entry(create_command(300));

    // Full replication
    communicate(fsm1, fsm2, fsm3);

    // Verify commit
    BOOST_CHECK(fsm1.commit_idx() >= index_t{4}); // dummy + 3 entries
    BOOST_CHECK(fsm2.commit_idx() >= index_t{4});

    shutdown_trace();
}

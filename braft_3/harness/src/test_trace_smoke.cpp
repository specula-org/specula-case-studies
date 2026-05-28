// Copyright (c) 2024 Specula Project Authors. All rights reserved.
// Smoke-test scenarios that exercise common braft code paths and generate
// trace events for TLA+ trace validation.

#include <gflags/gflags.h>
#include <gtest/gtest.h>
#include <butil/logging.h>
#include <butil/time.h>
#include <bthread/bthread.h>
#include <bthread/countdown_event.h>
#include "braft/node.h"
#include "braft/storage.h"
#include "../test/util.h"

namespace braft {
DECLARE_bool(raft_enable_leader_lease);
}

// Helper: enable tracing for a test if RAFT_TRACE_FILE is set.
static void enable_tracing_from_env() {
#ifdef BRAFT_ENABLE_TRACE
    const char* tf = getenv("RAFT_TRACE_FILE");
    if (tf && tf[0]) {
        GFLAGS_NS::SetCommandLineOption("raft_trace_file", tf);
        GFLAGS_NS::SetCommandLineOption("raft_trace_enabled", "true");
    }
#endif
}

class TraceSmokeTest : public testing::Test {
protected:
    void SetUp() override {
        ::system("rm -rf data");
        braft::FLAGS_raft_sync = false;
        enable_tracing_from_env();
    }
    void TearDown() override {
        ::system("rm -rf data");
    }
};

// Scenario 1: 3-node cluster, elect a leader, replicate a few entries.
// Exercises: PreVote, HandlePreVote{Request,Response}, BecomeCandidate,
// CompletePersistTerm, HandleRequestVote{Request,Response}, BecomeLeader,
// SendHeartbeat / HandleAppendEntries{Request/Response} (heartbeat),
// SendReplicateEntries / HandleAppendEntries{Request/Response} (replicate),
// HandleReplicateResponse, AdvanceCommitIndex, CheckLeaderLease.
TEST_F(TraceSmokeTest, ElectAndReplicate) {
    std::vector<braft::PeerId> peers;
    for (int i = 0; i < 3; i++) {
        braft::PeerId peer;
        peer.addr.ip = butil::my_ip();
        peer.addr.port = 5306 + i;
        peer.idx = 0;
        peers.push_back(peer);
    }

    Cluster cluster("trace_smoke", peers, 1000);
    for (size_t i = 0; i < peers.size(); i++) {
        ASSERT_EQ(0, cluster.start(peers[i].addr));
    }

    cluster.wait_leader();
    braft::Node* leader = cluster.leader();
    ASSERT_TRUE(leader != NULL);
    LOG(WARNING) << "smoke-test leader: " << leader->node_id();

    // Apply 5 entries.
    bthread::CountdownEvent cond(5);
    for (int i = 0; i < 5; i++) {
        butil::IOBuf data;
        char buf[64];
        snprintf(buf, sizeof(buf), "smoke entry %d", i);
        data.append(buf);
        braft::Task task;
        task.data = &data;
        task.done = NEW_APPLYCLOSURE(&cond, 0);
        leader->apply(task);
    }
    cond.wait();
    cluster.ensure_same();

    // Sleep briefly so the heartbeat timer fires at least once.
    bthread_usleep(200 * 1000);
    cluster.stop_all();
}

// Scenario 2: 3-node cluster with leader lease enabled.
// Exercises CheckLeaderLease branch where the lease is VALID.
TEST_F(TraceSmokeTest, LeaderLeaseValid) {
    braft::FLAGS_raft_enable_leader_lease = true;

    std::vector<braft::PeerId> peers;
    for (int i = 0; i < 3; i++) {
        braft::PeerId peer;
        peer.addr.ip = butil::my_ip();
        peer.addr.port = 5316 + i;
        peer.idx = 0;
        peers.push_back(peer);
    }

    Cluster cluster("trace_lease", peers, 500, 10);
    for (size_t i = 0; i < peers.size(); i++) {
        ASSERT_EQ(0, cluster.start(peers[i].addr));
    }

    cluster.wait_leader();
    braft::Node* leader = cluster.leader();
    ASSERT_TRUE(leader != NULL);

    // Wait for lease to become valid and stepdown timer to fire.
    bthread_usleep(1500 * 1000);

    cluster.stop_all();
    braft::FLAGS_raft_enable_leader_lease = false;
}

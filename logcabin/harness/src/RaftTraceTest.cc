/* TLA+ Trace generation test for LogCabin Raft.
 *
 * Drives 3 RaftConsensus instances through election and log replication,
 * emitting trace events that can be validated against Trace.tla.
 *
 * Compile with -DLOGCABIN_TLA_TRACE and -fno-access-control.
 * Run: ./build/test/test --gtest_filter='RaftTraceTest.*'
 * Trace output: controlled by LOGCABIN_TRACE_FILE env var.
 */

#include <fcntl.h>
#include <gtest/gtest.h>
#include <sys/stat.h>

#include "build/Protocol/Raft.pb.h"
#include "Core/ProtoBuf.h"
#include "Core/StringUtil.h"
#include "Core/Time.h"
#include "Protocol/Common.h"
#include "Server/RaftConsensus.h"
#include "Server/Globals.h"
#include "Storage/MemoryLog.h"

#ifdef LOGCABIN_TLA_TRACE
#include "Server/tla_trace.h"
#endif

namespace LogCabin {
namespace Server {
namespace {

using namespace RaftConsensusInternal; // NOLINT
typedef RaftConsensus::State State;
typedef Storage::Log Log;

// 3-server configuration descriptor
static const char* threeServerConfig =
    "prev_configuration {"
    "    servers { server_id: 1, addresses: '127.0.0.1:5254' }"
    "    servers { server_id: 2, addresses: '127.0.0.1:5255' }"
    "    servers { server_id: 3, addresses: '127.0.0.1:5256' }"
    "}";

static Protocol::Raft::Configuration
desc(const char* description) {
    return Core::ProtoBuf::fromString<Protocol::Raft::Configuration>(
        description);
}

// Helper: drain leader disk queue (sync to disk + advance commit).
// This mirrors leaderDiskThreadMain but runs synchronously.
static void drainDiskQueue(RaftConsensus& consensus) {
    while (consensus.logSyncQueued) {
        std::unique_ptr<Log::Sync> sync = consensus.log->takeSync();
        consensus.logSyncQueued = false;
        sync->wait();
        consensus.configuration->localServer->lastSyncedIndex =
                    sync->lastIndex;
        consensus.advanceCommitIndex();
        consensus.log->syncComplete(std::move(sync));
    }
}

// Helper: get Peer* from a consensus instance.
static Peer* getPeer(RaftConsensus& c, uint64_t serverId) {
    Server* s = c.configuration->knownServers.at(serverId).get();
    return dynamic_cast<Peer*>(s);
}

// Helper: get role string for TLA+ trace from State enum.
static const char* roleStr(State s) {
    switch (s) {
        case State::FOLLOWER:  return "follower";
        case State::CANDIDATE: return "candidate";
        case State::LEADER:    return "leader";
    }
    return "unknown";
}

class RaftTraceTest : public ::testing::Test {
  protected:
    RaftTraceTest()
        : clockMocker()
    {
        startThreads = false;

        for (int i = 0; i < 3; i++) {
            globals[i].config.set("electionTimeoutMilliseconds", 5000);
            globals[i].config.set("heartbeatPeriodMilliseconds", 2500);
            globals[i].config.set("rpcFailureBackoffMilliseconds", 3000);
            globals[i].config.set("use-temporary-storage", "true");

            consensus[i].reset(new RaftConsensus(globals[i]));
            consensus[i]->serverId = static_cast<uint64_t>(i + 1);
            consensus[i]->serverAddresses =
                Core::StringUtil::format("127.0.0.1:%d", 5254 + i);
        }

#ifdef LOGCABIN_TLA_TRACE
        TlaTrace::registerServer(1, "s1");
        TlaTrace::registerServer(2, "s2");
        TlaTrace::registerServer(3, "s3");

        const char* tf = getenv("LOGCABIN_TRACE_FILE");
        if (tf && tf[0]) {
            TlaTrace::init(tf);
        }
#endif
    }

    ~RaftTraceTest() {
#ifdef LOGCABIN_TLA_TRACE
        TlaTrace::close();  // Close BEFORE destroying consensus to avoid spurious events
#endif
        startThreads = true;
        for (int i = 0; i < 3; i++)
            consensus[i].reset();
    }

    // Initialize consensus[i] with a 3-server config entry.
    void initServer(int idx) {
        auto* memLog = new Storage::MemoryLog();
        memLog->metadata.set_current_term(1);
        memLog->metadata.set_voted_for(0);

        Log::Entry cfgEntry;
        cfgEntry.set_term(1);
        cfgEntry.set_type(Protocol::Raft::EntryType::CONFIGURATION);
        *cfgEntry.mutable_configuration() = desc(threeServerConfig);
        cfgEntry.set_cluster_time(0);
        memLog->append({&cfgEntry});

        consensus[idx]->log.reset(memLog);
        consensus[idx]->init();
    }

    // Emit a trace event from test code, capturing real state from consensus.
    // Used for events embedded in RPC methods that can't fire without
    // actual network calls.
    void emitFromTest(RaftConsensus& c, const char* event) {
#ifdef LOGCABIN_TLA_TRACE
        if (!TlaTrace::isEnabled()) return;
        TlaTrace::Event(event, c.serverId)
            .state(c.currentTerm, roleStr(c.state), c.commitIndex,
                   c.log->getLastLogIndex(), c.getLastLogTerm())
            .emit();
#else
        (void)c; (void)event;
#endif
    }

    void emitFromTestWithField(RaftConsensus& c, const char* event,
                               const char* key, const std::string& val) {
#ifdef LOGCABIN_TLA_TRACE
        if (!TlaTrace::isEnabled()) return;
        TlaTrace::Event(event, c.serverId)
            .state(c.currentTerm, roleStr(c.state), c.commitIndex,
                   c.log->getLastLogIndex(), c.getLastLogTerm())
            .field(key, val)
            .emit();
#else
        (void)c; (void)event; (void)key; (void)val;
#endif
    }

    void emitFromTestMsg(RaftConsensus& c, const char* event,
                         uint64_t fromId, bool flagVal,
                         const char* flagKey) {
#ifdef LOGCABIN_TLA_TRACE
        if (!TlaTrace::isEnabled()) return;
        TlaTrace::Event(event, c.serverId)
            .state(c.currentTerm, roleStr(c.state), c.commitIndex,
                   c.log->getLastLogIndex(), c.getLastLogTerm())
            .field("from", TlaTrace::nid(fromId))
            .field(flagKey, flagVal)
            .emit();
#else
        (void)c; (void)event; (void)fromId; (void)flagVal; (void)flagKey;
#endif
    }

    void emitFromTestAEResp(RaftConsensus& c, uint64_t fromId,
                            bool success, uint64_t matchIdx) {
#ifdef LOGCABIN_TLA_TRACE
        if (!TlaTrace::isEnabled()) return;
        TlaTrace::Event("HandleAppendEntriesResponse", c.serverId)
            .state(c.currentTerm, roleStr(c.state), c.commitIndex,
                   c.log->getLastLogIndex(), c.getLastLogTerm())
            .field("from", TlaTrace::nid(fromId))
            .field("success", success)
            .field("matchIndex", matchIdx)
            .emit();
#else
        (void)c; (void)fromId; (void)success; (void)matchIdx;
#endif
    }

    void emitAppendEntriesSend(RaftConsensus& c, uint64_t toId,
                               uint64_t prevLogIndex, uint64_t numEntries) {
#ifdef LOGCABIN_TLA_TRACE
        if (!TlaTrace::isEnabled()) return;
        TlaTrace::Event("AppendEntries", c.serverId)
            .state(c.currentTerm, roleStr(c.state), c.commitIndex,
                   c.log->getLastLogIndex(), c.getLastLogTerm())
            .field("from", TlaTrace::nid(c.serverId))
            .field("to", TlaTrace::nid(toId))
            .field("prevLogIndex", prevLogIndex)
            .field("numEntries", numEntries)
            .emit();
#else
        (void)c; (void)toId; (void)prevLogIndex; (void)numEntries;
#endif
    }

    Globals globals[3];
    Clock::Mocker clockMocker;
    std::unique_ptr<RaftConsensus> consensus[3];
};


/**
 * Scenario: basic_consensus
 *
 * 3 servers. s1 wins election, becomes leader, replicates NOOP to s2+s3,
 * advances commitIndex.
 *
 * Trace events produced:
 *   Timeout(s1), HandleRequestVote(s2), HandleRequestVote(s3),
 *   HandleRequestVoteResponse(s1 from s2), HandleRequestVoteResponse(s1 from s3),
 *   BecomeLeader(s1), LeaderDiskSync(s1),
 *   AppendEntries(s1→s2), HandleAppendEntries(s2),
 *   AppendEntries(s1→s3), HandleAppendEntries(s3),
 *   HandleAppendEntriesResponse(s1 from s2),
 *   HandleAppendEntriesResponse(s1 from s3),
 *   AdvanceCommitIndex(s1)
 */
TEST_F(RaftTraceTest, basic_consensus) {
    // ---- Init all 3 servers ----
    for (int i = 0; i < 3; i++)
        initServer(i);

    RaftConsensus& s1 = *consensus[0];
    RaftConsensus& s2 = *consensus[1];
    RaftConsensus& s3 = *consensus[2];

    // Verify initial state
    ASSERT_EQ(State::FOLLOWER, s1.state);
    ASSERT_EQ(1U, s1.currentTerm);
    ASSERT_EQ(1U, s1.log->getLastLogIndex());

    // ========================================
    // Step 1: s1 starts election → Timeout(s1)
    // ========================================
    s1.startNewElection();
    ASSERT_EQ(State::CANDIDATE, s1.state);
    ASSERT_EQ(2U, s1.currentTerm);
    ASSERT_EQ(1U, s1.votedFor); // voted for self

    // ========================================
    // Step 2: s2 handles RequestVote → HandleRequestVote(s2)
    // ========================================
    {
        Protocol::Raft::RequestVote::Request req;
        req.set_server_id(1);
        req.set_term(2);
        req.set_last_log_term(1);
        req.set_last_log_index(1);

        Protocol::Raft::RequestVote::Response resp;
        s2.handleRequestVote(req, resp);
        EXPECT_TRUE(resp.granted());
        EXPECT_EQ(2U, resp.term());
        EXPECT_EQ(2U, s2.currentTerm);
        EXPECT_EQ(1U, s2.votedFor); // voted for s1
    }

    // ========================================
    // Step 3: s3 handles RequestVote → HandleRequestVote(s3)
    // ========================================
    {
        Protocol::Raft::RequestVote::Request req;
        req.set_server_id(1);
        req.set_term(2);
        req.set_last_log_term(1);
        req.set_last_log_index(1);

        Protocol::Raft::RequestVote::Response resp;
        s3.handleRequestVote(req, resp);
        EXPECT_TRUE(resp.granted());
        EXPECT_EQ(2U, resp.term());
    }

    // ========================================
    // Steps 4-5: Simulate vote response processing on s1
    //   → HandleRequestVoteResponse(s1) x2
    // ========================================
    {
        Peer* p2 = getPeer(s1, 2);
        p2->haveVote_ = true;
        p2->requestVoteDone = true;
        p2->lastAckEpoch = s1.currentEpoch;
        s1.stateChanged.notify_all();
        // Emit HandleRequestVoteResponse for s2's vote
        emitFromTestMsg(s1, "HandleRequestVoteResponse",
                        2, true, "granted");
    }
    {
        Peer* p3 = getPeer(s1, 3);
        p3->haveVote_ = true;
        p3->requestVoteDone = true;
        p3->lastAckEpoch = s1.currentEpoch;
        s1.stateChanged.notify_all();
        // Emit HandleRequestVoteResponse for s3's vote
        emitFromTestMsg(s1, "HandleRequestVoteResponse",
                        3, true, "granted");
    }

    // ========================================
    // Step 6: s1 becomes leader → BecomeLeader(s1)
    // ========================================
    ASSERT_TRUE(s1.configuration->quorumAll(&Server::haveVote));
    s1.becomeLeader();
    ASSERT_EQ(State::LEADER, s1.state);
    ASSERT_EQ(2U, s1.log->getLastLogIndex()); // config + NOOP

    // ========================================
    // Step 7: Drain disk queue → LeaderDiskSync(s1)
    //         (emitted via instrumented advanceCommitIndex path;
    //          we emit LeaderDiskSync manually since drainDiskQueue
    //          doesn't go through leaderDiskThreadMain)
    // ========================================
    {
        // Emit LeaderDiskSync before draining
        emitFromTest(s1, "LeaderDiskSync");
    }
    drainDiskQueue(s1);
    // After drain: lastSyncedIndex = 2, commitIndex still 0
    // (peers haven't replicated yet)
    ASSERT_EQ(0U, s1.commitIndex);

    // ========================================
    // Steps 8-9: Build AppendEntries for s2 and call handler
    //   → AppendEntries(s1→s2), HandleAppendEntries(s2)
    // ========================================
    {
        // s1's perspective: nextIndex[2] should be lastLogIndex+1 = 3
        // after becomeLeader. But we want to send the NOOP.
        // prevLogIndex = 1, entries = [NOOP(term=2)]
        uint64_t prevLogIndex = 1;
        uint64_t prevLogTerm = s1.log->getEntry(prevLogIndex).term();
        uint64_t numEntries = s1.log->getLastLogIndex() - prevLogIndex;

        emitAppendEntriesSend(s1, 2, prevLogIndex, numEntries);

        Protocol::Raft::AppendEntries::Request req;
        req.set_server_id(1);
        req.set_term(2);
        req.set_prev_log_index(prevLogIndex);
        req.set_prev_log_term(prevLogTerm);
        req.set_commit_index(std::min(s1.commitIndex,
                                       prevLogIndex + numEntries));

        // Pack entries
        for (uint64_t idx = prevLogIndex + 1;
             idx <= s1.log->getLastLogIndex(); idx++) {
            const Log::Entry& e = s1.log->getEntry(idx);
            *req.add_entries() = e;
        }

        Protocol::Raft::AppendEntries::Response resp;
        s2.handleAppendEntries(req, resp);
        EXPECT_TRUE(resp.success());
        EXPECT_EQ(2U, s2.log->getLastLogIndex());
    }

    // ========================================
    // Steps 10-11: Same for s3
    //   → AppendEntries(s1→s3), HandleAppendEntries(s3)
    // ========================================
    {
        uint64_t prevLogIndex = 1;
        uint64_t prevLogTerm = s1.log->getEntry(prevLogIndex).term();
        uint64_t numEntries = s1.log->getLastLogIndex() - prevLogIndex;

        emitAppendEntriesSend(s1, 3, prevLogIndex, numEntries);

        Protocol::Raft::AppendEntries::Request req;
        req.set_server_id(1);
        req.set_term(2);
        req.set_prev_log_index(prevLogIndex);
        req.set_prev_log_term(prevLogTerm);
        req.set_commit_index(std::min(s1.commitIndex,
                                       prevLogIndex + numEntries));

        for (uint64_t idx = prevLogIndex + 1;
             idx <= s1.log->getLastLogIndex(); idx++) {
            const Log::Entry& e = s1.log->getEntry(idx);
            *req.add_entries() = e;
        }

        Protocol::Raft::AppendEntries::Response resp;
        s3.handleAppendEntries(req, resp);
        EXPECT_TRUE(resp.success());
        EXPECT_EQ(2U, s3.log->getLastLogIndex());
    }

    // ========================================
    // Step 12: Simulate AppendEntries response processing on s1
    //   → HandleAppendEntriesResponse(s1) x2
    // ========================================
    {
        Peer* p2 = getPeer(s1, 2);
        p2->matchIndex = 2;
        p2->nextIndex = 3;
        p2->lastAckEpoch = s1.currentEpoch;
        emitFromTestAEResp(s1, 2, true, 2);
    }
    {
        Peer* p3 = getPeer(s1, 3);
        p3->matchIndex = 2;
        p3->nextIndex = 3;
        p3->lastAckEpoch = s1.currentEpoch;
        emitFromTestAEResp(s1, 3, true, 2);
    }

    // ========================================
    // Step 13: Advance commit index → AdvanceCommitIndex(s1)
    // ========================================
    s1.advanceCommitIndex();
    ASSERT_EQ(2U, s1.commitIndex);

    // ---- Verify final state ----
    EXPECT_EQ(State::LEADER, s1.state);
    EXPECT_EQ(2U, s1.currentTerm);
    EXPECT_EQ(2U, s1.commitIndex);
    EXPECT_EQ(2U, s1.log->getLastLogIndex());
}


/**
 * Scenario: leader_stepdown
 *
 * s1 is leader (from basic_consensus setup), receives an AppendEntries
 * request with a higher term and steps down. Tests the Timeout →
 * BecomeLeader → HandleAppendEntries (as leader) step-down path.
 */
TEST_F(RaftTraceTest, leader_stepdown) {
    // ---- Init and fast-forward s1 to leader ----
    for (int i = 0; i < 3; i++)
        initServer(i);

    RaftConsensus& s1 = *consensus[0];
    RaftConsensus& s2 = *consensus[1];

    // s1: become leader in term 2 (abbreviated, no events for vote responses)
    s1.startNewElection();  // Timeout, term=2
    getPeer(s1, 2)->haveVote_ = true;
    getPeer(s1, 2)->requestVoteDone = true;
    getPeer(s1, 3)->haveVote_ = true;
    getPeer(s1, 3)->requestVoteDone = true;
    s1.becomeLeader();  // BecomeLeader, term=2
    drainDiskQueue(s1);
    ASSERT_EQ(State::LEADER, s1.state);

    // ---- s2 starts election in term 2 ----
    s2.startNewElection();  // Timeout, s2, term=2
    ASSERT_EQ(2U, s2.currentTerm);

    // ---- s1 receives AppendEntries from a "new leader" in term 4 ----
    // This forces s1 to step down.
    {
        Protocol::Raft::AppendEntries::Request req;
        req.set_server_id(2);
        req.set_term(4);
        req.set_prev_log_index(0);
        req.set_prev_log_term(0);
        req.set_commit_index(0);

        Protocol::Raft::AppendEntries::Response resp;
        s1.handleAppendEntries(req, resp);
        // s1 should step down to follower in term 4
        EXPECT_EQ(State::FOLLOWER, s1.state);
        EXPECT_EQ(4U, s1.currentTerm);
    }
}

} // anonymous namespace
} // namespace Server
} // namespace LogCabin

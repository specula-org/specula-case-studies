/* Copyright (c) 2024 — TLA+ trace test scenarios for nebula raft.
 *
 * Each test writes a separate NDJSON trace file under traces/.
 * Tests reuse the existing RaftexTestBase infrastructure.
 */

#include <folly/String.h>
#include <gtest/gtest.h>

#include "common/base/Base.h"
#include "common/fs/FileUtils.h"
#include "common/fs/TempDir.h"
#include "common/network/NetworkUtils.h"
#include "common/thread/GenericThreadPool.h"
#include "kvstore/raftex/RaftexService.h"
#include "kvstore/raftex/test/RaftexTestBase.h"
#include "kvstore/raftex/test/TestShard.h"

#ifdef NEBULA_ENABLE_TRACE
#include "kvstore/raftex/trace_logger.h"
#endif

DECLARE_bool(nebula_trace_enabled);
DECLARE_string(nebula_trace_file);
DECLARE_uint32(raft_heartbeat_interval_secs);

namespace nebula {
namespace raftex {

// ---------------------------------------------------------------------------
// Scenario 1: basic_consensus
//   3-node cluster, elect leader, append 5 logs, verify consensus.
//   Exercises: Timeout, SendPreVote, SendRequestVote, HandlePreVoteRequest,
//   HandleRequestVoteRequest, HandlePreVoteResponse, HandleRequestVoteResponse,
//   BecomeLeader, ClientRequest, AppendEntries, HandleAppendEntriesRequest,
//   HandleAppendEntriesResponse, SendHeartbeat, HandleHeartbeatRequest,
//   HandleHeartbeatResponse.
// ---------------------------------------------------------------------------
TEST(TraceTest, BasicConsensus) {
  LOG(INFO) << "=====> Start BasicConsensus trace test";

  FLAGS_raft_heartbeat_interval_secs = 1;

#ifdef NEBULA_ENABLE_TRACE
  // Trace file path set via --nebula_trace_file command line flag
  FLAGS_nebula_trace_enabled = true;
  trace::TraceWriter::instance().close();  // Close any previous trace file
#endif

  fs::TempDir walRoot("/tmp/trace_basic_consensus.XXXXXX");
  std::shared_ptr<thread::GenericThreadPool> workers;
  std::vector<std::string> wals;
  std::vector<HostAddr> allHosts;
  std::vector<std::shared_ptr<RaftexService>> services;
  std::vector<std::shared_ptr<test::TestShard>> copies;
  std::shared_ptr<test::TestShard> leader;

  setupRaft(3, walRoot, workers, wals, allHosts, services, copies, leader);
  checkLeadership(copies, leader);

  // Append 5 logs
  std::vector<std::string> msgs;
  appendLogs(0, 4, leader, msgs, true /* waitLastLog */);

  // Wait for replication to complete
  sleep(FLAGS_raft_heartbeat_interval_secs + 1);

  // Verify all copies have the same logs
  ASSERT_TRUE(checkConsensus(copies, 0, 4, msgs));

  finishRaft(services, copies, workers, leader);

#ifdef NEBULA_ENABLE_TRACE
  trace::TraceWriter::instance().close();
#endif

  LOG(INFO) << "<===== Done BasicConsensus trace test";
}

// ---------------------------------------------------------------------------
// Scenario 2: leader_crash_reelection
//   3-node cluster, elect leader, append logs, crash leader, re-elect,
//   append more logs.
//   Exercises: Crash, Restart (via reboot), all election actions again.
// ---------------------------------------------------------------------------
TEST(TraceTest, LeaderCrashReelection) {
  LOG(INFO) << "=====> Start LeaderCrashReelection trace test";

  FLAGS_raft_heartbeat_interval_secs = 1;

#ifdef NEBULA_ENABLE_TRACE
  FLAGS_nebula_trace_enabled = true;
  trace::TraceWriter::instance().close();
#endif

  fs::TempDir walRoot("/tmp/trace_leader_crash.XXXXXX");
  std::shared_ptr<thread::GenericThreadPool> workers;
  std::vector<std::string> wals;
  std::vector<HostAddr> allHosts;
  std::vector<std::shared_ptr<RaftexService>> services;
  std::vector<std::shared_ptr<test::TestShard>> copies;
  std::shared_ptr<test::TestShard> leader;

  setupRaft(3, walRoot, workers, wals, allHosts, services, copies, leader);
  checkLeadership(copies, leader);

  // Append 3 logs
  std::vector<std::string> msgs;
  appendLogs(0, 2, leader, msgs, true /* waitLastLog */);
  sleep(FLAGS_raft_heartbeat_interval_secs + 1);

  // Crash the leader
  size_t leaderIdx = leader->index();
  LOG(INFO) << "=====> Killing leader at index " << leaderIdx;

#ifdef NEBULA_ENABLE_TRACE
  // Emit a Crash event before stopping
  if (trace::traceIsEnabled()) {
    auto addr = copies[leaderIdx]->address();
    std::string hostPort = addr.host + ":" + std::to_string(addr.port);
    std::string nid = trace::TraceServerMap::instance().lookup(hostPort);
    trace::TraceEvent("Crash").node(nid).emit();
  }
#endif

  killOneCopy(services, copies, leader, leaderIdx);

  // Wait for re-election
  sleep(FLAGS_raft_heartbeat_interval_secs * 3);

  // Reboot the crashed copy
  LOG(INFO) << "=====> Rebooting copy at index " << leaderIdx;
  rebootOneCopy(services, copies, allHosts, leaderIdx);

  // Wait for leader
  waitUntilLeaderElected(copies, leader);
  checkLeadership(copies, leader);

  // Append more logs
  appendLogs(3, 5, leader, msgs, true /* waitLastLog */);
  sleep(FLAGS_raft_heartbeat_interval_secs + 1);

  finishRaft(services, copies, workers, leader);

#ifdef NEBULA_ENABLE_TRACE
  trace::TraceWriter::instance().close();
#endif

  LOG(INFO) << "<===== Done LeaderCrashReelection trace test";
}

// ---------------------------------------------------------------------------
// Scenario 3: log_replication
//   3-node cluster, append 20 logs in rapid succession.
//   Exercises log replication pipeline more heavily.
// ---------------------------------------------------------------------------
TEST(TraceTest, LogReplication) {
  LOG(INFO) << "=====> Start LogReplication trace test";

  FLAGS_raft_heartbeat_interval_secs = 1;

#ifdef NEBULA_ENABLE_TRACE
  FLAGS_nebula_trace_enabled = true;
  trace::TraceWriter::instance().close();
#endif

  fs::TempDir walRoot("/tmp/trace_log_replication.XXXXXX");
  std::shared_ptr<thread::GenericThreadPool> workers;
  std::vector<std::string> wals;
  std::vector<HostAddr> allHosts;
  std::vector<std::shared_ptr<RaftexService>> services;
  std::vector<std::shared_ptr<test::TestShard>> copies;
  std::shared_ptr<test::TestShard> leader;

  setupRaft(3, walRoot, workers, wals, allHosts, services, copies, leader);
  checkLeadership(copies, leader);

  // Append 20 logs
  std::vector<std::string> msgs;
  appendLogs(0, 19, leader, msgs, true /* waitLastLog */);

  // Wait for replication
  sleep(FLAGS_raft_heartbeat_interval_secs * 2);

  ASSERT_TRUE(checkConsensus(copies, 0, 19, msgs));

  finishRaft(services, copies, workers, leader);

#ifdef NEBULA_ENABLE_TRACE
  trace::TraceWriter::instance().close();
#endif

  LOG(INFO) << "<===== Done LogReplication trace test";
}

}  // namespace raftex
}  // namespace nebula

int main(int argc, char** argv) {
  testing::InitGoogleTest(&argc, argv);
  folly::init(&argc, &argv, true);
  google::SetStderrLogging(google::INFO);

  return RUN_ALL_TESTS();
}

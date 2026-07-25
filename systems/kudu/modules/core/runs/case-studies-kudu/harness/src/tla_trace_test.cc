// Licensed under the Apache License, Version 2.0.
// TLA+ trace test scenarios for Kudu Raft consensus.
// Exercises leader election + log replication to produce NDJSON traces.

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <memory>
#include <optional>
#include <ostream>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <gflags/gflags_declare.h>
#include <glog/logging.h>
#include <gtest/gtest.h>

#include "kudu/clock/logical_clock.h"
#include "kudu/common/common.pb.h"
#include "kudu/common/schema.h"
#include "kudu/common/timestamp.h"
#include "kudu/common/wire_protocol-test-util.h"
#include "kudu/common/wire_protocol.pb.h"
#include "kudu/consensus/consensus-test-util.h"
#include "kudu/consensus/consensus.pb.h"
#include "kudu/consensus/consensus_meta.h"
#include "kudu/consensus/consensus_meta_manager.h"
#include "kudu/consensus/consensus_peers.h"
#include "kudu/consensus/consensus_queue.h"
#include "kudu/consensus/log.h"
#include "kudu/consensus/log.pb.h"
#include "kudu/consensus/log_index.h"
#include "kudu/consensus/log_reader.h"
#include "kudu/consensus/log_util.h"
#include "kudu/consensus/metadata.pb.h"
#include "kudu/consensus/opid.pb.h"
#include "kudu/consensus/opid_util.h"
#include "kudu/consensus/quorum_util.h"
#include "kudu/consensus/raft_consensus.h"
#include "kudu/consensus/time_manager.h"
#include "kudu/consensus/tla_trace.h"
#include "kudu/fs/fs_manager.h"
#include "kudu/gutil/casts.h"
#include "kudu/gutil/map-util.h"
#include "kudu/gutil/ref_counted.h"
#include "kudu/gutil/strings/strcat.h"
#include "kudu/gutil/strings/substitute.h"
#include "kudu/tablet/metadata.pb.h"
#include "kudu/util/async_util.h"
#include "kudu/util/mem_tracker.h"
#include "kudu/util/metrics.h"
#include "kudu/util/monotime.h"
#include "kudu/util/pb_util.h"
#include "kudu/util/status.h"
#include "kudu/util/status_callback.h"
#include "kudu/util/test_macros.h"
#include "kudu/util/test_util.h"
#include "kudu/util/threadpool.h"

DECLARE_int32(raft_heartbeat_interval_ms);
DECLARE_bool(enable_leader_failure_detection);

METRIC_DECLARE_entity(tablet);

using kudu::log::Log;
using kudu::log::LogEntryPB;
using kudu::log::LogOptions;
using kudu::log::LogReader;
using kudu::pb_util::SecureShortDebugString;
using std::nullopt;
using std::optional;
using std::shared_ptr;
using std::string;
using std::unique_ptr;
using std::vector;
using strings::Substitute;

namespace kudu {
namespace consensus {

static const char* kTestTablet = "TlaTraceTestTablet";

static void DoNothing(const string& s) {
}

// Test fixture that sets up a 3-node Raft cluster for trace generation.
class TlaTraceTest : public KuduTest {
 public:
  TlaTraceTest()
      : clock_(Timestamp(1)),
        metric_entity_(METRIC_ENTITY_tablet.Instantiate(&metric_registry_, "tla-trace-test")),
        schema_(GetSimpleTestSchema()) {
    options_.tablet_id = kTestTablet;
    // Disable failure detection — we trigger elections explicitly.
    FLAGS_enable_leader_failure_detection = false;
    // Fast heartbeats for quick replication.
    FLAGS_raft_heartbeat_interval_ms = 50;
    CHECK_OK(ThreadPoolBuilder("raft").Build(&raft_pool_));
  }

  void SetUp() override {
    KuduTest::SetUp();
    // Initialize TLA+ tracing from environment variable.
    const char* trace_file = getenv("KUDU_TRACE_FILE");
    if (trace_file && trace_file[0]) {
      LOG(INFO) << "TLA+ trace file: " << trace_file;
    }
  }

  // Build filesystem managers and WALs for num peers.
  Status BuildFsManagersAndLogs(int num) {
    for (int i = 0; i < num; i++) {
      shared_ptr<MemTracker> parent_mem_tracker =
          MemTracker::CreateTracker(-1, Substitute("peer-$0", i));
      parent_mem_trackers_.push_back(parent_mem_tracker);
      string test_path = GetTestPath(Substitute("peer-$0-root", i));
      FsManagerOpts opts;
      opts.parent_mem_tracker = parent_mem_tracker;
      opts.wal_root = test_path;
      opts.data_roots = { test_path };
      unique_ptr<FsManager> fs_manager(new FsManager(env_, opts));
      string tenant_name, tenant_id, encryption_key, encryption_key_iv, encryption_key_version;
      GetEncryptionKey(&tenant_name, &tenant_id, &encryption_key,
                       &encryption_key_iv, &encryption_key_version);
      if (tenant_name.empty() && encryption_key.empty()) {
        RETURN_NOT_OK(fs_manager->CreateInitialFileSystemLayout());
      } else if (tenant_name.empty()) {
        RETURN_NOT_OK(fs_manager->CreateInitialFileSystemLayout(nullopt, nullopt, nullopt,
                        encryption_key, encryption_key_iv, encryption_key_version));
      } else {
        RETURN_NOT_OK(fs_manager->CreateInitialFileSystemLayout(nullopt, tenant_name, tenant_id,
                        encryption_key, encryption_key_iv, encryption_key_version));
      }
      RETURN_NOT_OK(fs_manager->Open());

      scoped_refptr<Log> log;
      RETURN_NOT_OK(Log::Open(LogOptions(), fs_manager.get(), nullptr,
                              kTestTablet, schema_, 0, nullptr, &log));
      logs_.emplace_back(std::move(log));
      fs_managers_.push_back(std::move(fs_manager));
    }
    return Status::OK();
  }

  RaftConfigPB BuildRaftConfigPB(int num) {
    RaftConfigPB raft_config;
    for (int i = 0; i < num; i++) {
      RaftPeerPB* peer_pb = raft_config.add_peers();
      peer_pb->set_member_type(RaftPeerPB::VOTER);
      peer_pb->set_permanent_uuid(fs_managers_[i]->uuid());
      HostPortPB* hp = peer_pb->mutable_last_known_addr();
      hp->set_host(Substitute("peer-$0.fake-domain", i));
      hp->set_port(0);
    }
    return raft_config;
  }

  Status BuildPeers() {
    CHECK_EQ(config_.peers_size(), fs_managers_.size());
    for (int i = 0; i < config_.peers_size(); i++) {
      FsManager* fs = fs_managers_[i].get();
      scoped_refptr<ConsensusMetadataManager> cmeta_manager(
          new ConsensusMetadataManager(fs));
      RETURN_NOT_OK(cmeta_manager->Create(kTestTablet, config_, kMinimumTerm));

      RaftPeerPB* local_peer_pb;
      RETURN_NOT_OK(GetRaftConfigMember(&config_, fs->uuid(), &local_peer_pb));

      shared_ptr<RaftConsensus> peer;
      ServerContext ctx({ nullptr, nullptr, raft_pool_.get() });
      RETURN_NOT_OK(RaftConsensus::Create(options_, config_.peers(i),
                                          std::move(cmeta_manager), std::move(ctx), &peer));
      peers_->AddPeer(config_.peers(i).permanent_uuid(), peer);
    }
    return Status::OK();
  }

  Status StartPeers() {
    ConsensusBootstrapInfo boot_info;
    for (int i = 0; i < config_.peers_size(); i++) {
      shared_ptr<RaftConsensus> peer;
      RETURN_NOT_OK(peers_->GetPeerByIdx(i, &peer));

      unique_ptr<PeerProxyFactory> proxy_factory(new LocalTestPeerProxyFactory(peers_.get()));
      unique_ptr<TimeManager> time_manager(new TimeManager(&clock_, Timestamp::kMin));
      unique_ptr<TestOpFactory> op_factory(new TestOpFactory(logs_[i].get()));
      op_factory->SetConsensus(peer.get());
      op_factories_.emplace_back(std::move(op_factory));

      RETURN_NOT_OK(peer->Start(boot_info, std::move(proxy_factory), logs_[i], nullptr,
                                std::move(time_manager), op_factories_.back().get(),
                                metric_entity_, &DoNothing));
    }
    return Status::OK();
  }

  Status BuildAndStartCluster(int num) {
    RETURN_NOT_OK(BuildFsManagersAndLogs(num));
    config_ = BuildRaftConfigPB(num);
    config_.set_opid_index(kInvalidOpIdIndex);
    peers_.reset(new TestPeerMapManager(config_));
    RETURN_NOT_OK(BuildPeers());

    // Initialize TLA+ trace server mapping.
    if (tla_trace::IsEnabled()) {
      vector<string> all_uuids;
      for (int i = 0; i < num; i++) {
        all_uuids.push_back(fs_managers_[i]->uuid());
      }
      tla_trace::Init(all_uuids[0], all_uuids);
    }

    RETURN_NOT_OK(StartPeers());
    return Status::OK();
  }

  Status AppendDummyMessage(int peer_idx, scoped_refptr<ConsensusRound>* round) {
    unique_ptr<ReplicateMsg> msg(new ReplicateMsg());
    msg->set_op_type(NO_OP);
    msg->mutable_noop_request();
    msg->set_timestamp(clock_.Now().ToUint64());

    shared_ptr<RaftConsensus> peer;
    CHECK_OK(peers_->GetPeerByIdx(peer_idx, &peer));

    unique_ptr<Synchronizer> sync(new Synchronizer());
    *round = peer->NewRound(std::move(msg), sync->AsStatusCallback());
    EmplaceOrDie(&syncs_, round->get(), std::move(sync));
    RETURN_NOT_OK_PREPEND(peer->Replicate(round->get()),
                          Substitute("Unable to replicate to peer $0", peer_idx));
    return Status::OK();
  }

  Status WaitForReplicate(ConsensusRound* round) {
    return FindOrDie(syncs_, round)->Wait();
  }

  void WaitForCommitIfNotAlreadyPresent(int64_t to_wait_for, int peer_idx) {
    MonoDelta timeout(MonoDelta::FromSeconds(10));
    MonoTime start(MonoTime::Now());
    shared_ptr<RaftConsensus> peer;
    CHECK_OK(peers_->GetPeerByIdx(peer_idx, &peer));
    while (true) {
      optional<OpId> committed = peer->GetLastOpId(COMMITTED_OPID);
      if (committed && committed->index() >= to_wait_for) return;
      if (MonoTime::Now() > start + timeout) {
        FAIL() << "Timed out waiting for commit of index " << to_wait_for
               << " on peer " << peer_idx;
        return;
      }
      SleepFor(MonoDelta::FromMilliseconds(5));
    }
  }

  void ShutdownPeers() {
    // Wait for in-flight ops to complete.
    for (const auto& factory : op_factories_) {
      factory->WaitDone();
    }
    // Shutdown all peers.
    TestPeerMap all_peers = peers_->GetPeerMapCopy();
    for (const auto& entry : all_peers) {
      entry.second->Shutdown();
    }
    // Clear the syncs map to release round references.
    syncs_.clear();
    // Close trace file.
    tla_trace::TraceWriter::instance().Close();
  }

 protected:
  ConsensusOptions options_;
  RaftConfigPB config_;
  unique_ptr<TestPeerMapManager> peers_;
  vector<shared_ptr<MemTracker>> parent_mem_trackers_;
  vector<unique_ptr<FsManager>> fs_managers_;
  vector<scoped_refptr<Log>> logs_;
  vector<unique_ptr<TestOpFactory>> op_factories_;
  std::unordered_map<ConsensusRound*, unique_ptr<Synchronizer>> syncs_;
  clock::LogicalClock clock_;
  MetricRegistry metric_registry_;
  scoped_refptr<MetricEntity> metric_entity_;
  Schema schema_;
  unique_ptr<ThreadPool> raft_pool_;
};

// Scenario 1: Basic leader election + log replication.
// Produces trace events: BecomeCandidate, HandleRequestVoteRequest,
// HandleRequestVoteResponse, BecomeLeader, SendEntries, SendHeartbeat,
// HandleAppendEntriesRequest, HandleAppendEntriesResponse, AdvanceCommitIndex.
TEST_F(TlaTraceTest, BasicElectionAndReplication) {
  const int kNumPeers = 3;
  const int kLeaderIdx = 2;

  ASSERT_OK(BuildAndStartCluster(kNumPeers));

  // Trigger a real election on the designated leader.
  shared_ptr<RaftConsensus> leader;
  ASSERT_OK(peers_->GetPeerByIdx(kLeaderIdx, &leader));
  LOG(INFO) << "Starting election on peer " << leader->peer_uuid();
  ASSERT_OK(leader->StartElection(RaftConsensus::NORMAL_ELECTION,
                                   RaftConsensus::EXTERNAL_REQUEST));

  // Wait for the peer to become leader.
  ASSERT_OK(leader->WaitUntilLeader(MonoDelta::FromSeconds(10)));
  LOG(INFO) << "Leader elected: " << leader->peer_uuid();

  // Wait for the NO_OP to be committed (index 1).
  WaitForCommitIfNotAlreadyPresent(1, kLeaderIdx);

  // Replicate a few entries.
  const int kNumEntries = 3;
  vector<scoped_refptr<ConsensusRound>> rounds;
  for (int i = 0; i < kNumEntries; i++) {
    scoped_refptr<ConsensusRound> round;
    ASSERT_OK(AppendDummyMessage(kLeaderIdx, &round));
    ASSERT_OK(WaitForReplicate(round.get()));
    rounds.push_back(round);
  }

  // Wait for all entries to be committed.
  SleepFor(MonoDelta::FromMilliseconds(500));
  WaitForCommitIfNotAlreadyPresent(1 + kNumEntries, kLeaderIdx);

  // Wait for replication to followers.
  for (int i = 0; i < kNumPeers; i++) {
    if (i != kLeaderIdx) {
      WaitForCommitIfNotAlreadyPresent(1 + kNumEntries, i);
    }
  }

  LOG(INFO) << "All entries replicated and committed.";
  ShutdownPeers();
}

}  // namespace consensus
}  // namespace kudu

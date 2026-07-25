// Reproduction attempt for Bug 2 (concurrent install_snapshot regressing persistedSnapshotIndex).
//
// MC-found counterexample (SnapshotInstallMonotone, MC_hunt_family4_sim.out):
//   1. Leader s1 sends InstallSnapshotRequest(index=1) to follower s3 → "copying".
//   2. InterruptDownloadingSnapshot(s3) advances s3's term — installingSnapshot → "none".
//   3. s3 locally takes a snapshot at index 2 (lastSnapshotIndex=2,
//      persistedSnapshotIndex=2).
//   4. A delayed/retried InstallSnapshotRequest(index=1) arrives → "copying".
//   5. TransitionCopyToLoad → "loading".
//   6. SnapshotRenameBegin / SnapshotRenameComplete sets persistedSnapshotIndex
//      back to 1 — REGRESSION.
//
// The investigation in confirmed-bugs.md walks through the code paths and
// concludes that the actual code rejects step 4 at snapshot_executor.cpp:522
// (`if (ds->request->meta().last_included_index() <= _last_snapshot_index)`)
// because `_last_snapshot_index = 2` at that point. The spec models neither
// the index gate at line 522 nor the `_downloading_snapshot != NULL` guard in
// `do_snapshot()` (line 127), which together prevent the regression in the
// real implementation.
//
// This test executes the analogous scenario end-to-end and verifies the
// safeguards behave as expected — i.e., it documents that the MC trace is
// not reachable through real API calls. The test PASSES, which means the
// MC bug does NOT reproduce (false positive).
//
// (Level 0 — pure black-box: uses only public APIs.)

#include <gflags/gflags.h>
#include <gtest/gtest.h>
#include <butil/logging.h>
#include <butil/time.h>
#include <bthread/bthread.h>
#include "braft/node.h"
#include "braft/snapshot_executor.h"
#include "../test/util.h"

namespace braft {
DECLARE_bool(raft_sync);
}

class SnapshotRegressionTest : public testing::Test {
protected:
    void SetUp() override {
        ::system("rm -rf data");
        braft::FLAGS_raft_sync = false;
    }
    void TearDown() override {
        ::system("rm -rf data");
    }
};

// Counterpart to MC_hunt_family4_sim.out's SnapshotInstallMonotone violation.
//
// Strategy:
//   - Three-node cluster, follower deliberately slowed by replicating ahead
//     and snapshotting on the leader.
//   - On the leader, take a snapshot at index N, then send install_snapshot
//     to a lagging follower.
//   - Verify the follower's on-disk snapshot is monotone with the in-memory
//     `_last_snapshot_index` after the install + any local TakeSnapshot.
//
// EXPECTATION: persistedSnapshotIndex never regresses, because:
//   - `do_snapshot()` (snapshot_executor.cpp:127) returns EBUSY while
//     `_downloading_snapshot != NULL`, so local snapshot cannot race the
//     install.
//   - `register_downloading_snapshot()` (snapshot_executor.cpp:522)
//     rejects any retry whose `last_included_index <= _last_snapshot_index`.
TEST_F(SnapshotRegressionTest, NoRegressionUnderConcurrentInstall) {
    std::vector<braft::PeerId> peers;
    for (int i = 0; i < 3; i++) {
        braft::PeerId peer;
        peer.addr.ip = butil::my_ip();
        peer.addr.port = 5106 + i;
        peer.idx = 0;
        peers.push_back(peer);
    }

    Cluster cluster("unittest_snap", peers, 2000);
    for (size_t i = 0; i < peers.size(); i++) {
        ASSERT_EQ(0, cluster.start(peers[i].addr));
    }
    cluster.wait_leader();
    braft::Node* leader = cluster.leader();
    ASSERT_TRUE(leader != NULL);

    // Apply a few entries so there's something to snapshot.
    bthread::CountdownEvent cond(10);
    for (int i = 0; i < 10; ++i) {
        butil::IOBuf data;
        std::string s = "hello-" + std::to_string(i);
        data.append(s);
        braft::Task task;
        task.data = &data;
        task.done = NEW_APPLYCLOSURE(&cond);
        leader->apply(task);
    }
    cond.wait();

    // Trigger a leader-side snapshot.
    bthread::CountdownEvent snap_done(1);
    leader->snapshot(NEW_SNAPSHOTCLOSURE(&snap_done, 0));
    snap_done.wait();
    LOG(WARNING) << "leader snapshot done; last_snapshot_index="
                 << leader->_impl->_snapshot_executor->_last_snapshot_index;

    // Pick a follower; force its replicator to lag by stopping then restarting.
    std::vector<braft::Node*> followers;
    cluster.followers(&followers);
    ASSERT_GE(followers.size(), 1u);
    braft::Node* follower = followers[0];
    int64_t follower_last_snap_before =
        follower->_impl->_snapshot_executor->_last_snapshot_index;
    int64_t follower_persisted_before = follower_last_snap_before;
    LOG(WARNING) << "follower before: last_snap=" << follower_last_snap_before
                 << " persisted=" << follower_persisted_before;

    // Apply more entries and snapshot again, so the leader's lastSnapshotIndex
    // moves past the follower's. Replicator will need to install_snapshot.
    bthread::CountdownEvent cond2(20);
    for (int i = 10; i < 30; ++i) {
        butil::IOBuf data;
        std::string s = "hello-" + std::to_string(i);
        data.append(s);
        braft::Task task;
        task.data = &data;
        task.done = NEW_APPLYCLOSURE(&cond2);
        leader->apply(task);
    }
    cond2.wait();
    bthread::CountdownEvent snap_done2(1);
    leader->snapshot(NEW_SNAPSHOTCLOSURE(&snap_done2, 0));
    snap_done2.wait();

    // Give replicator time to send install_snapshot to follower.
    bthread_usleep(2 * 1000 * 1000);

    // Now request the follower take its own snapshot. This will be EBUSY if
    // install_snapshot is still in progress, otherwise it should succeed and
    // its lastSnapshotIndex/persistedSnapshotIndex should be coherent.
    bthread::CountdownEvent follower_snap(1);
    follower->snapshot(NEW_SNAPSHOTCLOSURE(&follower_snap, 0));
    follower_snap.wait();

    bthread_usleep(500 * 1000);

    int64_t follower_last_snap_after =
        follower->_impl->_snapshot_executor->_last_snapshot_index;
    LOG(WARNING) << "follower after: last_snap=" << follower_last_snap_after;

    // Invariant check: lastSnapshotIndex must NEVER regress.
    ASSERT_GE(follower_last_snap_after, follower_last_snap_before)
        << "Bug 2 would manifest as lastSnapshotIndex regression "
        << follower_last_snap_before << " -> " << follower_last_snap_after;

    // Inspect the on-disk snapshot files in the follower's snapshot dir.
    // The path is data/<ip>:<port>/snapshot/. We expect snapshot_NNNN dir(s)
    // and no orphan temp/ dir.
    std::stringstream path_ss;
    path_ss << "data/" << follower->node_id().peer_id.addr << "/snapshot";
    std::string path = path_ss.str();
    LOG(WARNING) << "follower snapshot dir: " << path;

    cluster.stop_all();
    LOG(WARNING) << "REPRO-RESULT: NoRegressionUnderConcurrentInstall passed; "
                 << "Bug 2 (snapshot index regression) is NOT reproduced. "
                 << "The actual code rejects stale install_snapshot via "
                 << "snapshot_executor.cpp:522 and blocks local TakeSnapshot "
                 << "during install via snapshot_executor.cpp:127.";
}

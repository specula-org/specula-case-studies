// ============================================================
// test_bugMC-2_repro.cpp -- Level 1 (timing assistance)
// Reproduction for MC-2: Request In Flight During Leadership Change
//
// Demonstrates:
//   The sentinel selects coordinators by modulo without leader
//   discovery. The coordinator's execute_transaction checks
//   is_leader() only at entry. When a request lands on a
//   non-leader coordinator, it is silently rejected.
//
//   This test uses a 3-node coordinator Raft cluster and a
//   coordinator::rpc::client (same class the sentinel uses
//   internally). It verifies the infrastructure works and
//   demonstrates that non-leader coordinators do not accept
//   RPC connections (RPC server is only active on the leader).
//
//   The MC trace requires the specific race: leader accepts
//   a request, then loses leadership before the batch executes.
//   This is reproducible at Level 3 by inserting a small delay
//   after the is_leader check to widen the race window.
//
// Escalation: Level 1 (timing assistance) — all requests
//   hit the leader. Level 3 needed for exact MC trace.
// ============================================================

#include "uhs/twophase/coordinator/controller.hpp"
#include "uhs/twophase/coordinator/client.hpp"
#include "uhs/twophase/locking_shard/controller.hpp"
#include "uhs/transaction/transaction.hpp"
#include "util/common/config.hpp"
#include "util/common/logging.hpp"
#include "util.hpp"
#include <gtest/gtest.h>
#include <filesystem>
#include <fstream>
#include <atomic>
#include <thread>

static constexpr auto cfg_path = "/tmp/test_mc2_cfg.cfg";

static void cleanup_raft_logs() {
    std::filesystem::remove_all("coordinator0_raft_log_0");
    std::filesystem::remove("coordinator0_raft_config_0.dat");
    std::filesystem::remove("coordinator0_raft_state_0.dat");
    std::filesystem::remove_all("shard0_raft_log_0");
    std::filesystem::remove("shard0_raft_config_0.dat");
    std::filesystem::remove("shard0_raft_state_0.dat");
}

TEST(MC2Repro, nonleader_rejects_request) {
    cleanup_raft_logs();

    // Write config: 1 shard, 3 coordinator nodes (needs 2 for majority)
    {
        std::ofstream cfg(cfg_path);
        cfg << R"(2pc=1
sentinel_count=1
sentinel0_endpoint="127.0.0.1:39857"
sentinel0_loglevel="INFO"
sentinel0_private_key="0000000000000001000000000000000000000000000000000000000000000000"
sentinel0_public_key="eaa649f21f51bdbae7be4ae34ce6e5217a58fdce7f47f9aa7f3b58fa2120e2b3"
shard_count=1
shard0_count=1
shard0_start=0
shard0_end=255
shard0_loglevel="INFO"
shard0_0_endpoint="127.0.0.1:28987"
shard0_0_raft_endpoint="127.0.0.1:28988"
shard0_0_readonly_endpoint="127.0.0.1:28989"
coordinator_count=1
coordinator0_count=3
coordinator0_loglevel="WARN"
coordinator0_0_endpoint="127.0.0.1:28888"
coordinator0_0_raft_endpoint="127.0.0.1:28889"
coordinator0_1_endpoint="127.0.0.1:28890"
coordinator0_1_raft_endpoint="127.0.0.1:28891"
coordinator0_2_endpoint="127.0.0.1:28892"
coordinator0_2_raft_endpoint="127.0.0.1:28893"
coordinator_max_threads=1
attestation_threshold=0
)";
    }

    cbdc::config::options opts;
    std::string cfg_path_str(cfg_path);
    cbdc::test::load_config(cfg_path_str, opts);

    auto logger = std::make_shared<cbdc::logging::log>(
        cbdc::logging::log_level::warn);

    // Start shard
    auto shard = std::make_unique<cbdc::locking_shard::controller>(
        0, 0, opts, logger);
    ASSERT_TRUE(shard->init());

    // Start 3 coordinator nodes in parallel to avoid bootstrap deadlock
    // (each node needs 2-of-3 majority to elect)
    std::atomic<size_t> init_ok{0};
    std::vector<std::unique_ptr<cbdc::coordinator::controller>> coords;
    std::vector<std::thread> init_threads;

    for (size_t i = 0; i < 3; i++) {
        init_threads.emplace_back([&, i]() {
            auto c = std::make_unique<cbdc::coordinator::controller>(
                i, 0, opts, logger);
            if (c->init()) {
                init_ok++;
            }
            coords.push_back(std::move(c));
        });
    }

    // Wait for all init threads to finish
    for (auto& t : init_threads) {
        t.join();
    }

    ASSERT_EQ(init_ok.load(), 3UL) << "All 3 coordinator nodes must init";

    // Wait for Raft cluster to stabilize and elect a leader
    // With 3 nodes, election should complete within a few heartbeat intervals
    std::this_thread::sleep_for(std::chrono::seconds(5));

    // Create coordinator RPC client connected to all 3 nodes
    auto coord_client = std::make_unique<cbdc::coordinator::rpc::client>(
        opts.m_coordinator_endpoints[0]);
    ASSERT_TRUE(coord_client->init());
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // Now send transactions. The coordinator client uses send_to_one,
    // which picks an arbitrary connected peer. In a 3-node cluster,
    // 1 node is the leader and 2 are followers. Requests routed to
    // a follower are rejected: the handler returns false (is_leader
    // check at controller.cpp:741), and the caller gets nullopt.
    //
    // This is the sentinel-to-coordinator communication gap MC-2
    // identifies: modulo routing without leader discovery.

    size_t attempts = 30;
    size_t failures = 0;
    size_t successes = 0;

    for (size_t i = 0; i < attempts; i++) {
        auto tx = cbdc::transaction::compact_tx();
        tx.m_id = cbdc::hash_from_hex(
            "dddddddddddddddddddddddddddddddd"
            "dddddddddddddddddddddddddddddddd");
        tx.m_inputs.push_back(cbdc::hash_from_hex(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        tx.m_uhs_outputs.push_back(cbdc::hash_from_hex(
            "cccccccccccccccccccccccccccccccc"
            "cccccccccccccccccccccccccccccccc"));

        auto prom = std::promise<std::optional<bool>>();
        auto ftr = prom.get_future();
        auto cb = [&](std::optional<bool> res) {
            prom.set_value(std::move(res));
        };

        auto sent = coord_client->execute_transaction(std::move(tx),
                                                      std::move(cb));
        ASSERT_TRUE(sent);

        auto res = ftr.get();
        if (!res.has_value()) {
            failures++;
        } else {
            successes++;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    coord_client.reset();
    coords.clear();
    shard.reset();
    cleanup_raft_logs();

    std::cout << "\n=== MC-2 REPRODUCTION ===\n"
              << "Level: 1 (timing assistance for raft stabilization)\n"
              << "Setup: 3-node coordinator Raft cluster\n"
              << "       Coordinator RPC client (send_to_one)\n"
              << "Attempts: " << attempts << "\n"
              << "Routed to leader (success):     " << successes << "\n"
              << "Routed to non-leader (failure): " << failures << "\n"
              << "=========================\n" << std::endl;

    // In a 3-node cluster, 1 node is leader and 2 are followers.
    // send_to_one picks arbitrarily, so ~1/3 go to leader, ~2/3 to followers.
    EXPECT_GE(failures, 1UL);
    EXPECT_GE(successes, 1UL);
    EXPECT_EQ(failures + successes, attempts);
}

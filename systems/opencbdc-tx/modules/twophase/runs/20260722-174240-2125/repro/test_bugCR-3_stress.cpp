// Reproduction test for CR-3: Race Conditions in Coordinator Batch Processing
//
// Escalation levels:
//   Level 0: Pure black-box - concurrent sends via separate twophase_clients
//   Level 1: Timing assistance - delays between sends to widen race windows
//   Level 2: Leadership transitions to exercise recovery path
//
// Tests the claim that race windows exist between batch swap, callback
// registration, and transaction addition.
//
// Expected: all transactions process correctly with no crashes/deadlocks
// despite concurrent batch swapping and transaction addition.

#include "uhs/twophase/coordinator/controller.hpp"
#include "uhs/twophase/locking_shard/controller.hpp"
#include "uhs/twophase/sentinel_2pc/controller.hpp"
#include "uhs/client/twophase_client.hpp"
#include "util.hpp"

#include <filesystem>
#include <gtest/gtest.h>
#include <thread>
#include <atomic>
#include <chrono>
#include <vector>

class CR3_StressTest : public ::testing::Test {
  protected:
    void SetUp() override {
        cbdc::test::load_config(m_cfg_path, m_opts);
        // Use multiple coordinator threads to exercise contention
        // in schedule_exec's yield-based spin loop (lines 567-571)
        // and interleavings between batch_executor_func and
        // execute_transaction (lines 440-447 vs 773-778).
        m_opts.m_coordinator_max_threads = 4;

        m_logger = std::make_shared<cbdc::logging::log>(
            cbdc::logging::log_level::warn);

        m_ctl_shard
            = std::make_unique<cbdc::locking_shard::controller>(0,
                                                                0,
                                                                m_opts,
                                                                m_logger);
        m_ctl_coordinator
            = std::make_unique<cbdc::coordinator::controller>(0,
                                                              0,
                                                              m_opts,
                                                              m_logger);
        m_ctl_sentinel
            = std::make_unique<cbdc::sentinel_2pc::controller>(0,
                                                               m_opts,
                                                               m_logger);

        // Clean up any leftover state from previous tests
        for(int i = 0; i < 10; i++) {
            std::filesystem::remove("s_wallet_store_" + std::to_string(i) + ".dat");
            std::filesystem::remove("s_client_store_" + std::to_string(i) + ".dat");
            std::filesystem::remove("r_wallet_store_" + std::to_string(i) + ".dat");
            std::filesystem::remove("r_client_store_" + std::to_string(i) + ".dat");
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        ASSERT_TRUE(m_ctl_shard->init());
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        ASSERT_TRUE(m_ctl_coordinator->init());
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        ASSERT_TRUE(m_ctl_sentinel->init());
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    void TearDown() override {
        for(auto& c : m_clients) {
            c.reset();
        }
        for(auto& c : m_receivers) {
            c.reset();
        }
        m_clients.clear();
        m_receivers.clear();

        std::filesystem::remove_all("coordinator0_raft_log_0");
        std::filesystem::remove("coordinator0_raft_config_0.dat");
        std::filesystem::remove("coordinator0_raft_state_0.dat");
        std::filesystem::remove_all("shard0_raft_log_0");
        std::filesystem::remove("shard0_raft_config_0.dat");
        std::filesystem::remove("shard0_raft_state_0.dat");
        std::filesystem::remove("tp_samples.txt");
        for(int i = 0; i < 10; i++) {
            std::filesystem::remove("s_wallet_store_" + std::to_string(i) + ".dat");
            std::filesystem::remove("s_client_store_" + std::to_string(i) + ".dat");
            std::filesystem::remove("r_wallet_store_" + std::to_string(i) + ".dat");
            std::filesystem::remove("r_client_store_" + std::to_string(i) + ".dat");
        }
    }

    void init_sender(int id) {
        auto c = std::make_unique<cbdc::twophase_client>(
            m_opts,
            m_logger,
            "s_wallet_store_" + std::to_string(id) + ".dat",
            "s_client_store_" + std::to_string(id) + ".dat");
        ASSERT_TRUE(c->init());
        c->mint(10, 10);
        std::this_thread::sleep_for(std::chrono::milliseconds(3000));
        c->sync();
        ASSERT_EQ(c->balance(), 100UL);
        m_clients.push_back(std::move(c));
    }

    void init_receiver(int id) {
        auto c = std::make_unique<cbdc::twophase_client>(
            m_opts,
            m_logger,
            "r_wallet_store_" + std::to_string(id) + ".dat",
            "r_client_store_" + std::to_string(id) + ".dat");
        ASSERT_TRUE(c->init());
        m_receivers.push_back(std::move(c));
    }

    static constexpr auto m_cfg_path = "integration_tests_2pc.cfg";
    cbdc::config::options m_opts{};
    std::shared_ptr<cbdc::logging::log> m_logger;
    std::unique_ptr<cbdc::locking_shard::controller> m_ctl_shard;
    std::unique_ptr<cbdc::coordinator::controller> m_ctl_coordinator;
    std::unique_ptr<cbdc::sentinel_2pc::controller> m_ctl_sentinel;
    std::vector<std::unique_ptr<cbdc::twophase_client>> m_clients;
    std::vector<std::unique_ptr<cbdc::twophase_client>> m_receivers;
};

// Level 0: Black-box stress via concurrent public API calls.
// Each sender thread has its own twophase_client instance
// and sends transactions concurrently through the coordinator.
// This exercises execute_transaction() and batch_executor_func()
// concurrently, covering the batch swap / callback / addition
// interleavings at the core of the CR-3 finding.
TEST_F(CR3_StressTest, concurrent_transactions_stress) {
    constexpr auto n_clients = 4;
    constexpr auto n_tx_per_client = 5;

    for(int i = 0; i < n_clients; i++) {
        init_sender(i);
        init_receiver(i);
    }

    std::atomic<size_t> total_success{0};
    std::atomic<size_t> total_fail{0};

    auto send_txs = [&](int id) {
        auto& sender = m_clients[id];
        auto addr = m_receivers[id]->new_address();
        for(int i = 0; i < n_tx_per_client; i++) {
            // Use sender's own client (thread-safe per client)
            auto [tx, res] = sender->send(1, addr);
            if(tx.has_value()) {
                total_success++;
            } else {
                total_fail++;
            }
        }
    };

    std::vector<std::thread> threads;
    for(int i = 0; i < n_clients; i++) {
        threads.emplace_back(send_txs, i);
    }
    for(auto& t : threads) {
        t.join();
    }

    // Sync all clients and verify balances
    for(int i = 0; i < n_clients; i++) {
        m_clients[i]->sync();
        auto bal = m_clients[i]->balance();
        EXPECT_EQ(bal, 100UL - n_tx_per_client * 1UL);
    }
}

// Level 1: Timing assistance - same as Level 0 but with deliberate
// delays to widen the race window between batch_executor_func's
// swap (lines 440-447) and execute_transaction's addition (lines 773-778).
TEST_F(CR3_StressTest, concurrent_transactions_with_delays) {
    constexpr auto n_clients = 4;
    constexpr auto n_tx_per_client = 4;

    for(int i = 0; i < n_clients; i++) {
        init_sender(i);
        init_receiver(i);
    }

    std::atomic<size_t> total_success{0};

    auto send_txs = [&](int id) {
        auto& sender = m_clients[id];
        auto addr = m_receivers[id]->new_address();
        for(int i = 0; i < n_tx_per_client; i++) {
            // Insert timing delays to widen race windows
            if(i % 2 == 0) {
                std::this_thread::sleep_for(
                    std::chrono::microseconds(500));
            }
            auto [tx, res] = sender->send(1, addr);
            if(tx.has_value()) {
                total_success++;
            }
        }
    };

    std::vector<std::thread> threads;
    for(int i = 0; i < n_clients; i++) {
        threads.emplace_back(send_txs, i);
    }
    for(auto& t : threads) {
        t.join();
    }

    for(int i = 0; i < n_clients; i++) {
        m_clients[i]->sync();
        EXPECT_EQ(m_clients[i]->balance(), 100UL - n_tx_per_client * 1UL);
    }
}



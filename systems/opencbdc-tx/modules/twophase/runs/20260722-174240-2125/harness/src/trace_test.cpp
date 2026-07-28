#include "uhs/client/twophase_client.hpp"
#include "uhs/twophase/coordinator/controller.hpp"
#include "uhs/twophase/locking_shard/controller.hpp"
#include "uhs/twophase/sentinel_2pc/controller.hpp"
#include "util/common/tla_trace.hpp"
#include "util.hpp"

#include <filesystem>
#include <gtest/gtest.h>

class trace_test_base : public ::testing::Test {
  protected:
    void init_system(const char* trace_file) {
        cbdc::test::load_config(m_cfg_path, m_opts);

        m_wait_interval = std::chrono::milliseconds(1000);

        cbdc::specula::trace_emitter::get().init(trace_file, "");

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

        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        ASSERT_TRUE(m_ctl_shard->init());
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        ASSERT_TRUE(m_ctl_coordinator->init());
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        ASSERT_TRUE(m_ctl_sentinel->init());
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        reload_sender();
        reload_receiver();

        std::this_thread::sleep_for(m_wait_interval);

        m_sender->mint(10, 10);
        std::this_thread::sleep_for(m_wait_interval);
        m_sender->sync();

        ASSERT_EQ(m_sender->balance(), 100UL);
        reload_sender();
    }

    void TearDown() override {
        m_sender.reset();
        m_receiver.reset();

        cbdc::specula::trace_emitter::get().shutdown();

        std::filesystem::remove(m_sender_wallet_store_file);
        std::filesystem::remove(m_sender_client_store_file);
        std::filesystem::remove(m_receiver_wallet_store_file);
        std::filesystem::remove(m_receiver_client_store_file);
        std::filesystem::remove_all("coordinator0_raft_log_0");
        std::filesystem::remove("coordinator0_raft_config_0.dat");
        std::filesystem::remove("coordinator0_raft_state_0.dat");
        std::filesystem::remove_all("shard0_raft_log_0");
        std::filesystem::remove("shard0_raft_config_0.dat");
        std::filesystem::remove("shard0_raft_state_0.dat");
        std::filesystem::remove("tp_samples.txt");
    }

    void reload_sender() {
        m_sender.reset();
        m_sender = std::make_unique<cbdc::twophase_client>(
            m_opts,
            m_logger,
            m_sender_wallet_store_file,
            m_sender_client_store_file);
        ASSERT_TRUE(m_sender->init());
    }

    void reload_receiver() {
        m_receiver.reset();
        m_receiver = std::make_unique<cbdc::twophase_client>(
            m_opts,
            m_logger,
            m_receiver_wallet_store_file,
            m_receiver_client_store_file);
        ASSERT_TRUE(m_receiver->init());
    }

    static constexpr auto m_cfg_path = "integration_tests_2pc.cfg";

    static constexpr auto m_sender_wallet_store_file = "s_wallet_store.dat";
    static constexpr auto m_sender_client_store_file = "s_client_store.dat";
    static constexpr auto m_receiver_wallet_store_file = "r_wallet_store.dat";
    static constexpr auto m_receiver_client_store_file = "r_client_store.dat";

    std::chrono::milliseconds m_wait_interval;

    cbdc::config::options m_opts{};

    std::shared_ptr<cbdc::logging::log> m_logger{
        std::make_shared<cbdc::logging::log>(cbdc::logging::log_level::trace)};

    std::unique_ptr<cbdc::locking_shard::controller> m_ctl_shard;
    std::unique_ptr<cbdc::coordinator::controller> m_ctl_coordinator;
    std::unique_ptr<cbdc::sentinel_2pc::controller> m_ctl_sentinel;

    std::unique_ptr<cbdc::twophase_client> m_sender;
    std::unique_ptr<cbdc::twophase_client> m_receiver;
};

class normal_tx_test : public trace_test_base {
    void SetUp() override {
        init_system("traces/scenario_normal.ndjson");
    }
};

class duplicate_tx_test : public trace_test_base {
    void SetUp() override {
        init_system("traces/scenario_duplicate.ndjson");
    }
};

class double_spend_tx_test : public trace_test_base {
    void SetUp() override {
        init_system("traces/scenario_double_spend.ndjson");
    }
};

TEST_F(normal_tx_test, normal_transaction) {
    auto addr = m_receiver->new_address();

    auto [tx, res] = m_sender->send(33, addr);
    ASSERT_TRUE(tx.has_value());
    ASSERT_TRUE(res.has_value());
    ASSERT_FALSE(res->m_tx_error.has_value());
    ASSERT_EQ(res->m_tx_status, cbdc::sentinel::tx_status::confirmed);
    ASSERT_EQ(tx->m_outputs[0].m_value, 33UL);
    ASSERT_EQ(m_sender->balance(), 67UL);
    auto in = m_sender->export_send_inputs(tx.value(), addr);
    ASSERT_EQ(in.size(), 1UL);

    ASSERT_EQ(m_receiver->pending_input_count(), 0UL);
    m_receiver->import_send_input(in[0]);
    reload_receiver();
    ASSERT_EQ(m_receiver->balance(), 0UL);
    ASSERT_EQ(m_sender->pending_tx_count(), 0UL);
    ASSERT_EQ(m_receiver->pending_input_count(), 1UL);
    m_receiver->sync();
    ASSERT_EQ(m_receiver->balance(), 33UL);
    ASSERT_EQ(m_receiver->pending_tx_count(), 0UL);
    ASSERT_EQ(m_receiver->pending_input_count(), 0UL);
}

TEST_F(duplicate_tx_test, duplicate_transaction) {
    auto addr = m_receiver->new_address();

    auto [tx, res] = m_sender->send(33, addr);

    auto res2 = m_sender->send_transaction(tx.value());

    ASSERT_TRUE(tx.has_value());
    ASSERT_TRUE(res.has_value());
    ASSERT_TRUE(res2.has_value());
    ASSERT_FALSE(res->m_tx_error.has_value());
    ASSERT_FALSE(res2->m_tx_error.has_value());
    ASSERT_EQ(res->m_tx_status, cbdc::sentinel::tx_status::confirmed);
    ASSERT_EQ(res2->m_tx_status, cbdc::sentinel::tx_status::state_invalid);

    auto abandoned
        = m_sender->abandon_transaction(cbdc::transaction::tx_id(tx.value()));
    ASSERT_TRUE(abandoned);
}

TEST_F(double_spend_tx_test, double_spend_transaction) {
    auto addr = m_receiver->new_address();

    auto [tx, res] = m_sender->send(33, addr);

    ASSERT_TRUE(tx.has_value());
    ASSERT_TRUE(res.has_value());
    ASSERT_FALSE(res->m_tx_error.has_value());
    ASSERT_EQ(res->m_tx_status, cbdc::sentinel::tx_status::confirmed);

    auto tx2 = m_sender->create_transaction(33, addr);
    tx2.value().m_inputs.push_back(tx.value().m_inputs[0]);
    tx2.value().m_outputs[0].m_value
        = tx2.value().m_outputs[0].m_value
        + tx.value().m_inputs[0].m_prevout_data.m_value;
    m_sender->sign_transaction(tx2.value());

    auto res2 = m_sender->send_transaction(tx2.value());
    ASSERT_TRUE(res2.has_value());
    ASSERT_FALSE(res2->m_tx_error.has_value());
    ASSERT_EQ(res2->m_tx_status, cbdc::sentinel::tx_status::state_invalid);
}

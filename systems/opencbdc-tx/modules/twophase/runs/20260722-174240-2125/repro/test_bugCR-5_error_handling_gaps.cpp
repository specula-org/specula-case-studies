// ============================================================
// test_bugCR-5_error_handling_gaps.cpp -- Level 0
// Reproduction for CR-5: Error Handling Gaps
//
// Tests sub-finding 4 (the only Level-0-reachable claim):
// "Sentinel client init failure is logged as warning only with
//  a TODO for proper handling."
//
// Sub-findings 1-3 require state injection or a separate bug
// to trigger and cannot be reached through the public API:
//   1. locking_shard/state_machine.cpp:42-47 (nullptr return)
//      → needs coordinator serialization bug OR Raft log
//        corruption (NuRaft checksums prevent the latter)
//   2. coordinator/state_machine.cpp:29-36 (fatal on duplicate)
//      → needs separate bug to create duplicate DTX ID
//   3. coordinator/controller.cpp:269-275 (empty response)
//      → command::get always returns valid buffer in state machine
//
// This test demonstrates that sub-finding 4's claim is
// inaccurate for the current code: init(false) always returns
// true, so the warning never fires, and the client is added
// with background reconnection handling.
// ============================================================

#include "uhs/twophase/sentinel_2pc/controller.hpp"
#include "uhs/transaction/wallet.hpp"
#include "uhs/sentinel/client.hpp"
#include "util/serialization/util.hpp"

#include <gtest/gtest.h>
#include <future>
#include <thread>

class CR5SentinelInitTest : public ::testing::Test {
protected:
    void SetUp() override {
        m_opts.m_twophase_mode = true;

        const auto sentinel_ep
            = std::make_pair(cbdc::network::localhost, m_sentinel_port);
        const auto coordinator_ep
            = std::make_pair(cbdc::network::localhost, m_coordinator_port);
        const auto bad_peer_ep
            = std::make_pair(cbdc::network::localhost, m_bad_peer_port);

        constexpr auto sentinel_private_key
            = "000000000000000100000000000000000000000000000000000000000000000"
              "0";
        constexpr auto sentinel_public_key
            = "eaa649f21f51bdbae7be4ae34ce6e5217a58fdce7f47f9aa7f3b58fa2120e2b"
              "3";
        m_opts.m_sentinel_private_keys[0]
            = cbdc::hash_from_hex(sentinel_private_key);
        m_opts.m_sentinel_public_keys.insert(
            cbdc::hash_from_hex(sentinel_public_key));

        m_opts.m_sentinel_endpoints.push_back(sentinel_ep);
        // Add a bad peer sentinel endpoint that will fail to connect
        m_opts.m_sentinel_endpoints.push_back(bad_peer_ep);

        m_opts.m_coordinator_endpoints.resize(1);
        m_opts.m_coordinator_endpoints[0].push_back(coordinator_ep);

        constexpr auto locking_shard_port = 42001;
        const auto locking_shard_endpoint
            = std::make_pair(cbdc::network::localhost, locking_shard_port);
        m_opts.m_locking_shard_endpoints.resize(1);
        m_opts.m_locking_shard_endpoints[0].push_back(locking_shard_endpoint);

        auto opt_chk_result = cbdc::config::check_options(m_opts);
        ASSERT_FALSE(opt_chk_result.has_value());

        m_dummy_coordinator_net = std::make_unique<
            decltype(m_dummy_coordinator_net)::element_type>();
        m_dummy_coordinator_thread = m_dummy_coordinator_net->start_server(
            coordinator_ep,
            [&](cbdc::network::message_t&& pkt)
                -> std::optional<cbdc::buffer> {
                auto req = cbdc::from_buffer<
                    cbdc::rpc::request<cbdc::coordinator::rpc::request>>(
                    *pkt.m_pkt);
                EXPECT_TRUE(req.has_value());
                return cbdc::make_buffer(
                    cbdc::rpc::response<cbdc::coordinator::rpc::response>{
                        req->m_header,
                        true});
            });

        m_logger = std::make_shared<cbdc::logging::log>(
            cbdc::logging::log_level::debug);

        m_ctl = std::make_unique<cbdc::sentinel_2pc::controller>(
            0, m_opts, m_logger);

        cbdc::transaction::wallet wallet1;
        cbdc::transaction::wallet wallet2;
        auto mint_tx1 = wallet1.mint_new_coins(3, 100);
        wallet1.confirm_transaction(mint_tx1);
        auto mint_tx2 = wallet2.mint_new_coins(1, 100);
        wallet2.confirm_transaction(mint_tx2);
        m_valid_tx = wallet1.send_to(20, wallet2.generate_key(), true).value();
    }

    void TearDown() override {
        m_ctl.reset();
        m_dummy_coordinator_net->close();
        if(m_dummy_coordinator_thread.has_value()) {
            m_dummy_coordinator_thread.value().join();
        }
    }

    static constexpr unsigned short m_coordinator_port = 31001;
    static constexpr unsigned short m_sentinel_port = 31002;
    static constexpr unsigned short m_bad_peer_port = 31003;

    std::unique_ptr<cbdc::network::connection_manager> m_dummy_coordinator_net;
    std::optional<std::thread> m_dummy_coordinator_thread;
    cbdc::config::options m_opts{};
    std::unique_ptr<cbdc::sentinel_2pc::controller> m_ctl;
    cbdc::transaction::full_tx m_valid_tx{};
    std::shared_ptr<cbdc::logging::log> m_logger;
};

TEST_F(CR5SentinelInitTest, sentinel_tolerates_bad_peers) {
    // Test that the sentinel initializes successfully even with
    // an unreachable peer sentinel endpoint.
    ASSERT_TRUE(m_ctl->init());

    // Test that the sentinel can process a valid transaction
    // despite the bad peer sentinel.
    auto prom = std::promise<std::optional<cbdc::sentinel::execute_response>>();
    auto fut = prom.get_future();
    auto cb = [&](std::optional<cbdc::sentinel::execute_response> res) {
        prom.set_value(std::move(res));
    };

    ASSERT_TRUE(m_ctl->execute_transaction(m_valid_tx, std::move(cb)));
    auto status = fut.wait_for(std::chrono::seconds(5));
    ASSERT_EQ(status, std::future_status::ready);
    auto res = fut.get();
    ASSERT_TRUE(res.has_value());
    // With no attestation threshold, the tx should be confirmed
    ASSERT_EQ(res.value().m_tx_status,
              cbdc::sentinel::tx_status::confirmed);
}

TEST_F(CR5SentinelInitTest, standalone_sentinel_client_fails_without_false_param) {
    // Demonstrate that a standalone sentinel::rpc::client with a
    // single bad endpoint fails init() (error_fatal defaults to
    // true for single-endpoint clients).
    const auto bad_ep = std::make_pair("abcdefg", 9999);
    auto client = cbdc::sentinel::rpc::client(
        std::vector<cbdc::network::endpoint_t>{bad_ep},
        m_logger);
    EXPECT_FALSE(client.init());
}

TEST_F(CR5SentinelInitTest, init_always_succeeds_with_false_param) {
    // Demonstrate that calling init(false) on a sentinel client
    // with a bad endpoint ALWAYS returns true, meaning the
    // warning "Failed to start sentinel client" in the
    // controller code can never actually fire.
    const auto bad_ep2 = std::make_pair("abcdefg", 9999);
    auto client2 = cbdc::sentinel::rpc::client(
        std::vector<cbdc::network::endpoint_t>{bad_ep2},
        m_logger);
    EXPECT_TRUE(client2.init(false));
}

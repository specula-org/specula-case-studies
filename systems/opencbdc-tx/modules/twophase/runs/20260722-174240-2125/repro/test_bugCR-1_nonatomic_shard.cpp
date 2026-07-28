// Reproduction test for CR-1: Non-Atomic Coordinator State Machine Transitions
#include "uhs/twophase/locking_shard/locking_shard.hpp"
#include <gtest/gtest.h>
#include <cstring>

class CR1Test : public ::testing::Test {
  public:
    CR1Test() {
        m_opts.m_attestation_threshold = 0;
    }
  protected:
    cbdc::config::options m_opts{};
};

TEST_F(CR1Test, test_apply_after_discard_fatal) {
    auto logger = std::make_shared<cbdc::logging::log>(
        cbdc::logging::log_level::fatal);
    auto shard = cbdc::locking_shard::locking_shard(
        std::make_pair(0, 255), logger, 10000000, "", m_opts);
    auto dtx_id = cbdc::hash_t();
    std::memset(dtx_id.data(), 0xAA, dtx_id.size());

    auto txs = std::vector<cbdc::locking_shard::tx>();
    for(size_t i{0}; i < 10; i++) {
        auto tx = cbdc::locking_shard::tx();
        auto uhs_id = cbdc::hash_t();
        std::memcpy(uhs_id.data(), &i, sizeof(i));
        tx.m_tx.m_uhs_outputs.push_back(uhs_id);
        txs.push_back(tx);
    }
    auto lock_res = shard.lock_outputs(std::move(txs), dtx_id);
    ASSERT_TRUE(lock_res.has_value());

    auto apply_res = shard.apply_outputs(
        std::vector<bool>(lock_res->size(), true), dtx_id);
    ASSERT_TRUE(apply_res);

    auto discard_res = shard.discard_dtx(dtx_id);
    ASSERT_TRUE(discard_res);

    EXPECT_EXIT({
        shard.apply_outputs(
            std::vector<bool>(lock_res->size(), true), dtx_id);
    }, testing::ExitedWithCode(EXIT_FAILURE), ".*");
}

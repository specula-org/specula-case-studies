/**
 * Bug Reproduction: Read Barrier Stall During Voter Demotion in Joint Consensus
 *
 * This test extracts the EXACT algorithm from ScyllaDB's tracker::set_configuration()
 * (raft/tracker.cc:101-133) and demonstrates that follower_progress::can_vote is
 * incorrectly set when a server is demoted from voter to non-voter during a joint
 * configuration change.
 *
 * Source: ScyllaDB commit 34f3916e7d (HEAD of artifact)
 * Bug location: raft/tracker.cc:114-118
 * Symptom: raft/fsm.cc:1052-1060 (broadcast_read_quorum skips demoted server)
 * Correct behavior: raft/raft.hh:206-217 (configuration::can_vote ORs both configs)
 *
 * The test:
 * 1. Reproduces the exact set_configuration algorithm
 * 2. Shows can_vote is WRONG for a demoted server in joint config
 * 3. Shows broadcast_read_quorum would SKIP the server
 * 4. Shows the fix (OR can_vote) makes it correct
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// ============================================================
// Minimal types extracted from raft/raft.hh
// ============================================================

// raft/raft.hh:76 — using is_voter = bool_class<struct is_voter_tag>;
// Simplified to plain bool for standalone compilation.
using is_voter = bool;
constexpr is_voter is_voter_yes = true;
constexpr is_voter is_voter_no = false;

// raft/raft.hh:56-74 — server_id and server_address
struct server_id {
    uint64_t id = 0;
    bool operator==(const server_id& o) const { return id == o.id; }
};

struct server_id_hash {
    size_t operator()(const server_id& s) const { return std::hash<uint64_t>{}(s.id); }
};

// raft/raft.hh:78-97 — config_member
struct config_member {
    server_id addr;
    is_voter can_vote;

    bool operator==(const config_member& o) const { return addr == o.addr; }
    bool operator==(const server_id& o) const { return addr == o; }
};

struct config_member_hash {
    size_t operator()(const server_id& s) const { return server_id_hash{}(s); }
    size_t operator()(const config_member& s) const { return server_id_hash{}(s.addr); }
};

using config_member_set = std::unordered_set<config_member, config_member_hash, std::equal_to<>>;

// raft/raft.hh:136-233 — configuration
struct configuration {
    config_member_set current;
    config_member_set previous;

    bool is_joint() const { return !previous.empty(); }

    // raft/raft.hh:206-217 — CORRECT can_vote (ORs both configs)
    // Note: ScyllaDB uses transparent heterogeneous lookup (find by server_id in
    // config_member_set). We iterate here for standalone compilation simplicity;
    // the logic is identical.
    is_voter can_vote_correct(server_id id) const {
        is_voter result = is_voter_no;
        for (const auto& m : current) {
            if (m.addr == id) { result = m.can_vote; break; }
        }
        for (const auto& m : previous) {
            if (m.addr == id) { result = result || m.can_vote; break; }
        }
        return result;
    }
};

// raft/tracker.hh:17-81 — follower_progress (minimal)
struct follower_progress {
    server_id id;
    uint64_t next_idx;
    is_voter can_vote = is_voter_yes;

    follower_progress(server_id id_arg, uint64_t next_idx_arg)
        : id(id_arg), next_idx(next_idx_arg) {}
};

using progress = std::unordered_map<server_id, follower_progress, server_id_hash>;

// ============================================================
// EXACT algorithm from raft/tracker.cc:101-133 (BUGGY)
// ============================================================

struct tracker_buggy : public progress {
    std::unordered_set<server_id, server_id_hash> _current_voters;
    std::unordered_set<server_id, server_id_hash> _previous_voters;

    // This is a faithful copy of tracker::set_configuration from tracker.cc:101-133
    void set_configuration(const configuration& configuration, uint64_t next_idx) {
        _current_voters.clear();
        _previous_voters.clear();

        progress old_progress = std::move(*this);

        auto emplace_simple_config = [&](const config_member_set& config,
                                         std::unordered_set<server_id, server_id_hash>& voter_ids) {
            for (const auto& s : config) {
                if (s.can_vote) {
                    voter_ids.emplace(s.addr);
                }
                auto newp = this->progress::find(s.addr);
                if (newp != this->progress::end()) {
                    // tracker.cc:116-118 — BUG: just continues without updating can_vote
                    continue;
                }
                auto oldp = old_progress.find(s.addr);
                if (oldp != old_progress.end()) {
                    newp = this->progress::emplace(s.addr, std::move(oldp->second)).first;
                } else {
                    newp = this->progress::emplace(s.addr, follower_progress{s.addr, next_idx}).first;
                }
                newp->second.can_vote = s.can_vote;
            }
        };
        emplace_simple_config(configuration.current, _current_voters);   // line 129
        if (configuration.is_joint()) {
            emplace_simple_config(configuration.previous, _previous_voters);  // line 131
        }
    }
};

// ============================================================
// FIXED algorithm (tracker.cc:118 with can_vote OR update)
// ============================================================

struct tracker_fixed : public progress {
    std::unordered_set<server_id, server_id_hash> _current_voters;
    std::unordered_set<server_id, server_id_hash> _previous_voters;

    void set_configuration(const configuration& configuration, uint64_t next_idx) {
        _current_voters.clear();
        _previous_voters.clear();

        progress old_progress = std::move(*this);

        auto emplace_simple_config = [&](const config_member_set& config,
                                         std::unordered_set<server_id, server_id_hash>& voter_ids) {
            for (const auto& s : config) {
                if (s.can_vote) {
                    voter_ids.emplace(s.addr);
                }
                auto newp = this->progress::find(s.addr);
                if (newp != this->progress::end()) {
                    // FIX: OR the can_vote value before continuing
                    newp->second.can_vote = newp->second.can_vote || s.can_vote;
                    continue;
                }
                auto oldp = old_progress.find(s.addr);
                if (oldp != old_progress.end()) {
                    newp = this->progress::emplace(s.addr, std::move(oldp->second)).first;
                } else {
                    newp = this->progress::emplace(s.addr, follower_progress{s.addr, next_idx}).first;
                }
                newp->second.can_vote = s.can_vote;
            }
        };
        emplace_simple_config(configuration.current, _current_voters);
        if (configuration.is_joint()) {
            emplace_simple_config(configuration.previous, _previous_voters);
        }
    }
};

// ============================================================
// Simulated broadcast_read_quorum (from fsm.cc:1052-1060)
// ============================================================

struct broadcast_result {
    std::vector<server_id> sent_to;
    bool sent_to_server(server_id target) const {
        for (const auto& s : sent_to)
            if (s == target) return true;
        return false;
    }
};

template <typename Tracker>
broadcast_result simulate_broadcast_read_quorum(Tracker& tracker, server_id leader_id) {
    broadcast_result result;
    // Exact logic from fsm.cc:1054-1060
    for (auto&& [_, p] : tracker) {
        if (p.can_vote) {           // fsm.cc:1055
            if (p.id == leader_id) {
                // self-ack (fsm.cc:1056-1057)
                result.sent_to.push_back(p.id);
            } else {
                // send_to (fsm.cc:1058-1059)
                result.sent_to.push_back(p.id);
            }
        }
    }
    return result;
}

// ============================================================
// Test
// ============================================================

static int test_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "  FAIL: %s\n    at %s:%d\n", msg, __FILE__, __LINE__); \
        test_failures++; \
    } else { \
        fprintf(stderr, "  PASS: %s\n", msg); \
    } \
} while(0)

int main() {
    server_id A{1}, B{2}, C{3};

    fprintf(stderr, "=== Bug Reproduction: Read Barrier Stall During Voter Demotion ===\n\n");

    // -------------------------------------------------------
    // Setup: 3-node cluster {A, B, C}, all voters
    // Operation: Demote C from voter to non-voter
    // Joint config: current = {A(v), B(v), C(nv)}, previous = {A(v), B(v), C(v)}
    // -------------------------------------------------------

    configuration joint_config;
    joint_config.current = {
        config_member{A, is_voter_yes},
        config_member{B, is_voter_yes},
        config_member{C, is_voter_no},    // C demoted to non-voter in new config
    };
    joint_config.previous = {
        config_member{A, is_voter_yes},
        config_member{B, is_voter_yes},
        config_member{C, is_voter_yes},   // C was voter in old config
    };

    fprintf(stderr, "--- configuration::can_vote (raft.hh:206-217, CORRECT reference) ---\n");
    fprintf(stderr, "  A: can_vote = %s\n", joint_config.can_vote_correct(A) ? "yes" : "no");
    fprintf(stderr, "  B: can_vote = %s\n", joint_config.can_vote_correct(B) ? "yes" : "no");
    fprintf(stderr, "  C: can_vote = %s\n", joint_config.can_vote_correct(C) ? "yes" : "no");
    CHECK(joint_config.can_vote_correct(C) == is_voter_yes,
          "configuration::can_vote(C) == yes (ORs current=no with previous=yes)");

    // -------------------------------------------------------
    // Test 1: BUGGY tracker::set_configuration (tracker.cc:101-133)
    // -------------------------------------------------------
    fprintf(stderr, "\n--- BUGGY tracker::set_configuration (tracker.cc:118 skips can_vote) ---\n");
    {
        tracker_buggy tracker;
        tracker.set_configuration(joint_config, 1);

        auto it_A = tracker.find(A);
        auto it_B = tracker.find(B);
        auto it_C = tracker.find(C);

        CHECK(it_A != tracker.end(), "A is in progress map");
        CHECK(it_B != tracker.end(), "B is in progress map");
        CHECK(it_C != tracker.end(), "C is in progress map");

        fprintf(stderr, "  A: follower_progress.can_vote = %s\n", it_A->second.can_vote ? "yes" : "no");
        fprintf(stderr, "  B: follower_progress.can_vote = %s\n", it_B->second.can_vote ? "yes" : "no");
        fprintf(stderr, "  C: follower_progress.can_vote = %s  <-- BUG! Should be yes (voter in previous)\n",
                it_C->second.can_vote ? "yes" : "no");

        CHECK(it_C->second.can_vote == is_voter_no,
              "BUG CONFIRMED: follower_progress.can_vote(C) == no (only from current config)");

        // Check _previous_voters correctly includes C
        CHECK(tracker._previous_voters.count(C) == 1,
              "_previous_voters includes C (correct — C is voter in previous)");

        // Simulate broadcast_read_quorum
        fprintf(stderr, "\n  Simulating broadcast_read_quorum (fsm.cc:1052-1060)...\n");
        auto result = simulate_broadcast_read_quorum(tracker, A);
        fprintf(stderr, "  Messages sent to: ");
        for (const auto& s : result.sent_to)
            fprintf(stderr, "%c ", "?ABC"[s.id]);
        fprintf(stderr, "\n");

        CHECK(!result.sent_to_server(C),
              "BUG CONFIRMED: broadcast_read_quorum SKIPS C (can_vote=false)");
        CHECK(result.sent_to.size() == 2,
              "Only 2 servers receive read_quorum (A self-ack + B)");

        // Show the consequence: if B is slow, read barrier stalls
        fprintf(stderr, "\n  Consequence: previous-config quorum requires 2/3 (majority of {A,B,C})\n");
        fprintf(stderr, "  Only A (self-ack) and B can respond. If B is slow/partitioned:\n");
        fprintf(stderr, "  -> Only A's ack (1/3) — STALL! Read barrier can never complete.\n");
        fprintf(stderr, "  Without the bug, C also receives request: A+C = 2/3 -> quorum OK.\n");
    }

    // -------------------------------------------------------
    // Test 2: FIXED tracker::set_configuration
    // -------------------------------------------------------
    fprintf(stderr, "\n--- FIXED tracker::set_configuration (OR can_vote at line 118) ---\n");
    {
        tracker_fixed tracker;
        tracker.set_configuration(joint_config, 1);

        auto it_C = tracker.find(C);
        CHECK(it_C != tracker.end(), "C is in progress map");
        fprintf(stderr, "  C: follower_progress.can_vote = %s  <-- CORRECT\n",
                it_C->second.can_vote ? "yes" : "no");

        CHECK(it_C->second.can_vote == is_voter_yes,
              "FIX VERIFIED: follower_progress.can_vote(C) == yes (ORed from both configs)");

        auto result = simulate_broadcast_read_quorum(tracker, A);
        CHECK(result.sent_to_server(C),
              "FIX VERIFIED: broadcast_read_quorum sends to C");
        CHECK(result.sent_to.size() == 3,
              "All 3 servers receive read_quorum (A + B + C)");
    }

    // -------------------------------------------------------
    // Test 3: Larger cluster — 5 nodes, demote 2
    // -------------------------------------------------------
    fprintf(stderr, "\n--- Larger cluster: 5 nodes, demote D and E ---\n");
    {
        server_id D{4}, E{5};
        configuration cfg5;
        cfg5.current = {
            config_member{A, is_voter_yes},
            config_member{B, is_voter_yes},
            config_member{C, is_voter_yes},
            config_member{D, is_voter_no},   // demoted
            config_member{E, is_voter_no},   // demoted
        };
        cfg5.previous = {
            config_member{A, is_voter_yes},
            config_member{B, is_voter_yes},
            config_member{C, is_voter_yes},
            config_member{D, is_voter_yes},  // was voter
            config_member{E, is_voter_yes},  // was voter
        };

        tracker_buggy buggy;
        buggy.set_configuration(cfg5, 1);
        auto buggy_result = simulate_broadcast_read_quorum(buggy, A);

        tracker_fixed fixed;
        fixed.set_configuration(cfg5, 1);
        auto fixed_result = simulate_broadcast_read_quorum(fixed, A);

        fprintf(stderr, "  Buggy: %zu servers receive read_quorum (expected 5)\n", buggy_result.sent_to.size());
        fprintf(stderr, "  Fixed: %zu servers receive read_quorum (expected 5)\n", fixed_result.sent_to.size());

        CHECK(buggy_result.sent_to.size() == 3,
              "BUG: only 3/5 servers receive read_quorum (D,E skipped)");
        CHECK(fixed_result.sent_to.size() == 5,
              "FIX: all 5 servers receive read_quorum");

        fprintf(stderr, "  Previous-config quorum: need 3/5 majority\n");
        fprintf(stderr, "  Buggy: only A,B,C can respond -> tolerates 0 failures (need all 3)\n");
        fprintf(stderr, "  Fixed: A,B,C,D,E can respond -> tolerates 2 failures (normal)\n");
    }

    // -------------------------------------------------------
    // Summary
    // -------------------------------------------------------
    fprintf(stderr, "\n=== SUMMARY ===\n");
    if (test_failures == 0) {
        fprintf(stderr, "All checks passed. Bug reproduced and fix verified.\n");
        return 0;
    } else {
        fprintf(stderr, "%d check(s) FAILED.\n", test_failures);
        return 1;
    }
}

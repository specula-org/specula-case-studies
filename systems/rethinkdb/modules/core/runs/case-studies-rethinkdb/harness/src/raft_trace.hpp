// Copyright (c) 2024 Specula Project Authors. All rights reserved.
// Trace instrumentation for TLA+ trace validation of RethinkDB Raft.
//
// This header provides NDJSON trace emission for the raft_core.tcc template.
// Enable with: -DRETHINKDB_TLA_TRACE
// Set trace file via: RAFT_TRACE_FILE=path.ndjson environment variable.

#ifndef RAFT_TRACE_HPP_
#define RAFT_TRACE_HPP_

#ifdef RETHINKDB_TLA_TRACE

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <map>
#include <string>
#include <inttypes.h>

// raft_member_id_t and uuid_u are available since this is included from
// raft_core.tcc which already includes raft_core.hpp and containers/uuid.hpp.

class raft_trace_writer_t {
public:
    static raft_trace_writer_t &get() {
        static raft_trace_writer_t instance;
        return instance;
    }

    void init(const char *path) {
        if (fp_ != nullptr) return;
        fp_ = std::fopen(path, "w");
    }

    void init_from_env() {
        const char *path = std::getenv("RAFT_TRACE_FILE");
        if (path != nullptr && path[0] != '\0') {
            init(path);
        }
    }

    void shutdown() {
        if (fp_ != nullptr) {
            std::fflush(fp_);
            std::fclose(fp_);
            fp_ = nullptr;
        }
    }

    bool enabled() const { return fp_ != nullptr; }

    std::string register_server(const raft_member_id_t &mid) {
        auto it = server_map_.find(mid.uuid);
        if (it != server_map_.end()) {
            return it->second;
        }
        char buf[16];
        std::snprintf(buf, sizeof(buf), "s%d", next_id_++);
        std::string name(buf);
        server_map_[mid.uuid] = name;
        return name;
    }

    std::string nid(const raft_member_id_t &mid) const {
        auto it = server_map_.find(mid.uuid);
        if (it != server_map_.end()) {
            return it->second;
        }
        return "unknown";
    }

    // Returns "\"nil\"" for nil member IDs, or "\"s1\"" etc.
    // Uses string "nil" to match TLA+ Nil constant.
    std::string nid_or_null(const raft_member_id_t &mid) const {
        if (mid.is_nil()) return "\"nil\"";
        return "\"" + nid(mid) + "\"";
    }

    // Use microseconds relative to first event to keep numbers small
    // (TLA+ JSON parser can overflow on very large integers)
    int64_t now_us() const {
        static auto base = std::chrono::steady_clock::now();
        return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - base).count();
    }

    void emit(const std::string &json_line) {
        if (fp_ == nullptr) return;
        std::fputs(json_line.c_str(), fp_);
        std::fputc('\n', fp_);
        std::fflush(fp_);
    }

private:
    raft_trace_writer_t() : fp_(nullptr), next_id_(1) {}
    ~raft_trace_writer_t() { shutdown(); }

    raft_trace_writer_t(const raft_trace_writer_t &) = delete;
    raft_trace_writer_t &operator=(const raft_trace_writer_t &) = delete;

    FILE *fp_;
    int next_id_;
    std::map<uuid_u, std::string> server_map_;
};

// ============================================================================
// Emit helpers — each builds a complete JSON line and calls emit()
// State includes snapshotIndex + snapshotTerm per instrumentation-spec §3.9
// ============================================================================

// Node event with full state snapshot (timeout, client_request, etc.)
inline void raft_trace_emit_node(
        const char *event_name,
        const raft_member_id_t &node_id,
        uint64_t current_term,
        const char *role,
        uint64_t commit_index,
        uint64_t last_log_index,
        uint64_t last_log_term,
        const raft_member_id_t &voted_for,
        uint64_t snapshot_index,
        uint64_t snapshot_term,
        const char *extra = "") {
    auto &tw = raft_trace_writer_t::get();
    if (!tw.enabled()) return;
    char buf[2048];
    std::snprintf(buf, sizeof(buf),
        "{\"tag\":\"raft\",\"event\":\"%s\",\"node\":\"%s\",\"ts\":%" PRId64
        ",\"state\":{\"currentTerm\":%" PRIu64 ",\"role\":\"%s\""
        ",\"commitIndex\":%" PRIu64 ",\"lastLogIndex\":%" PRIu64
        ",\"lastLogTerm\":%" PRIu64 ",\"votedFor\":%s"
        ",\"snapshotIndex\":%" PRIu64 ",\"snapshotTerm\":%" PRIu64 "}%s}",
        event_name,
        tw.nid(node_id).c_str(),
        tw.now_us(),
        current_term, role, commit_index,
        last_log_index, last_log_term,
        tw.nid_or_null(voted_for).c_str(),
        snapshot_index, snapshot_term,
        extra);
    tw.emit(buf);
}

// Recv event: node received message from another node, with full state
inline void raft_trace_emit_recv(
        const char *event_name,
        const raft_member_id_t &node_id,
        const raft_member_id_t &from_id,
        uint64_t current_term,
        const char *role,
        uint64_t commit_index,
        uint64_t last_log_index,
        uint64_t last_log_term,
        const raft_member_id_t &voted_for,
        uint64_t snapshot_index,
        uint64_t snapshot_term,
        const char *extra = "") {
    auto &tw = raft_trace_writer_t::get();
    if (!tw.enabled()) return;
    char buf[2048];
    std::snprintf(buf, sizeof(buf),
        "{\"tag\":\"raft\",\"event\":\"%s\",\"node\":\"%s\""
        ",\"from\":\"%s\",\"ts\":%" PRId64
        ",\"state\":{\"currentTerm\":%" PRIu64 ",\"role\":\"%s\""
        ",\"commitIndex\":%" PRIu64 ",\"lastLogIndex\":%" PRIu64
        ",\"lastLogTerm\":%" PRIu64 ",\"votedFor\":%s"
        ",\"snapshotIndex\":%" PRIu64 ",\"snapshotTerm\":%" PRIu64 "}%s}",
        event_name,
        tw.nid(node_id).c_str(),
        tw.nid(from_id).c_str(),
        tw.now_us(),
        current_term, role, commit_index,
        last_log_index, last_log_term,
        tw.nid_or_null(voted_for).c_str(),
        snapshot_index, snapshot_term,
        extra);
    tw.emit(buf);
}

// Send event: from -> to (no state snapshot needed)
inline void raft_trace_emit_send(
        const char *event_name,
        const raft_member_id_t &from_id,
        const raft_member_id_t &to_id,
        const char *extra = "") {
    auto &tw = raft_trace_writer_t::get();
    if (!tw.enabled()) return;
    char buf[1024];
    std::snprintf(buf, sizeof(buf),
        "{\"tag\":\"raft\",\"event\":\"%s\",\"from\":\"%s\""
        ",\"to\":\"%s\",\"ts\":%" PRId64 "%s}",
        event_name,
        tw.nid(from_id).c_str(),
        tw.nid(to_id).c_str(),
        tw.now_us(),
        extra);
    tw.emit(buf);
}

// Bare event: node only, no state (crash, step_down_config_change)
inline void raft_trace_emit_bare(
        const char *event_name,
        const raft_member_id_t &node_id,
        const char *extra = "") {
    auto &tw = raft_trace_writer_t::get();
    if (!tw.enabled()) return;
    char buf[512];
    std::snprintf(buf, sizeof(buf),
        "{\"tag\":\"raft\",\"event\":\"%s\",\"node\":\"%s\""
        ",\"ts\":%" PRId64 "%s}",
        event_name,
        tw.nid(node_id).c_str(),
        tw.now_us(),
        extra);
    tw.emit(buf);
}

// Convenience macro for full state capture from raft_member_t context.
// Usage: RAFT_TRACE_STATE_ARGS expands to the 8 arguments after event_name/node_id.
#define RAFT_TRACE_STATE_ARGS \
    ps().current_term, RAFT_TRACE_ROLE, \
    ps().commit_index, ps().log.get_latest_index(), \
    ps().log.get_entry_term(ps().log.get_latest_index()), \
    ps().voted_for, \
    static_cast<uint64_t>(ps().log.prev_index), \
    static_cast<uint64_t>(ps().log.prev_term)

#endif // RETHINKDB_TLA_TRACE

#endif // RAFT_TRACE_HPP_

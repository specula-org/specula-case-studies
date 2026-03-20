/*
 * TLA+ Trace Emission Module for ScyllaDB Raft
 *
 * Header-only trace logger. Activated by env var SCYLLA_TLA_TRACE=<path>.
 * Emits NDJSON lines matching the Trace.tla event schema.
 *
 * Usage: #include this header in fsm.cc, call tla_trace::init() at startup,
 * and tla_trace::emit_*() at each instrumentation point.
 */
#pragma once

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <chrono>
#include <mutex>
#include <cinttypes>

namespace raft {
namespace tla_trace {

// ---------------------------------------------------------------------------
// TraceWriter: file output singleton
// ---------------------------------------------------------------------------
struct TraceWriter {
    FILE* fp = nullptr;
    std::mutex mu;

    static TraceWriter& instance() {
        static TraceWriter w;
        return w;
    }

    bool open(const char* path) {
        std::lock_guard<std::mutex> lk(mu);
        if (fp) return true;  // already open
        fp = fopen(path, "w");
        return fp != nullptr;
    }

    void write(const std::string& line) {
        std::lock_guard<std::mutex> lk(mu);
        if (!fp) return;
        fwrite(line.data(), 1, line.size(), fp);
        fputc('\n', fp);
        fflush(fp);
    }

    void close() {
        std::lock_guard<std::mutex> lk(mu);
        if (fp) { fclose(fp); fp = nullptr; }
    }

    bool is_open() const { return fp != nullptr; }
};

// ---------------------------------------------------------------------------
// ServerMap: UUID-based server_id -> "s1", "s2", ...
// ---------------------------------------------------------------------------
struct ServerMap {
    std::unordered_map<uint64_t, std::string> map;
    int next_id = 1;
    std::mutex mu;

    static ServerMap& instance() {
        static ServerMap m;
        return m;
    }

    // Register a server, return its short name.
    // Uses low bits of UUID as key (sufficient for test UUIDs).
    std::string register_server(uint64_t uuid_low) {
        std::lock_guard<std::mutex> lk(mu);
        auto it = map.find(uuid_low);
        if (it != map.end()) return it->second;
        char buf[16];
        snprintf(buf, sizeof(buf), "s%d", next_id++);
        map[uuid_low] = buf;
        return buf;
    }

    std::string lookup(uint64_t uuid_low) {
        std::lock_guard<std::mutex> lk(mu);
        auto it = map.find(uuid_low);
        if (it != map.end()) return it->second;
        // Auto-register on first encounter
        char buf[16];
        snprintf(buf, sizeof(buf), "s%d", next_id++);
        map[uuid_low] = buf;
        return buf;
    }

    void reset() {
        std::lock_guard<std::mutex> lk(mu);
        map.clear();
        next_id = 1;
    }
};

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------
inline bool g_enabled = false;

inline bool enabled() { return g_enabled; }

inline void init() {
    const char* path = std::getenv("SCYLLA_TLA_TRACE");
    if (!path || path[0] == '\0') return;
    if (TraceWriter::instance().open(path)) {
        g_enabled = true;
    }
}

inline void shutdown() {
    TraceWriter::instance().close();
    ServerMap::instance().reset();
    g_enabled = false;
}

inline int64_t now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

// ---------------------------------------------------------------------------
// JSON builder helpers (manual, no external deps)
// ---------------------------------------------------------------------------
inline void append_num(std::string& out, int64_t v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%" PRId64, v);
    out += buf;
}

inline void append_str(std::string& out, const std::string& v) {
    out += '"';
    out += v;
    out += '"';
}

// State block: {"term":N,"role":"...","commitIndex":N,"lastLogIndex":N,"lastLogTerm":N}
inline void append_state(std::string& out, int64_t term, const char* role,
                          int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    out += "\"state\":{\"term\":";
    append_num(out, term);
    out += ",\"role\":\"";
    out += role;
    out += "\",\"commitIndex\":";
    append_num(out, commitIdx);
    out += ",\"lastLogIndex\":";
    append_num(out, lastLogIdx);
    out += ",\"lastLogTerm\":";
    append_num(out, lastLogTerm);
    out += "}";
}

// Envelope: {"tag":"trace","ts":"<ns>","event":{...}}
inline std::string begin_event(const char* name, const std::string& nid) {
    std::string out;
    out.reserve(512);
    out += "{\"tag\":\"trace\",\"ts\":\"";
    append_num(out, now_ns());
    out += "\",\"event\":{\"name\":\"";
    out += name;
    out += "\",\"nid\":\"";
    out += nid;
    out += "\"";
    return out;
}

inline void finish_event(std::string& out) {
    out += "}}";
    TraceWriter::instance().write(out);
}

// ---------------------------------------------------------------------------
// Emit functions — one per instrumentation point
// ---------------------------------------------------------------------------

// Timeout: server starts election
inline void emit_timeout(uint64_t nid_low, int64_t term, const char* role,
                          int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("Timeout", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    finish_event(out);
}

// BecomeLeader
inline void emit_become_leader(uint64_t nid_low, int64_t term, const char* role,
                                int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("BecomeLeader", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    finish_event(out);
}

// ClientRequest
inline void emit_client_request(uint64_t nid_low, int64_t term, const char* role,
                                 int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("ClientRequest", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    finish_event(out);
}

// AppendEntries: leader sends to follower
inline void emit_append_entries(uint64_t from_low, uint64_t to_low,
                                 int64_t term, const char* role,
                                 int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                 int64_t msg_term, int64_t prevLogIdx, int64_t prevLogTerm,
                                 int64_t numEntries, int64_t leaderCommitIdx) {
    auto& sm = ServerMap::instance();
    auto from = sm.lookup(from_low);
    auto to = sm.lookup(to_low);
    auto out = begin_event("AppendEntries", from);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\",\"to\":\"";
    out += to;
    out += "\",\"term\":";
    append_num(out, msg_term);
    out += ",\"prevLogIdx\":";
    append_num(out, prevLogIdx);
    out += ",\"prevLogTerm\":";
    append_num(out, prevLogTerm);
    out += ",\"numEntries\":";
    append_num(out, numEntries);
    out += ",\"leaderCommitIdx\":";
    append_num(out, leaderCommitIdx);
    out += "}";
    finish_event(out);
}

// HandleAppendEntriesRequest: follower processes append
inline void emit_handle_ae_request(uint64_t nid_low, uint64_t from_low,
                                    int64_t term, const char* role,
                                    int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    auto& sm = ServerMap::instance();
    auto nid = sm.lookup(nid_low);
    auto from = sm.lookup(from_low);
    auto out = begin_event("HandleAppendEntriesRequest", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\"}";
    finish_event(out);
}

// HandleAppendEntriesResponse: leader processes reply
inline void emit_handle_ae_response(uint64_t nid_low, uint64_t from_low,
                                     int64_t term, const char* role,
                                     int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                     bool success, int64_t matchIdx) {
    auto& sm = ServerMap::instance();
    auto nid = sm.lookup(nid_low);
    auto from = sm.lookup(from_low);
    auto out = begin_event("HandleAppendEntriesResponse", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\",\"success\":";
    out += success ? "true" : "false";
    out += ",\"matchIdx\":";
    append_num(out, matchIdx);
    out += "}";
    finish_event(out);
}

// HandleRequestVoteRequest
inline void emit_handle_rv_request(uint64_t nid_low, uint64_t from_low,
                                    int64_t term, const char* role,
                                    int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                    bool voteGranted) {
    auto& sm = ServerMap::instance();
    auto nid = sm.lookup(nid_low);
    auto from = sm.lookup(from_low);
    auto out = begin_event("HandleRequestVoteRequest", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\",\"voteGranted\":";
    out += voteGranted ? "true" : "false";
    out += "}";
    finish_event(out);
}

// HandleRequestVoteResponse
inline void emit_handle_rv_response(uint64_t nid_low, uint64_t from_low,
                                     int64_t term, const char* role,
                                     int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                     bool voteGranted) {
    auto& sm = ServerMap::instance();
    auto nid = sm.lookup(nid_low);
    auto from = sm.lookup(from_low);
    auto out = begin_event("HandleRequestVoteResponse", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\",\"voteGranted\":";
    out += voteGranted ? "true" : "false";
    out += "}";
    finish_event(out);
}

// MaybeCommit
inline void emit_maybe_commit(uint64_t nid_low, int64_t term, const char* role,
                               int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("MaybeCommit", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    finish_event(out);
}

// BroadcastReadQuorum
inline void emit_broadcast_read_quorum(uint64_t nid_low, int64_t term, const char* role,
                                        int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                        int64_t readId) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("BroadcastReadQuorum", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"readId\":";
    append_num(out, readId);
    finish_event(out);
}

// HandleReadQuorumRequest
inline void emit_handle_rq_request(uint64_t nid_low, uint64_t from_low,
                                    int64_t term, const char* role,
                                    int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                    int64_t readId) {
    auto& sm = ServerMap::instance();
    auto nid = sm.lookup(nid_low);
    auto from = sm.lookup(from_low);
    auto out = begin_event("HandleReadQuorumRequest", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\",\"readId\":";
    append_num(out, readId);
    out += "}";
    finish_event(out);
}

// HandleReadQuorumResponse
inline void emit_handle_rq_response(uint64_t nid_low, uint64_t from_low,
                                     int64_t term, const char* role,
                                     int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                     int64_t readId, int64_t maxReadIdWithQuorum) {
    auto& sm = ServerMap::instance();
    auto nid = sm.lookup(nid_low);
    auto from = sm.lookup(from_low);
    auto out = begin_event("HandleReadQuorumResponse", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\",\"readId\":";
    append_num(out, readId);
    out += ",\"maxReadIdWithQuorum\":";
    append_num(out, maxReadIdWithQuorum);
    out += "}";
    finish_event(out);
}

// SendInstallSnapshot
inline void emit_send_install_snapshot(uint64_t from_low, uint64_t to_low,
                                        int64_t term, const char* role,
                                        int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                        int64_t snapshotIdx, int64_t snapshotTerm) {
    auto& sm = ServerMap::instance();
    auto from = sm.lookup(from_low);
    auto to = sm.lookup(to_low);
    auto out = begin_event("SendInstallSnapshot", from);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\",\"to\":\"";
    out += to;
    out += "\",\"snapshotIdx\":";
    append_num(out, snapshotIdx);
    out += ",\"snapshotTerm\":";
    append_num(out, snapshotTerm);
    out += "}";
    finish_event(out);
}

// HandleInstallSnapshot
inline void emit_handle_install_snapshot(uint64_t nid_low, uint64_t from_low,
                                          int64_t term, const char* role,
                                          int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    auto& sm = ServerMap::instance();
    auto nid = sm.lookup(nid_low);
    auto from = sm.lookup(from_low);
    auto out = begin_event("HandleInstallSnapshot", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"msg\":{\"from\":\"";
    out += from;
    out += "\"}";
    finish_event(out);
}

// TakeLocalSnapshot
inline void emit_take_local_snapshot(uint64_t nid_low, int64_t term, const char* role,
                                      int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                      int64_t snapshotIdx, int64_t snapshotTerm) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("TakeLocalSnapshot", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"snapshotIdx\":";
    append_num(out, snapshotIdx);
    out += ",\"snapshotTerm\":";
    append_num(out, snapshotTerm);
    finish_event(out);
}

// Crash
inline void emit_crash(uint64_t nid_low, int64_t term, const char* role,
                        int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("Crash", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    finish_event(out);
}

// UpdateTerm
inline void emit_update_term(uint64_t nid_low, int64_t term, const char* role,
                              int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("UpdateTerm", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    finish_event(out);
}

// ProposeConfigChange
inline void emit_propose_config_change(uint64_t nid_low, int64_t term, const char* role,
                                        int64_t commitIdx, int64_t lastLogIdx, int64_t lastLogTerm,
                                        const std::string& newVotersJson) {
    auto nid = ServerMap::instance().lookup(nid_low);
    auto out = begin_event("ProposeConfigChange", nid);
    out += ",";
    append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
    out += ",\"newVoters\":";
    out += newVotersJson;  // pre-formatted JSON array like ["s1","s2","s3"]
    finish_event(out);
}

// Emit config line (first line of trace)
inline void emit_config(const std::string& serversJson) {
    std::string out;
    out.reserve(256);
    out += "{\"tag\":\"config\",\"ts\":\"";
    append_num(out, now_ns());
    out += "\",\"config\":{\"servers\":";
    out += serversJson;
    out += "}}";
    TraceWriter::instance().write(out);
}

} // namespace tla_trace
} // namespace raft

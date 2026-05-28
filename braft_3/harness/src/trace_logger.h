// Copyright (c) 2024 Specula Project Authors. All rights reserved.
// Trace instrumentation for TLA+ trace validation (braft_3).
// Guarded by BRAFT_ENABLE_TRACE; zero-cost when disabled.

#ifndef BRAFT_TRACE_LOGGER_H
#define BRAFT_TRACE_LOGGER_H

#include <string>
#include <map>
#include <mutex>
#include <cstdio>
#include <cstdint>

#include "braft/configuration.h"
#include "braft/raft.h"

namespace braft {

class NodeImpl;
class BallotBox;
class LogManager;

// --------------------------------------------------------------------------
// Server ID Mapping
// --------------------------------------------------------------------------
// Maps braft PeerId (ip:port:idx) to stable short IDs ("s1", "s2", "s3").
// Registration order determines the ID, so the harness must register peers
// in a deterministic order at startup.

class TraceServerMap {
public:
    static TraceServerMap& instance();

    // Register a peer and return its short ID. Thread-safe and idempotent.
    std::string register_peer(const PeerId& peer);

    // Look up a peer's short ID. Returns "" if not registered.
    std::string lookup(const PeerId& peer) const;

    // Reset all mappings (for testing).
    void reset();

private:
    TraceServerMap() : _next_id(1) {}
    mutable std::mutex _mu;
    std::map<std::string, std::string> _map;  // peer.to_string() -> "sN"
    int _next_id;
};

// --------------------------------------------------------------------------
// Trace State Snapshot
// --------------------------------------------------------------------------
// Captures the core state fields validated by Trace.tla.
// Caller must hold the appropriate locks before calling capture().

struct TraceState {
    int64_t term;
    const char* role;       // "Follower", "Candidate", "Leader"
    std::string votedFor;   // Short server ID or "" for Nil
    int64_t commitIndex;
    int64_t lastLogIndex;
    int64_t lastLogTerm;

    // Family-3/4/5 extras: filled when capture() can read them.
    bool has_extras;
    const char* nodeRole;   // "Voter" | "Witness"
    int64_t lastSnapshotIndex;
    int64_t lastSnapshotTerm;
    int64_t virtualFirstLog;
    int64_t physicalFirstLog;
    const char* installingSnapshot;  // "none" | "copying" | "loading"
    bool leaderLeaseValid;
    bool followerLease;

    TraceState();

    // Capture full state from a NodeImpl. Caller must hold _mutex.
    static TraceState capture(const NodeImpl* node);

    // Capture weak state: only term and role. Use from replicator bthreads
    // where full state is unavailable.
    static TraceState capture_weak(int64_t term, State role);

    // Specialized capture for AdvanceCommitIndex (term + role + commitIndex).
    static TraceState capture_commit(int64_t term, State role, int64_t ci);
};

// --------------------------------------------------------------------------
// Trace Event Builder
// --------------------------------------------------------------------------
//
// Usage:
//   TraceEvent("HandlePreVoteRequest")
//       .node(server_id)
//       .state(snap)
//       .msg_field("from", from_id)
//       .msg_field("to", to_id)
//       .msg_field("term", term)
//       .msg_field("granted", granted)
//       .emit();

class TraceEvent {
public:
    explicit TraceEvent(const char* name);

    TraceEvent& node(const std::string& nid);
    TraceEvent& state(const TraceState& s);

    TraceEvent& msg_field(const char* key, const std::string& val);
    TraceEvent& msg_field(const char* key, int64_t val);
    TraceEvent& msg_field(const char* key, bool val);

    void emit();

private:
    const char* _name;
    std::string _nid;
    TraceState _state;
    bool _has_state;

    struct MsgField {
        const char* key;
        std::string json_val;
    };
    MsgField _msg_fields[12];
    int _msg_count;
};

// --------------------------------------------------------------------------
// Trace File Writer
// --------------------------------------------------------------------------

class TraceWriter {
public:
    static TraceWriter& instance();

    int open(const std::string& path);
    void write(const std::string& line);
    void close();

    bool is_open() const { return _fp != nullptr; }

private:
    TraceWriter() : _fp(nullptr) {}
    ~TraceWriter() { close(); }
    std::mutex _mu;
    FILE* _fp;
};

// Map braft State enum to TLA+ role string.
inline const char* trace_role_str(State st) {
    switch (st) {
    case STATE_LEADER:       return "Leader";
    case STATE_TRANSFERRING: return "Leader";  // still leader in spec
    case STATE_CANDIDATE:    return "Candidate";
    case STATE_FOLLOWER:     return "Follower";
    default:                 return "Follower";
    }
}

bool trace_is_enabled();

// Call once per node during init. Registers self and all peers in the
// configuration, and opens the trace output file (first call only).
void trace_init(const PeerId& self, const Configuration& conf);

// Force the trace file path / enable flag at runtime. Used by tests.
void trace_set_file(const std::string& path);
void trace_set_enabled(bool enabled);

// --------------------------------------------------------------------------
// Macros for guarded instrumentation
// --------------------------------------------------------------------------
#ifdef BRAFT_ENABLE_TRACE

#define BRAFT_TRACE_IF_ENABLED(expr) \
    do { if (::braft::trace_is_enabled()) { expr; } } while (0)

#else

#define BRAFT_TRACE_IF_ENABLED(expr) do {} while (0)

#endif  // BRAFT_ENABLE_TRACE

}  // namespace braft

#endif  // BRAFT_TRACE_LOGGER_H

// Licensed under the Apache License, Version 2.0.
// TLA+ trace emission module for Kudu Raft consensus.
// Produces NDJSON trace lines for trace validation against Trace.tla.
#pragma once

#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace kudu {
namespace consensus {
namespace tla_trace {

// ---------------------------------------------------------------------------
// TraceServerMap — maps implementation UUIDs to short TLA+ names (s1, s2, …)
// Thread-safe singleton.
// ---------------------------------------------------------------------------
class TraceServerMap {
 public:
  static TraceServerMap& instance();

  // Register a peer; returns assigned short name. Idempotent.
  std::string Register(const std::string& uuid);

  // Lookup an already-registered peer. Returns "" if not found.
  std::string Lookup(const std::string& uuid) const;

  void Reset();

 private:
  TraceServerMap() : next_id_(1) {}
  mutable std::mutex mu_;
  std::map<std::string, std::string> map_;
  int next_id_;
};

// Shorthand: map a UUID to its short name (auto-registers if unknown).
std::string Nid(const std::string& uuid);

// ---------------------------------------------------------------------------
// TraceWriter — thread-safe NDJSON file writer (singleton)
// ---------------------------------------------------------------------------
class TraceWriter {
 public:
  static TraceWriter& instance();

  // Open trace file. Idempotent (won't re-open if already open).
  // Returns 0 on success.
  int Open(const std::string& path);

  void Write(const std::string& line);
  void Close();
  bool IsOpen() const;

 private:
  TraceWriter() : fp_(nullptr) {}
  mutable std::mutex mu_;
  FILE* fp_;
};

// ---------------------------------------------------------------------------
// TraceState — snapshot of a node's consensus state
// ---------------------------------------------------------------------------
struct TraceState {
  int64_t term = 0;
  std::string role;       // "Follower", "Candidate", "Leader"
  std::string votedFor;   // short server name or "" (nil)
  int64_t commitIndex = 0;
  int64_t lastLogIndex = 0;
  int64_t lastLogTerm = 0;
  bool is_weak = false;   // if true, only term+role are valid

  // Serialize to JSON object string (for embedding in event).
  std::string ToJson() const;
};

// ---------------------------------------------------------------------------
// TraceEvent — fluent builder for one NDJSON trace line
// ---------------------------------------------------------------------------
class TraceEvent {
 public:
  explicit TraceEvent(const char* name);

  TraceEvent& Node(const std::string& nid);
  TraceEvent& State(const TraceState& s);
  TraceEvent& MsgStr(const char* key, const std::string& val);
  TraceEvent& MsgInt(const char* key, int64_t val);
  TraceEvent& MsgBool(const char* key, bool val);

  // Write the NDJSON line to the trace file.
  void Emit();

 private:
  std::string name_;
  std::string nid_;
  TraceState state_;
  bool has_state_ = false;
  std::string msg_fields_;  // accumulated JSON fragments for msg object
  bool has_msg_ = false;
};

// ---------------------------------------------------------------------------
// Initialization helpers
// ---------------------------------------------------------------------------

// Check if tracing is enabled (KUDU_TRACE_FILE env var set).
bool IsEnabled();

// Initialize tracing: register self + peers, open trace file.
// Call once per node at startup.
void Init(const std::string& self_uuid,
          const std::vector<std::string>& peer_uuids);

// Role string conversion: RaftPeerPB::Role enum → "Follower"/"Candidate"/"Leader"
std::string RoleStr(int role_enum);

}  // namespace tla_trace
}  // namespace consensus
}  // namespace kudu

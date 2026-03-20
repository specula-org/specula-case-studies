/* Copyright (c) 2024 — TLA+ trace instrumentation for nebula raft.
 * Controlled by -DNEBULA_ENABLE_TRACE compile flag.
 */

#ifndef KVSTORE_RAFTEX_TRACE_LOGGER_H_
#define KVSTORE_RAFTEX_TRACE_LOGGER_H_

#ifdef NEBULA_ENABLE_TRACE

#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace nebula {
namespace raftex {
namespace trace {

// ---------------------------------------------------------------------------
// TraceServerMap — maps HostAddr strings to stable short IDs ("s1", "s2", …)
// ---------------------------------------------------------------------------
class TraceServerMap {
 public:
  static TraceServerMap& instance();

  // Register a peer and return its short ID. Thread-safe.
  std::string registerPeer(const std::string& hostPort);

  // Look up a peer that was already registered. Returns "" if unknown.
  std::string lookup(const std::string& hostPort) const;

 private:
  TraceServerMap() = default;
  mutable std::mutex mu_;
  std::unordered_map<std::string, std::string> map_;
  int nextId_{1};
};

// ---------------------------------------------------------------------------
// TraceState — snapshot of a node's raft state at one point in time
// ---------------------------------------------------------------------------
struct TraceState {
  int64_t term{0};
  std::string role;        // "Follower", "Candidate", "Leader"
  std::string votedFor;    // short server ID or "" for Nil
  int64_t commitIndex{0};
  int64_t lastLogIndex{0};
  int64_t lastLogTerm{0};
  bool isBlindFollower{false};
  bool commitInThisTerm{false};
};

// ---------------------------------------------------------------------------
// TraceEvent — builder for a single NDJSON trace line
// ---------------------------------------------------------------------------
class TraceEvent {
 public:
  explicit TraceEvent(const char* name);

  TraceEvent& node(const std::string& nid);
  TraceEvent& state(const TraceState& s);
  TraceEvent& msgField(const char* key, const std::string& val);
  TraceEvent& msgField(const char* key, int64_t val);
  TraceEvent& msgField(const char* key, bool val);

  void emit();

 private:
  const char* name_;
  std::string nid_;
  TraceState state_;
  bool hasState_{false};

  struct MsgField {
    const char* key;
    std::string sval;
    int64_t ival;
    bool bval;
    enum { STR, INT, BOOL } type;
  };
  MsgField msgFields_[12];
  int msgFieldCount_{0};
};

// ---------------------------------------------------------------------------
// TraceWriter — singleton file writer
// ---------------------------------------------------------------------------
class TraceWriter {
 public:
  static TraceWriter& instance();

  int open(const std::string& path);
  void write(const std::string& line);
  void close();
  bool isOpen() const;

 private:
  TraceWriter() = default;
  std::mutex mu_;
  FILE* fp_{nullptr};
};

// ---------------------------------------------------------------------------
// Global helpers
// ---------------------------------------------------------------------------
bool traceIsEnabled();
void traceInit(const std::string& selfAddr, const std::vector<std::string>& peerAddrs);

}  // namespace trace
}  // namespace raftex
}  // namespace nebula

#define NEBULA_TRACE_IF_ENABLED(expr) \
  do {                                \
    if (::nebula::raftex::trace::traceIsEnabled()) { expr; } \
  } while (0)

#else  // !NEBULA_ENABLE_TRACE

#define NEBULA_TRACE_IF_ENABLED(expr) do {} while (0)

#endif  // NEBULA_ENABLE_TRACE
#endif  // KVSTORE_RAFTEX_TRACE_LOGGER_H_

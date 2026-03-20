/* Copyright (c) 2024 — TLA+ trace instrumentation for nebula raft. */

#ifdef NEBULA_ENABLE_TRACE

#include "kvstore/raftex/trace_logger.h"

#include <chrono>
#include <cstdlib>
#include <cstring>

#include <gflags/gflags.h>

DEFINE_bool(nebula_trace_enabled, false, "Enable TLA+ trace instrumentation");
DEFINE_string(nebula_trace_file, "", "Output file for TLA+ trace (NDJSON)");

namespace nebula {
namespace raftex {
namespace trace {

// ===========================================================================
// TraceServerMap
// ===========================================================================

TraceServerMap& TraceServerMap::instance() {
  static TraceServerMap inst;
  return inst;
}

std::string TraceServerMap::registerPeer(const std::string& hostPort) {
  std::lock_guard<std::mutex> g(mu_);
  auto it = map_.find(hostPort);
  if (it != map_.end()) return it->second;
  std::string id = "s" + std::to_string(nextId_++);
  map_[hostPort] = id;
  return id;
}

std::string TraceServerMap::lookup(const std::string& hostPort) const {
  std::lock_guard<std::mutex> g(mu_);
  auto it = map_.find(hostPort);
  return it != map_.end() ? it->second : "";
}

// ===========================================================================
// TraceWriter
// ===========================================================================

TraceWriter& TraceWriter::instance() {
  static TraceWriter inst;
  return inst;
}

int TraceWriter::open(const std::string& path) {
  std::lock_guard<std::mutex> g(mu_);
  if (fp_) return 0;  // already open — prevent truncation on re-open
  fp_ = fopen(path.c_str(), "w");
  return fp_ ? 0 : -1;
}

void TraceWriter::write(const std::string& line) {
  std::lock_guard<std::mutex> g(mu_);
  if (!fp_) return;
  fputs(line.c_str(), fp_);
  fputc('\n', fp_);
  fflush(fp_);
}

void TraceWriter::close() {
  std::lock_guard<std::mutex> g(mu_);
  if (fp_) {
    fflush(fp_);
    fclose(fp_);
    fp_ = nullptr;
  }
}

bool TraceWriter::isOpen() const { return fp_ != nullptr; }

// ===========================================================================
// Timestamp helper
// ===========================================================================

static int64_t nowMonotonicMs() {
  auto now = std::chrono::steady_clock::now();
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             now.time_since_epoch())
      .count();
}

// ===========================================================================
// TraceEvent
// ===========================================================================

TraceEvent::TraceEvent(const char* name) : name_(name) {}

TraceEvent& TraceEvent::node(const std::string& nid) {
  nid_ = nid;
  return *this;
}

TraceEvent& TraceEvent::state(const TraceState& s) {
  state_ = s;
  hasState_ = true;
  return *this;
}

TraceEvent& TraceEvent::msgField(const char* key, const std::string& val) {
  if (msgFieldCount_ < 12) {
    auto& f = msgFields_[msgFieldCount_++];
    f.key = key;
    f.sval = val;
    f.type = MsgField::STR;
  }
  return *this;
}

TraceEvent& TraceEvent::msgField(const char* key, int64_t val) {
  if (msgFieldCount_ < 12) {
    auto& f = msgFields_[msgFieldCount_++];
    f.key = key;
    f.ival = val;
    f.type = MsgField::INT;
  }
  return *this;
}

TraceEvent& TraceEvent::msgField(const char* key, bool val) {
  if (msgFieldCount_ < 12) {
    auto& f = msgFields_[msgFieldCount_++];
    f.key = key;
    f.bval = val;
    f.type = MsgField::BOOL;
  }
  return *this;
}

// Escape a string for JSON (handles quotes and backslashes).
static std::string jsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 4);
  for (char c : s) {
    if (c == '"') out += "\\\"";
    else if (c == '\\') out += "\\\\";
    else out += c;
  }
  return out;
}

void TraceEvent::emit() {
  // Build the JSON line manually for zero external dependencies.
  char buf[2048];
  int pos = 0;

  pos += snprintf(buf + pos, sizeof(buf) - pos,
                  R"({"tag":"trace","ts":"%ld","event":{"name":"%s")",
                  nowMonotonicMs(), name_);

  if (!nid_.empty()) {
    pos += snprintf(buf + pos, sizeof(buf) - pos, R"(,"nid":"%s")", nid_.c_str());
  }

  if (hasState_) {
    std::string vf = state_.votedFor.empty() ? "" : jsonEscape(state_.votedFor);
    pos += snprintf(buf + pos, sizeof(buf) - pos,
                    R"(,"state":{"term":%ld,"role":"%s","votedFor":"%s")"
                    R"(,"commitIndex":%ld,"lastLogIndex":%ld,"lastLogTerm":%ld)"
                    R"(,"blindFollower":%s,"commitInThisTerm":%s})",
                    state_.term, state_.role.c_str(), vf.c_str(),
                    state_.commitIndex, state_.lastLogIndex, state_.lastLogTerm,
                    state_.isBlindFollower ? "true" : "false",
                    state_.commitInThisTerm ? "true" : "false");
  }

  if (msgFieldCount_ > 0) {
    pos += snprintf(buf + pos, sizeof(buf) - pos, R"(,"msg":{)");
    for (int i = 0; i < msgFieldCount_; ++i) {
      if (i > 0) buf[pos++] = ',';
      auto& f = msgFields_[i];
      switch (f.type) {
        case MsgField::STR:
          pos += snprintf(buf + pos, sizeof(buf) - pos,
                          R"("%s":"%s")", f.key, jsonEscape(f.sval).c_str());
          break;
        case MsgField::INT:
          pos += snprintf(buf + pos, sizeof(buf) - pos,
                          R"("%s":%ld)", f.key, f.ival);
          break;
        case MsgField::BOOL:
          pos += snprintf(buf + pos, sizeof(buf) - pos,
                          R"("%s":%s)", f.key, f.bval ? "true" : "false");
          break;
      }
    }
    buf[pos++] = '}';
  }

  // Close event and outer
  pos += snprintf(buf + pos, sizeof(buf) - pos, "}}");

  TraceWriter::instance().write(std::string(buf, pos));
}

// ===========================================================================
// Global helpers
// ===========================================================================

bool traceIsEnabled() {
  return FLAGS_nebula_trace_enabled && !FLAGS_nebula_trace_file.empty();
}

void traceInit(const std::string& selfAddr, const std::vector<std::string>& peerAddrs) {
  if (!traceIsEnabled()) return;

  // Also check env var override
  const char* envFile = std::getenv("NEBULA_TRACE_FILE");
  if (envFile && envFile[0] != '\0') {
    FLAGS_nebula_trace_file = envFile;
  }

  auto& sm = TraceServerMap::instance();
  sm.registerPeer(selfAddr);
  for (auto& p : peerAddrs) {
    sm.registerPeer(p);
  }

  TraceWriter::instance().open(FLAGS_nebula_trace_file);
}

}  // namespace trace
}  // namespace raftex
}  // namespace nebula

#endif  // NEBULA_ENABLE_TRACE

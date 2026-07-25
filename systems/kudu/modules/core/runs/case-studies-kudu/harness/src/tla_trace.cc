// Licensed under the Apache License, Version 2.0.
// TLA+ trace emission module for Kudu Raft consensus.

#include "kudu/consensus/tla_trace.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <vector>

namespace kudu {
namespace consensus {
namespace tla_trace {

// ---------------------------------------------------------------------------
// TraceServerMap
// ---------------------------------------------------------------------------

TraceServerMap& TraceServerMap::instance() {
  static TraceServerMap inst;
  return inst;
}

std::string TraceServerMap::Register(const std::string& uuid) {
  std::lock_guard<std::mutex> g(mu_);
  auto it = map_.find(uuid);
  if (it != map_.end()) return it->second;
  std::string name = "s" + std::to_string(next_id_++);
  map_[uuid] = name;
  return name;
}

std::string TraceServerMap::Lookup(const std::string& uuid) const {
  std::lock_guard<std::mutex> g(mu_);
  auto it = map_.find(uuid);
  return it != map_.end() ? it->second : "";
}

void TraceServerMap::Reset() {
  std::lock_guard<std::mutex> g(mu_);
  map_.clear();
  next_id_ = 1;
}

std::string Nid(const std::string& uuid) {
  return TraceServerMap::instance().Register(uuid);
}

// ---------------------------------------------------------------------------
// TraceWriter
// ---------------------------------------------------------------------------

TraceWriter& TraceWriter::instance() {
  static TraceWriter inst;
  return inst;
}

int TraceWriter::Open(const std::string& path) {
  std::lock_guard<std::mutex> g(mu_);
  if (fp_) return 0;  // idempotent
  fp_ = fopen(path.c_str(), "w");
  return fp_ ? 0 : -1;
}

void TraceWriter::Write(const std::string& line) {
  std::lock_guard<std::mutex> g(mu_);
  if (!fp_) return;
  fwrite(line.data(), 1, line.size(), fp_);
  fputc('\n', fp_);
  fflush(fp_);
}

void TraceWriter::Close() {
  std::lock_guard<std::mutex> g(mu_);
  if (fp_) {
    fclose(fp_);
    fp_ = nullptr;
  }
}

bool TraceWriter::IsOpen() const {
  std::lock_guard<std::mutex> g(mu_);
  return fp_ != nullptr;
}

// ---------------------------------------------------------------------------
// TraceState
// ---------------------------------------------------------------------------

static std::string JsonStr(const std::string& s) {
  // Simple JSON string escape (sufficient for short IDs).
  std::string out = "\"";
  for (char c : s) {
    if (c == '"') out += "\\\"";
    else if (c == '\\') out += "\\\\";
    else out += c;
  }
  out += '"';
  return out;
}

std::string TraceState::ToJson() const {
  std::ostringstream os;
  os << "{\"term\":" << term
     << ",\"role\":" << JsonStr(role);
  if (!is_weak) {
    os << ",\"votedFor\":" << JsonStr(votedFor)
       << ",\"commitIndex\":" << commitIndex
       << ",\"lastLogIndex\":" << lastLogIndex
       << ",\"lastLogTerm\":" << lastLogTerm;
  }
  os << "}";
  return os.str();
}

// ---------------------------------------------------------------------------
// TraceEvent
// ---------------------------------------------------------------------------

TraceEvent::TraceEvent(const char* name) : name_(name) {}

TraceEvent& TraceEvent::Node(const std::string& nid) {
  nid_ = nid;
  return *this;
}

TraceEvent& TraceEvent::State(const TraceState& s) {
  state_ = s;
  has_state_ = true;
  return *this;
}

TraceEvent& TraceEvent::MsgStr(const char* key, const std::string& val) {
  if (has_msg_) msg_fields_ += ",";
  msg_fields_ += JsonStr(key) + ":" + JsonStr(val);
  has_msg_ = true;
  return *this;
}

TraceEvent& TraceEvent::MsgInt(const char* key, int64_t val) {
  if (has_msg_) msg_fields_ += ",";
  msg_fields_ += JsonStr(key) + ":" + std::to_string(val);
  has_msg_ = true;
  return *this;
}

TraceEvent& TraceEvent::MsgBool(const char* key, bool val) {
  if (has_msg_) msg_fields_ += ",";
  msg_fields_ += JsonStr(key) + ":" + (val ? "true" : "false");
  has_msg_ = true;
  return *this;
}

void TraceEvent::Emit() {
  if (!TraceWriter::instance().IsOpen()) return;

  // Real timestamp: nanoseconds since epoch.
  auto now = std::chrono::steady_clock::now();
  auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
      now.time_since_epoch()).count();

  std::ostringstream os;
  os << "{\"tag\":\"trace\",\"ts\":\"" << ns << "\",\"event\":{"
     << "\"name\":" << JsonStr(name_)
     << ",\"nid\":" << JsonStr(nid_);
  if (has_state_) {
    os << ",\"state\":" << state_.ToJson();
  }
  if (has_msg_) {
    os << ",\"msg\":{" << msg_fields_ << "}";
  }
  os << "}}";

  TraceWriter::instance().Write(os.str());
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

bool IsEnabled() {
  const char* path = getenv("KUDU_TRACE_FILE");
  return path && path[0];
}

void Init(const std::string& self_uuid,
          const std::vector<std::string>& peer_uuids) {
  if (!IsEnabled()) return;

  auto& map = TraceServerMap::instance();
  map.Register(self_uuid);
  for (const auto& uuid : peer_uuids) {
    map.Register(uuid);
  }

  const char* path = getenv("KUDU_TRACE_FILE");
  if (path && path[0]) {
    TraceWriter::instance().Open(path);
  }
}

std::string RoleStr(int role_enum) {
  // RaftPeerPB::Role: FOLLOWER=0, LEADER=1, LEARNER=2, NON_PARTICIPANT=3, UNKNOWN_ROLE=7
  // We map LEADER→"Leader", FOLLOWER→"Follower", everything else→"Candidate"
  // Note: Kudu doesn't have an explicit CANDIDATE role enum. The Candidate state
  // is encoded as state_==Candidate in our spec, which maps from FOLLOWER role
  // during election. We detect this at the trace emit point.
  switch (role_enum) {
    case 1: return "Leader";   // RaftPeerPB::LEADER
    case 0: return "Follower"; // RaftPeerPB::FOLLOWER
    default: return "Follower";
  }
}

}  // namespace tla_trace
}  // namespace consensus
}  // namespace kudu

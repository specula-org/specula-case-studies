// Copyright (c) 2024 Specula Project Authors. All rights reserved.
// Trace instrumentation for TLA+ trace validation (braft_3).

#include "braft/trace_logger.h"
#include "braft/node.h"
#include "braft/ballot_box.h"
#include "braft/log_manager.h"

#include <butil/time.h>
#include <gflags/gflags.h>

#ifdef BRAFT_ENABLE_TRACE

DEFINE_string(raft_trace_file, "",
              "Path to write NDJSON trace events. Empty disables tracing.");

DEFINE_bool(raft_trace_enabled, false,
            "Enable trace event emission. Also requires raft_trace_file.");

namespace braft {

// --------------------------------------------------------------------------
// TraceServerMap
// --------------------------------------------------------------------------

TraceServerMap& TraceServerMap::instance() {
    static TraceServerMap inst;
    return inst;
}

std::string TraceServerMap::register_peer(const PeerId& peer) {
    std::string key = peer.to_string();
    std::lock_guard<std::mutex> lk(_mu);
    auto it = _map.find(key);
    if (it != _map.end()) {
        return it->second;
    }
    char buf[16];
    snprintf(buf, sizeof(buf), "s%d", _next_id++);
    _map[key] = buf;
    return buf;
}

std::string TraceServerMap::lookup(const PeerId& peer) const {
    std::string key = peer.to_string();
    std::lock_guard<std::mutex> lk(_mu);
    auto it = _map.find(key);
    if (it != _map.end()) {
        return it->second;
    }
    return "";
}

void TraceServerMap::reset() {
    std::lock_guard<std::mutex> lk(_mu);
    _map.clear();
    _next_id = 1;
}

// --------------------------------------------------------------------------
// TraceState
// --------------------------------------------------------------------------

TraceState::TraceState()
    : term(0), role("Follower"), commitIndex(0),
      lastLogIndex(0), lastLogTerm(0),
      has_extras(false), nodeRole("Voter"),
      lastSnapshotIndex(0), lastSnapshotTerm(0),
      virtualFirstLog(1), physicalFirstLog(1),
      installingSnapshot("none"),
      leaderLeaseValid(false), followerLease(false) {}

TraceState TraceState::capture(const NodeImpl* node) {
    // Caller MUST hold node->_mutex.
    TraceState s;
    s.term = node->_current_term;
    s.role = trace_role_str(node->_state);

    if (node->_voted_id == ANY_PEER) {
        s.votedFor = "";
    } else {
        s.votedFor = TraceServerMap::instance().lookup(node->_voted_id);
    }

    s.commitIndex = node->_ballot_box->last_committed_index();
    s.lastLogIndex = node->_log_manager->last_log_index();
    if (s.lastLogIndex > 0) {
        s.lastLogTerm = node->_log_manager->get_term(s.lastLogIndex);
    } else {
        s.lastLogTerm = 0;
    }

    s.has_extras = true;
    s.nodeRole = node->is_witness() ? "Witness" : "Voter";
    s.virtualFirstLog  = node->_log_manager->first_log_index();
    s.physicalFirstLog = node->_log_manager->first_log_index();
    s.installingSnapshot = "none";

    return s;
}

TraceState TraceState::capture_weak(int64_t term, State role) {
    TraceState s;
    s.term = term;
    s.role = trace_role_str(role);
    return s;
}

TraceState TraceState::capture_commit(int64_t term, State role, int64_t ci) {
    TraceState s = capture_weak(term, role);
    s.commitIndex = ci;
    return s;
}

// --------------------------------------------------------------------------
// TraceEvent
// --------------------------------------------------------------------------

TraceEvent::TraceEvent(const char* name)
    : _name(name), _has_state(false), _msg_count(0) {
}

TraceEvent& TraceEvent::node(const std::string& nid) {
    _nid = nid;
    return *this;
}

TraceEvent& TraceEvent::state(const TraceState& s) {
    _state = s;
    _has_state = true;
    return *this;
}

TraceEvent& TraceEvent::msg_field(const char* key, const std::string& val) {
    if (_msg_count < 12) {
        std::string buf;
        buf.reserve(val.size() + 2);
        buf += '"';
        buf += val;
        buf += '"';
        _msg_fields[_msg_count++] = {key, buf};
    }
    return *this;
}

TraceEvent& TraceEvent::msg_field(const char* key, int64_t val) {
    if (_msg_count < 12) {
        char buf[32];
        snprintf(buf, sizeof(buf), "%ld", val);
        _msg_fields[_msg_count++] = {key, buf};
    }
    return *this;
}

TraceEvent& TraceEvent::msg_field(const char* key, bool val) {
    if (_msg_count < 12) {
        _msg_fields[_msg_count++] = {key, val ? "true" : "false"};
    }
    return *this;
}

void TraceEvent::emit() {
    TraceWriter& w = TraceWriter::instance();
    if (!w.is_open()) {
        return;
    }

    std::string out;
    out.reserve(768);

    int64_t ts_ms = butil::monotonic_time_ms();

    out += "{\"tag\":\"trace\",\"ts\":\"";
    char num[32];
    snprintf(num, sizeof(num), "%ld", ts_ms);
    out += num;
    out += "\",\"event\":{\"name\":\"";
    out += _name;
    out += "\",\"nid\":\"";
    out += _nid;
    out += "\"";

    // State block
    if (_has_state) {
        out += ",\"state\":{\"term\":";
        snprintf(num, sizeof(num), "%ld", _state.term);
        out += num;
        out += ",\"role\":\"";
        out += _state.role;
        out += "\",\"votedFor\":\"";
        out += _state.votedFor;
        out += "\",\"commitIndex\":";
        snprintf(num, sizeof(num), "%ld", _state.commitIndex);
        out += num;
        out += ",\"lastLogIndex\":";
        snprintf(num, sizeof(num), "%ld", _state.lastLogIndex);
        out += num;
        out += ",\"lastLogTerm\":";
        snprintf(num, sizeof(num), "%ld", _state.lastLogTerm);
        out += num;
        if (_state.has_extras) {
            out += ",\"nodeRole\":\"";
            out += _state.nodeRole;
            out += "\",\"lastSnapshotIndex\":";
            snprintf(num, sizeof(num), "%ld", _state.lastSnapshotIndex);
            out += num;
            out += ",\"lastSnapshotTerm\":";
            snprintf(num, sizeof(num), "%ld", _state.lastSnapshotTerm);
            out += num;
            out += ",\"virtualFirstLog\":";
            snprintf(num, sizeof(num), "%ld", _state.virtualFirstLog);
            out += num;
            out += ",\"physicalFirstLog\":";
            snprintf(num, sizeof(num), "%ld", _state.physicalFirstLog);
            out += num;
            out += ",\"installingSnapshot\":\"";
            out += _state.installingSnapshot;
            out += "\",\"leaderLeaseValid\":";
            out += _state.leaderLeaseValid ? "true" : "false";
            out += ",\"followerLease\":";
            out += _state.followerLease ? "true" : "false";
        }
        out += "}";
    }

    // Message block
    if (_msg_count > 0) {
        out += ",\"msg\":{";
        for (int i = 0; i < _msg_count; ++i) {
            if (i > 0) out += ",";
            out += "\"";
            out += _msg_fields[i].key;
            out += "\":";
            out += _msg_fields[i].json_val;
        }
        out += "}";
    }

    out += "}}";
    w.write(out);
}

// --------------------------------------------------------------------------
// TraceWriter
// --------------------------------------------------------------------------

TraceWriter& TraceWriter::instance() {
    static TraceWriter inst;
    return inst;
}

int TraceWriter::open(const std::string& path) {
    std::lock_guard<std::mutex> lk(_mu);
    if (_fp) {
        // Already open. Re-opening would truncate concurrent writers'
        // output; ignore subsequent open() calls from other nodes.
        return 0;
    }
    _fp = fopen(path.c_str(), "w");
    return _fp ? 0 : -1;
}

void TraceWriter::write(const std::string& line) {
    std::lock_guard<std::mutex> lk(_mu);
    if (_fp) {
        fwrite(line.data(), 1, line.size(), _fp);
        fputc('\n', _fp);
        fflush(_fp);
    }
}

void TraceWriter::close() {
    std::lock_guard<std::mutex> lk(_mu);
    if (_fp) {
        fclose(_fp);
        _fp = nullptr;
    }
}

// --------------------------------------------------------------------------
// Global enable check
// --------------------------------------------------------------------------

bool trace_is_enabled() {
    return FLAGS_raft_trace_enabled && !FLAGS_raft_trace_file.empty();
}

void trace_set_file(const std::string& path) {
    FLAGS_raft_trace_file = path;
}

void trace_set_enabled(bool enabled) {
    FLAGS_raft_trace_enabled = enabled;
}

void trace_init(const PeerId& self, const Configuration& conf) {
    if (!trace_is_enabled()) return;
    TraceServerMap& map = TraceServerMap::instance();
    map.register_peer(self);
    std::set<PeerId> peers;
    conf.list_peers(&peers);
    for (const auto& p : peers) {
        map.register_peer(p);
    }
    if (!TraceWriter::instance().is_open()) {
        if (TraceWriter::instance().open(FLAGS_raft_trace_file) != 0) {
            LOG(WARNING) << "Failed to open trace file: "
                         << FLAGS_raft_trace_file;
        }
    }
}

}  // namespace braft

#else  // !BRAFT_ENABLE_TRACE

namespace braft {

TraceServerMap& TraceServerMap::instance() {
    static TraceServerMap inst;
    return inst;
}
std::string TraceServerMap::register_peer(const PeerId&) { return ""; }
std::string TraceServerMap::lookup(const PeerId&) const { return ""; }
void TraceServerMap::reset() {}

TraceState::TraceState()
    : term(0), role("Follower"), commitIndex(0),
      lastLogIndex(0), lastLogTerm(0),
      has_extras(false), nodeRole("Voter"),
      lastSnapshotIndex(0), lastSnapshotTerm(0),
      virtualFirstLog(1), physicalFirstLog(1),
      installingSnapshot("none"),
      leaderLeaseValid(false), followerLease(false) {}
TraceState TraceState::capture(const NodeImpl*) { return TraceState(); }
TraceState TraceState::capture_weak(int64_t, State) { return TraceState(); }
TraceState TraceState::capture_commit(int64_t, State, int64_t) { return TraceState(); }

TraceEvent::TraceEvent(const char*) : _name(""), _has_state(false), _msg_count(0) {}
TraceEvent& TraceEvent::node(const std::string&) { return *this; }
TraceEvent& TraceEvent::state(const TraceState&) { return *this; }
TraceEvent& TraceEvent::msg_field(const char*, const std::string&) { return *this; }
TraceEvent& TraceEvent::msg_field(const char*, int64_t) { return *this; }
TraceEvent& TraceEvent::msg_field(const char*, bool) { return *this; }
void TraceEvent::emit() {}

TraceWriter& TraceWriter::instance() {
    static TraceWriter inst;
    return inst;
}
int TraceWriter::open(const std::string&) { return -1; }
void TraceWriter::write(const std::string&) {}
void TraceWriter::close() {}

bool trace_is_enabled() { return false; }
void trace_set_file(const std::string&) {}
void trace_set_enabled(bool) {}

void trace_init(const PeerId&, const Configuration&) {}

}  // namespace braft

#endif  // BRAFT_ENABLE_TRACE

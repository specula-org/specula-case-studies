// TLA+ trace instrumentation for MongoDB logical session lifecycle.
//
// Include this header in:
//   session_catalog.cpp
//   session_catalog_mongod.cpp
//   logical_session_cache_impl.cpp
//
// Enable at compile time with: -DMONGODB_TLA_TRACE
// Set trace output path via: MONGODB_TLA_TRACE_FILE env var (or call init_session_trace())
//
// Session ID mapping: first distinct UUID seen → "s1", second → "s2", ...
// Shadow state for disk records: maintained as in-memory counters to avoid live reads.
//
// Thread safety: all functions are protected by a single global mutex.
#pragma once

#ifdef MONGODB_TLA_TRACE

#include <atomic>
#include <chrono>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <cstdlib>

namespace mongo {
namespace tla_trace {

// ---------------------------------------------------------------------------
// Session ID mapper: maps opaque UUIDs to TLA+ symbolic names s1, s2, ...
// ---------------------------------------------------------------------------
class SessionMapper {
public:
    std::string map(const std::string& uuid) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = m_.find(uuid);
        if (it != m_.end()) return it->second;
        std::string name = "s" + std::to_string(++next_);
        m_[uuid] = name;
        return name;
    }
    void reset() {
        std::lock_guard<std::mutex> lk(mu_);
        m_.clear(); next_ = 0;
    }
private:
    std::mutex mu_;
    std::map<std::string, std::string> m_;
    int next_ = 0;
};

// ---------------------------------------------------------------------------
// Shadow state for disk record existence.
// Maintains per-session booleans without doing live disk reads.
// ---------------------------------------------------------------------------
struct SessionDiskState {
    bool txnRecordOnDisk   = true;
    bool imageRecordOnDisk = true;
};

class DiskStateShadow {
public:
    // Call when a session is first created / vivified.
    void vivify(const std::string& sid) {
        std::lock_guard<std::mutex> lk(mu_);
        states_[sid] = SessionDiskState{};
    }
    void set_txn_reaped(const std::string& sid) {
        std::lock_guard<std::mutex> lk(mu_);
        states_[sid].txnRecordOnDisk = false;
    }
    void set_image_reaped(const std::string& sid) {
        std::lock_guard<std::mutex> lk(mu_);
        states_[sid].imageRecordOnDisk = false;
    }
    SessionDiskState get(const std::string& sid) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = states_.find(sid);
        return it != states_.end() ? it->second : SessionDiskState{};
    }
private:
    std::mutex mu_;
    std::map<std::string, SessionDiskState> states_;
};

// ---------------------------------------------------------------------------
// Global instances
// ---------------------------------------------------------------------------
inline SessionMapper&   g_session_map()    { static SessionMapper   m; return m; }
inline DiskStateShadow& g_disk_shadow()    { static DiskStateShadow d; return d; }

// ---------------------------------------------------------------------------
// Trace writer
// ---------------------------------------------------------------------------
class TraceWriter {
public:
    static TraceWriter& instance() {
        static TraceWriter w;
        return w;
    }

    void open(const std::string& path) {
        std::lock_guard<std::mutex> lk(mu_);
        file_.open(path, std::ios::out | std::ios::app);
        enabled_ = file_.is_open();
    }

    bool enabled() const { return enabled_.load(); }

    void write_session(const std::string& event,
                       const std::string& sid,
                       const std::string& state_json) {
        if (!enabled_.load()) return;
        auto ts = ts_ns();
        std::lock_guard<std::mutex> lk(mu_);
        file_ << "{\"tag\":\"trace\","
              << "\"ts\":" << ts << ","
              << "\"event\":\"" << event << "\","
              << "\"session\":\"" << sid << "\","
              << "\"state\":" << state_json
              << "}\n";
        file_.flush();
    }

    void write_global(const std::string& event, const std::string& state_json) {
        if (!enabled_.load()) return;
        auto ts = ts_ns();
        std::lock_guard<std::mutex> lk(mu_);
        file_ << "{\"tag\":\"trace\","
              << "\"ts\":" << ts << ","
              << "\"event\":\"" << event << "\","
              << "\"state\":" << state_json
              << "}\n";
        file_.flush();
    }

private:
    std::ofstream file_;
    std::atomic<bool> enabled_{false};
    std::mutex mu_;

    int64_t ts_ns() const {
        using namespace std::chrono;
        return duration_cast<nanoseconds>(system_clock::now().time_since_epoch()).count();
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
inline void init_session_trace(const std::string& path = "") {
    std::string p = path;
    if (p.empty()) {
        const char* env = std::getenv("MONGODB_TLA_TRACE_FILE");
        p = env ? env : "/tmp/mongodb_session_trace.ndjson";
    }
    TraceWriter::instance().open(p);
}

inline bool session_trace_enabled() {
    return TraceWriter::instance().enabled();
}

// Helper: lsid → stable TLA+ name
inline std::string sid(const LogicalSessionId& lsid) {
    return g_session_map().map(lsid.getId().toString());
}

// Helper: build simple JSON object from pre-formatted key:value pairs
inline std::string json_obj(std::initializer_list<std::pair<std::string,std::string>> fields) {
    std::string buf = "{";
    bool first = true;
    for (auto& [k, v] : fields) {
        if (!first) buf += ',';
        first = false;
        buf += '"'; buf += k; buf += "\":"; buf += v;
    }
    buf += '}';
    return buf;
}

// Helpers for JSON value formatting
inline std::string jstr(const std::string& v) { return "\"" + v + "\""; }
inline std::string jnum(int v) { return std::to_string(v); }
inline std::string jbool(bool v) { return v ? "true" : "false"; }

} // namespace tla_trace
} // namespace mongo

// ---------------------------------------------------------------------------
// Instrumentation macros
// ---------------------------------------------------------------------------
#define TLA_SESSION_EMIT(event, lsid, ...) \
    do { \
        if (::mongo::tla_trace::session_trace_enabled()) { \
            auto __sid = ::mongo::tla_trace::sid(lsid); \
            auto __state = ::mongo::tla_trace::json_obj({__VA_ARGS__}); \
            ::mongo::tla_trace::TraceWriter::instance().write_session(event, __sid, __state); \
        } \
    } while (0)

#define TLA_GLOBAL_EMIT(event, ...) \
    do { \
        if (::mongo::tla_trace::session_trace_enabled()) { \
            auto __state = ::mongo::tla_trace::json_obj({__VA_ARGS__}); \
            ::mongo::tla_trace::TraceWriter::instance().write_global(event, __state); \
        } \
    } while (0)

#else  // !MONGODB_TLA_TRACE

#define TLA_SESSION_EMIT(event, lsid, ...) do {} while (0)
#define TLA_GLOBAL_EMIT(event, ...) do {} while (0)

#endif  // MONGODB_TLA_TRACE

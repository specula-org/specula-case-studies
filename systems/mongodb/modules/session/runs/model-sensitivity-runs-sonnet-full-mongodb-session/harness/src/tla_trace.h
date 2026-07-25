// Trace emission module for MongoDB logical session lifecycle.
// Used both by the standalone scenario runner and (via patch) by the real
// MongoDB source code when compiled with -DMONGODB_TLA_TRACE.
#pragma once

#include <string>
#include <fstream>
#include <mutex>
#include <sstream>
#include <chrono>
#include <stdexcept>

namespace mongo {
namespace tla_trace {

// Minimal JSON object builder — no external dependencies.
class JsObj {
public:
    JsObj() = default;

    JsObj& s(const std::string& k, const std::string& v) {
        sep(); buf_ += '"'; buf_ += k; buf_ += "\":\""; buf_ += v; buf_ += '"';
        return *this;
    }
    JsObj& n(const std::string& k, long long v) {
        sep(); buf_ += '"'; buf_ += k; buf_ += "\":"; buf_ += std::to_string(v);
        return *this;
    }
    JsObj& b(const std::string& k, bool v) {
        sep(); buf_ += '"'; buf_ += k; buf_ += "\":"; buf_ += (v ? "true" : "false");
        return *this;
    }
    JsObj& nested(const std::string& k, const JsObj& v) {
        sep(); buf_ += '"'; buf_ += k; buf_ += "\":"; buf_ += v.build();
        return *this;
    }
    std::string build() const { return "{" + buf_ + "}"; }

private:
    std::string buf_;
    bool first_ = true;
    void sep() { if (!first_) buf_ += ','; first_ = false; }
};

// Thread-safe NDJSON trace emitter.
//
// Every emitted line has the form:
//   {"tag":"trace","ts":<ns>,"event":"<name>","session":"<id>","state":{...}}
// For global (session-less) events, the "session" field is omitted.
class TraceEmitter {
public:
    explicit TraceEmitter(const std::string& path) {
        file_.open(path, std::ios::out | std::ios::trunc);
        if (!file_.is_open())
            throw std::runtime_error("tla_trace: cannot open " + path);
    }
    ~TraceEmitter() {
        std::lock_guard<std::mutex> lk(mu_);
        if (file_.is_open()) { file_.flush(); file_.close(); }
    }

    // Session-scoped event: includes "session" field.
    void emit(const std::string& event,
              const std::string& session,
              const JsObj& state) {
        std::string line;
        line += "{\"tag\":\"trace\",\"ts\":";
        line += std::to_string(ts_ns());
        line += ",\"event\":\""; line += event; line += "\"";
        line += ",\"session\":\""; line += session; line += "\"";
        line += ",\"state\":"; line += state.build();
        line += "}";
        write(line);
    }

    // Global event (no "session" field).
    void emit_global(const std::string& event, const JsObj& state) {
        std::string line;
        line += "{\"tag\":\"trace\",\"ts\":";
        line += std::to_string(ts_ns());
        line += ",\"event\":\""; line += event; line += "\"";
        line += ",\"state\":"; line += state.build();
        line += "}";
        write(line);
    }

private:
    std::ofstream file_;
    std::mutex mu_;

    int64_t ts_ns() const {
        using namespace std::chrono;
        return duration_cast<nanoseconds>(
            system_clock::now().time_since_epoch()).count();
    }
    void write(const std::string& line) {
        std::lock_guard<std::mutex> lk(mu_);
        file_ << line << '\n';
        file_.flush();
    }
};

// Global singleton used by instrumentation macros in MongoDB source.
extern TraceEmitter* g_emitter;
void init_trace(const std::string& path);
void shutdown_trace();

} // namespace tla_trace
} // namespace mongo

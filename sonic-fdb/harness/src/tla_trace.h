#ifndef SONIC_FDB_TLA_TRACE_H
#define SONIC_FDB_TLA_TRACE_H

/*
 * TLA+ Trace Emission Module for SONiC FDB Bridge Port Lifecycle
 *
 * Usage:
 *   Set SONIC_FDB_TRACE_FILE=path.ndjson to enable trace emission.
 *   When unset, all trace calls are no-ops.
 *
 * Thread safety: mutex-protected (orchagent is single-threaded, but safe regardless).
 */

#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <mutex>
#include <string>
#include <nlohmann/json.hpp>

namespace sonic_tla_trace {

using json = nlohmann::json;

class TraceWriter {
public:
    static TraceWriter& instance() {
        static TraceWriter tw;
        return tw;
    }

    bool is_enabled() const { return fp_ != nullptr; }

    void emit(const json& event) {
        if (!fp_) return;
        std::lock_guard<std::mutex> lock(mu_);
        // Add tag and real timestamp
        json line = event;
        line["tag"] = "trace";
        auto now = std::chrono::steady_clock::now();
        auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            now.time_since_epoch()).count();
        line["ts"] = ns;
        std::string s = line.dump();
        fprintf(fp_, "%s\n", s.c_str());
        fflush(fp_);
    }

    void close() {
        std::lock_guard<std::mutex> lock(mu_);
        if (fp_) {
            fclose(fp_);
            fp_ = nullptr;
        }
    }

    ~TraceWriter() { close(); }

private:
    TraceWriter() {
        const char* path = std::getenv("SONIC_FDB_TRACE_FILE");
        if (path && path[0]) {
            fp_ = fopen(path, "w");
            if (!fp_) {
                fprintf(stderr, "tla_trace: cannot open %s\n", path);
            }
        }
    }
    TraceWriter(const TraceWriter&) = delete;
    TraceWriter& operator=(const TraceWriter&) = delete;

    FILE* fp_ = nullptr;
    std::mutex mu_;
};

// Convenience: emit a trace event with the given fields
inline void emit_event(const json& event) {
    TraceWriter::instance().emit(event);
}

// Check if tracing is enabled
inline bool trace_enabled() {
    return TraceWriter::instance().is_enabled();
}

} // namespace sonic_tla_trace

// Macros for easy instrumentation in orchagent code
#define SONIC_TLA_TRACE_EMIT(event_json) \
    do { sonic_tla_trace::emit_event(event_json); } while(0)

#define SONIC_TLA_TRACE_ENABLED() sonic_tla_trace::trace_enabled()

#endif // SONIC_FDB_TLA_TRACE_H

// tla_trace.h — TLA+ trace emission for MongoDB range deletion protocol
//
// Category A: Distributed / Message-Passing — single-file NDJSON output, mutex-protected.
//
// Usage:
//   #include "tla_trace.h"
//   tla_trace::init("/path/to/traces/scenario.ndjson");
//   tla_trace::emit("WriteCoordDoc", migId, "present", "absent", "absent", true);
//   tla_trace::close();
//
// Environment variable TLA_TRACE_FILE overrides the path set by init().
// Set to "" or do not call init() to disable tracing.

#pragma once

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>

namespace tla_trace {

class Tracer {
public:
    static Tracer& instance() {
        static Tracer t;
        return t;
    }

    void init(const std::string& filepath) {
        const char* envPath = std::getenv("TLA_TRACE_FILE");
        const std::string& path = (envPath && *envPath) ? std::string(envPath) : filepath;
        if (path.empty())
            return;

        std::lock_guard<std::mutex> lk(_mutex);
        _file.open(path, std::ios::app);
        _enabled.store(true, std::memory_order_release);
    }

    // Emit one NDJSON event line to the trace file.
    // All field values must be valid per instrumentation-spec.md.
    void emit(const std::string& event,
              const std::string& migrationId,
              const std::string& coordDocState,
              const std::string& donorTaskState,
              const std::string& recipientTaskState,
              bool recipientAlive) {
        if (!_enabled.load(std::memory_order_acquire))
            return;

        // Real nanosecond timestamp — never synthetic/sequential
        auto ts = std::chrono::duration_cast<std::chrono::nanoseconds>(
                      std::chrono::system_clock::now().time_since_epoch())
                      .count();

        std::ostringstream line;
        line << R"({"tag":"trace","ts":")" << ts
             << R"(","event":")" << event
             << R"(","migrationId":")" << migrationId
             << R"(","coordDocState":")" << coordDocState
             << R"(","donorTaskState":")" << donorTaskState
             << R"(","recipientTaskState":")" << recipientTaskState
             << R"(","recipientAlive":)" << (recipientAlive ? "true" : "false")
             << "}\n";

        std::lock_guard<std::mutex> lk(_mutex);
        if (_file.is_open()) {
            _file << line.str();
            _file.flush();
        }
    }

    void close() {
        std::lock_guard<std::mutex> lk(_mutex);
        _enabled.store(false, std::memory_order_release);
        if (_file.is_open())
            _file.close();
    }

private:
    Tracer() = default;
    std::mutex _mutex;
    std::ofstream _file;
    std::atomic<bool> _enabled{false};
};

inline void init(const std::string& filepath) {
    Tracer::instance().init(filepath);
}

inline void emit(const std::string& event,
                 const std::string& migrationId,
                 const std::string& coordDocState,
                 const std::string& donorTaskState,
                 const std::string& recipientTaskState,
                 bool recipientAlive) {
    Tracer::instance().emit(
        event, migrationId, coordDocState, donorTaskState, recipientTaskState, recipientAlive);
}

inline void close() {
    Tracer::instance().close();
}

}  // namespace tla_trace

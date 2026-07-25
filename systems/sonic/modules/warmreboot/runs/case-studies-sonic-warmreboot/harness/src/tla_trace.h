/*
 * TLA+ Trace Emission Module for SONiC Warm Reboot.
 *
 * Header-only, thread-safe NDJSON writer for C++ SONiC components.
 * Include in orchdaemon.cpp, warmRestartAssist.cpp, Syncd.cpp, neighsyncd.cpp.
 *
 * Usage:
 *   #include "tla_trace.h"
 *
 *   // Initialize once at startup:
 *   TlaTrace::init("orchagent");
 *
 *   // Emit trace events at instrumentation points:
 *   TlaTrace::emit("OrchCheckReady", {
 *       {"orchState", "CheckingReady"},
 *       {"phase", "Freeze"},
 *   });
 *
 *   // Shutdown:
 *   TlaTrace::close();
 *
 * Enable via environment variable: TLA_TRACE_FILE=/path/to/trace.ndjson
 * If not set, tracing is a no-op (zero overhead in production).
 */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <chrono>
#include <cstdio>
#include <mutex>
#include <string>
#include <sstream>
#include <map>

namespace TlaTrace {

namespace detail {

inline std::mutex& getMutex() {
    static std::mutex mtx;
    return mtx;
}

inline FILE*& getFile() {
    static FILE* fp = nullptr;
    return fp;
}

inline std::string& getComponent() {
    static std::string comp;
    return comp;
}

inline bool& isEnabled() {
    static bool enabled = false;
    return enabled;
}

// Escape a string for JSON output
inline std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:   out += c;      break;
        }
    }
    return out;
}

// Get ISO 8601 timestamp with microsecond precision
inline std::string timestamp() {
    auto now = std::chrono::system_clock::now();
    auto us = std::chrono::duration_cast<std::chrono::microseconds>(
        now.time_since_epoch()).count();
    time_t sec = us / 1000000;
    int usec = us % 1000000;
    struct tm tm;
    gmtime_r(&sec, &tm);
    char buf[64];
    snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ",
             tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec, usec);
    return std::string(buf);
}

} // namespace detail

using StateMap = std::map<std::string, std::string>;

/**
 * Initialize tracing.
 * Reads TLA_TRACE_FILE env var; if not set, tracing is disabled.
 */
inline void init(const std::string& component) {
    const char* path = getenv("TLA_TRACE_FILE");
    if (!path || path[0] == '\0') {
        detail::isEnabled() = false;
        return;
    }
    detail::getFile() = fopen(path, "a");
    if (!detail::getFile()) {
        detail::isEnabled() = false;
        return;
    }
    detail::getComponent() = component;
    detail::isEnabled() = true;
}

/**
 * Emit one NDJSON trace line.
 *
 * @param eventName  TLA+ action name (e.g., "OrchCheckReady")
 * @param state      State fields to include in the event
 * @param detail     Optional detail fields (key, cacheState, etc.)
 */
inline void emit(const std::string& eventName,
                 const StateMap& state,
                 const StateMap& detail = {}) {
    if (!detail::isEnabled()) return;

    std::ostringstream ss;
    ss << "{\"tag\":\"trace\",\"timestamp\":\""
       << detail::timestamp()
       << "\",\"event\":{\"name\":\""
       << detail::jsonEscape(eventName)
       << "\",\"component\":\""
       << detail::jsonEscape(detail::getComponent())
       << "\",\"state\":{";

    bool first = true;
    for (const auto& kv : state) {
        if (!first) ss << ",";
        first = false;
        // Detect booleans and integers
        if (kv.second == "true" || kv.second == "false") {
            ss << "\"" << detail::jsonEscape(kv.first) << "\":"
               << kv.second;
        } else {
            // Try integer
            bool isInt = !kv.second.empty();
            for (char c : kv.second) {
                if (c < '0' || c > '9') { isInt = false; break; }
            }
            if (isInt && !kv.second.empty()) {
                ss << "\"" << detail::jsonEscape(kv.first) << "\":"
                   << kv.second;
            } else {
                ss << "\"" << detail::jsonEscape(kv.first) << "\":\""
                   << detail::jsonEscape(kv.second) << "\"";
            }
        }
    }
    ss << "}";

    if (!detail.empty()) {
        ss << ",\"detail\":{";
        first = true;
        for (const auto& kv : detail) {
            if (!first) ss << ",";
            first = false;
            ss << "\"" << detail::jsonEscape(kv.first) << "\":\""
               << detail::jsonEscape(kv.second) << "\"";
        }
        ss << "}";
    }

    ss << "}}";

    std::string line = ss.str();
    std::lock_guard<std::mutex> lock(detail::getMutex());
    if (detail::getFile()) {
        fprintf(detail::getFile(), "%s\n", line.c_str());
        fflush(detail::getFile());
    }
}

/**
 * Close the trace file.
 */
inline void close() {
    std::lock_guard<std::mutex> lock(detail::getMutex());
    if (detail::getFile()) {
        fclose(detail::getFile());
        detail::getFile() = nullptr;
    }
    detail::isEnabled() = false;
}

} // namespace TlaTrace

#endif // TLA_TRACE_H

#pragma once

#include <fstream>
#include <mutex>
#include <chrono>
#include <string>
#include <map>

namespace tla_trace {

class TraceEmitter {
public:
    static TraceEmitter& getInstance();

    void init(const std::string& trace_file);
    void shutdown();

    void emitEvent(const std::string& event_type,
                   const std::string& node_id,
                   const std::map<std::string, std::string>& state_fields);

    TraceEmitter(const TraceEmitter&) = delete;
    TraceEmitter& operator=(const TraceEmitter&) = delete;

private:
    TraceEmitter() = default;

    std::mutex _lock;
    std::ofstream _trace_file;
    bool _initialized = false;

    int64_t getTimestampUs();
    std::string escapeJson(const std::string& str);
};

// Helper macro for easy access
#define TRACE_EMIT(event_type, node_id, fields) \
    tla_trace::TraceEmitter::getInstance().emitEvent(event_type, node_id, fields)

} // namespace tla_trace

#include "tla_trace.h"
#include <iostream>
#include <sstream>
#include <iomanip>
#include <chrono>
#include <cstring>

namespace tla_trace {

TraceEmitter& TraceEmitter::getInstance() {
    static TraceEmitter instance;
    return instance;
}

void TraceEmitter::init(const std::string& trace_file) {
    std::lock_guard<std::mutex> lock(_lock);
    if (_initialized) {
        return;
    }
    _trace_file.open(trace_file, std::ios::app);
    if (!_trace_file.is_open()) {
        std::cerr << "Failed to open trace file: " << trace_file << std::endl;
        return;
    }
    _initialized = true;
}

void TraceEmitter::shutdown() {
    std::lock_guard<std::mutex> lock(_lock);
    if (_trace_file.is_open()) {
        _trace_file.flush();
        _trace_file.close();
    }
    _initialized = false;
}

int64_t TraceEmitter::getTimestampUs() {
    auto now = std::chrono::system_clock::now();
    auto duration = now.time_since_epoch();
    return std::chrono::duration_cast<std::chrono::microseconds>(duration).count();
}

std::string TraceEmitter::escapeJson(const std::string& str) {
    std::ostringstream escaped;
    for (char c : str) {
        switch (c) {
            case '"':  escaped << "\\\""; break;
            case '\\': escaped << "\\\\"; break;
            case '\b': escaped << "\\b";  break;
            case '\f': escaped << "\\f";  break;
            case '\n': escaped << "\\n";  break;
            case '\r': escaped << "\\r";  break;
            case '\t': escaped << "\\t";  break;
            default:
                if (c < 0x20) {
                    escaped << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                            << static_cast<int>(c);
                } else {
                    escaped << c;
                }
        }
    }
    return escaped.str();
}

void TraceEmitter::emitEvent(const std::string& event_type,
                             const std::string& node_id,
                             const std::map<std::string, std::string>& state_fields) {
    std::lock_guard<std::mutex> lock(_lock);
    if (!_initialized || !_trace_file.is_open()) {
        return;
    }

    int64_t timestamp = getTimestampUs();

    // Build JSON: {"tag":"trace","type":"...", "timestamp":123, "nodeId":"...", ...state_fields}
    std::ostringstream json;
    json << "{\"tag\":\"trace\",\"type\":\"" << escapeJson(event_type)
         << "\",\"timestamp\":" << timestamp
         << ",\"nodeId\":\"" << escapeJson(node_id) << "\"";

    for (const auto& [key, value] : state_fields) {
        json << ",\"" << escapeJson(key) << "\":\"" << escapeJson(value) << "\"";
    }
    json << "}";

    _trace_file << json.str() << "\n";
    _trace_file.flush();
}

} // namespace tla_trace

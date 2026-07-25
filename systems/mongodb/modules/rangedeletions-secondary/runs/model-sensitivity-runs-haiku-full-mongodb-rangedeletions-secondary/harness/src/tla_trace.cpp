/**
 * TLA+ Trace Emission Module Implementation
 */

#include "tla_trace.h"

#include <iostream>
#include <sstream>
#include <iomanip>

namespace mongo {
namespace tla_trace {

int64_t TraceEmitter::now() {
    using namespace std::chrono;
    auto now = high_resolution_clock::now();
    return duration_cast<microseconds>(now.time_since_epoch()).count();
}

void TraceEmitter::init(const std::string& filePath) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_initialized) {
        return;
    }
    _file = std::make_unique<std::ofstream>(filePath, std::ios::app);
    if (!_file->is_open()) {
        std::cerr << "Failed to open trace file: " << filePath << std::endl;
        return;
    }
    _initialized = true;
}

void TraceEmitter::shutdown() {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_file && _file->is_open()) {
        _file->flush();
        _file->close();
    }
    _initialized = false;
}

std::string TraceEmitter::eventToJson(const TraceEvent& event) {
    std::stringstream ss;
    ss << "{\"tag\":\"trace\",";
    ss << "\"ts\":" << event.timestamp << ",";
    ss << "\"eventName\":\"" << event.eventName << "\",";
    ss << "\"node\":\"" << event.node << "\",";
    ss << "\"currentTerm\":" << event.currentTerm << ",";
    ss << "\"replicaRole\":\"" << event.replicaRole << "\",";
    ss << "\"processorState\":\"" << event.processorState << "\",";

    // Persistent task state
    ss << "\"persistentTaskState\":{";
    bool first = true;
    for (const auto& [taskId, state] : event.persistentTaskState) {
        if (!first) ss << ",";
        ss << "\"" << taskId << "\":\"" << state << "\"";
        first = false;
    }
    ss << "},";

    // In-memory tasks
    ss << "\"inMemoryTaskExists\":[";
    for (size_t i = 0; i < event.inMemoryTaskExists.size(); ++i) {
        if (i > 0) ss << ",";
        ss << event.inMemoryTaskExists[i];
    }
    ss << "],";

    ss << "\"recoveryInFlight\":" << (event.recoveryInFlight ? "true" : "false") << ",";
    ss << "\"recoveryOutcome\":\"" << event.recoveryOutcome << "\"";

    // Action-specific fields
    if (event.taskId >= 0) {
        ss << ",\"taskId\":" << event.taskId;
    }
    if (!event.overlappingTasks.empty()) {
        ss << ",\"overlappingTasks\":[";
        for (size_t i = 0; i < event.overlappingTasks.size(); ++i) {
            if (i > 0) ss << ",";
            ss << event.overlappingTasks[i];
        }
        ss << "]";
    }
    if (!event.tasksRecoveredInTerm.empty()) {
        ss << ",\"tasksRecoveredInTerm\":[";
        for (size_t i = 0; i < event.tasksRecoveredInTerm.size(); ++i) {
            if (i > 0) ss << ",";
            ss << event.tasksRecoveredInTerm[i];
        }
        ss << "]";
    }
    if (!event.deletionProgress.empty()) {
        ss << ",\"deletionProgress\":\"" << event.deletionProgress << "\"";
    }
    if (!event.invalidatedRanges.empty()) {
        ss << ",\"invalidatedRanges\":[";
        for (size_t i = 0; i < event.invalidatedRanges.size(); ++i) {
            if (i > 0) ss << ",";
            ss << event.invalidatedRanges[i];
        }
        ss << "]";
    }
    if (event.taskBeingDeleted >= 0) {
        ss << ",\"taskBeingDeleted\":" << event.taskBeingDeleted;
    }

    ss << "}";
    return ss.str();
}

void TraceEmitter::emit(const TraceEvent& event) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_initialized || !_file || !_file->is_open()) {
        return;
    }
    *_file << eventToJson(event) << "\n";
    _file->flush();
}

} // namespace tla_trace
} // namespace mongo

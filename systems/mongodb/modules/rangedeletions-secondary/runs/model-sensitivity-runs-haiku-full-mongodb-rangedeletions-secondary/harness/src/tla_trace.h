/**
 * TLA+ Trace Emission Module
 * Emits NDJSON trace events for trace validation
 */

#pragma once

#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <map>
#include <vector>
#include <cstdint>
#include <chrono>

namespace mongo {
namespace tla_trace {

// Wrapper around shared state for tracing
struct TraceEvent {
    std::string eventName;
    std::string node;
    int64_t timestamp;
    int64_t currentTerm;
    std::string replicaRole;
    std::string processorState;
    std::map<int, std::string> persistentTaskState;
    std::vector<int> inMemoryTaskExists;
    bool recoveryInFlight;
    std::string recoveryOutcome;

    // Action-specific fields (optional)
    int taskId = -1;
    std::vector<int> overlappingTasks;
    std::vector<int> tasksRecoveredInTerm;
    std::string deletionProgress;
    std::vector<int> invalidatedRanges;
    int taskBeingDeleted = -1;
};

class TraceEmitter {
public:
    static TraceEmitter& getInstance() {
        static TraceEmitter instance;
        return instance;
    }

    // Initialize trace file
    void init(const std::string& filePath);

    // Shutdown and close file
    void shutdown();

    // Emit a trace event
    void emit(const TraceEvent& event);

    // Get timestamp in microseconds
    static int64_t now();

private:
    TraceEmitter() = default;
    ~TraceEmitter();

    std::mutex _mutex;
    std::unique_ptr<std::ofstream> _file;
    bool _initialized = false;

    // Convert event to JSON and write
    std::string eventToJson(const TraceEvent& event);
};

// Helper to initialize
inline void initTrace(const std::string& path) {
    TraceEmitter::getInstance().init(path);
}

// Helper to shutdown
inline void shutdownTrace() {
    TraceEmitter::getInstance().shutdown();
}

// Helper to emit
inline void emitTrace(const TraceEvent& event) {
    TraceEmitter::getInstance().emit(event);
}

} // namespace tla_trace
} // namespace mongo

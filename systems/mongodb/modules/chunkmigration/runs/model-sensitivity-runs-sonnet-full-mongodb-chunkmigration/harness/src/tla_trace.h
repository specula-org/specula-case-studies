/**
 * tla_trace.h — TLA+ trace emission for MongoDB chunk migration.
 *
 * Drop this header in src/mongo/db/s/ and include it from the four
 * instrumented translation units.  Thread-safe via mutex.
 *
 * Env var TLA_TRACE_FILE controls the output path (default: /tmp/tla_trace.ndjson).
 * Set TLA_TRACE_FILE="" to disable emission at runtime.
 */
#pragma once

#include <chrono>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <string>

#include "mongo/bson/bsonobjbuilder.h"
#include "mongo/db/s/migration_coordinator_document_gen.h"
#include "mongo/db/s/range_deletion_task_gen.h"

namespace mongo {
namespace tla_trace {

namespace detail {

inline std::mutex& fileMutex() {
    static std::mutex m;
    return m;
}

inline std::ofstream& traceFile() {
    static std::ofstream f;
    return f;
}

inline bool& initialized() {
    static bool v = false;
    return v;
}

inline void ensureOpen() {
    if (initialized()) return;
    initialized() = true;
    const char* path = std::getenv("TLA_TRACE_FILE");
    if (path == nullptr) path = "/tmp/tla_trace.ndjson";
    if (path[0] == '\0') return;  // disabled
    traceFile().open(path, std::ios::app);
}

inline std::string nowIso() {
    auto now = std::chrono::system_clock::now();
    auto ms  = std::chrono::duration_cast<std::chrono::milliseconds>(
                   now.time_since_epoch()).count();
    // Format as Unix epoch milliseconds (Trace.tla accepts any real timestamp)
    return std::to_string(ms);
}

}  // namespace detail

// ---------------------------------------------------------------------------
// State helpers — read observable state from in-process data structures.
// ---------------------------------------------------------------------------

inline std::string donorPhaseStr(int stateEnum) {
    // MigrationSourceManager::kNew=0, kCloning=1, kCloneCaughtUp=2, kCriticalSection=3,
    // kCloneCompleted=4, kCommittingOnConfig=5, kDone=6
    switch (stateEnum) {
        case 0: return "d_init";
        case 1: case 2: return "d_cloning";
        case 3: case 4: case 5: return "d_critsec";
        case 6: return "d_committed";
        default: return "d_init";
    }
}

inline std::string recipientStateStr(int stateEnum) {
    // MigrationDestinationManager enum order: kReady=0,kClone=1,kCatchup=2,
    // kSteadyState=3,kEnteredCritSec=4,kExitCritSec=5,kDone=6,kFail=7,kAbort=8
    // NOTE: exact ordering varies by version — use string names where possible.
    switch (stateEnum) {
        case 0: return "kInit";
        case 1: case 2: case 3: return "kCloning";
        case 4: case 5: return "kEnteredCritSec";
        case 6: return "kDone";
        case 7: return "kFail";
        case 8: return "kAbort";
        default: return "kInit";
    }
}

inline std::string rdTaskStateStr(bool docExists, bool pending) {
    if (!docExists) return "absent";
    return pending ? "pending" : "ready";
}

// ---------------------------------------------------------------------------
// Emit one NDJSON trace line.
// ---------------------------------------------------------------------------

inline void emitEvent(const std::string& eventName,
                      const std::string& node,
                      const BSONObj& beforeState,
                      const BSONObj& afterState) {
    std::lock_guard<std::mutex> lk(detail::fileMutex());
    detail::ensureOpen();
    auto& f = detail::traceFile();
    if (!f.is_open()) return;

    BSONObjBuilder root;
    root.append("tag", "trace");
    root.append("ts", detail::nowIso());
    root.append("event", eventName);
    root.append("node", node);
    root.append("before", beforeState);
    root.append("after", afterState);

    f << root.obj().jsonString() << '\n';
    f.flush();
}

// ---------------------------------------------------------------------------
// Convenience: build state BSON from field map.
// ---------------------------------------------------------------------------
struct StateSnapshot {
    BSONObjBuilder b;

    StateSnapshot& donorPhase(const std::string& v)               { b.append("donorPhase", v); return *this; }
    StateSnapshot& recipientState(const std::string& v)           { b.append("recipientState", v); return *this; }
    StateSnapshot& configCommitted(bool v)                        { b.append("configCommitted", v); return *this; }
    StateSnapshot& coordinatorDocPresent(bool v)                  { b.append("coordinatorDocPresent", v); return *this; }
    StateSnapshot& coordinatorDocDecision(const std::string& v)   { b.append("coordinatorDocDecision", v); return *this; }
    StateSnapshot& critSecReleaseRPCSent(bool v)                  { b.append("critSecReleaseRPCSent", v); return *this; }
    StateSnapshot& recipientCritSecReleased(bool v)               { b.append("recipientCritSecReleased", v); return *this; }
    StateSnapshot& donorCrashed(bool v)                           { b.append("donorCrashed", v); return *this; }
    StateSnapshot& recipientAbortSignaled(bool v)                 { b.append("recipientAbortSignaled", v); return *this; }
    StateSnapshot& recipientRecoveryDocPresent(bool v)            { b.append("recipientRecoveryDocPresent", v); return *this; }
    StateSnapshot& recipientInRecovery(bool v)                    { b.append("recipientInRecovery", v); return *this; }
    StateSnapshot& donorRDTask(const std::string& v)              { b.append("donorRDTask", v); return *this; }
    StateSnapshot& recipientRDTask(const std::string& v)          { b.append("recipientRDTask", v); return *this; }

    BSONObj obj() { return b.obj(); }
};

}  // namespace tla_trace
}  // namespace mongo

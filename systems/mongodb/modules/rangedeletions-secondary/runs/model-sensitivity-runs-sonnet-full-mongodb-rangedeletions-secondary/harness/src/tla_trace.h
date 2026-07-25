/**
 * TLA+ Trace Emission Header for MongoDB RangeDeleterService
 *
 * Provides thread-safe NDJSON trace event emission for Specula trace validation.
 * Include this header in instrumented source files. Call tlaTrace::init() once
 * at service startup (or test setup), then call emit functions at instrumentation points.
 *
 * Output format: {"tag":"trace","ts":"<ns>","event":"<Name>","node":"<id>","state":{...}}\n
 *
 * Configuration (environment variables):
 *   TLA_TRACE_FILE  - path to output NDJSON file (default: /tmp/tla_trace.ndjson)
 *   TLA_NODE_NAME   - this node's TLA+ name, e.g. "n1" (default: "n1")
 */
#pragma once

#include <atomic>
#include <cstdio>
#include <ctime>
#include <mutex>
#include <string>
#include <cstdlib>

namespace tlaTrace {

// -------------------------------------------------------------------------
// Internal state
// -------------------------------------------------------------------------

namespace detail {

struct Writer {
    FILE* file = nullptr;
    std::mutex mutex;
    std::string nodeId = "n1";

    ~Writer() {
        if (file) fclose(file);
    }
};

inline Writer& getWriter() {
    static Writer w;
    return w;
}

// Recovery phase string, shared across threads within a step-up cycle.
// The recovery task lambda updates this as it progresses.
inline std::atomic<int>& recoveryPhaseAtom() {
    // 0=idle, 1=phase1, 2=phase2, 3=done
    static std::atomic<int> a{0};
    return a;
}

inline const char* recoveryPhaseStr(int v) {
    switch (v) {
        case 1: return "phase1";
        case 2: return "phase2";
        case 3: return "done";
        default: return "idle";
    }
}

inline uint64_t nowNs() {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL +
           static_cast<uint64_t>(ts.tv_nsec);
}

// Write a pre-formatted NDJSON line. Caller holds no lock.
// The string must be a complete JSON object (without trailing newline).
inline void writeLine(const std::string& json) {
    auto& w = getWriter();
    std::lock_guard<std::mutex> lk(w.mutex);
    if (!w.file) return;
    fprintf(w.file, "%s\n", json.c_str());
    fflush(w.file);
}

// JSON-escape a string (handles quotes and backslashes)
inline std::string jsonStr(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    out += '"';
    for (char c : s) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    out += '"';
    return out;
}

} // namespace detail

// -------------------------------------------------------------------------
// Initialization
// -------------------------------------------------------------------------

// Call once before emitting events (e.g., in test setUp or service startup).
// traceFile: output NDJSON file path (or "" to use TLA_TRACE_FILE env var)
// nodeId:    TLA+ name for this node (or "" to use TLA_NODE_NAME env var)
inline void init(const std::string& traceFile = "", const std::string& nodeId = "") {
    auto& w = detail::getWriter();
    std::lock_guard<std::mutex> lk(w.mutex);

    const char* envFile = traceFile.empty() ? std::getenv("TLA_TRACE_FILE") : nullptr;
    const char* envNode = nodeId.empty()    ? std::getenv("TLA_NODE_NAME")  : nullptr;

    std::string file = !traceFile.empty() ? traceFile
                     : (envFile ? envFile : "/tmp/tla_trace.ndjson");
    w.nodeId = !nodeId.empty() ? nodeId
             : (envNode ? envNode : "n1");

    if (w.file) { fclose(w.file); w.file = nullptr; }
    w.file = fopen(file.c_str(), "a");
    detail::recoveryPhaseAtom().store(0);
}

// Close the trace file (called from tearDown or shutdown).
inline void close() {
    auto& w = detail::getWriter();
    std::lock_guard<std::mutex> lk(w.mutex);
    if (w.file) { fclose(w.file); w.file = nullptr; }
}

// Get this node's TLA+ name.
inline const std::string& nodeId() {
    return detail::getWriter().nodeId;
}

// Update the recovery phase (called from within the recovery task).
inline void setRecoveryPhase(int phase) { // 0=idle,1=phase1,2=phase2,3=done
    detail::recoveryPhaseAtom().store(phase);
}
inline int getRecoveryPhase() {
    return detail::recoveryPhaseAtom().load();
}

// -------------------------------------------------------------------------
// Task key helpers
// -------------------------------------------------------------------------

// Build the stable task key: "collUUID:rangeMin:rangeMax"
// Callers must pass string representations of the UUID and range bounds.
inline std::string taskKey(const std::string& collUUID,
                           const std::string& rangeMin,
                           const std::string& rangeMax) {
    return collUUID + ":" + rangeMin + ":" + rangeMax;
}

// -------------------------------------------------------------------------
// Emit functions (one per TLA+ action)
// -------------------------------------------------------------------------
// All emit functions capture the PRE-STATE (before the action changes spec vars).
// This matches how Trace.tla's ValidateNodeState/ValidateDiskTask/ValidateDeletionStep
// use unprimed variables to constrain the pre-state of each transition.

// Helper to build the outer envelope and write it.
inline void emitEvent(const std::string& eventName,
                      const std::string& node,
                      const std::string& task,      // empty if not task-scoped
                      const std::string& primary,   // for ReplicateDiskState only
                      const std::string& secondary, // for ReplicateDiskState only
                      const std::string& stateJson) {
    uint64_t ts = detail::nowNs();

    std::string line = "{";
    line += "\"tag\":\"trace\"";
    line += ",\"ts\":\"" + std::to_string(ts) + "\"";
    line += ",\"event\":\"" + eventName + "\"";

    if (!node.empty()) {
        line += ",\"node\":" + detail::jsonStr(node);
    }
    if (!task.empty()) {
        line += ",\"task\":" + detail::jsonStr(task);
    }
    if (!primary.empty()) {
        line += ",\"primary\":" + detail::jsonStr(primary);
        line += ",\"secondary\":" + detail::jsonStr(secondary);
    }
    line += ",\"state\":{" + stateJson + "}";
    line += "}";

    detail::writeLine(line);
}

// Helper: build node state fields string (role, termInitReady, recoveryPhase)
inline std::string nodeStateFields(const std::string& role,
                                   bool termInitReady,
                                   int recoveryPhase) {
    std::string s;
    s += "\"role\":" + detail::jsonStr(role);
    s += ",\"termInitReady\":" + std::string(termInitReady ? "true" : "false");
    s += ",\"recoveryPhase\":" + detail::jsonStr(detail::recoveryPhaseStr(recoveryPhase));
    return s;
}

// ---- Action emit functions ----

// OpObserverClearPending: emit at op_observer onCommit, BEFORE disk state changes.
// diskTaskState should be the CURRENT (pre-state) disk state = "pending".
inline void emitOpObserverClearPending(const std::string& node,
                                       const std::string& task,
                                       const std::string& role,
                                       bool termInitReady,
                                       const std::string& diskTaskState) {
    int rp = getRecoveryPhase();
    std::string st = nodeStateFields(role, termInitReady, rp);
    st += ",\"diskTaskState\":" + detail::jsonStr(diskTaskState);
    emitEvent("OpObserverClearPending", node, task, "", "", st);
}

// StepUp: emit at onStepUpComplete, BEFORE _state = kReadyForInitialization.
// Pre-state: role=Secondary, termInitReady=false, recoveryPhase=idle.
inline void emitStepUp(const std::string& node,
                       long long term) {
    // Pre-state: Secondary, termInitReady=false, recoveryPhase=idle
    // (We emit BEFORE calling ensureSet and state transition)
    setRecoveryPhase(0); // ensure idle before step-up emits
    std::string st = nodeStateFields("Secondary", false, 0);
    st += ",\"term\":" + std::to_string(term);
    emitEvent("StepUp", node, "", "", "", st);
    // After emitting, mark phase1 (recovery will start)
    setRecoveryPhase(1);
}

// RecoveryPhase1Scan: emit BEFORE the phase-1 while loop exits.
// Pre-state: role=Primary, termInitReady=true, recoveryPhase=phase1.
inline void emitRecoveryPhase1Scan(const std::string& node) {
    // Pre-state: still in phase1
    std::string st = nodeStateFields("Primary", true, 1);
    emitEvent("RecoveryPhase1Scan", node, "", "", "", st);
    setRecoveryPhase(2); // Transition to phase2 after emitting
}

// RecoveryPhase2Scan: emit BEFORE the phase-2 while loop exits.
// Pre-state: role=Primary, termInitReady=true, recoveryPhase=phase2.
inline void emitRecoveryPhase2Scan(const std::string& node) {
    // Pre-state: still in phase2
    std::string st = nodeStateFields("Primary", true, 2);
    emitEvent("RecoveryPhase2Scan", node, "", "", "", st);
    setRecoveryPhase(3); // Transition to done after emitting
}

// OpObserverRegisterTask: emit after registerTask succeeds on primary.
// Pre-state: role=Primary, termInitReady=true, current recoveryPhase.
inline void emitOpObserverRegisterTask(const std::string& node,
                                       const std::string& task) {
    int rp = getRecoveryPhase();
    std::string st = nodeStateFields("Primary", true, rp);
    emitEvent("OpObserverRegisterTask", node, task, "", "", st);
}

// DeleteOrphans: emit at "Beginning deletion" LOGV2_INFO, BEFORE deleteRangeInBatches.
// Pre-state: diskTaskState=ready (before processing flag set), deletionStep=idle.
inline void emitDeleteOrphans(const std::string& node,
                               const std::string& task,
                               const std::string& diskTaskState,  // "ready" or "processing"
                               const std::string& deletionStep) { // "idle"
    std::string st;
    st += "\"diskTaskState\":" + detail::jsonStr(diskTaskState);
    st += ",\"deletionStep\":" + detail::jsonStr(deletionStep);
    emitEvent("DeleteOrphans", node, task, "", "", st);
}

// MajorityWaitSuccess: emit after .get(opCtx) returns without throw.
// Pre-state: deletionStep=deleting.
inline void emitMajorityWaitSuccess(const std::string& node,
                                     const std::string& task) {
    // Pre-state: "deleting"
    std::string st = "\"deletionStep\":\"deleting\"";
    emitEvent("MajorityWaitSuccess", node, task, "", "", st);
}

// MajorityWaitInterrupted: emit when _stopRequested() is true after DBException.
// Pre-state: deletionStep=deleting, diskTaskState=processing.
inline void emitMajorityWaitInterrupted(const std::string& node,
                                         const std::string& task) {
    // Pre-state: "deleting", disk still "processing"
    std::string st;
    st += "\"deletionStep\":\"deleting\"";
    st += ",\"diskTaskState\":\"processing\"";
    emitEvent("MajorityWaitInterrupted", node, task, "", "", st);
}

// CompleteInMemory: emit after completeTask() returns (before removePersistentTask).
// Pre-state: deletionStep=waiting.
inline void emitCompleteInMemory(const std::string& node,
                                  const std::string& task) {
    // Pre-state: "waiting"
    std::string st;
    st += "\"deletionStep\":\"waiting\"";
    st += ",\"completionFulfilled\":false";
    emitEvent("CompleteInMemory", node, task, "", "", st);
}

// RemovePersistentTask: emit after removePersistentTask() returns.
// Pre-state: deletionStep=completing, diskTaskState=processing.
inline void emitRemovePersistentTask(const std::string& node,
                                      const std::string& task) {
    // Pre-state: "completing", disk="processing"
    std::string st;
    st += "\"deletionStep\":\"completing\"";
    st += ",\"diskTaskState\":\"processing\"";
    emitEvent("RemovePersistentTask", node, task, "", "", st);
}

// StepDown: emit at entry of onStepDown, BEFORE _stopService() runs.
// Pre-state: role=Primary, termInitReady=caller-supplied, current recoveryPhase.
inline void emitStepDown(const std::string& node, bool termInitReady = true) {
    int rp = getRecoveryPhase();
    std::string st = nodeStateFields("Primary", termInitReady, rp);
    emitEvent("StepDown", node, "", "", "", st);
    setRecoveryPhase(0); // Reset to idle after step down
}

// ReplicateDiskState: emit on secondary when oplog entry for config.rangeDeletions applied.
// diskTaskState is the SECONDARY's CURRENT (pre-state) disk state (before it catches up).
inline void emitReplicateDiskState(const std::string& primaryNode,
                                    const std::string& secondaryNode,
                                    const std::string& task,
                                    const std::string& diskTaskState) {
    std::string st = "\"diskTaskState\":" + detail::jsonStr(diskTaskState);
    emitEvent("ReplicateDiskState", "", task, primaryNode, secondaryNode, st);
}

} // namespace tlaTrace

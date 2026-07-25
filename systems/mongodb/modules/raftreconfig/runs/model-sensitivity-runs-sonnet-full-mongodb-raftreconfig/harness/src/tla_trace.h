/**
 * tla_trace.h — TLA+ trace emission for MongoDB replication coordinator.
 *
 * Thread-safe (Category A: mutex-protected global writer).
 * Timestamps use a monotonically incrementing counter incremented under _mutex.
 *
 * Usage:
 *   TlaTrace::init("/path/to/trace.ndjson");
 *   // ... in instrumented code ...
 *   TlaTrace::emitTimeout(nodeId, currentTerm, roleStr);
 *   TlaTrace::shutdown();
 */

#pragma once

#include <atomic>
#include <cstdint>
#include <fstream>
#include <mutex>
#include <string>

namespace mongo {
namespace repl {

class TlaTrace {
public:
    // Initialize the trace writer. Call once before any emit.
    static void init(const std::string& outputPath);

    // Flush and close.
    static void shutdown();

    // Emit a raw NDJSON line. The caller is responsible for building valid JSON.
    // Automatically prepends {"tag":"trace","ts":<counter>, and appends the rest.
    static void emit(const std::string& jsonBody);

    // ---------- Per-action emit helpers ----------

    // Timeout(n): node becomes candidate, increments term.
    // Trigger: after _updateTerm + voteForMyselfV1, before vote requester fires.
    static void emitTimeout(const std::string& node,
                            long long currentTerm,
                            const std::string& role);

    // RequestVotes(n): vote requests sent to all config members.
    // Trigger: after all VoteRequest messages enqueued.
    static void emitRequestVotes(const std::string& node,
                                 long long currentTerm,
                                 const std::string& role);

    // HandleRequestVote(voter, m): in-memory _lastVote updated.
    // Trigger: after _lastVote updated in topology_coordinator.cpp:3789, before persist.
    static void emitHandleRequestVote(const std::string& voterNode,
                                      const std::string& fromNode,
                                      long long msgTerm,
                                      long long currentTerm,
                                      const std::string& role,
                                      long long inMemVoteTerm);

    // PersistVote(n): durable write to local.replset.election completed.
    // Trigger: after storeLocalLastVoteDocument succeeds.
    static void emitPersistVote(const std::string& node, long long durableVoteTerm);

    // BecomeLeader(n): quorum confirmed; node transitions to primary.
    // Trigger: after _postWonElectionUpdateMemberState.
    static void emitBecomeLeader(const std::string& node,
                                 long long currentTerm,
                                 const std::string& role,
                                 bool autoReconfigPending);

    // AutoReconfig(n): step-up auto-reconfig completed.
    // Trigger: after doOptimizedReconfig returns OK.
    static void emitAutoReconfig(const std::string& node,
                                 long long configVersion,
                                 long long configTerm,
                                 const std::string& configState,
                                 bool autoReconfigPending);

    // AutoReconfigPreempted(n): concurrent reconfig blocked auto-reconfig.
    // Trigger: on ConfigurationInProgress error path.
    static void emitAutoReconfigPreempted(const std::string& node,
                                          bool autoReconfigPending,
                                          const std::string& configState);

    // ForceReconfig(n, newCfg, newVer): force reconfig applied.
    // Trigger: after _setCurrentRSConfig in force=true branch.
    static void emitForceReconfig(const std::string& node,
                                  long long newConfigVersion,
                                  long long configVersion,
                                  long long configTerm,  // will be -1
                                  const std::string& configState,
                                  long long lastCommittedInPrevConfig);

    // SafeReconfigStart(n, newCfg): configState transitions to kConfigReconfiguring.
    // Trigger: after _setConfigState(lk, kConfigReconfiguring).
    static void emitSafeReconfigStart(const std::string& node, const std::string& configState);

    // SafeReconfigSwap(n, newCfg): _setCurrentRSConfig returned (config installed).
    // Trigger: immediately after _setCurrentRSConfig(lk, opCtx, newConfig, myIndex).
    static void emitSafeReconfigSwap(const std::string& node,
                                     long long configVersion,
                                     long long configTerm,
                                     const std::string& configState);

    // SafeReconfigCaptureBarrier(n): updateLastCommittedInPrevConfig returned.
    // Trigger: immediately after _topCoord->updateLastCommittedInPrevConfig().
    static void emitSafeReconfigCaptureBarrier(const std::string& node,
                                               const std::string& configState,
                                               long long lastCommittedInPrevConfig);

    // HBReconfigSchedule(n, newCfg, v, t): configState set to kConfigHBReconfiguring.
    // Trigger: after _setConfigState(lk, kConfigHBReconfiguring) in _scheduleHeartbeatReconfig.
    // schedCfgJson must be a JSON array of host strings, e.g. "[\"h1\",\"h2\"]".
    // Including schedVer/schedTerm/schedCfg lets Trace.tla avoid the large quantifier.
    static void emitHBReconfigSchedule(const std::string& node,
                                       long long schedVer,
                                       long long schedTerm,
                                       const std::string& schedCfgJson,
                                       const std::string& configState);

    // HBReconfigFinish(n): heartbeat reconfig committed, configState returns to Steady.
    // Trigger: after new config installed in _heartbeatReconfigFinish.
    static void emitHBReconfigFinish(const std::string& node,
                                     long long configVersion,
                                     long long configTerm,
                                     const std::string& configState);

    // AppendEntry(n): leader appended a new log entry.
    // Trigger: after entry appended to local log.
    static void emitAppendEntry(const std::string& node, long long logLen);

    // AdvanceCommitIndex(n): commitIndex advanced.
    // Trigger: after commitIndex updated in _updateLastCommittedOpTimeAndWallTime.
    static void emitAdvanceCommitIndex(const std::string& node, long long commitIndex);

private:
    static std::mutex _mutex;
    static std::ofstream _out;
    static uint64_t _counter;
    static bool _initialized;

    static uint64_t _nextTs();
    static void _writeLine(const std::string& line);
};

}  // namespace repl
}  // namespace mongo

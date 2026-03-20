/* TLA+ trace instrumentation for LogCabin Raft.
 *
 * Emits NDJSON trace events from inside the real RaftConsensus code,
 * capturing state at each instrumentation point. Activated by the
 * LOGCABIN_TRACE_FILE environment variable or explicit init() call.
 *
 * All public functions are thread-safe.
 *
 * When LOGCABIN_TLA_TRACE is NOT defined, everything compiles away
 * to zero-cost no-ops.
 */

#ifndef LOGCABIN_SERVER_TLA_TRACE_H
#define LOGCABIN_SERVER_TLA_TRACE_H

#ifdef LOGCABIN_TLA_TRACE

#include <cstdint>
#include <cstdio>
#include <string>
#include <mutex>
#include <unordered_map>
#include <time.h>

namespace LogCabin {
namespace Server {
namespace TlaTrace {

/**
 * Initialize trace output to the given file path.
 * If already open, does nothing (prevents double-open / truncation).
 * Returns 0 on success.
 */
int init(const char* filepath);

/**
 * Register a mapping: implementation server ID -> TLA+ name.
 * E.g., registerServer(1, "s1").
 */
void registerServer(uint64_t implId, const std::string& tlaId);

/**
 * Look up the TLA+ name for an implementation server ID.
 * Returns "?" if not registered.
 */
const std::string& nid(uint64_t implId);

/**
 * Check whether tracing is active.
 */
bool isEnabled();

/**
 * Builder for a single NDJSON trace event line.
 *
 * Usage:
 *   TlaTrace::Event("Timeout", serverId)
 *       .state(currentTerm, "candidate", commitIndex,
 *              log->getLastLogIndex(), getLastLogTerm())
 *       .field("from", nid(peerId))
 *       .field("granted", true)
 *       .emit();
 */
class Event {
  public:
    Event(const char* name, uint64_t nodeId);

    /** Attach full state snapshot. */
    Event& state(uint64_t currentTerm, const char* role,
                 uint64_t commitIndex, uint64_t lastLogIndex,
                 uint64_t lastLogTerm);

    /** Attach a string field. */
    Event& field(const char* key, const std::string& val);
    Event& field(const char* key, const char* val);

    /** Attach a uint64 field. */
    Event& field(const char* key, uint64_t val);

    /** Attach a bool field. */
    Event& field(const char* key, bool val);

    /** Write the event line to the trace file. */
    void emit();

  private:
    static const int MAX_FIELDS = 12;

    const char* name_;
    uint64_t nodeId_;
    bool hasState_;
    uint64_t currentTerm_;
    const char* role_;
    uint64_t commitIndex_;
    uint64_t lastLogIndex_;
    uint64_t lastLogTerm_;

    struct Field {
        const char* key;
        enum { STRING, UINT, BOOL } type;
        std::string sval;
        uint64_t uval;
        bool bval;
    };
    Field fields_[MAX_FIELDS];
    int nfields_;
};

/**
 * Emit a Crash event (no state snapshot).
 */
void emitCrash(uint64_t nodeId);

/**
 * Close the trace file and flush.
 */
void close();

} // namespace TlaTrace
} // namespace Server
} // namespace LogCabin

// Helper macro: compute role string from RaftConsensus::State inside a member
// function where the private enum is accessible.
#define TLA_ROLE_STR \
    ((state == State::FOLLOWER)  ? "follower"  : \
     (state == State::CANDIDATE) ? "candidate" : "leader")

// Helper macro: full state capture from within a RaftConsensus member function.
#define TLA_STATE() \
    currentTerm, TLA_ROLE_STR, commitIndex, \
    log->getLastLogIndex(), getLastLogTerm()

#else // !LOGCABIN_TLA_TRACE

// Stubs: everything compiles away.
namespace LogCabin {
namespace Server {
namespace TlaTrace {
inline int init(const char*) { return 0; }
inline void registerServer(uint64_t, const std::string&) {}
inline bool isEnabled() { return false; }
inline void emitCrash(uint64_t) {}
inline void close() {}
} // namespace TlaTrace
} // namespace Server
} // namespace LogCabin

#endif // LOGCABIN_TLA_TRACE
#endif // LOGCABIN_SERVER_TLA_TRACE_H

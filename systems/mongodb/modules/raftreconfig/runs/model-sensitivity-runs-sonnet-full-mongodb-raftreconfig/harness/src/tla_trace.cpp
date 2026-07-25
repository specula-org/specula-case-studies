/**
 * tla_trace.cpp — TLA+ trace emission implementation.
 *
 * Every emitted line has this structure:
 *   {"tag":"trace","ts":<counter>,"event":"<Name>","node":"<id>","post":{...}[,...]}
 *
 * The counter is monotonically increasing and is incremented under _mutex,
 * so events emitted under the replication mutex get consistent ordering.
 */

#include "mongo/db/repl/tla_trace.h"

#include <cstdlib>
#include <sstream>
#include <string>

namespace mongo {
namespace repl {

// ---- statics ----
std::mutex   TlaTrace::_mutex;
std::ofstream TlaTrace::_out;
uint64_t     TlaTrace::_counter = 0;
bool         TlaTrace::_initialized = false;

// ---- internal helpers ----

static std::string jsonStr(const std::string& s) {
    // Minimal JSON string escaping (values we emit are trusted internal strings).
    std::string out;
    out.reserve(s.size() + 2);
    out += '"';
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            default:   out += c;
        }
    }
    out += '"';
    return out;
}

uint64_t TlaTrace::_nextTs() {
    return ++_counter;
}

void TlaTrace::_writeLine(const std::string& line) {
    if (!_initialized) return;
    _out << line << '\n';
    _out.flush();
}

// ---- public API ----

void TlaTrace::init(const std::string& outputPath) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (_initialized) return;
    _out.open(outputPath, std::ios::out | std::ios::trunc);
    _initialized = _out.is_open();
    _counter = 0;
}

void TlaTrace::shutdown() {
    std::lock_guard<std::mutex> lk(_mutex);
    if (_initialized) {
        _out.flush();
        _out.close();
        _initialized = false;
    }
}

void TlaTrace::emit(const std::string& jsonBody) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream oss;
    oss << "{\"tag\":\"trace\",\"ts\":" << ts << ',' << jsonBody << '}';
    _writeLine(oss.str());
}

// ---- per-action emitters ----

void TlaTrace::emitTimeout(const std::string& node,
                           long long currentTerm,
                           const std::string& role) {
    std::ostringstream body;
    body << "\"event\":\"Timeout\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"currentTerm\":" << currentTerm
         << ",\"role\":" << jsonStr(role) << "}}";
    // emit() adds the outer braces — we must NOT add a trailing } here.
    // Actually emit() wraps with { and }, so body must be the interior:
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"Timeout\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"currentTerm\":" << currentTerm
         << ",\"role\":" << jsonStr(role) << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitRequestVotes(const std::string& node,
                                long long currentTerm,
                                const std::string& role) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"RequestVotes\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"currentTerm\":" << currentTerm
         << ",\"role\":" << jsonStr(role) << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitHandleRequestVote(const std::string& voterNode,
                                     const std::string& fromNode,
                                     long long msgTerm,
                                     long long currentTerm,
                                     const std::string& role,
                                     long long inMemVoteTerm) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"HandleRequestVote\",\"node\":" << jsonStr(voterNode)
         << ",\"from\":" << jsonStr(fromNode)
         << ",\"msgTerm\":" << msgTerm
         << ",\"post\":{\"currentTerm\":" << currentTerm
         << ",\"role\":" << jsonStr(role)
         << ",\"inMemVoteTerm\":" << inMemVoteTerm << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitPersistVote(const std::string& node, long long durableVoteTerm) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"PersistVote\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"durableVoteTerm\":" << durableVoteTerm << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitBecomeLeader(const std::string& node,
                                long long currentTerm,
                                const std::string& role,
                                bool autoReconfigPending) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"BecomeLeader\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"currentTerm\":" << currentTerm
         << ",\"role\":" << jsonStr(role)
         << ",\"autoReconfigPending\":" << (autoReconfigPending ? "true" : "false") << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitAutoReconfig(const std::string& node,
                                long long configVersion,
                                long long configTerm,
                                const std::string& configState,
                                bool autoReconfigPending) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"AutoReconfig\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"configVersion\":" << configVersion
         << ",\"configTerm\":" << configTerm
         << ",\"configState\":" << jsonStr(configState)
         << ",\"autoReconfigPending\":" << (autoReconfigPending ? "true" : "false") << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitAutoReconfigPreempted(const std::string& node,
                                         bool autoReconfigPending,
                                         const std::string& configState) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"AutoReconfigPreempted\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"autoReconfigPending\":" << (autoReconfigPending ? "true" : "false")
         << ",\"configState\":" << jsonStr(configState) << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitForceReconfig(const std::string& node,
                                 long long newConfigVersion,
                                 long long configVersion,
                                 long long configTerm,
                                 const std::string& configState,
                                 long long lastCommittedInPrevConfig) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"ForceReconfig\",\"node\":" << jsonStr(node)
         << ",\"newConfigVersion\":" << newConfigVersion
         << ",\"post\":{\"configVersion\":" << configVersion
         << ",\"configTerm\":" << configTerm
         << ",\"configState\":" << jsonStr(configState)
         << ",\"lastCommittedInPrevConfig\":" << lastCommittedInPrevConfig << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitSafeReconfigStart(const std::string& node, const std::string& configState) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"SafeReconfigStart\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"configState\":" << jsonStr(configState) << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitSafeReconfigSwap(const std::string& node,
                                    long long configVersion,
                                    long long configTerm,
                                    const std::string& configState) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"SafeReconfigSwap\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"configVersion\":" << configVersion
         << ",\"configTerm\":" << configTerm
         << ",\"configState\":" << jsonStr(configState) << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitSafeReconfigCaptureBarrier(const std::string& node,
                                              const std::string& configState,
                                              long long lastCommittedInPrevConfig) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"SafeReconfigCaptureBarrier\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"configState\":" << jsonStr(configState)
         << ",\"lastCommittedInPrevConfig\":" << lastCommittedInPrevConfig << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitHBReconfigSchedule(const std::string& node,
                                      long long schedVer,
                                      long long schedTerm,
                                      const std::string& schedCfgJson,
                                      const std::string& configState) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"HBReconfigSchedule\",\"node\":" << jsonStr(node)
         << ",\"schedVer\":" << schedVer
         << ",\"schedTerm\":" << schedTerm
         << ",\"schedCfg\":" << schedCfgJson
         << ",\"post\":{\"configState\":" << jsonStr(configState) << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitHBReconfigFinish(const std::string& node,
                                    long long configVersion,
                                    long long configTerm,
                                    const std::string& configState) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"HBReconfigFinish\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"configVersion\":" << configVersion
         << ",\"configTerm\":" << configTerm
         << ",\"configState\":" << jsonStr(configState) << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitAppendEntry(const std::string& node, long long logLen) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"AppendEntry\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"logLen\":" << logLen << "}}";
    _writeLine(line.str());
}

void TlaTrace::emitAdvanceCommitIndex(const std::string& node, long long commitIndex) {
    std::lock_guard<std::mutex> lk(_mutex);
    if (!_initialized) return;
    uint64_t ts = _nextTs();
    std::ostringstream line;
    line << "{\"tag\":\"trace\",\"ts\":" << ts
         << ",\"event\":\"AdvanceCommitIndex\",\"node\":" << jsonStr(node)
         << ",\"post\":{\"commitIndex\":" << commitIndex << "}}";
    _writeLine(line.str());
}

}  // namespace repl
}  // namespace mongo

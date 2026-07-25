#pragma once

#include <string>
#include <map>
#include <memory>
#include <fstream>
#include <mutex>
#include <chrono>
#include <boost/optional.hpp>
#include <nlohmann/json.hpp>

namespace mongo {
namespace tla_trace {

using json = nlohmann::json;

class TraceEmitter {
public:
    TraceEmitter(const std::string& trace_file_path);
    ~TraceEmitter();

    // Initialize and set up the trace file
    void initialize();

    // Register an operation context to a stable ID
    void registerOpCtx(void* opCtx_ptr, int opCtx_id);
    void unregisterOpCtx(void* opCtx_ptr);
    int getOpCtxId(void* opCtx_ptr);

    // Emit a trace event with full state
    void emitEvent(
        const std::string& event_name,
        const std::string& session_id,
        bool forKill,  // For CheckOutSession
        const std::string& session_state,
        int kills_requested,
        bool marked_for_reap,
        const std::string& reap_mode,
        const std::string& checkout_opctx,
        const std::string& cache_state
    );

    // Simplified emitters for different event types
    void emitCheckOutSession(
        const std::string& sid,
        bool forKill,
        const std::string& session_state,
        int kills_requested,
        bool marked_for_reap,
        const std::string& reap_mode,
        const std::string& checkout_opctx,
        const std::string& cache_state
    );

    void emitKill(
        const std::string& sid,
        const std::string& session_state,
        int kills_requested,
        bool marked_for_reap,
        const std::string& reap_mode,
        const std::string& checkout_opctx,
        const std::string& cache_state
    );

    void emitReleaseSession(
        const std::string& sid,
        const std::string& session_state,
        int kills_requested,
        bool marked_for_reap,
        const std::string& reap_mode,
        const std::string& checkout_opctx,
        const std::string& cache_state
    );

    void emitScanSessionsForReap(
        const std::string& sid,
        const std::vector<std::string>& marked_sessions
    );

    void emitFinishReap(const std::string& sid);

    void emitCreateChildSession(
        const std::string& parent_sid,
        const std::string& child_sid
    );

    void emitExecuteEagerReapCallback(const std::string& sid);
    void emitCompleteEagerReapCallback(const std::string& sid);

    void flush();
    void close();

private:
    std::string trace_file_path_;
    std::unique_ptr<std::ofstream> trace_file_;
    std::mutex mutex_;
    std::map<void*, int> opctx_map_;
    int next_opctx_id_;

    uint64_t getTimestampNanos();
    json buildStateObject(
        const std::string& session_state,
        int kills_requested,
        bool marked_for_reap,
        const std::string& reap_mode,
        const std::string& checkout_opctx,
        const std::string& cache_state
    );
};

// Global trace emitter instance
extern std::unique_ptr<TraceEmitter> g_trace_emitter;

void initializeTraceEmitter(const std::string& trace_file_path);

}  // namespace tla_trace
}  // namespace mongo

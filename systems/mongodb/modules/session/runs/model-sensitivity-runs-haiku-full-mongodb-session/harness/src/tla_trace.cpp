#include "tla_trace.h"
#include <chrono>
#include <iostream>
#include <sstream>
#include <iomanip>

namespace mongo {
namespace tla_trace {

std::unique_ptr<TraceEmitter> g_trace_emitter;

TraceEmitter::TraceEmitter(const std::string& trace_file_path)
    : trace_file_path_(trace_file_path), next_opctx_id_(0) {
    initialize();
}

TraceEmitter::~TraceEmitter() {
    close();
}

void TraceEmitter::initialize() {
    std::lock_guard<std::mutex> lock(mutex_);
    trace_file_ = std::make_unique<std::ofstream>(trace_file_path_, std::ios::app);
    if (!trace_file_->is_open()) {
        std::cerr << "Failed to open trace file: " << trace_file_path_ << std::endl;
    }
}

void TraceEmitter::registerOpCtx(void* opCtx_ptr, int opCtx_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    opctx_map_[opCtx_ptr] = opCtx_id;
}

void TraceEmitter::unregisterOpCtx(void* opCtx_ptr) {
    std::lock_guard<std::mutex> lock(mutex_);
    opctx_map_.erase(opCtx_ptr);
}

int TraceEmitter::getOpCtxId(void* opCtx_ptr) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (opctx_map_.find(opCtx_ptr) != opctx_map_.end()) {
        return opctx_map_[opCtx_ptr];
    }
    opctx_map_[opCtx_ptr] = next_opctx_id_++;
    return opctx_map_[opCtx_ptr];
}

uint64_t TraceEmitter::getTimestampNanos() {
    auto now = std::chrono::high_resolution_clock::now();
    auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(
        now.time_since_epoch()).count();
    return static_cast<uint64_t>(nanos);
}

json TraceEmitter::buildStateObject(
    const std::string& session_state,
    int kills_requested,
    bool marked_for_reap,
    const std::string& reap_mode,
    const std::string& checkout_opctx,
    const std::string& cache_state) {
    json state;
    state["sessionState"] = session_state;
    state["killsRequested"] = kills_requested;
    state["markedForReap"] = marked_for_reap;
    state["reapMode"] = reap_mode;
    state["checkoutOpCtx"] = checkout_opctx;
    state["cacheState"] = cache_state;
    return state;
}

void TraceEmitter::emitEvent(
    const std::string& event_name,
    const std::string& session_id,
    bool forKill,
    const std::string& session_state,
    int kills_requested,
    bool marked_for_reap,
    const std::string& reap_mode,
    const std::string& checkout_opctx,
    const std::string& cache_state) {

    std::lock_guard<std::mutex> lock(mutex_);
    if (!trace_file_ || !trace_file_->is_open()) {
        return;
    }

    json event;
    event["event"] = event_name;
    event["timestamp"] = getTimestampNanos();
    event["sessionId"] = session_id;

    if (event_name == "CheckOutSession") {
        event["forKill"] = forKill;
    }

    event["state"] = buildStateObject(
        session_state, kills_requested, marked_for_reap,
        reap_mode, checkout_opctx, cache_state);

    *trace_file_ << event.dump() << std::endl;
    trace_file_->flush();
}

void TraceEmitter::emitCheckOutSession(
    const std::string& sid,
    bool forKill,
    const std::string& session_state,
    int kills_requested,
    bool marked_for_reap,
    const std::string& reap_mode,
    const std::string& checkout_opctx,
    const std::string& cache_state) {
    emitEvent("CheckOutSession", sid, forKill, session_state, kills_requested,
              marked_for_reap, reap_mode, checkout_opctx, cache_state);
}

void TraceEmitter::emitKill(
    const std::string& sid,
    const std::string& session_state,
    int kills_requested,
    bool marked_for_reap,
    const std::string& reap_mode,
    const std::string& checkout_opctx,
    const std::string& cache_state) {
    emitEvent("Kill", sid, false, session_state, kills_requested,
              marked_for_reap, reap_mode, checkout_opctx, cache_state);
}

void TraceEmitter::emitReleaseSession(
    const std::string& sid,
    const std::string& session_state,
    int kills_requested,
    bool marked_for_reap,
    const std::string& reap_mode,
    const std::string& checkout_opctx,
    const std::string& cache_state) {
    emitEvent("ReleaseSession", sid, false, session_state, kills_requested,
              marked_for_reap, reap_mode, checkout_opctx, cache_state);
}

void TraceEmitter::emitScanSessionsForReap(
    const std::string& sid,
    const std::vector<std::string>& marked_sessions) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!trace_file_ || !trace_file_->is_open()) {
        return;
    }

    json event;
    event["event"] = "ScanSessionsForReap";
    event["timestamp"] = getTimestampNanos();
    event["sessionId"] = sid;
    event["marked_for_reap"] = marked_sessions;

    *trace_file_ << event.dump() << std::endl;
    trace_file_->flush();
}

void TraceEmitter::emitFinishReap(const std::string& sid) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!trace_file_ || !trace_file_->is_open()) {
        return;
    }

    json event;
    event["event"] = "FinishReap";
    event["timestamp"] = getTimestampNanos();
    event["sessionId"] = sid;

    *trace_file_ << event.dump() << std::endl;
    trace_file_->flush();
}

void TraceEmitter::emitCreateChildSession(
    const std::string& parent_sid,
    const std::string& child_sid) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!trace_file_ || !trace_file_->is_open()) {
        return;
    }

    json event;
    event["event"] = "CreateChildSession";
    event["timestamp"] = getTimestampNanos();
    event["parentSessionId"] = parent_sid;
    event["childSessionId"] = child_sid;

    *trace_file_ << event.dump() << std::endl;
    trace_file_->flush();
}

void TraceEmitter::emitExecuteEagerReapCallback(const std::string& sid) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!trace_file_ || !trace_file_->is_open()) {
        return;
    }

    json event;
    event["event"] = "ExecuteEagerReapCallback";
    event["timestamp"] = getTimestampNanos();
    event["sessionId"] = sid;

    *trace_file_ << event.dump() << std::endl;
    trace_file_->flush();
}

void TraceEmitter::emitCompleteEagerReapCallback(const std::string& sid) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!trace_file_ || !trace_file_->is_open()) {
        return;
    }

    json event;
    event["event"] = "CompleteEagerReapCallback";
    event["timestamp"] = getTimestampNanos();
    event["sessionId"] = sid;

    *trace_file_ << event.dump() << std::endl;
    trace_file_->flush();
}

void TraceEmitter::flush() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (trace_file_ && trace_file_->is_open()) {
        trace_file_->flush();
    }
}

void TraceEmitter::close() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (trace_file_ && trace_file_->is_open()) {
        trace_file_->flush();
        trace_file_->close();
    }
}

void initializeTraceEmitter(const std::string& trace_file_path) {
    g_trace_emitter = std::make_unique<TraceEmitter>(trace_file_path);
}

}  // namespace tla_trace
}  // namespace mongo

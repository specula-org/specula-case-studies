/*
 * tla_trace.h — Header-only TLA+ trace emission for sonic-linkmgrd
 *
 * Emits NDJSON trace events for Trace.tla validation.
 * Guarded by LINKMGRD_TRACE; zero overhead when disabled.
 *
 * Category A (distributed/event-driven) — mutex-protected single writer.
 */
#pragma once

#ifdef LINKMGRD_TRACE

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

#include "link_prober/LinkProberState.h"
#include "mux_state/MuxState.h"
#include "link_state/LinkState.h"
#include "common/MuxPortConfig.h"
#include "link_manager/LinkManagerStateMachineBase.h"

namespace tla_trace {

// =====================================================================
//  String conversion helpers
// =====================================================================

inline const char* lpStateStr(link_prober::LinkProberState::Label s) {
    switch (s) {
        case link_prober::LinkProberState::Active:      return "active";
        case link_prober::LinkProberState::Standby:     return "active"; // maps to active in AA
        case link_prober::LinkProberState::Unknown:     return "unknown";
        case link_prober::LinkProberState::Wait:        return "wait";
        case link_prober::LinkProberState::PeerActive:  return "peer_active";
        case link_prober::LinkProberState::PeerUnknown: return "peer_unknown";
        case link_prober::LinkProberState::PeerWait:    return "peer_wait";
        default: return "unknown";
    }
}

inline const char* muxStateStr(mux_state::MuxState::Label s) {
    switch (s) {
        case mux_state::MuxState::Active:  return "active";
        case mux_state::MuxState::Standby: return "standby";
        case mux_state::MuxState::Unknown: return "unknown";
        case mux_state::MuxState::Error:   return "error";
        case mux_state::MuxState::Wait:    return "wait";
        default: return "unknown";
    }
}

inline const char* linkStateStr(link_state::LinkState::Label s) {
    switch (s) {
        case link_state::LinkState::Up:   return "up";
        case link_state::LinkState::Down: return "down";
        default: return "down";
    }
}

inline const char* defaultRouteStr(link_manager::LinkManagerStateMachineBase::DefaultRoute dr) {
    switch (dr) {
        case link_manager::LinkManagerStateMachineBase::DefaultRoute::OK:   return "ok";
        case link_manager::LinkManagerStateMachineBase::DefaultRoute::NA:   return "na";
        case link_manager::LinkManagerStateMachineBase::DefaultRoute::Wait: return "wait";
        default: return "wait";
    }
}

inline const char* modeStr(common::MuxPortConfig::Mode m) {
    switch (m) {
        case common::MuxPortConfig::Auto:     return "auto";
        case common::MuxPortConfig::Active:   return "active";
        case common::MuxPortConfig::Standby:  return "standby";
        case common::MuxPortConfig::Detached: return "detached";
        case common::MuxPortConfig::Manual:   return "active"; // manual maps to active behavior
        default: return "auto";
    }
}

// Map heartbeat new state to event name
inline const char* heartbeatEventName(link_prober::LinkProberState::Label newState) {
    switch (newState) {
        case link_prober::LinkProberState::Active:      return "HeartbeatActive";
        case link_prober::LinkProberState::Unknown:     return "HeartbeatUnknown";
        case link_prober::LinkProberState::PeerActive:  return "PeerHeartbeatActive";
        case link_prober::LinkProberState::PeerUnknown: return "PeerHeartbeatUnknown";
        default: return nullptr; // no trace for other transitions
    }
}

// =====================================================================
//  Singleton trace writer
// =====================================================================

class TraceWriter {
public:
    static TraceWriter& instance() {
        static TraceWriter w;
        return w;
    }

    void init(const std::string& filepath) {
        std::lock_guard<std::mutex> lock(mu_);
        if (file_) fclose(file_);
        file_ = fopen(filepath.c_str(), "w");
    }

    void initFromEnv() {
        const char* p = std::getenv("LINKMGRD_TRACE_FILE");
        if (p && p[0]) init(p);
    }

    void close() {
        std::lock_guard<std::mutex> lock(mu_);
        if (file_) { fclose(file_); file_ = nullptr; }
    }

    void registerTor(const std::string& portName, const std::string& torId) {
        std::lock_guard<std::mutex> lock(mu_);
        torMap_[portName] = torId;
    }

    const char* getTorId(const std::string& portName) {
        std::lock_guard<std::mutex> lock(mu_);
        auto it = torMap_.find(portName);
        if (it != torMap_.end()) return it->second.c_str();
        // Auto-assign: first port → t1, second → t2
        int n = static_cast<int>(torMap_.size()) + 1;
        char buf[16];
        snprintf(buf, sizeof(buf), "t%d", n);
        torMap_[portName] = buf;
        return torMap_[portName].c_str();
    }

    void write(const char* line) {
        std::lock_guard<std::mutex> lock(mu_);
        if (file_) {
            fputs(line, file_);
            fputc('\n', file_);
            fflush(file_);
        }
    }

    bool isOpen() {
        std::lock_guard<std::mutex> lock(mu_);
        return file_ != nullptr;
    }

private:
    TraceWriter() : file_(nullptr) {
        // Auto-init from environment on first access
        const char* p = std::getenv("LINKMGRD_TRACE_FILE");
        if (p && p[0]) file_ = fopen(p, "w");
    }
    ~TraceWriter() { if (file_) fclose(file_); }
    TraceWriter(const TraceWriter&) = delete;
    TraceWriter& operator=(const TraceWriter&) = delete;

    std::mutex mu_;
    FILE* file_;
    std::unordered_map<std::string, std::string> torMap_;
};

// =====================================================================
//  Timestamp
// =====================================================================

inline int64_t nowNanos() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

// =====================================================================
//  Emit helpers — each writes one NDJSON line
// =====================================================================

// --- Heartbeat events (HeartbeatActive, HeartbeatUnknown, PeerHeartbeat*) ---
// Called from LinkProberStateMachineBase::processEvent<T>
inline void emitHeartbeat(
    const std::string& portName,
    link_prober::LinkProberState::Label newState)
{
    const char* evName = heartbeatEventName(newState);
    if (!evName) return;
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"%s","tor":"%s","ts":%lld,"state":{"sub_lp_state":"%s"},"data":{}})",
        evName,
        w.getTorId(portName),
        (long long)nowNanos(),
        lpStateStr(newState));
    w.write(buf);
}

// --- MuxNotification ---
inline void emitMuxNotification(
    const std::string& portName,
    mux_state::MuxState::Label subMuxState,
    mux_state::MuxState::Label lastNotification,
    const char* source)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"MuxNotification","tor":"%s","ts":%lld,"state":{"sub_mux_state":"%s","last_mux_notification":"%s"},"data":{"source":"%s"}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        muxStateStr(subMuxState),
        muxStateStr(lastNotification),
        source);
    w.write(buf);
}

// --- LinkChange ---
inline void emitLinkChange(
    const std::string& portName,
    link_state::LinkState::Label newState)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"LinkChange","tor":"%s","ts":%lld,"state":{"sub_link_state":"%s"},"data":{"new_state":"%s"}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        linkStateStr(newState),
        linkStateStr(newState));
    w.write(buf);
}

// --- ProcessEvent ---
// Called after composite state update in handleStateChange handlers
inline void emitProcessEvent(
    const std::string& portName,
    link_prober::LinkProberState::Label lpState,
    mux_state::MuxState::Label muxState,
    link_state::LinkState::Label linkState,
    mux_state::MuxState::Label peerMuxState,
    link_prober::LinkProberState::Label peerLpState,
    uint32_t muxProbeBackoff,
    const char* eventType,
    const char* handlerName)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[2048];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"ProcessEvent","tor":"%s","ts":%lld,)"
        R"("state":{"lp_state":"%s","mux_state":"%s","link_state":"%s",)"
        R"("peer_mux_state":"%s","peer_lp_state":"%s","mux_probe_backoff":%u},)"
        R"("data":{"event_type":"%s","handler_name":"%s"}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        lpStateStr(lpState),
        muxStateStr(muxState),
        linkStateStr(linkState),
        muxStateStr(peerMuxState),
        lpStateStr(peerLpState),
        muxProbeBackoff,
        eventType,
        handlerName);
    w.write(buf);
}

// --- MuxProbeTimeout ---
inline void emitMuxProbeTimeout(
    const std::string& portName,
    uint32_t muxProbeBackoff,
    mux_state::MuxState::Label muxStateAtExpiry)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"MuxProbeTimeout","tor":"%s","ts":%lld,"state":{"mux_probe_backoff":%u},"data":{"mux_state_at_expiry":"%s"}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        muxProbeBackoff,
        muxStateStr(muxStateAtExpiry));
    w.write(buf);
}

// --- MuxWaitTimeout ---
inline void emitMuxWaitTimeout(
    const std::string& portName,
    const char* waitCause)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"MuxWaitTimeout","tor":"%s","ts":%lld,"state":{},"data":{"wait_cause":"%s"}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        waitCause);
    w.write(buf);
}

// --- PeerWaitTimeout ---
inline void emitPeerWaitTimeout(
    const std::string& portName,
    mux_state::MuxState::Label lastSetPeerMuxState)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"PeerWaitTimeout","tor":"%s","ts":%lld,"state":{},"data":{"last_set_peer_mux_state":"%s"}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        muxStateStr(lastSetPeerMuxState));
    w.write(buf);
}

// --- ResyncTimeout ---
inline void emitResyncTimeout(
    const std::string& portName,
    bool waitMux)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"ResyncTimeout","tor":"%s","ts":%lld,"state":{},"data":{"wait_mux":%s}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        waitMux ? "true" : "false");
    w.write(buf);
}

// --- DefaultRouteChange ---
inline void emitDefaultRouteChange(
    const std::string& portName,
    link_manager::LinkManagerStateMachineBase::DefaultRoute newRoute,
    link_manager::LinkManagerStateMachineBase::DefaultRoute oldRoute)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"DefaultRouteChange","tor":"%s","ts":%lld,"state":{"default_route":"%s"},"data":{"old_route":"%s","new_route":"%s"}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        defaultRouteStr(newRoute),
        defaultRouteStr(oldRoute),
        defaultRouteStr(newRoute));
    w.write(buf);
}

// --- ModeChange ---
inline void emitModeChange(
    const std::string& portName,
    common::MuxPortConfig::Mode newMode,
    common::MuxPortConfig::Mode oldMode)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"ModeChange","tor":"%s","ts":%lld,"state":{"mode":"%s"},"data":{"old_mode":"%s","new_mode":"%s"}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        modeStr(newMode),
        modeStr(oldMode),
        modeStr(newMode));
    w.write(buf);
}

// --- SoCRestart ---
inline void emitSoCRestart(
    const std::string& portName,
    mux_state::MuxState::Label peerMuxState,
    link_prober::LinkProberState::Label peerLpState)
{
    auto& w = TraceWriter::instance();
    if (!w.isOpen()) return;

    char buf[1024];
    snprintf(buf, sizeof(buf),
        R"({"tag":"linkmgrd","event":"SoCRestart","tor":"%s","ts":%lld,"state":{"peer_mux_state":"%s","peer_lp_state":"%s"},"data":{}})",
        w.getTorId(portName),
        (long long)nowNanos(),
        muxStateStr(peerMuxState),
        lpStateStr(peerLpState));
    w.write(buf);
}

} // namespace tla_trace

// =====================================================================
//  Convenience macros (no-op when LINKMGRD_TRACE undefined)
// =====================================================================

#define TLA_TRACE_HEARTBEAT(portName, newState) \
    tla_trace::emitHeartbeat(portName, newState)

#define TLA_TRACE_MUX_NOTIFICATION(portName, subMux, lastNotif, source) \
    tla_trace::emitMuxNotification(portName, subMux, lastNotif, source)

#define TLA_TRACE_LINK_CHANGE(portName, newState) \
    tla_trace::emitLinkChange(portName, newState)

#define TLA_TRACE_PROCESS_EVENT(portName, lp, mux, link, peerMux, peerLp, backoff, evType, handler) \
    tla_trace::emitProcessEvent(portName, lp, mux, link, peerMux, peerLp, backoff, evType, handler)

#define TLA_TRACE_MUX_PROBE_TIMEOUT(portName, backoff, muxAtExpiry) \
    tla_trace::emitMuxProbeTimeout(portName, backoff, muxAtExpiry)

#define TLA_TRACE_MUX_WAIT_TIMEOUT(portName, cause) \
    tla_trace::emitMuxWaitTimeout(portName, cause)

#define TLA_TRACE_PEER_WAIT_TIMEOUT(portName, lastSetPeer) \
    tla_trace::emitPeerWaitTimeout(portName, lastSetPeer)

#define TLA_TRACE_RESYNC_TIMEOUT(portName, waitMux) \
    tla_trace::emitResyncTimeout(portName, waitMux)

#define TLA_TRACE_DEFAULT_ROUTE_CHANGE(portName, newRoute, oldRoute) \
    tla_trace::emitDefaultRouteChange(portName, newRoute, oldRoute)

#define TLA_TRACE_MODE_CHANGE(portName, newMode, oldMode) \
    tla_trace::emitModeChange(portName, newMode, oldMode)

#define TLA_TRACE_SOC_RESTART(portName, peerMux, peerLp) \
    tla_trace::emitSoCRestart(portName, peerMux, peerLp)

#else // !LINKMGRD_TRACE

#define TLA_TRACE_HEARTBEAT(portName, newState) ((void)0)
#define TLA_TRACE_MUX_NOTIFICATION(portName, subMux, lastNotif, source) ((void)0)
#define TLA_TRACE_LINK_CHANGE(portName, newState) ((void)0)
#define TLA_TRACE_PROCESS_EVENT(portName, lp, mux, link, peerMux, peerLp, backoff, evType, handler) ((void)0)
#define TLA_TRACE_MUX_PROBE_TIMEOUT(portName, backoff, muxAtExpiry) ((void)0)
#define TLA_TRACE_MUX_WAIT_TIMEOUT(portName, cause) ((void)0)
#define TLA_TRACE_PEER_WAIT_TIMEOUT(portName, lastSetPeer) ((void)0)
#define TLA_TRACE_RESYNC_TIMEOUT(portName, waitMux) ((void)0)
#define TLA_TRACE_DEFAULT_ROUTE_CHANGE(portName, newRoute, oldRoute) ((void)0)
#define TLA_TRACE_MODE_CHANGE(portName, newMode, oldMode) ((void)0)
#define TLA_TRACE_SOC_RESTART(portName, peerMux, peerLp) ((void)0)

#endif // LINKMGRD_TRACE

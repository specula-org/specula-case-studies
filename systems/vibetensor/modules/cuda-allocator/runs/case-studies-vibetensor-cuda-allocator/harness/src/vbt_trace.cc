// SPDX-License-Identifier: Apache-2.0
#include "vbt_trace.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <sys/syscall.h>
#include <unistd.h>

namespace vbt_trace {

thread_local ThreadState tls;
thread_local bool fail_next_event_record = false;

GlobalState& globals() {
    static GlobalState g;
    return g;
}

void init_process(const char* path_prefix) {
    auto& g = globals();
    g.prefix = path_prefix ? path_prefix : "trace";
    g.next_tid.store(0);
    g.next_block_id.store(1);
    g.next_stream_id.store(1);
    g.block_ids.clear();
    g.retired_block_ids.clear();
    g.stream_ids.clear();
}

void thread_register() {
    if (tls.fp) return;
    auto& g = globals();
    int tid = g.next_tid.fetch_add(1);
    char path[1024];
    std::snprintf(path, sizeof(path),
                  "%s-thread-%d.ndjson", g.prefix.c_str(), tid);
    tls.fp  = std::fopen(path, "w");
    tls.tid = tid;
    if (!tls.fp) {
        std::fprintf(stderr,
                     "[vbt_trace] failed to open %s: %s\n",
                     path, std::strerror(errno));
    }
}

void shutdown() {
    // Flush every thread's file by iterating through registered threads.
    // Each thread's own tls.fp must be flushed by that thread; here we can
    // only flush the calling thread.  Tests should call this from each
    // worker at the end of their scenario body.
    if (tls.fp) {
        std::fflush(tls.fp);
        std::fclose(tls.fp);
        tls.fp = nullptr;
    }
}

// -----------------------------------------------------------------------------
// ID interning
// -----------------------------------------------------------------------------
int register_block(const void* block_ptr) {
    auto& g = globals();
    std::lock_guard<std::mutex> lk(g.block_id_mu);
    auto addr = reinterpret_cast<std::uintptr_t>(block_ptr);
    auto it = g.block_ids.find(addr);
    if (it != g.block_ids.end()) return it->second;
    int id = g.next_block_id.fetch_add(1);
    g.block_ids[addr] = id;
    return id;
}

int block_id_of(const void* block_ptr) {
    if (!block_ptr) return 0;
    auto& g = globals();
    std::lock_guard<std::mutex> lk(g.block_id_mu);
    auto addr = reinterpret_cast<std::uintptr_t>(block_ptr);
    auto it = g.block_ids.find(addr);
    if (it != g.block_ids.end()) return it->second;
    auto jt = g.retired_block_ids.find(addr);
    if (jt != g.retired_block_ids.end()) return jt->second;
    // Lazy-intern unknown blocks too (defensive — shouldn't happen if
    // register_block is called on every new Block).
    int id = g.next_block_id.fetch_add(1);
    g.block_ids[addr] = id;
    return id;
}

void retire_block(const void* block_ptr) {
    if (!block_ptr) return;
    auto& g = globals();
    std::lock_guard<std::mutex> lk(g.block_id_mu);
    auto addr = reinterpret_cast<std::uintptr_t>(block_ptr);
    auto it = g.block_ids.find(addr);
    if (it == g.block_ids.end()) return;
    g.retired_block_ids[addr] = it->second;
    g.block_ids.erase(it);
}

int retired_block_id_of(const void* block_ptr) {
    if (!block_ptr) return 0;
    auto& g = globals();
    std::lock_guard<std::mutex> lk(g.block_id_mu);
    auto addr = reinterpret_cast<std::uintptr_t>(block_ptr);
    auto it = g.retired_block_ids.find(addr);
    if (it != g.retired_block_ids.end()) return it->second;
    return 0;
}

int stream_id_of(std::uint64_t sid) {
    if (sid == 0) return 0;  // NullStream / default
    auto& g = globals();
    std::lock_guard<std::mutex> lk(g.stream_id_mu);
    auto it = g.stream_ids.find(sid);
    if (it != g.stream_ids.end()) return it->second;
    int id = g.next_stream_id.fetch_add(1);
    g.stream_ids[sid] = id;
    return id;
}

// -----------------------------------------------------------------------------
// Emit
// -----------------------------------------------------------------------------
void emit_line(const Timebox& tb,
               const char*    state_json,
               const char*    fields_json) {
    if (!tls.fp) return;

    const std::uint64_t end = tb.ended ? tb.end : rdtsc();
    // NDJSON envelope per references/trace-module-patterns.md § Category B.
    //   {"tag":"trace", "name":"X", "tid":N, "start":S, "end":E,
    //    "state":{...}, "fields":{...}}
    std::fprintf(tls.fp,
        "{\"tag\":\"trace\","
        "\"name\":\"%s\","
        "\"tid\":%d,"
        "\"start\":%llu,"
        "\"end\":%llu,"
        "\"state\":{%s},"
        "\"fields\":{%s}}\n",
        tb.name, tls.tid,
        (unsigned long long)tb.start,
        (unsigned long long)end,
        state_json ? state_json : "",
        fields_json ? fields_json : "");
}

void emit_name(const Timebox& tb, const char* state_json) {
    emit_line(tb, state_json, "");
}

// -----------------------------------------------------------------------------
// Format a BaseStateSnapshot into a JSON object body
// -----------------------------------------------------------------------------
std::string format_state(const BaseStateSnapshot& s) {
    std::ostringstream os;
    os  << "\"existingBlockIds\":" << (s.existingBlockIds.empty() ? "[]" : s.existingBlockIds)
        << ",\"activeBlockIds\":"  << (s.activeBlockIds.empty()   ? "[]" : s.activeBlockIds)
        << ",\"perStreamFree\":"   << (s.perStreamFree.empty()    ? "{}" : s.perStreamFree)
        << ",\"crossStreamFree\":" << (s.crossStreamFree.empty()  ? "[]" : s.crossStreamFree)
        << ",\"deferredLen\":"     << s.deferredLen
        << ",\"limboLens\":"       << (s.limboLens.empty() ? "{}" : s.limboLens)
        << ",\"reservedBytes\":"   << s.reservedBytes
        << ",\"routingFlag\":"     << (s.routingFlag ? "true" : "false")
        << ",\"tlsActive\":"       << (s.tlsActive   ? "true" : "false")
        << ",\"tlsPool\":"         << s.tlsPool
        << ",\"rdOutcome\":\""     << s.rdOutcome << "\"";
    return os.str();
}

// -----------------------------------------------------------------------------
// Capture simulation (used by cudaStreamIsCapturing stub in test builds)
// -----------------------------------------------------------------------------
static std::mutex g_capture_mu;
static std::set<std::uint64_t> g_capturing_streams;

bool is_capture_active(std::uint64_t sid) {
    std::lock_guard<std::mutex> lk(g_capture_mu);
    return g_capturing_streams.count(sid) > 0;
}

void set_capture_active(std::uint64_t sid, bool active) {
    std::lock_guard<std::mutex> lk(g_capture_mu);
    if (active) g_capturing_streams.insert(sid);
    else        g_capturing_streams.erase(sid);
}

}  // namespace vbt_trace

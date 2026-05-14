// SPDX-License-Identifier: Apache-2.0
//
// VibeTensor CUDA allocator trace emission (Category B, per-thread timebox).
//
// Trace format is NDJSON; one file per thread at `<prefix>-thread-<tid>.ndjson`.
// A preprocessor merges these into a single JSON consumed by Trace.tla.
//
// Every emitted line MUST include "tag":"trace"; the validator filters on it.
//
// Usage:
//   vbt_trace::init_process("traces/<scenario>");   // once, early in main
//   vbt_trace::thread_register();                   // once per worker thread
//   { auto tb = vbt_trace::begin("raw_alloc.new");  // [start,end] interval
//     ...do the real work...
//     tb.end(); }                                   // captures `end`
//   vbt_trace::emit(tb,                             // emits one NDJSON line
//                   vbt_trace::state_snapshot(),
//                   "\"bid\":42,\"sid\":\"s1\",\"size\":1024");
//   vbt_trace::shutdown();                          // flush and close all files
//
// `state_snapshot()` returns a caller-filled JSON fragment (object fields
// without surrounding braces) describing the post-action BaseState; the
// allocator instrumentation supplies this via a helper that reads fields
// under the relevant lock.  See `src/vbt/cuda/allocator.cc` after apply.sh
// for call sites.
#pragma once

#include <atomic>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

namespace vbt_trace {

// -----------------------------------------------------------------------------
// Timestamp
// -----------------------------------------------------------------------------
// x86: rdtsc + mfence is the cheapest monotonic read (~25 cycles).
// Portable fallback: clock_gettime(CLOCK_MONOTONIC) on non-x86 builds.
static inline std::uint64_t rdtsc() noexcept {
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)
    unsigned lo, hi;
    __asm__ volatile ("mfence\n\trdtsc" : "=a"(lo), "=d"(hi));
    return (static_cast<std::uint64_t>(hi) << 32) | lo;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<std::uint64_t>(ts.tv_sec) * 1000000000ull
         + static_cast<std::uint64_t>(ts.tv_nsec);
#endif
}

// -----------------------------------------------------------------------------
// Per-thread writer (no mutex on hot path)
// -----------------------------------------------------------------------------
struct ThreadState {
    FILE*       fp{nullptr};
    int         tid{-1};
    // small stable-id caches to avoid a global lock on every emit
    // Block*     -> int (1-based)
    // StreamId   -> int (1-based)
    std::unordered_map<std::uintptr_t, int> block_ids;
    std::unordered_map<std::uint64_t, int>  stream_ids;
};

extern thread_local ThreadState tls;

// Process-global config (initialized once)
struct GlobalState {
    std::string prefix;   // path prefix for per-thread files
    std::atomic<int> next_tid{0};
    std::mutex       block_id_mu;
    std::unordered_map<std::uintptr_t, int> block_ids;  // address -> dense id
    // "retired" ids: when block deleted but tracing may still reference it
    std::unordered_map<std::uintptr_t, int> retired_block_ids;
    std::atomic<int> next_block_id{1};
    std::atomic<int> next_stream_id{1};
    std::mutex       stream_id_mu;
    std::unordered_map<std::uint64_t, int> stream_ids;
};

GlobalState& globals();

void init_process(const char* path_prefix);
void thread_register();  // called at entry of each worker thread
void shutdown();

// Lookup/intern a Block* → stable integer id; -1 if unknown (caller should
// have a RetireBlock/RegisterBlock hook in the allocator).
int block_id_of(const void* block_ptr);
// Register a Block* and return its new id (caller invokes on creation).
int register_block(const void* block_ptr);
// Retire a Block* (caller invokes right before `delete block`).  Subsequent
// block_id_of returns the retired id so trace lines referencing the freed
// block remain stable (F1/F2 dangling case).
void retire_block(const void* block_ptr);
int retired_block_id_of(const void* block_ptr);

// Lookup/intern StreamId → stable integer id
int stream_id_of(std::uint64_t sid);

// -----------------------------------------------------------------------------
// Timebox accumulator
// -----------------------------------------------------------------------------
struct Timebox {
    const char* name{""};
    std::uint64_t start{0};
    std::uint64_t end{0};
    bool          ended{false};

    void mark_end() noexcept {
        if (!ended) { end = rdtsc(); ended = true; }
    }
};

static inline Timebox begin(const char* name) noexcept {
    Timebox t;
    t.name  = name;
    t.start = rdtsc();
    return t;
}

// Low-level: emit a fully-formed NDJSON line (already includes outer braces).
// Caller provides `state_json` and `fields_json` as **inner** object bodies
// (no surrounding braces); this function wraps them.
void emit_line(const Timebox& tb,
               const char*    state_json,
               const char*    fields_json);

// Convenience wrappers for common fields
void emit_name(const Timebox& tb,
               const char*    state_json);  // no fields payload

// -----------------------------------------------------------------------------
// State-snapshot helper
// -----------------------------------------------------------------------------
// The instrumentation spec (§1) lists state fields captured on every event.
// `BaseStateJson` is passed verbatim as the `state` object body.  Callers
// assemble it via a small helper in the allocator (see apply.sh).
//
// Fields: existingBlockIds, activeBlockIds, perStreamFree, crossStreamFree,
//         deferredLen, limboLens, reservedBytes, routingFlag, tlsActive,
//         tlsPool, rdOutcome.
//
// The allocator-side helper walks the state and produces a JSON fragment of
// the form:
//   "existingBlockIds":[1,2,3], "activeBlockIds":[1,3], ...
// A helper `format_state` is defined in vbt_trace.cc for use by tests.
struct BaseStateSnapshot {
    // Raw fields; format_state() stringifies them into a JSON fragment.
    std::string existingBlockIds;  // already-JSON list: "[1,2,3]"
    std::string activeBlockIds;
    std::string perStreamFree;     // "{\"s1\":[1],\"s2\":[]}"
    std::string crossStreamFree;   // "[1,2]"
    std::uint64_t deferredLen{0};
    std::string limboLens;         // "{\"s1\":0}"
    std::uint64_t reservedBytes{0};
    bool          routingFlag{false};
    bool          tlsActive{false};
    std::uint64_t tlsPool{0};
    const char*   rdOutcome{""};   // "", "Published", "RolledBack", "Deferred"
};

// Format a BaseStateSnapshot into the inner object body (no braces).
std::string format_state(const BaseStateSnapshot& s);

// Convenience: allocator-side `capture_state_under_lock` is implemented in
// the instrumentation patch (needs access to private allocator state).
// The declaration here is symbolic; callers in the allocator.cc patch call
// their own helper and pass the resulting string to `emit_line`.

// -----------------------------------------------------------------------------
// Fault-injection hooks (env.capture_start / env.capture_end)
// -----------------------------------------------------------------------------
// Lets test scenarios emit synthetic capture-start/end markers without
// actually starting a CUDA capture.  The cudaStreamIsCapturing stub reads
// the `stream_capture_set` to report Active status for marked streams.
bool  is_capture_active(std::uint64_t sid);
void  set_capture_active(std::uint64_t sid, bool active);

// Fault-injection for cudaEventRecord: when true, the next call in this
// thread returns cudaErrorUnknown to exercise raw_delete.record_fail and
// pe.record_fail paths.
extern thread_local bool fail_next_event_record;

}  // namespace vbt_trace

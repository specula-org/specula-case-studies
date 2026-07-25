// SPDX-License-Identifier: Apache-2.0
// Scenario 1: Basic alloc → cross-stream record → free → process_events.
//
// Exercises:
//   - raw_alloc.new (fresh cudaMalloc path)
//   - record_stream (adds a foreign stream to stream_uses)
//   - raw_delete.mark (multi-stream free → goes to limbo)
//   - raw_delete.record_ok, raw_delete.publish
//   - pe.snapshot, pe.pop_ready (limbo drain)
//
// Single-threaded scenario; subsequent scenarios add multi-thread overlap.
#include "vbt/cuda/allocator.h"
#include "vbt/cuda/stream.h"
#include "vbt_trace.h"

#include <cstdio>
#include <cstdlib>

using namespace vbt::cuda;

int main(int argc, char** argv) {
    const char* prefix = argc > 1 ? argv[1] : "../traces/basic_alloc_free";

    vbt_trace::init_process(prefix);
    vbt_trace::thread_register();

    auto& a = Allocator::get(0);

    // Two distinct streams from the pool to exercise the stream-ordered path.
    auto s_alloc = getStreamFromPool(false, 0);
    auto s_use   = getStreamFromPool(false, 0);
    setCurrentStream(s_alloc);

    // ---- Small allocation on s_alloc ---------------------------------------
    void* p1 = a.raw_alloc(1024, s_alloc);
    if (!p1) { std::fprintf(stderr, "raw_alloc failed\n"); return 1; }

    // ---- Record a foreign stream (cross-stream use) ------------------------
    a.record_stream(p1, s_use);

    // ---- Switch freeing stream to s_use; raw_delete will need a fence on
    // s_alloc (prev owner), hitting the record_ok/publish path --------------
    setCurrentStream(s_use);
    a.raw_delete(p1);

    // ---- process_events drains limbo (stub: events always ready) ----------
    a.process_events(-1);

    // ---- Second allocation should reuse the freed block -------------------
    setCurrentStream(s_use);
    void* p2 = a.raw_alloc(1024, s_use);
    if (p2) a.raw_delete(p2);
    a.process_events(-1);

    vbt_trace::shutdown();
    return 0;
}

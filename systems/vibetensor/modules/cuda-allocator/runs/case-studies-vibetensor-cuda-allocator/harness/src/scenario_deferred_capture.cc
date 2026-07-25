// SPDX-License-Identifier: Apache-2.0
// Scenario 3: Simulated CUDA graph capture → raw_delete deferred → capture
// ends → process_events flushes the deferred queue.
//
// Exercises:
//   - raw_delete.to_deferred   (capture is active → skip record_*)
//   - pe.snapshot, pe.publish  (deferred drain after capture ends)
//   - env.capture_start / env.capture_end (harness-driven markers — emitted
//     from the test because the stub cudaStreamIsCapturing reads the
//     capture-active set maintained by vbt_trace::set_capture_active)
#include "vbt/cuda/allocator.h"
#include "vbt/cuda/stream.h"
#include "vbt_trace.h"

#include <cstdio>

using namespace vbt::cuda;

static void emit_env_capture(const char* name, std::uint64_t sid) {
    auto tb = vbt_trace::begin(name);
    tb.mark_end();
    char buf[64];
    std::snprintf(buf, sizeof(buf), "\"sid\":\"s%d\"",
                  ::vbt_trace::stream_id_of(sid));
    vbt_trace::emit_line(tb, "", buf);
}

int main(int argc, char** argv) {
    const char* prefix = argc > 1 ? argv[1] : "../traces/deferred_capture";

    vbt_trace::init_process(prefix);
    vbt_trace::thread_register();

    auto& a = Allocator::get(0);
    auto s_alloc = getStreamFromPool(false, 0);
    auto s_other = getStreamFromPool(false, 0);
    setCurrentStream(s_alloc);

    // Allocate and cross-stream-use before capture starts.
    void* p1 = a.raw_alloc(4096, s_alloc);
    a.record_stream(p1, s_other);

    // Start a "capture" on s_alloc — the stub will report Active for this sid.
    vbt_trace::set_capture_active(s_alloc.id(), true);
    emit_env_capture("env.capture_start", s_alloc.id());

    // raw_delete while capture is active → goes to deferred_.
    setCurrentStream(s_other);
    a.raw_delete(p1);

    // End capture.
    emit_env_capture("env.capture_end", s_alloc.id());
    vbt_trace::set_capture_active(s_alloc.id(), false);

    // process_events should now flush the deferred queue.
    a.process_events(-1);

    vbt_trace::shutdown();
    return 0;
}

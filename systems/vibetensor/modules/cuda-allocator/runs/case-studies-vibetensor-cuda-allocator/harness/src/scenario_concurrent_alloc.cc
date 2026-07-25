// SPDX-License-Identifier: Apache-2.0
// Scenario 2: Two producer threads allocating/freeing on their own streams,
// so timebox intervals overlap.
//
// Exercises (in addition to scenario 1):
//   - raw_delete.same_stream_fast path (alloc + free on same stream, no
//     cross-stream uses → immediate coalesce)
//   - Interval overlap between the two worker threads (Category B concurrency)
//   - Optionally a fault-injected raw_delete.record_fail via the
//     vbt_trace::fail_next_event_record hook.
#include "vbt/cuda/allocator.h"
#include "vbt/cuda/stream.h"
#include "vbt_trace.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

using namespace vbt::cuda;

static void worker(int worker_idx, int iters, bool inject_fault,
                   std::atomic<int>* barrier, int total_workers) {
    vbt_trace::thread_register();
    auto& a = Allocator::get(0);

    // Each worker picks its own stream.
    auto own = getStreamFromPool(false, 0);
    auto other = getStreamFromPool(true, 0);  // second stream, maybe foreign
    setCurrentStream(own);

    // Barrier: wait until all workers are ready before running the body.
    barrier->fetch_add(1);
    while (barrier->load() < total_workers) {
        std::this_thread::yield();
    }

    for (int i = 0; i < iters; ++i) {
        // Size varies to exercise rounding / different size classes.
        std::size_t nbytes = 512 + (i % 4) * 256;
        void* p = a.raw_alloc(nbytes, own);
        if (!p) continue;

        if (i % 2 == 0) {
            // Same-stream free (no record_stream) → should take the fast path.
            a.raw_delete(p);
        } else {
            // Cross-stream use, then free on a different stream → goes through
            // the record_ok → publish path.
            a.record_stream(p, other);
            setCurrentStream(other);
            if (inject_fault && i == 3) {
                vbt_trace::fail_next_event_record = true;
            }
            a.raw_delete(p);
            setCurrentStream(own);
        }

        if (i % 3 == 0) a.process_events(-1);
    }

    a.process_events(-1);
    vbt_trace::shutdown();
}

int main(int argc, char** argv) {
    const char* prefix = argc > 1 ? argv[1] : "../traces/concurrent_alloc";
    const int nworkers = 2;
    const int iters    = 6;

    vbt_trace::init_process(prefix);
    vbt_trace::thread_register();

    auto& a = Allocator::get(0);
    (void)a;

    std::atomic<int> barrier{0};
    std::vector<std::thread> threads;
    for (int i = 0; i < nworkers; ++i) {
        threads.emplace_back(worker, i, iters, /*inject_fault=*/false,
                             &barrier, nworkers + 1);
    }

    // Main thread also crosses the barrier and does a concurrent workload.
    barrier.fetch_add(1);
    while (barrier.load() < nworkers + 1) { std::this_thread::yield(); }

    auto s = getStreamFromPool(false, 0);
    setCurrentStream(s);
    for (int i = 0; i < iters; ++i) {
        void* p = a.raw_alloc(2048 + (i & 1) * 1024, s);
        if (p) a.raw_delete(p);
    }
    a.process_events(-1);

    for (auto& t : threads) t.join();
    a.emptyCache();

    vbt_trace::shutdown();
    return 0;
}

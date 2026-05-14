// SPDX-License-Identifier: Apache-2.0
// Minimal stub of vbt/cuda/graphs.h symbols referenced by allocator.cc.
// The full graphs.cc is ~1100 LoC and pulls in many CUDA Graph APIs we do not
// need for the allocator trace harness.  Everything here returns trivial
// "not capturing / 0 counters" — test scenarios that want to simulate capture
// should use vbt_trace::set_capture_active(sid, true) which flips what
// cudaStreamIsCapturing (in cuda_stub.cc) reports.

#include "vbt/cuda/graphs.h"
#include "vbt/cuda/stream.h"
#include "vbt_trace.h"

#include <atomic>

namespace vbt { namespace cuda {

CaptureStatus streamCaptureStatus(Stream s) {
    // Default stream is never capturing in our harness.
    if (s.id() == 0) return CaptureStatus::None;
    return vbt_trace::is_capture_active(s.id())
             ? CaptureStatus::Active
             : CaptureStatus::None;
}

CaptureStatus currentStreamCaptureStatus(DeviceIndex dev) {
    return streamCaptureStatus(getCurrentStream(dev));
}

// Capture-mode RAII guard — no-op.
CUDAStreamCaptureModeGuard::CUDAStreamCaptureModeGuard(Stream, CaptureMode) noexcept {}
CUDAStreamCaptureModeGuard::~CUDAStreamCaptureModeGuard() noexcept {}

GraphCounters cuda_graphs_counters() noexcept { return {}; }

void assert_not_capturing_backward_stream(const vbt::core::Device&) {}

namespace detail {

static std::atomic<std::uint64_t> g_allocator_capture_denied{0};

void bump_allocator_capture_denied() noexcept {
    g_allocator_capture_denied.fetch_add(1, std::memory_order_relaxed);
}

void poll_deferred_graph_cleanup() noexcept {}

}  // namespace detail
}}  // namespace vbt::cuda

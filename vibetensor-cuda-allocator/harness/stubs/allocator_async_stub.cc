// SPDX-License-Identifier: Apache-2.0
// Empty async backend — the trace harness always runs the Native backend so
// AsyncBackend::get() is never actually called.  These stubs exist only so
// the linker is happy when compiling the allocator TU.
#define VBT_WITH_CUDA 1

#include "vbt/cuda/allocator_async.h"

#include <cstdlib>
#include <stdexcept>

namespace vbt { namespace cuda {

AsyncBackend::AsyncBackend(DeviceIndex dev) : dev_(dev) {}

AsyncBackend& AsyncBackend::get(DeviceIndex dev) {
    static AsyncBackend inst(dev);
    return inst;
}

void AsyncBackend::configure(double, std::size_t, bool, bool, bool) {}
void AsyncBackend::set_memory_fraction(double) {}

void AsyncBackend::lazy_init_() {}
void AsyncBackend::mallocAsync_(void**, DeviceIndex, std::size_t, cudaStream_t) {}
void AsyncBackend::free_impl_(void*) {}
bool AsyncBackend::any_stream_capturing_(const PtrUsage&, StreamId) const noexcept { return false; }

void* AsyncBackend::raw_alloc(std::size_t) {
    throw std::runtime_error("AsyncBackend stubbed out of trace harness");
}
void* AsyncBackend::raw_alloc(std::size_t, Stream) {
    throw std::runtime_error("AsyncBackend stubbed out of trace harness");
}
void AsyncBackend::raw_delete(void*) noexcept {}
void AsyncBackend::record_stream(void*, Stream) noexcept {}
void AsyncBackend::emptyCache() noexcept {}

DeviceStats AsyncBackend::getDeviceStats() const noexcept { return {}; }
void AsyncBackend::resetPeakStats() noexcept {}
bool AsyncBackend::owns(const void*) const noexcept { return false; }
void* AsyncBackend::getBaseAllocation(void*, std::size_t*) const noexcept { return nullptr; }

cudaError_t AsyncBackend::memcpyAsync(void*, int, const void*, int, std::size_t, Stream, bool) noexcept {
    return cudaSuccess;
}
cudaError_t AsyncBackend::enablePeerAccess(int, int) noexcept { return cudaSuccess; }

#ifdef VBT_INTERNAL_TESTS
double AsyncBackend::debug_fraction() const noexcept { return 1.0; }
std::size_t AsyncBackend::debug_limit_bytes() const noexcept { return static_cast<std::size_t>(-1); }
#endif

}}  // namespace vbt::cuda

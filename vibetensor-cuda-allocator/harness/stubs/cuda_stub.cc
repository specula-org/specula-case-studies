// SPDX-License-Identifier: Apache-2.0
// CUDA runtime + driver stub implementation for the allocator trace harness.
// The allocator's algorithmic core (split/coalesce/free-list/GC ladder) is
// exercised end-to-end; CUDA primitives are implemented in-process so no
// NVIDIA toolchain or GPU is required.

#include "cuda_runtime_api.h"
#include "cuda.h"

#include "vbt_trace.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unordered_set>

// --- Driver API -------------------------------------------------------------
extern "C" CUresult cuInit(unsigned int /*flags*/) { return CUDA_SUCCESS; }
extern "C" CUresult cuDeviceGetCount(int* count) {
    if (count) *count = 1;
    return CUDA_SUCCESS;
}

// --- Runtime API: device ---------------------------------------------------
thread_local int s_current_dev = 0;

extern "C" cudaError_t cudaGetDevice(int* device) {
    if (device) *device = s_current_dev;
    return cudaSuccess;
}
extern "C" cudaError_t cudaSetDevice(int device) {
    s_current_dev = device;
    return cudaSuccess;
}
extern "C" cudaError_t cudaGetDeviceCount(int* count) {
    if (count) *count = 1;
    return cudaSuccess;
}
extern "C" cudaError_t cudaDeviceCanAccessPeer(int* out, int, int) {
    if (out) *out = 0;
    return cudaSuccess;
}
extern "C" cudaError_t cudaDeviceEnablePeerAccess(int, unsigned int) {
    return cudaErrorPeerAccessUnsupported;
}
extern "C" cudaError_t cudaDeviceGetStreamPriorityRange(int* least, int* greatest) {
    if (least)    *least    = 0;
    if (greatest) *greatest = 0;
    return cudaSuccess;
}

// --- Error strings ---------------------------------------------------------
thread_local cudaError_t s_last_err = cudaSuccess;
extern "C" const char* cudaGetErrorString(cudaError_t e) {
    switch (e) {
        case cudaSuccess: return "success";
        case cudaErrorNotReady: return "not ready";
        case cudaErrorUnknown: return "unknown";
        default: return "cuda stub error";
    }
}
extern "C" cudaError_t cudaGetLastError(void) {
    cudaError_t e = s_last_err;
    s_last_err = cudaSuccess;
    return e;
}

// --- Memory (simulated on host) --------------------------------------------
// Track totals so cudaMemGetInfo reports something sensible.
static std::atomic<size_t> g_alloc_current{0};
static constexpr size_t g_total_capacity = static_cast<size_t>(8) << 30;  // 8 GiB

extern "C" cudaError_t cudaMalloc(void** devPtr, size_t size) {
    if (!devPtr) return cudaErrorInvalidValue;
    if (size == 0) { *devPtr = nullptr; return cudaSuccess; }
    void* p = std::malloc(size);
    if (!p) return cudaErrorMemoryAllocation;
    // Zero-fill is not required for correctness, but matches CUDA's behaviour
    // for the allocator (it treats blocks as opaque).
    *devPtr = p;
    g_alloc_current.fetch_add(size);
    return cudaSuccess;
}
extern "C" cudaError_t cudaFree(void* devPtr) {
    if (devPtr) std::free(devPtr);
    return cudaSuccess;
}
extern "C" cudaError_t cudaMemGetInfo(size_t* freeB, size_t* totalB) {
    if (totalB) *totalB = g_total_capacity;
    size_t used = g_alloc_current.load();
    if (freeB)  *freeB  = used < g_total_capacity ? g_total_capacity - used : 0;
    return cudaSuccess;
}

// --- Streams ---------------------------------------------------------------
static std::atomic<uint64_t> g_next_stream{1};
extern "C" cudaError_t cudaStreamCreate(cudaStream_t* s) {
    if (s) *s = reinterpret_cast<cudaStream_t>(g_next_stream.fetch_add(1));
    return cudaSuccess;
}
extern "C" cudaError_t cudaStreamCreateWithFlags(cudaStream_t* s, unsigned int) {
    return cudaStreamCreate(s);
}
extern "C" cudaError_t cudaStreamCreateWithPriority(cudaStream_t* s, unsigned int, int) {
    return cudaStreamCreate(s);
}
extern "C" cudaError_t cudaStreamDestroy(cudaStream_t) { return cudaSuccess; }
extern "C" cudaError_t cudaStreamSynchronize(cudaStream_t) { return cudaSuccess; }
extern "C" cudaError_t cudaStreamQuery(cudaStream_t) { return cudaSuccess; }
extern "C" cudaError_t cudaStreamGetPriority(cudaStream_t, int* p) {
    if (p) *p = 0;
    return cudaSuccess;
}

extern "C" cudaError_t cudaStreamIsCapturing(cudaStream_t s,
                                             cudaStreamCaptureStatus* pStatus) {
    if (!pStatus) return cudaErrorInvalidValue;
    uint64_t sid = reinterpret_cast<uintptr_t>(s);
    *pStatus = vbt_trace::is_capture_active(sid)
                 ? cudaStreamCaptureStatusActive
                 : cudaStreamCaptureStatusNone;
    return cudaSuccess;
}
extern "C" cudaError_t cudaStreamWaitEvent(cudaStream_t, cudaEvent_t, unsigned int) {
    return cudaSuccess;
}
extern "C" cudaError_t cudaThreadExchangeStreamCaptureMode(cudaStreamCaptureMode*) {
    return cudaSuccess;
}

// --- Events ----------------------------------------------------------------
// Each fake event is a raw pointer token (just an int counter cast to pointer).
static std::atomic<uintptr_t> g_next_event{1};

extern "C" cudaError_t cudaEventCreateWithFlags(cudaEvent_t* e, unsigned int) {
    if (e) *e = reinterpret_cast<cudaEvent_t>(g_next_event.fetch_add(1));
    return cudaSuccess;
}
extern "C" cudaError_t cudaEventDestroy(cudaEvent_t) { return cudaSuccess; }

extern "C" cudaError_t cudaEventRecord(cudaEvent_t, cudaStream_t) {
    if (vbt_trace::fail_next_event_record) {
        vbt_trace::fail_next_event_record = false;
        return cudaErrorUnknown;
    }
    return cudaSuccess;
}
extern "C" cudaError_t cudaEventQuery(cudaEvent_t) {
    // In the stub, events are always ready immediately.  This is the
    // "happy path" for pe.pop_ready to fire.
    return cudaSuccess;
}
extern "C" cudaError_t cudaEventSynchronize(cudaEvent_t) { return cudaSuccess; }

// --- Memcpy (unused by the trace scenarios but required by the linker) -----
extern "C" cudaError_t cudaMemcpyAsync(void* dst, const void* src, size_t n,
                                       cudaMemcpyKind, cudaStream_t) {
    if (dst && src && n) std::memcpy(dst, src, n);
    return cudaSuccess;
}
extern "C" cudaError_t cudaMemcpyPeerAsync(void* dst, int, const void* src, int,
                                           size_t n, cudaStream_t) {
    if (dst && src && n) std::memcpy(dst, src, n);
    return cudaSuccess;
}

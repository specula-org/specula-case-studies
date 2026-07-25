// SPDX-License-Identifier: Apache-2.0
// Minimal CUDA runtime stub for the vibetensor-cuda-allocator trace harness.
// Declares just enough of the CUDA runtime API to compile and link the
// allocator's *real* algorithmic core without an NVIDIA toolchain or GPU.
//
// Behaviour: allocations go through host malloc/free; events and streams are
// counters; cudaEventQuery returns cudaSuccess immediately unless overridden
// via vbt_trace fault-injection helpers.  See stubs/cuda_stub.cc for impls.
//
// This file is picked up by pre-pending `stubs/` to the include path; no
// changes to the artifact source are needed.
#pragma once

#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// --- Enums / typedefs --------------------------------------------------------

typedef int cudaError_t;

enum {
    cudaSuccess                         = 0,
    cudaErrorNotReady                   = 600,
    cudaErrorInvalidValue               = 1,
    cudaErrorInvalidDevice              = 101,
    cudaErrorInvalidResourceHandle      = 400,
    cudaErrorPeerAccessUnsupported      = 217,
    cudaErrorPeerAccessNotEnabled       = 708,
    cudaErrorPeerAccessAlreadyEnabled   = 704,
    cudaErrorNotSupported               = 801,
    cudaErrorInvalidMemcpyDirection     = 21,
    cudaErrorUnknown                    = 999,
    cudaErrorMemoryAllocation           = 2
};

typedef struct cudaStream_st*  cudaStream_t;
typedef struct cudaEvent_st*   cudaEvent_t;
typedef struct cudaGraph_st*   cudaGraph_t;
typedef struct cudaGraphExec_st* cudaGraphExec_t;

typedef enum {
    cudaStreamCaptureStatusNone         = 0,
    cudaStreamCaptureStatusActive       = 1,
    cudaStreamCaptureStatusInvalidated  = 2
} cudaStreamCaptureStatus;

typedef enum {
    cudaStreamCaptureModeGlobal       = 0,
    cudaStreamCaptureModeThreadLocal  = 1,
    cudaStreamCaptureModeRelaxed      = 2
} cudaStreamCaptureMode;

typedef enum {
    cudaMemcpyHostToHost      = 0,
    cudaMemcpyHostToDevice    = 1,
    cudaMemcpyDeviceToHost    = 2,
    cudaMemcpyDeviceToDevice  = 3,
    cudaMemcpyDefault         = 4
} cudaMemcpyKind;

enum {
    cudaStreamDefault     = 0x00,
    cudaStreamNonBlocking = 0x01
};

enum {
    cudaEventDefault        = 0x00,
    cudaEventDisableTiming  = 0x02
};

// --- Runtime API -------------------------------------------------------------

cudaError_t cudaMalloc(void** devPtr, size_t size);
cudaError_t cudaFree(void* devPtr);
cudaError_t cudaMemGetInfo(size_t* free_bytes, size_t* total_bytes);

cudaError_t cudaGetDevice(int* device);
cudaError_t cudaSetDevice(int device);
cudaError_t cudaGetDeviceCount(int* count);
const char* cudaGetErrorString(cudaError_t err);
cudaError_t cudaGetLastError(void);
cudaError_t cudaDeviceCanAccessPeer(int* canAccessPeer, int device, int peerDevice);
cudaError_t cudaDeviceEnablePeerAccess(int peerDevice, unsigned int flags);
cudaError_t cudaDeviceGetStreamPriorityRange(int* leastPriority, int* greatestPriority);

cudaError_t cudaStreamCreate(cudaStream_t* pStream);
cudaError_t cudaStreamCreateWithFlags(cudaStream_t* pStream, unsigned int flags);
cudaError_t cudaStreamCreateWithPriority(cudaStream_t* pStream, unsigned int flags, int priority);
cudaError_t cudaStreamDestroy(cudaStream_t stream);
cudaError_t cudaStreamSynchronize(cudaStream_t stream);
cudaError_t cudaStreamQuery(cudaStream_t stream);
cudaError_t cudaStreamGetPriority(cudaStream_t hStream, int* priority);
cudaError_t cudaStreamIsCapturing(cudaStream_t stream, cudaStreamCaptureStatus* pCaptureStatus);
cudaError_t cudaStreamWaitEvent(cudaStream_t stream, cudaEvent_t event, unsigned int flags);
cudaError_t cudaThreadExchangeStreamCaptureMode(cudaStreamCaptureMode* mode);

cudaError_t cudaEventCreateWithFlags(cudaEvent_t* event, unsigned int flags);
cudaError_t cudaEventDestroy(cudaEvent_t event);
cudaError_t cudaEventRecord(cudaEvent_t event, cudaStream_t stream);
cudaError_t cudaEventQuery(cudaEvent_t event);
cudaError_t cudaEventSynchronize(cudaEvent_t event);

cudaError_t cudaMemcpyAsync(void* dst, const void* src, size_t count,
                            cudaMemcpyKind kind, cudaStream_t stream);
cudaError_t cudaMemcpyPeerAsync(void* dst, int dstDevice, const void* src, int srcDevice,
                                size_t count, cudaStream_t stream);

#ifdef __cplusplus
}  // extern "C"
#endif

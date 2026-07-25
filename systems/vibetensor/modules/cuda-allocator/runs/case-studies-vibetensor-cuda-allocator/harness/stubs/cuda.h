// SPDX-License-Identifier: Apache-2.0
// Minimal CUDA driver API stub — only what device_count.cc references.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef int CUresult;

#define CUDA_SUCCESS 0

CUresult cuInit(unsigned int flags);
CUresult cuDeviceGetCount(int* count);

#ifdef __cplusplus
}
#endif

// SPDX-License-Identifier: Apache-2.0
// Minimal dlpack.h stub — only the enum that vbt/core/device.h uses.
#pragma once
#include <cstdint>

typedef enum {
    kDLCPU     = 1,
    kDLCUDA    = 2,
    kDLCUDAHost = 3,
} DLDeviceType;

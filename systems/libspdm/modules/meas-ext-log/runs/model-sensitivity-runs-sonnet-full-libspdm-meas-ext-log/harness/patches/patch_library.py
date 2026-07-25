#!/usr/bin/env python3
"""
Idempotent instrumentation patcher for libspdm MEL trace harness.
Run from the run directory: python3 harness/patches/patch_library.py
"""
import sys, os, re

BASE = os.path.join(os.path.dirname(__file__), '..', '..')
LIBSPDM = os.path.join(BASE, 'artifact', 'libspdm')

def patch_file(relpath, changes):
    """Apply a list of (old, new) replacements to a file, idempotently."""
    path = os.path.join(LIBSPDM, relpath)
    with open(path, 'r') as f:
        content = f.read()
    original = content
    for old, new in changes:
        if new in content:
            continue  # already applied
        if old not in content:
            print(f"  WARNING: expected text not found in {relpath}:")
            print(f"    {repr(old[:80])}")
            continue
        content = content.replace(old, new, 1)
    if content != original:
        with open(path, 'w') as f:
            f.write(content)
        print(f"  Patched: {relpath}")
    else:
        print(f"  Already up-to-date: {relpath}")

def copy_file(src, dst_rel):
    """Copy a file into the artifact tree."""
    dst = os.path.join(LIBSPDM, dst_rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    import shutil
    shutil.copy2(src, dst)
    print(f"  Copied: {dst_rel}")

HARNESS_SRC = os.path.join(BASE, 'harness', 'src')

NEGOTIATE_ALGOS = "library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c"
REQ_MEL = "library/spdm_requester_lib/libspdm_req_get_measurement_extension_log.c"
RSP_MEL = "library/spdm_responder_lib/libspdm_rsp_measurement_extension_log.c"
CMAKELISTS = "unit_test/test_spdm_requester/CMakeLists.txt"

print("=== Applying TLA trace instrumentation ===")

# 1. Copy harness files
copy_file(os.path.join(HARNESS_SRC, 'tla_trace.h'), 'include/tla_trace.h')
copy_file(os.path.join(HARNESS_SRC, 'tla_trace.c'),
          'unit_test/test_spdm_requester/tla_trace.c')
copy_file(os.path.join(HARNESS_SRC, 'mel_trace_test.c'),
          'unit_test/test_spdm_requester/mel_trace_test.c')

# 2. Patch negotiate_algorithms.c
patch_file(NEGOTIATE_ALGOS, [
    (
        '#include "internal/libspdm_requester_lib.h"',
        '#include "internal/libspdm_requester_lib.h"\n#include "tla_trace.h"'
    ),
    (
        '    uint8_t req_param1 = 0;\n',
        '    uint8_t req_param1 = 0;\n    uint8_t mel_spec_wire = 0;\n'
    ),
    (
        '            spdm_context->connection_info.algorithm.mel_spec =\n'
        '                spdm_response->mel_specification_sel;\n'
        '        }\n'
        '    }',
        '            spdm_context->connection_info.algorithm.mel_spec =\n'
        '                spdm_response->mel_specification_sel;\n'
        '            mel_spec_wire = spdm_response->mel_specification_sel;\n'
        '        }\n'
        '    }'
    ),
    (
        '        spdm_context->connection_info.algorithm.kem_alg = 0;\n'
        '    }\n\n'
        '    LIBSPDM_DEBUG',
        '        spdm_context->connection_info.algorithm.kem_alg = 0;\n'
        '    }\n\n'
        '    if (spdm_response->header.spdm_version >= SPDM_MESSAGE_VERSION_13) {\n'
        '        tla_emit_negotiate_algorithms(spdm_context, mel_spec_wire);\n'
        '    }\n\n'
        '    LIBSPDM_DEBUG'
    ),
])

# 3. Patch libspdm_req_get_measurement_extension_log.c
patch_file(REQ_MEL, [
    (
        '#include "internal/libspdm_requester_lib.h"\n\n#if LIBSPDM_ENABLE_CAPABILITY_MEL_CAP',
        '#include "internal/libspdm_requester_lib.h"\n#include "tla_trace.h"\n\n#if LIBSPDM_ENABLE_CAPABILITY_MEL_CAP'
    ),
    (
        '        spdm_request_size = sizeof(spdm_get_measurement_extension_log_request_t);\n'
        '        LIBSPDM_DEBUG((LIBSPDM_DEBUG_INFO, "request (offset 0x%x, size 0x%x):\\n",',
        '        spdm_request_size = sizeof(spdm_get_measurement_extension_log_request_t);\n'
        '        if (spdm_request->offset == 0) {\n'
        '            tla_emit_send_get_mel_first_chunk(spdm_context, spdm_request->length);\n'
        '        } else {\n'
        '            tla_emit_send_get_mel_next_chunk(spdm_context, spdm_request->offset,\n'
        '                                            spdm_request->length);\n'
        '        }\n'
        '        LIBSPDM_DEBUG((LIBSPDM_DEBUG_INFO, "request (offset 0x%x, size 0x%x):\\n",'
    ),
    (
        '        mel_size_internal += spdm_response->portion_length;\n\n'
        '        /* -=[Log Message Phase]=- */',
        '        mel_size_internal += spdm_response->portion_length;\n'
        '        {\n'
        '            bool tla_is_done = (spdm_response->remainder_length == 0);\n'
        '            if (spdm_request->offset == 0) {\n'
        '                tla_emit_process_mel_first_chunk_resp(spdm_context,\n'
        '                    mel_size_internal, spdm_response->portion_length,\n'
        '                    tla_is_done, g_mel_generation_counter);\n'
        '            } else {\n'
        '                tla_emit_process_mel_next_chunk_resp(spdm_context,\n'
        '                    mel_size_internal, tla_is_done);\n'
        '            }\n'
        '        }\n\n'
        '        /* -=[Log Message Phase]=- */'
    ),
])

# 4. Patch libspdm_rsp_measurement_extension_log.c
patch_file(RSP_MEL, [
    (
        '#include "internal/libspdm_responder_lib.h"\n\n#if LIBSPDM_ENABLE_CAPABILITY_MEL_CAP',
        '#include "internal/libspdm_responder_lib.h"\n#include "tla_trace.h"\n\n#if LIBSPDM_ENABLE_CAPABILITY_MEL_CAP'
    ),
    (
        '    spdm_mel = NULL;\n'
        '    spdm_mel_len = 0;\n'
        '    if (!libspdm_measurement_extension_log_collection(',
        '    spdm_mel = NULL;\n'
        '    spdm_mel_len = 0;\n'
        '    if (offset == 0) {\n'
        '        g_mel_generation_counter = 0;\n'
        '    } else {\n'
        '        g_mel_generation_counter++;\n'
        '    }\n'
        '    if (!libspdm_measurement_extension_log_collection('
    ),
    (
        '        return libspdm_generate_error_response(spdm_context,\n'
        '                                               SPDM_ERROR_CODE_OPERATION_FAILED, 0,\n'
        '                                               response_size, response);\n'
        '    }\n\n'
        '    if (offset >= spdm_mel_len)',
        '        return libspdm_generate_error_response(spdm_context,\n'
        '                                               SPDM_ERROR_CODE_OPERATION_FAILED, 0,\n'
        '                                               response_size, response);\n'
        '    }\n'
        '    if (offset > 0) {\n'
        '        tla_emit_mel_update(spdm_mel_len, g_mel_generation_counter);\n'
        '    }\n\n'
        '    if (offset >= spdm_mel_len)'
    ),
    (
        '    spdm_response->portion_length = length;\n'
        '    spdm_response->remainder_length = (uint32_t)remainder_length;\n\n'
        '    libspdm_copy_mem(spdm_response + 1,',
        '    spdm_response->portion_length = length;\n'
        '    spdm_response->remainder_length = (uint32_t)remainder_length;\n\n'
        '    if (offset == 0) {\n'
        '        tla_emit_respond_get_mel_first_chunk(spdm_context, length,\n'
        '            (uint32_t)remainder_length, spdm_mel_len,\n'
        '            g_mel_generation_counter);\n'
        '    } else {\n'
        '        tla_emit_respond_get_mel_next_chunk(spdm_context, length,\n'
        '            (uint32_t)remainder_length, spdm_mel_len,\n'
        '            g_mel_generation_counter);\n'
        '    }\n\n'
        '    libspdm_copy_mem(spdm_response + 1,'
    ),
])

# 5. Patch CMakeLists.txt to add test_mel_trace target
# Sentinel: if this marker is present the patch is already applied
CMAKELISTS_SENTINEL = "add_executable(test_mel_trace)"

CMAKELISTS_ADDITIONS = """\

add_executable(test_mel_trace)

target_include_directories(test_mel_trace
    PRIVATE
        ${LIBSPDM_DIR}/unit_test/test_spdm_requester
        ${LIBSPDM_DIR}/include
        ${LIBSPDM_DIR}/unit_test/include
        ${LIBSPDM_DIR}/os_stub/spdm_device_secret_lib_${DEVICE}
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common
        ${LIBSPDM_DIR}/os_stub
)

target_sources(test_mel_trace
    PRIVATE
        mel_trace_test.c
        tla_trace.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/common.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/algo.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/support.c
)

target_link_libraries(test_mel_trace
    PRIVATE
        memlib
        debuglib
        spdm_responder_lib
        spdm_requester_lib
        spdm_common_lib
        ${CRYPTO_LIB_PATHS}
        rnglib
        cryptlib_${CRYPTO}
        malloclib
        spdm_crypt_lib
        spdm_crypt_ext_lib
        spdm_secured_message_lib
        spdm_device_secret_lib_${DEVICE}
        spdm_transport_test_lib
        platform_lib
)
"""

cmake_path = os.path.join(LIBSPDM, CMAKELISTS)
with open(cmake_path) as _f:
    _cmake_content = _f.read()
if CMAKELISTS_SENTINEL not in _cmake_content:
    patch_file(CMAKELISTS, [
        (
            'add_executable(test_spdm_requester)\n',
            'add_executable(test_spdm_requester)\n' + CMAKELISTS_ADDITIONS
        ),
    ])
else:
    print(f"  Already up-to-date: {CMAKELISTS}")

print("=== Done ===")

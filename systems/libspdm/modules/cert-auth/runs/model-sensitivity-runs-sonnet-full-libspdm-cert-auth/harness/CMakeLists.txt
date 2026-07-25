cmake_minimum_required(VERSION 3.5)
project(tla_trace_harness C)

# --- paths ---
set(LIBSPDM_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../artifact/libspdm")
set(HARNESS_SRC "${CMAKE_CURRENT_SOURCE_DIR}/src")

# Device secret backend (sample reads keys from ecp256/ relative to CWD)
set(DEVICE "sample")

# --- tla_trace static library ---
add_library(tla_trace STATIC
    ${HARNESS_SRC}/tla_trace.c
)

target_include_directories(tla_trace
    PUBLIC
        ${HARNESS_SRC}
        ${LIBSPDM_DIR}/include
)

# --- trace_harness executable ---
add_executable(trace_harness
    ${HARNESS_SRC}/test_scenarios.c
    ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/support.c
)

target_include_directories(trace_harness
    PRIVATE
        ${HARNESS_SRC}
        ${LIBSPDM_DIR}/include
        ${LIBSPDM_DIR}/unit_test/include
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common
        ${LIBSPDM_DIR}/os_stub/spdm_device_secret_lib_${DEVICE}
        ${LIBSPDM_DIR}/os_stub
)

target_link_libraries(trace_harness
    PRIVATE
        tla_trace
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

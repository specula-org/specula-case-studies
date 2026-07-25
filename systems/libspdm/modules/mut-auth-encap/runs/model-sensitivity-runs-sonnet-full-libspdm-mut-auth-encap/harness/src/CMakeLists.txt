cmake_minimum_required(VERSION 3.5)

# tla_encap_test — standalone TLA+ trace collection binary for libspdm encap mut-auth
#
# Usage (from the libspdm build dir):
#   cmake -DLIBSPDM_TRACE_ENCAP=1 -DCMAKE_C_FLAGS="-DLIBSPDM_TRACE_ENCAP" ...
#   or add_compile_definitions(LIBSPDM_TRACE_ENCAP) here.

add_compile_definitions(LIBSPDM_TRACE_ENCAP)

set(TLA_SRCS
    ${CMAKE_CURRENT_SOURCE_DIR}/tla_encap_test.c
)

add_executable(tla_encap_test ${TLA_SRCS})

target_include_directories(tla_encap_test PRIVATE
    ${LIBSPDM_DIR}/include
    ${LIBSPDM_DIR}/include/hal
    ${LIBSPDM_DIR}/include/library
    ${LIBSPDM_DIR}/unit_test/include
    ${LIBSPDM_DIR}/os_stub
    ${LIBSPDM_DIR}/os_stub/spdm_device_secret_lib_sample
    ${CMAKE_CURRENT_SOURCE_DIR}   # for tla_trace.h
)

target_link_libraries(tla_encap_test
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
    memlib
    debuglib
    platform_lib
)

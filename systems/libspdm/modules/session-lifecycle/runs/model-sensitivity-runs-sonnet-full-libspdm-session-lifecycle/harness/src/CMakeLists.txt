cmake_minimum_required(VERSION 3.5)

add_executable(test_spdm_tla_trace)

target_include_directories(test_spdm_tla_trace
    PRIVATE
        ${LIBSPDM_DIR}/unit_test/test_spdm_tla_trace
        ${LIBSPDM_DIR}/include
        ${LIBSPDM_DIR}/unit_test/include
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common
        ${LIBSPDM_DIR}/os_stub/spdm_device_secret_lib_${DEVICE}
        ${LIBSPDM_DIR}/os_stub/spdm_cert_verify_callback_sample
        ${LIBSPDM_DIR}/os_stub
        ${LIBSPDM_DIR}/os_stub/include
)

target_sources(test_spdm_tla_trace
    PRIVATE
        trace_test.c
        tla_trace.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/algo.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/support.c
)

if(CMAKE_SYSTEM_NAME MATCHES "Windows")
    if((TOOLCHAIN STREQUAL "VS2015") OR (TOOLCHAIN STREQUAL "VS2019") OR (TOOLCHAIN STREQUAL "VS2022"))
        target_compile_options(test_spdm_tla_trace PRIVATE /wd4819)
    endif()
endif()

target_link_libraries(test_spdm_tla_trace
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
        spdm_cert_verify_callback_sample
        spdm_transport_test_lib
        platform_lib
)

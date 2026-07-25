cmake_minimum_required(VERSION 3.5)

add_executable(spdm_trace_test)

target_include_directories(spdm_trace_test
    PRIVATE
        ${LIBSPDM_DIR}/include
        ${LIBSPDM_DIR}/unit_test/include
        ${LIBSPDM_DIR}/os_stub/spdm_device_secret_lib_${DEVICE}
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common
        ${LIBSPDM_DIR}/os_stub
        ${HARNESS_SRC_DIR}
)

target_sources(spdm_trace_test
    PRIVATE
        ${HARNESS_SRC_DIR}/spdm_trace_test.c
        ${HARNESS_SRC_DIR}/tla_trace.c
        ${HARNESS_SRC_DIR}/support.c
)

target_compile_definitions(spdm_trace_test
    PRIVATE
        LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT=1
)

target_link_libraries(spdm_trace_test
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
        pthread
)

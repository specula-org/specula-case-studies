cmake_minimum_required(VERSION 3.5)

add_executable(test_tla_trace)

target_include_directories(test_tla_trace
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${LIBSPDM_DIR}/unit_test/test_spdm_responder
        ${LIBSPDM_DIR}/include
        ${LIBSPDM_DIR}/unit_test/include
        ${LIBSPDM_DIR}/os_stub/spdm_device_secret_lib_${DEVICE}
        ${LIBSPDM_DIR}/unit_test/cmockalib/cmocka/include
        ${LIBSPDM_DIR}/unit_test/cmockalib/cmocka/include/cmockery
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common
        ${LIBSPDM_DIR}/os_stub
)

target_compile_definitions(test_tla_trace
    PRIVATE
        TLA_TRACE_ENABLED
        LIBSPDM_DEBUG_LIBSPDM_ASSERT_CONFIG=3
)

target_sources(test_tla_trace
    PRIVATE
        tla_trace_main.c
        tla_scenarios.c
        tla_trace.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/common.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/algo.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/support.c
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common/event_support.c
)

target_link_libraries(test_tla_trace
    PRIVATE
        memlib
        debuglib
        spdm_requester_lib
        spdm_responder_lib
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
        cmockalib
        platform_lib
)

cmake_minimum_required(VERSION 3.5)

project(libspdm_tla_harness)

add_executable(test_session_lifecycle
    src/tla_trace.c
    src/test_session_lifecycle.c
)

target_include_directories(test_session_lifecycle
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(test_session_lifecycle
    PRIVATE
        pthread
)

set_target_properties(test_session_lifecycle PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED ON
)

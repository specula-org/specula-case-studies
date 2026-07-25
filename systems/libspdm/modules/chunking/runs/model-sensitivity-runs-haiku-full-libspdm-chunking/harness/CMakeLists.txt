cmake_minimum_required(VERSION 3.15)
project(libspdm-trace-harness C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -Wextra")

# Trace module
add_library(tla_trace STATIC
    src/tla_trace.h
    src/tla_trace.c
)

target_include_directories(tla_trace PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Test harness
add_executable(test_chunking
    src/test_chunking.c
)

target_link_libraries(test_chunking
    tla_trace
    pthread
)

target_include_directories(test_chunking PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Install
install(TARGETS test_chunking DESTINATION bin)

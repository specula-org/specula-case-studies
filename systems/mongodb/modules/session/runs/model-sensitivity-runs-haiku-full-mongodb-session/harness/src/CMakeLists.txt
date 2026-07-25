cmake_minimum_required(VERSION 3.10)
project(mongodb-session-harness)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find required packages
find_package(nlohmann_json 3.2.0 QUIET)

# If nlohmann_json is not installed, we'll include it as header-only
if(NOT nlohmann_json_FOUND)
    # Try to find it in common locations or use header-only mode
    if(EXISTS "/usr/include/nlohmann/json.hpp")
        include_directories(/usr/include)
    elseif(EXISTS "/usr/local/include/nlohmann/json.hpp")
        include_directories(/usr/local/include)
    else()
        message(WARNING "nlohmann/json not found, trying to download...")
        # For header-only usage, just include the path
        include_directories(${CMAKE_CURRENT_SOURCE_DIR})
    endif()
else()
    include_directories(${nlohmann_json_INCLUDE_DIRS})
endif()

# Add the trace library
add_library(tla_trace STATIC
    tla_trace.h
    tla_trace.cpp
)

target_include_directories(tla_trace PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# Add the test harness executable
add_executable(test_harness test_harness.cpp)
target_link_libraries(test_harness tla_trace pthread)

# Installation
install(TARGETS test_harness DESTINATION bin)
install(FILES tla_trace.h DESTINATION include)

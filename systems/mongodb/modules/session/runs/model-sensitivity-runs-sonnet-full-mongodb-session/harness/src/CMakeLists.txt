cmake_minimum_required(VERSION 3.10)
project(mongodb-session-harness CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O2 -Wall")

# Trace emission library (header-only; the .h is in this directory)
add_library(tla_trace INTERFACE)
target_include_directories(tla_trace INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})

# Session scenario generator
add_executable(session_scenarios session_scenarios.cpp)
target_link_libraries(session_scenarios PRIVATE tla_trace pthread)

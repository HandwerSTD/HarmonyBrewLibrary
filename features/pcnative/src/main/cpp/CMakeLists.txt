# 最小版本与工程模型一致
cmake_minimum_required(VERSION 3.5.0)
project(pcnative)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

# C++17：shell_hook.cpp 用到 std::string / 结构化声明，模板里默认的 gnu++11 不够
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(pcnative SHARED
    napi_init.cpp
    shell_hook.cpp)

target_link_libraries(pcnative PUBLIC libace_napi.z.so)

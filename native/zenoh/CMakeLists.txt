# libmobileros_zenoh: zenoh-pico (static) + the thin layer in mobileros_zenoh.c, as one shared library
# for Android (NDK) and Windows (MSVC). Built by native/zenoh/build_android.ps1 and build_windows.ps1.
cmake_minimum_required(VERSION 3.16)
project(mobileros_zenoh C)

set(ZENOH_PICO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.build/zenoh-pico" CACHE PATH "zenoh-pico source tree")

# Robots send maps and camera images of hundreds of KB: zenoh-pico's embedded defaults (4 KB messages,
# 2 KB batches) would drop them silently.
set(FRAG_MAX_SIZE 8388608 CACHE STRING "" FORCE)
set(BATCH_UNICAST_SIZE 65535 CACHE STRING "" FORCE)
# Advanced subscribers fetch what transient-local publishers kept (a latched /map). Unstable in 1.8.
set(Z_FEATURE_UNSTABLE_API 1 CACHE STRING "" FORCE)
set(Z_FEATURE_ADVANCED_SUBSCRIPTION 1 CACHE STRING "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_INTEGRATION OFF CACHE BOOL "" FORCE)
set(PACKAGING OFF CACHE STRING "" FORCE)
add_subdirectory(${ZENOH_PICO_DIR} zenoh-pico EXCLUDE_FROM_ALL)
if(ANDROID)
  # zenoh-pico builds for Android as a POSIX system; this header supplies what bionic lacks.
  target_compile_options(zenohpico_static PRIVATE "SHELL:-include ${CMAKE_CURRENT_SOURCE_DIR}/android_compat.h")
endif()

add_library(mobileros_zenoh SHARED mobileros_zenoh.c)
# zenoh-pico's API macros (z_move, z_loan, ...) use C11 _Generic; MSVC needs /std:c11 for it.
set_target_properties(mobileros_zenoh PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
if(MSVC)
  target_compile_options(mobileros_zenoh PRIVATE /utf-8)
endif()
target_link_libraries(mobileros_zenoh PRIVATE zenohpico::lib)
if(ANDROID)
  # 16 KB page alignment, required for Android 15+ devices (same as libmobileros_dds).
  # Export only the mz_* functions, drop zenoh-pico's symbols and debug info (as libmobileros_dds does).
  set_target_properties(mobileros_zenoh PROPERTIES C_VISIBILITY_PRESET hidden)
  target_link_options(mobileros_zenoh PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--exclude-libs,ALL"
    "-Wl,--gc-sections" "-s")
endif()
if(WIN32)
  target_link_libraries(mobileros_zenoh PRIVATE ws2_32 iphlpapi)
endif()

# libmobileros_llm: llama.cpp (static) + the thin layer in mobileros_llm.c, as one shared library for
# Android (NDK) and Windows (MSVC). Built by native/llm/build_android.ps1 and build_windows.ps1.
cmake_minimum_required(VERSION 3.16)
project(mobileros_llm C CXX)

set(LLAMA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.build/llama.cpp" CACHE PATH "llama.cpp source tree")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
# CPU only. GGML_NATIVE would tune for the build machine; a shipped library must run on any device.
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE ON CACHE BOOL "" FORCE)
# ARM builds come in two flavours: a baseline one that runs on every arm64 phone, and one using the
# dot-product and fp16 instructions most phones since 2019 have (about twice as fast). The app picks
# by the CPU's features (lib/agent/local/llm_native.dart). ML_ARM_ARCH selects the flavour.
set(ML_ARM_ARCH "" CACHE STRING "e.g. armv8.2-a+dotprod+fp16; empty for the baseline")
set(ML_OUTPUT_NAME "mobileros_llm" CACHE STRING "library name")
if(ML_ARM_ARCH)
  set(GGML_CPU_ARM_ARCH "${ML_ARM_ARCH}" CACHE STRING "" FORCE)
endif()
add_subdirectory(${LLAMA_DIR} llama.cpp EXCLUDE_FROM_ALL)

add_library(mobileros_llm SHARED mobileros_llm.c)
target_link_libraries(mobileros_llm PRIVATE llama)
set_target_properties(mobileros_llm PROPERTIES OUTPUT_NAME "${ML_OUTPUT_NAME}")
if(MSVC)
  target_compile_options(mobileros_llm PRIVATE /utf-8)
endif()
if(ANDROID)
  # 16 KB pages (Android 15+), only the ml_* functions exported, no debug info.
  set_target_properties(mobileros_llm PROPERTIES C_VISIBILITY_PRESET hidden)
  target_link_options(mobileros_llm PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--exclude-libs,ALL"
    "-Wl,--gc-sections" "-s")
endif()

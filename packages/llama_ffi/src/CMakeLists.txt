# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. llama.cpp itself needs a newer CMake, which the Android Gradle
# Plugin provides through the SDK's cmake package.
cmake_minimum_required(VERSION 3.14)

project(sc_llama_library VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- llama.cpp configuration -------------------------------------------------
# Snapdragon 680 (Cortex-A73/A53) is ARMv8.0-A: no dotprod, no i8mm. Never let
# ggml detect features from the build host, or the library dies with SIGILL.
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
if (ANDROID)
  set(GGML_CPU_ARM_ARCH "armv8-a" CACHE STRING "" FORCE)
endif()
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)   # json-schema-to-grammar
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_SUBPROCESS OFF CACHE BOOL "" FORCE)
set(LLAMA_LLGUIDANCE OFF CACHE BOOL "" FORCE)

set(LLAMA_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/llama.cpp")
add_subdirectory(${LLAMA_SRC} llama.cpp EXCLUDE_FROM_ALL)

# --- SkillCraft wrapper ------------------------------------------------------
add_library(sc_llama SHARED "sc_llama.cpp")

set_target_properties(sc_llama PROPERTIES
  PUBLIC_HEADER sc_llama.h
  OUTPUT_NAME "sc_llama"
  CXX_VISIBILITY_PRESET hidden
)

target_compile_definitions(sc_llama PUBLIC DART_SHARED_LIB)
target_compile_options(sc_llama PRIVATE -O3)
target_link_libraries(sc_llama PRIVATE llama llama-common)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(sc_llama PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_libraries(sc_llama PRIVATE android log)
endif()

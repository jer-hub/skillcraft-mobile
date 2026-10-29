# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. QuickJS-ng itself needs a newer CMake, which the Android Gradle
# Plugin provides through the SDK's cmake package.
cmake_minimum_required(VERSION 3.14)

project(sc_qjs_library VERSION 0.17.0 LANGUAGES C)

set(QJS_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/quickjs")

# Engine only: no qjs CLI, no libc module (scripts get no file/OS access).
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_LIBC OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(QJS_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(${QJS_SRC} quickjs EXCLUDE_FROM_ALL)
set_target_properties(qjs PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(sc_qjs SHARED "sc_qjs.c")

set_target_properties(sc_qjs PROPERTIES
  PUBLIC_HEADER sc_qjs.h
  OUTPUT_NAME "sc_qjs"
  C_VISIBILITY_PRESET hidden
)

target_compile_definitions(sc_qjs PUBLIC DART_SHARED_LIB)
target_compile_options(sc_qjs PRIVATE -O2)
target_link_libraries(sc_qjs PRIVATE qjs)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(sc_qjs PRIVATE "-Wl,-z,max-page-size=16384")
endif()

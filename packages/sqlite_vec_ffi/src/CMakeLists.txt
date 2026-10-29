# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(sqlite_vec_ffi_library VERSION 0.1.9 LANGUAGES C)

set(VEC_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/sqlite-vec")

# sqlite-vec.h is generated from a template upstream (see its Makefile).
file(READ "${VEC_SRC}/VERSION" VERSION)
string(STRIP "${VERSION}" VERSION)
string(REPLACE "." ";" _parts "${VERSION}")
list(GET _parts 0 VERSION_MAJOR)
list(GET _parts 1 VERSION_MINOR)
list(GET _parts 2 VERSION_PATCH)
set(DATE "")
set(SOURCE "")
configure_file("${VEC_SRC}/sqlite-vec.h.tmpl"
               "${CMAKE_CURRENT_BINARY_DIR}/generated/sqlite-vec.h")

# Built as a loadable extension (no SQLITE_CORE): it calls SQLite through the
# api-routines table handed over at registration, so it works with whichever
# SQLite the `sqlite3` Dart package bundles.
add_library(sqlite_vec SHARED "${VEC_SRC}/sqlite-vec.c")

target_include_directories(sqlite_vec PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}/generated"
  "${CMAKE_CURRENT_SOURCE_DIR}/sqlite"   # sqlite3.h + sqlite3ext.h, 3.54.1
)

target_compile_options(sqlite_vec PRIVATE -O2)

if (ANDROID)
  # Plain ARMv8.0 NEON (vld1q/vfmaq only), safe on Cortex-A53/A73.
  if (ANDROID_ABI STREQUAL "arm64-v8a")
    target_compile_definitions(sqlite_vec PRIVATE SQLITE_VEC_ENABLE_NEON)
  endif()
  # Support Android 15 16k page size
  target_link_options(sqlite_vec PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_libraries(sqlite_vec PRIVATE m)
endif()

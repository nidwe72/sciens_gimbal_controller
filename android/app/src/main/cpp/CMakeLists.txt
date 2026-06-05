cmake_minimum_required(VERSION 3.18.1)
project(panostitch)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Phase 6 — stitch with OpenPano (vendored under openpano/). OpenCV's
# auto-stitcher was non-deterministic on our regular grid; OpenPano
# reliably stitches the same tiles (validated on Linux). PNG-only I/O
# via bundled lodepng (no libjpeg). See SPEC Phase 6.
set(OP ${CMAKE_CURRENT_SOURCE_DIR}/openpano)
file(GLOB OPENPANO_SRC
  ${OP}/lib/*.cc
  ${OP}/feature/*.cc
  ${OP}/stitch/*.cc
  ${OP}/common/*.cc
  ${OP}/third-party/lodepng/*.cc
)

add_library(panostitch SHARED
  stitch.cpp
  openpano_stitch.cc
  ${OPENPANO_SRC}
)

target_include_directories(panostitch PRIVATE
  ${OP}
  ${OP}/third-party
  ${CMAKE_CURRENT_SOURCE_DIR}/eigen
)

# PNG-only (no libjpeg/CImg-jpeg). The bundled FLANN uses C++17-removed
# std features (binary_function, random_shuffle) — re-enable them in
# libc++.
target_compile_definitions(panostitch PRIVATE
  DISABLE_JPEG
  _LIBCPP_ENABLE_CXX17_REMOVED_FEATURES
  _LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION
  _LIBCPP_ENABLE_CXX17_REMOVED_RANDOM_SHUFFLE)

# OpenPano uses OpenMP; static-link libomp so there's no runtime .so dep.
target_compile_options(panostitch PRIVATE -fopenmp)
target_link_options(panostitch PRIVATE -fopenmp -static-openmp)

find_library(log-lib log)
target_link_libraries(panostitch ${log-lib})

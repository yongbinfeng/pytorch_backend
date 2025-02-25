# Copyright 2019-2024, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

cmake_minimum_required (VERSION 3.18)

project(tritonpytorchbackend LANGUAGES C CXX)

# Use C++17 standard as Triton's minimum required.
set(TRITON_MIN_CXX_STANDARD 17 CACHE STRING "The minimum C++ standard which features are requested to build this target.")

#
# Options
#
# To build the PyTorch backend you must either:
#
#   - Point to the already built PyTorch and Torchvision using
#     TRITON_PYTORCH_INCLUDE_PATHS and TRITON_PYTORCH_LIB_PATHS
#
#   or:
#
#   - Set TRITON_PYTORCH_DOCKER_IMAGE to use the docker image of
#     PyTorch to base the build off.
#

option(TRITON_ENABLE_GPU "Enable GPU support in backend" ON)
option(TRITON_ENABLE_STATS "Include statistics collections in backend" ON)
option(TRITON_ENABLE_NVTX "Include nvtx markers collection in backend." OFF)
option(TRITON_PYTORCH_ENABLE_TORCHTRT "Enable TorchTRT support" OFF)
option(TRITON_PYTORCH_ENABLE_TORCHVISION "Enable Torchvision support" ON)

set(TRITON_PYTORCH_DOCKER_IMAGE "" CACHE STRING "Docker image containing the PyTorch build required by backend.")
set(TRITON_PYTORCH_INCLUDE_PATHS "" CACHE PATH "Paths to Torch includes")
set(TRITON_PYTORCH_LIB_PATHS "" CACHE PATH "Paths to Torch libraries")

set(TRITON_BACKEND_REPO_TAG "main" CACHE STRING "Tag for triton-inference-server/backend repo")
set(TRITON_CORE_REPO_TAG "main" CACHE STRING "Tag for triton-inference-server/core repo")
set(TRITON_COMMON_REPO_TAG "main" CACHE STRING "Tag for triton-inference-server/common repo")

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(TRITON_PYTORCH_DOCKER_BUILD OFF)
if(TRITON_PYTORCH_LIB_PATHS STREQUAL "")
  if(TRITON_PYTORCH_DOCKER_IMAGE STREQUAL "")
    message(FATAL_ERROR "Using the PyTorch docker based build requires TRITON_PYTORCH_DOCKER_IMAGE")
  endif()
  set(TRITON_PYTORCH_DOCKER_BUILD ON)
  message(STATUS "Using PyTorch docker: ${TRITON_PYTORCH_DOCKER_IMAGE}")
else()
  # Look for installed Torch-TRT package in lib paths
  if(TRITON_PYTORCH_ENABLE_TORCHTRT AND NOT EXISTS "${TRITON_PYTORCH_LIB_PATHS}/libtorchtrt_runtime.so")
    message(WARNING "TRITON_PYTORCH_ENABLE_TORCHTRT is on, but TRITON_PYTORCH_LIB_PATHS does not contain Torch-TRT package")
  endif()

    # Look for installed Torchvision package in lib paths
  if(TRITON_PYTORCH_ENABLE_TORCHVISION AND NOT EXISTS "${TRITON_PYTORCH_LIB_PATHS}/libtorchvision.so")
    message(WARNING "TRITON_PYTORCH_ENABLE_TORCHVISION is on, but TRITON_PYTORCH_LIB_PATHS does not contain Torchvision package")
  endif()
endif()

# Python.h needed by torch headers.
find_package(Python3 REQUIRED COMPONENTS Development)

#
# Dependencies
#
# FetchContent's composability isn't very good. We must include the
# transitive closure of all repos so that we can override the tag.
#
include(FetchContent)

FetchContent_Declare(
  repo-common
  GIT_REPOSITORY https://github.com/triton-inference-server/common.git
  GIT_TAG ${TRITON_COMMON_REPO_TAG}
  GIT_SHALLOW ON
)
FetchContent_Declare(
  repo-core
  GIT_REPOSITORY https://github.com/triton-inference-server/core.git
  GIT_TAG ${TRITON_CORE_REPO_TAG}
  GIT_SHALLOW ON
)
FetchContent_Declare(
  repo-backend
  GIT_REPOSITORY https://github.com/triton-inference-server/backend.git
  GIT_TAG ${TRITON_BACKEND_REPO_TAG}
  GIT_SHALLOW ON
)
FetchContent_MakeAvailable(repo-common repo-core repo-backend)

#
# CUDA
#
if(${TRITON_ENABLE_GPU})
  find_package(CUDAToolkit REQUIRED)
else()
  if (${TRITON_PYTORCH_ENABLE_TORCHTRT})
    message(FATAL_ERROR "TRITON_PYTORCH_ENABLE_TORCHTRT is ON when TRITON_ENABLE_GPU is OFF")
  endif()
endif() # TRITON_ENABLE_GPU

if(${TRITON_ENABLE_NVTX})
  add_definitions(-DTRITON_ENABLE_NVTX=1)
endif() # TRITON_ENABLE_NVTX

#
# Shared library implementing the Triton Backend API
#
configure_file(src/libtriton_pytorch.ldscript libtriton_pytorch.ldscript COPYONLY)

set(PT_LIBS
    "libc10.so"
    "libc10_cuda.so"
    "libtorch.so"
    "libtorch_cpu.so"
    "libtorch_cuda.so"
    "libtorch_cuda_linalg.so"
    "libtorch_global_deps.so"
)

if (${TRITON_PYTORCH_ENABLE_TORCHVISION})
  set(PT_LIBS
      ${PT_LIBS}
      "libtorchvision.so"
  )
endif() # TRITON_PYTORCH_ENABLE_TORCHVISION

if (${TRITON_PYTORCH_ENABLE_TORCHTRT})
  set(PT_LIBS
      ${PT_LIBS}
      "libtorchtrt_runtime.so"
  )
endif() # TRITON_PYTORCH_ENABLE_TORCHTRT

if (CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64")
  set(LIBS_ARCH "aarch64")
  set(LIBTORCH_LIBS
      "libopenblas.so.0"
  )
else()
  set(LIBS_ARCH "x86_64")
  set(LIBTORCH_LIBS
    "libmkl_avx2.so.1"
    "libmkl_avx512.so.1"
    "libmkl_core.so.1"
    "libmkl_def.so.1"
    "libmkl_gnu_thread.so.1"
    "libmkl_intel_lp64.so.1"
    "libmkl_intel_thread.so.1"
    "libmkl_rt.so.1"
    "libmkl_sequential.so.1"
    "libmkl_vml_def.so.1"
  )
endif()
set(OPENCV_LIBS
    "libopencv_video.so"
    "libopencv_videoio.so"
    "libopencv_highgui.so"
    "libopencv_imgcodecs.so"
    "libopencv_imgproc.so"
    "libopencv_core.so"
    "libopencv_calib3d.so"
    "libopencv_flann.so"
    "libopencv_features2d.so"
    "libpng16.so"
    "libjpeg.so"
)

# The patchelf commands ensure the MKL libraries are loaded correctly during runtime
# Without these, the framework/backend complains of missing libraries / symbols and
# in some cases leads to segmentation faults.
if (${TRITON_PYTORCH_DOCKER_BUILD})
  string(REPLACE ";" " " LIBTORCH_LIBS_STR "${LIBTORCH_LIBS}")

  add_custom_command(
    OUTPUT
      ${PT_LIBS}
      ${LIBTORCH_LIBS}
      ${OPENCV_LIBS}
      LICENSE.pytorch
      include/torch
      include/torchvision
    COMMAND ${CMAKE_COMMAND} -E make_directory "include/torchvision"
    COMMAND docker pull ${TRITON_PYTORCH_DOCKER_IMAGE}
    COMMAND docker rm pytorch_backend_ptlib || echo "error ignored..." || true
    COMMAND docker create --name pytorch_backend_ptlib ${TRITON_PYTORCH_DOCKER_IMAGE}
    COMMAND /bin/sh -c "for i in ${LIBTORCH_LIBS_STR} ; do echo copying $i && docker cp -L pytorch_backend_ptlib:/usr/local/lib/$i $i ; done"
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/lib/libc10.so libc10.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/lib/libc10_cuda.so libc10_cuda.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/lib/libtorch.so libtorch.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/lib/libtorch_cpu.so libtorch_cpu.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/lib/libtorch_cuda.so libtorch_cuda.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/lib/libtorch_cuda_linalg.so libtorch_cuda_linalg.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/lib/libtorch_global_deps.so libtorch_global_deps.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/lib/libcaffe2_nvrtc.so libcaffe2_nvrtc.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/libtorchvision.so libtorchvision.so
    COMMAND /bin/sh -c "if [ ${TRITON_PYTORCH_ENABLE_TORCHTRT} = 'ON' ]; then docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch_tensorrt/lib/libtorchtrt_runtime.so libtorchtrt_runtime.so; fi"
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch_tensorrt/bin/torchtrtc torchtrtc || echo "error ignored..." || true
    COMMAND docker cp pytorch_backend_ptlib:/opt/pytorch/pytorch/LICENSE LICENSE.pytorch
    COMMAND docker cp pytorch_backend_ptlib:/usr/local/lib/python3.10/dist-packages/torch/include include/torch
    COMMAND docker cp pytorch_backend_ptlib:/opt/pytorch/pytorch/torch/csrc/jit/codegen include/torch/torch/csrc/jit/.
    COMMAND docker cp pytorch_backend_ptlib:/opt/pytorch/vision/torchvision/csrc include/torchvision/torchvision
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_videoio.so libopencv_videoio.so
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_highgui.so libopencv_highgui.so
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_video.so libopencv_video.so
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_imgcodecs.so libopencv_imgcodecs.so
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_imgproc.so libopencv_imgproc.so
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_core.so libopencv_core.so
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_calib3d.so libopencv_calib3d.so
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_features2d.so libopencv_features2d.so
    COMMAND docker cp -L pytorch_backend_ptlib:/usr/local/lib/libopencv_flann.so libopencv_flann.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/lib/${LIBS_ARCH}-linux-gnu/libpng16.so.16.37.0 libpng16.so
    COMMAND docker cp pytorch_backend_ptlib:/usr/lib/${LIBS_ARCH}-linux-gnu/libjpeg.so.8.2.2 libjpeg.so
    COMMAND /bin/sh -c "if [ -f libmkl_def.so.1 ]; then patchelf --add-needed libmkl_gnu_thread.so.1 libmkl_def.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_def.so.1 ]; then patchelf --add-needed libmkl_core.so.1 libmkl_def.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_avx2.so.1 ]; then patchelf --add-needed libmkl_gnu_thread.so.1 libmkl_avx2.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_avx2.so.1 ]; then patchelf --add-needed libmkl_core.so.1 libmkl_avx2.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_avx512.so.1 ]; then patchelf --add-needed libmkl_gnu_thread.so.1 libmkl_avx512.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_avx512.so.1 ]; then patchelf --add-needed libmkl_core.so.1 libmkl_avx512.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_vml_def.so.1 ]; then patchelf --add-needed libmkl_gnu_thread.so.1 libmkl_vml_def.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_vml_def.so.1 ]; then patchelf --add-needed libmkl_intel_thread.so.1 libmkl_vml_def.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_vml_def.so.1 ]; then patchelf --add-needed libmkl_core.so.1 libmkl_vml_def.so.1; fi"
    COMMAND /bin/sh -c "if [ -f libmkl_intel_thread.so.1 ]; then patchelf --add-needed libmkl_intel_lp64.so.1 libmkl_intel_thread.so.1; fi"
    COMMAND docker rm pytorch_backend_ptlib
    COMMENT "Extracting pytorch and torchvision libraries and includes from ${TRITON_PYTORCH_DOCKER_IMAGE}"
    VERBATIM
  )
  add_custom_target(ptlib_target DEPENDS ${PT_LIBS} ${LIBTORCH_LIBS} ${OPENCV_LIBS})
  add_library(ptlib SHARED IMPORTED GLOBAL)
  add_dependencies(ptlib ptlib_target)

  # Just one of the libs are enough to ensure the docker build
  set_target_properties(
    ptlib
    PROPERTIES
      IMPORTED_LOCATION libtorch.so
  )
endif() # TRITON_PYTORCH_DOCKER_BUILD

add_library(
  triton-pytorch-backend SHARED
  src/libtorch.cc
  src/libtorch_utils.cc
  src/libtorch_utils.h
)

add_library(
  TritonPyTorchBackend::triton-pytorch-backend ALIAS triton-pytorch-backend
)

target_include_directories(
  triton-pytorch-backend
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${Python3_INCLUDE_DIRS}
)

if (${TRITON_PYTORCH_DOCKER_BUILD})
  target_include_directories(
    triton-pytorch-backend
    PRIVATE
      ${CMAKE_CURRENT_BINARY_DIR}/include/torch
      ${CMAKE_CURRENT_BINARY_DIR}/include/torch/torch/csrc/api/include
      ${CMAKE_CURRENT_BINARY_DIR}/include/torchvision
  )
else()
  target_include_directories(
    triton-pytorch-backend
    PRIVATE ${TRITON_PYTORCH_INCLUDE_PATHS}
  )
endif() # TRITON_PYTORCH_DOCKER_BUILD

# Need to turn off -Werror due to Torchvision vision.h extern initialization
# Unfortunately gcc does not provide a specific flag to ignore the specific
# warning: https://gcc.gnu.org/bugzilla/show_bug.cgi?id=45977
target_compile_features(triton-pytorch-backend PRIVATE cxx_std_${TRITON_MIN_CXX_STANDARD})
target_compile_options(
  triton-pytorch-backend PRIVATE
  $<$<OR:$<CXX_COMPILER_ID:Clang>,$<CXX_COMPILER_ID:AppleClang>,$<CXX_COMPILER_ID:GNU>>:
    -Wall -Wextra -Wno-unused-parameter -Wno-type-limits>
)

if(${TRITON_ENABLE_GPU})
  target_compile_definitions(
    triton-pytorch-backend
    PRIVATE TRITON_ENABLE_GPU=1
  )
endif() # TRITON_ENABLE_GPU

set_target_properties(
  triton-pytorch-backend
  PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    OUTPUT_NAME triton_pytorch
    SKIP_BUILD_RPATH TRUE
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH_USE_LINK_PATH FALSE
    INSTALL_RPATH "$\{ORIGIN\}"
    LINK_DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/libtriton_pytorch.ldscript
    LINK_FLAGS "-Wl,--no-as-needed,--version-script libtriton_pytorch.ldscript"
)

# Need to turn off unused-but-set-variable due to Torchvision
# Need to turn off unknown-pragmas due to ATen OpenMP
set_target_properties(
  triton-pytorch-backend
  PROPERTIES COMPILE_FLAGS
    "-Wno-unknown-pragmas -Wno-unused-but-set-variable"
)

if (${TRITON_PYTORCH_DOCKER_BUILD})
  add_dependencies(
    triton-pytorch-backend
    ptlib
  )
endif() # TRITON_PYTORCH_DOCKER_BUILD

message(STATUS "Torchvision support is ${TRITON_PYTORCH_ENABLE_TORCHVISION}")
message(STATUS "Torch-TRT support is ${TRITON_PYTORCH_ENABLE_TORCHTRT}")

set(TRITON_PYTORCH_LDFLAGS "")
if (${TRITON_PYTORCH_DOCKER_BUILD})
  set(TRITON_PYTORCH_LIBS "${CMAKE_CURRENT_BINARY_DIR}/libtorch.so")

  if (${TRITON_PYTORCH_ENABLE_TORCHVISION})
    set(TRITON_PYTORCH_LIBS
        ${TRITON_PYTORCH_LIBS}
        "${CMAKE_CURRENT_BINARY_DIR}/libtorchvision.so")
  endif() # TRITON_PYTORCH_ENABLE_TORCHVISION

  if (${TRITON_PYTORCH_ENABLE_TORCHTRT})
    set(TRITON_PYTORCH_LIBS
        ${TRITON_PYTORCH_LIBS}
        "${CMAKE_CURRENT_BINARY_DIR}/libtorchtrt_runtime.so")
  endif() # TRITON_PYTORCH_ENABLE_TORCHTRT
else()
  set (TRITON_PYTORCH_LIBS "-ltorch")

  if (${TRITON_PYTORCH_ENABLE_TORCHVISION})
    set(TRITON_PYTORCH_LIBS
        ${TRITON_PYTORCH_LIBS}
        "-ltorchvision"
    )
  endif() # TRITON_PYTORCH_ENABLE_TORCHVISION

  if (${TRITON_PYTORCH_ENABLE_TORCHTRT})
    set(TRITON_PYTORCH_LIBS
        ${TRITON_PYTORCH_LIBS}
        "-ltorchtrt_runtime"
    )
  endif() # TRITON_PYTORCH_ENABLE_TORCHTRT

  FOREACH(p ${TRITON_PYTORCH_LIB_PATHS})
    set(TRITON_PYTORCH_LDFLAGS ${TRITON_PYTORCH_LDFLAGS} "-L${p}")
  ENDFOREACH(p)
endif() # TRITON_PYTORCH_DOCKER_BUILD

target_link_libraries(
  triton-pytorch-backend
  PRIVATE
    triton-core-serverapi  # from repo-core
    triton-core-backendapi # from repo-core
    triton-core-serverstub # from repo-core
    triton-backend-utils   # from repo-backend
    ${TRITON_PYTORCH_LDFLAGS}
    ${TRITON_PYTORCH_LIBS}
)

if(${TRITON_ENABLE_GPU})
  target_link_libraries(
    triton-pytorch-backend
    PRIVATE
      CUDA::cudart
  )
endif() # TRITON_ENABLE_GPU

#
# Install
#
include(GNUInstallDirs)
set(INSTALL_CONFIGDIR ${CMAKE_INSTALL_LIBDIR}/cmake/TritonPyTorchBackend)

install(
  TARGETS
    triton-pytorch-backend
  EXPORT
    triton-pytorch-backend-targets
  LIBRARY DESTINATION ${CMAKE_INSTALL_PREFIX}/backends/pytorch
  ARCHIVE DESTINATION ${CMAKE_INSTALL_PREFIX}/backends/pytorch
)

if (${TRITON_PYTORCH_DOCKER_BUILD})
  set(PT_LIB_PATHS "")
  FOREACH(plib ${PT_LIBS} ${LIBTORCH_LIBS} ${OPENCV_LIBS})
    set(PT_LIB_PATHS ${PT_LIB_PATHS} "${CMAKE_CURRENT_BINARY_DIR}/${plib}")
  ENDFOREACH(plib)

  install(
    FILES
      ${PT_LIB_PATHS}
      ${CMAKE_CURRENT_BINARY_DIR}/LICENSE.pytorch
    DESTINATION ${CMAKE_INSTALL_PREFIX}/backends/pytorch
  )

  if (${TRITON_PYTORCH_ENABLE_TORCHTRT})
    install(
      FILES
        ${CMAKE_CURRENT_BINARY_DIR}/torchtrtc
      DESTINATION ${CMAKE_INSTALL_PREFIX}/backends/pytorch
    )
  endif() # TRITON_PYTORCH_ENABLE_TORCHTRT

  FOREACH(plib ${PT_LIBS} ${LIBTORCH_LIBS} ${OPENCV_LIBS})
    install(
      CODE
        "EXECUTE_PROCESS(
          COMMAND patchelf --set-rpath \$ORIGIN ${plib}
          RESULT_VARIABLE PATCHELF_STATUS
          WORKING_DIRECTORY ${CMAKE_INSTALL_PREFIX}/backends/pytorch)
        if(PATCHELF_STATUS AND NOT PATCHELF_STATUS EQUAL 0)
          message(FATAL_ERROR \"FAILED: to run patchelf\")
        endif()"
    )
  ENDFOREACH(plib)

  set(OPENCV_VERSION "406")
  install(
    CODE
      "EXECUTE_PROCESS(
        COMMAND ln -sf libopencv_video.so libopencv_video.so.${OPENCV_VERSION}
        COMMAND ln -sf libopencv_videoio.so libopencv_videoio.so.${OPENCV_VERSION}
        COMMAND ln -sf libopencv_highgui.so libopencv_highgui.so.${OPENCV_VERSION}
        COMMAND ln -sf libopencv_imgcodecs.so libopencv_imgcodecs.so.${OPENCV_VERSION}
        COMMAND ln -sf libopencv_imgproc.so libopencv_imgproc.so.${OPENCV_VERSION}
        COMMAND ln -sf libopencv_core.so libopencv_core.so.${OPENCV_VERSION}
        COMMAND ln -sf libopencv_calib3d.so libopencv_calib3d.so.${OPENCV_VERSION}
        COMMAND ln -sf libopencv_features2d.so libopencv_features2d.so.${OPENCV_VERSION}
        COMMAND ln -sf libopencv_flann.so libopencv_flann.so.${OPENCV_VERSION}
        COMMAND ln -sf libpng16.so libpng16.so.16
        COMMAND ln -sf libjpeg.so libjpeg.so.8
        RESULT_VARIABLE LINK_STATUS
        WORKING_DIRECTORY ${CMAKE_INSTALL_PREFIX}/backends/pytorch)
      if(LINK_STATUS AND NOT LINK_STATUS EQUAL 0)
        message(FATAL_ERROR \"FAILED: to create links\")
      endif()"
  )
else()
  FOREACH(plib ${PT_LIBS})
    set(PT_LIB_PATHS ${PT_LIB_PATHS} "${TRITON_PYTORCH_LIB_PATHS}/${plib}")
  ENDFOREACH(plib)

  install(
    FILES
      ${PT_LIB_PATHS}
    DESTINATION ${CMAKE_INSTALL_PREFIX}/backends/pytorch
  )

  FOREACH(plib ${PT_LIBS})
    install(
      CODE
        "EXECUTE_PROCESS(
          COMMAND patchelf --set-rpath \$ORIGIN ${plib}
          RESULT_VARIABLE PATCHELF_STATUS
          WORKING_DIRECTORY ${CMAKE_INSTALL_PREFIX}/backends/pytorch)
        if(PATCHELF_STATUS AND NOT PATCHELF_STATUS EQUAL 0)
          message(FATAL_ERROR \"FAILED: to run patchelf\")
        endif()"
    )
  ENDFOREACH(plib)
endif() # TRITON_PYTORCH_DOCKER_BUILD

install(
  EXPORT
    triton-pytorch-backend-targets
  FILE
    TritonPyTorchBackendTargets.cmake
  NAMESPACE
    TritonPyTorchBackend::
  DESTINATION
    ${INSTALL_CONFIGDIR}
)

install(
  FILES
    src/model.py
  DESTINATION
    ${CMAKE_INSTALL_PREFIX}/backends/pytorch
)

include(CMakePackageConfigHelpers)
configure_package_config_file(
  ${CMAKE_CURRENT_LIST_DIR}/cmake/TritonPyTorchBackendConfig.cmake.in
  ${CMAKE_CURRENT_BINARY_DIR}/TritonPyTorchBackendConfig.cmake
  INSTALL_DESTINATION ${INSTALL_CONFIGDIR}
)

install(
  FILES
  ${CMAKE_CURRENT_BINARY_DIR}/TritonPyTorchBackendConfig.cmake
  DESTINATION ${INSTALL_CONFIGDIR}
)

#
# Export from build tree
#
export(
  EXPORT triton-pytorch-backend-targets
  FILE ${CMAKE_CURRENT_BINARY_DIR}/TritonPyTorchBackendTargets.cmake
  NAMESPACE TritonPyTorchBackend::
)

export(PACKAGE TritonPyTorchBackend)

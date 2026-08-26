cmake_minimum_required(VERSION 3.22.1)
project(lsfg-minecraft LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(LSFG_ROOT "${CMAKE_SOURCE_DIR}/../../../../lsfg-vk-android")
if(NOT EXISTS "${LSFG_ROOT}/framegen/CMakeLists.txt")
    message(FATAL_ERROR "Can't find lsfg-vk sources at ${LSFG_ROOT}.")
endif()

# -----------------------------------------------------------------------------
# volk
# -----------------------------------------------------------------------------
add_library(volk STATIC "${LSFG_ROOT}/thirdparty/volk/volk.c")
target_include_directories(volk PUBLIC "${LSFG_ROOT}/thirdparty/volk")
target_compile_definitions(volk PUBLIC VK_USE_PLATFORM_ANDROID_KHR=1)

# -----------------------------------------------------------------------------
# pe-parse (excluding test corpus)
# -----------------------------------------------------------------------------
set(PEPARSE_DIR "${LSFG_ROOT}/thirdparty/pe-parse/pe-parser-library")
add_library(pe-parse STATIC
    "${PEPARSE_DIR}/src/buffer.cpp"
    "${PEPARSE_DIR}/src/parse.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/unicode_minimal.cpp"
)
target_include_directories(pe-parse PUBLIC "${PEPARSE_DIR}/include")
target_compile_features(pe-parse PUBLIC cxx_std_17)

# -----------------------------------------------------------------------------
# dxbc
# -----------------------------------------------------------------------------
add_subdirectory("${LSFG_ROOT}/thirdparty/dxbc" "${CMAKE_BINARY_DIR}/dxbc" EXCLUDE_FROM_ALL)

# -----------------------------------------------------------------------------
# framegen
# -----------------------------------------------------------------------------
add_subdirectory("${LSFG_ROOT}/framegen" "${CMAKE_BINARY_DIR}/framegen" EXCLUDE_FROM_ALL)

# -----------------------------------------------------------------------------
# liblsfg-minecraft.so
# -----------------------------------------------------------------------------
add_library(lsfg-minecraft SHARED
    lsfg_mc_jni.cpp
    mc_shader_extractor.cpp
    mc_vk_probe.cpp
    mc_vk_passive_hook.cpp
)

target_include_directories(lsfg-minecraft PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${LSFG_ROOT}/framegen/public"
    "${LSFG_ROOT}/framegen/include"
    "${LSFG_ROOT}/thirdparty/dxbc/src"
    "${LSFG_ROOT}/thirdparty/pe-parse/pe-parser-library/include"
    "${LSFG_ROOT}/thirdparty/volk"
    "${LSFG_ROOT}/thirdparty/toml11/include"
)

target_link_libraries(lsfg-minecraft PRIVATE
    lsfg-vk-framegen
    dxbc
    pe-parse
    volk
    android
    log
)

set_target_properties(lsfg-minecraft PROPERTIES
    OUTPUT_NAME "lsfg-minecraft"
    PREFIX "lib"
    SUFFIX ".so"
)

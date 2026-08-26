#pragma once

#include <string>
#include <vector>
#include <cstdint>

namespace lsfg_mc {

/// Extracts DXBC and precompiled SPIR-V shaders from the user-provided Lossless.dll
/// and writes cached .spv files into cacheDir without modifying the source DLL.
///
/// @param dllPath Absolute path to the user's Lossless.dll
/// @param cacheDir Directory where shaders/ should be written
/// @return 0 on success, non-zero error code otherwise
int extract_dll_to_spirv(const std::string &dllPath, const std::string &cacheDir);

/// Validates whether a file is a valid PE DLL with required LSFG resources.
bool is_valid_pe_dll(const std::string &dllPath);

} // namespace lsfg_mc

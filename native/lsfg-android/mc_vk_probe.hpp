#pragma once

#include <string>

namespace lsfg_mc {

int probe_shaders_on_device(const std::string &cacheDir);
bool device_supports_float16();

} // namespace lsfg_mc

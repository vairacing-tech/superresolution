#include "mc_shader_extractor.hpp"

#include <pe-parse/parse.h>
#include <dxbc_modinfo.h>
#include <dxbc_module.h>
#include <dxbc_reader.h>
#include <thirdparty/spirv.hpp>

#include <android/log.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <unordered_map>
#include <vector>

#define LOG_TAG "lsfg-mc-extract"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)

namespace {

constexpr uint32_t kResourceIds[] = {
    255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266,
    267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279,
    280, 281, 282, 283, 284, 285, 286, 287, 288, 289,
    290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302,
};

constexpr uint32_t kFp16IdOffset = 49;
constexpr uint32_t kFp32SpirvIdOffset = 98;
constexpr std::array<uint8_t, 4> kSpirvMagic{0x03, 0x02, 0x23, 0x07};

struct ExtractionCtx {
    std::unordered_map<uint32_t, std::vector<uint8_t>> *out;
};

int on_resource(void *userData, const peparse::resource &res) {
    auto *ctx = static_cast<ExtractionCtx *>(userData);
    if (res.type != peparse::RT_RCDATA || res.buf == nullptr || res.buf->bufLen <= 0) {
        return 0;
    }
    std::vector<uint8_t> data(res.buf->bufLen);
    std::copy_n(res.buf->buf, res.buf->bufLen, data.data());
    (*ctx->out)[res.name] = std::move(data);
    return 0;
}

struct BindingOffsets {
    uint32_t bindingIndex{};
    uint32_t bindingOffset{};
    uint32_t setIndex{};
    uint32_t setOffset{};
};

void cap_spirv_version(std::vector<uint8_t> &spirv) {
    if (spirv.size() < 20) return;
    uint32_t ver;
    std::memcpy(&ver, spirv.data() + 4, 4);
    if (ver > 0x00010300u) {
        ver = 0x00010300u;
        std::memcpy(spirv.data() + 4, &ver, 4);
    }
}

bool rewrite_spirv_bindings_dense(std::vector<uint8_t> &spirv) {
    if (spirv.size() < 20 || (spirv.size() % 4) != 0) {
        return false;
    }
    auto *words = reinterpret_cast<uint32_t *>(spirv.data());
    const size_t wordCount = spirv.size() / 4;
    if (words[0] != 0x07230203u) {
        return false;
    }

    constexpr uint32_t kOpTypeImage = 25;
    constexpr uint32_t kOpTypeSampler = 26;
    constexpr uint32_t kOpTypeSampledImage = 27;
    constexpr uint32_t kOpTypeStruct = 30;
    constexpr uint32_t kOpTypePointer = 32;
    constexpr uint32_t kOpVariable = 59;
    constexpr uint32_t kOpDecorate = 71;
    constexpr uint32_t kOpFunction = 54;
    constexpr uint32_t kDecorationBinding = 33;

    enum Kind : int {
        KindUnknown = 4,
        KindUniformBuffer = 0,
        KindSampler = 1,
        KindSampledImage = 2,
        KindStorageImage = 3,
    };

    struct BindingSite {
        size_t valueWordIndex;
        uint32_t varId;
        uint32_t origBinding;
        Kind kind;
    };

    std::unordered_map<uint32_t, Kind> typeKind;
    std::unordered_map<uint32_t, uint32_t> ptrPointee;
    std::unordered_map<uint32_t, uint32_t> varType;
    std::vector<BindingSite> sites;
    sites.reserve(32);

    size_t i = 5;
    while (i < wordCount) {
        const uint32_t header = words[i];
        const uint32_t wc = (header >> 16) & 0xFFFFu;
        const uint32_t op = header & 0xFFFFu;
        if (wc == 0 || i + wc > wordCount) {
            return false;
        }
        if (op == kOpFunction) {
            break;
        }
        switch (op) {
            case kOpTypeSampler:
                if (wc >= 2) typeKind[words[i + 1]] = KindSampler;
                break;
            case kOpTypeImage:
                if (wc >= 8) {
                    typeKind[words[i + 1]] = (words[i + 7] == 2) ? KindStorageImage : KindSampledImage;
                }
                break;
            case kOpTypeSampledImage:
                if (wc >= 2) typeKind[words[i + 1]] = KindSampledImage;
                break;
            case kOpTypeStruct:
                if (wc >= 2) typeKind[words[i + 1]] = KindUniformBuffer;
                break;
            case kOpTypePointer:
                if (wc == 4) ptrPointee[words[i + 1]] = words[i + 3];
                break;
            case kOpVariable:
                if (wc >= 4) varType[words[i + 2]] = words[i + 1];
                break;
            case kOpDecorate:
                if (wc == 4 && words[i + 2] == kDecorationBinding) {
                    sites.push_back({i + 3, words[i + 1], words[i + 3], KindUnknown});
                }
                break;
            default:
                break;
        }
        i += wc;
    }

    for (auto &s : sites) {
        const auto vt = varType.find(s.varId);
        if (vt == varType.end()) continue;
        const auto pp = ptrPointee.find(vt->second);
        if (pp == ptrPointee.end()) continue;
        const auto tk = typeKind.find(pp->second);
        if (tk != typeKind.end()) {
            s.kind = tk->second;
        }
    }

    for (const auto &s : sites) {
        if (s.kind == KindUnknown) {
            return false;
        }
    }
    std::stable_sort(sites.begin(), sites.end(), [](const BindingSite &a, const BindingSite &b) {
        if (a.kind != b.kind) return static_cast<int>(a.kind) < static_cast<int>(b.kind);
        return a.origBinding < b.origBinding;
    });

    for (size_t k = 0; k < sites.size(); ++k) {
        words[sites[k].valueWordIndex] = static_cast<uint32_t>(k);
    }
    return true;
}

std::vector<uint8_t> translate_dxbc_to_spirv(const std::vector<uint8_t> &bytecode) {
    dxvk::DxbcReader reader(reinterpret_cast<const char *>(bytecode.data()), bytecode.size());
    dxvk::DxbcModule module(reader);
    const dxvk::DxbcModuleInfo info{};
    auto code = module.compile(info, "CS");

    std::vector<BindingOffsets> bindingOffsets;
    std::vector<uint32_t> varIds;
    for (auto ins : code) {
        if (ins.opCode() == spv::OpDecorate) {
            if (ins.arg(2) == spv::DecorationBinding) {
                const uint32_t varId = ins.arg(1);
                bindingOffsets.resize(std::max(bindingOffsets.size(), size_t(varId + 1)));
                bindingOffsets[varId].bindingIndex = ins.arg(3);
                bindingOffsets[varId].bindingOffset = ins.offset() + 3;
                varIds.push_back(varId);
            }
            if (ins.arg(2) == spv::DecorationDescriptorSet) {
                const uint32_t varId = ins.arg(1);
                bindingOffsets.resize(std::max(bindingOffsets.size(), size_t(varId + 1)));
                bindingOffsets[varId].setIndex = ins.arg(3);
                bindingOffsets[varId].setOffset = ins.offset() + 3;
            }
        }
        if (ins.opCode() == spv::OpFunction) {
            break;
        }
    }

    std::vector<BindingOffsets> validBindings;
    for (const auto varId : varIds) {
        const auto info = bindingOffsets[varId];
        if (info.bindingOffset) {
            validBindings.push_back(info);
        }
    }

    for (size_t i = 0; i < validBindings.size(); ++i) {
        code.data()[validBindings[i].bindingOffset] = static_cast<uint8_t>(i);
    }

    std::vector<uint8_t> spirv(code.size());
    std::copy_n(reinterpret_cast<const uint8_t *>(code.data()), code.size(), spirv.data());
    cap_spirv_version(spirv);
    return spirv;
}

bool write_file(const std::string &path, const std::vector<uint8_t> &data) {
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f) {
        return false;
    }
    f.write(reinterpret_cast<const char *>(data.data()), static_cast<std::streamsize>(data.size()));
    return f.good();
}

} // namespace

namespace lsfg_mc {

bool is_valid_pe_dll(const std::string &dllPath) {
    peparse::parsed_pe *dll = peparse::ParsePEFromFile(dllPath.c_str());
    if (!dll) return false;
    peparse::DestructParsedPE(dll);
    return true;
}

int extract_dll_to_spirv(const std::string &dllPath, const std::string &cacheDir) {
    peparse::parsed_pe *dll = peparse::ParsePEFromFile(dllPath.c_str());
    if (!dll) {
        LOGE("ParsePEFromFile failed for %s", dllPath.c_str());
        return -1;
    }

    std::unordered_map<uint32_t, std::vector<uint8_t>> blobsByResId;
    ExtractionCtx ctx{&blobsByResId};
    peparse::IterRsrc(dll, on_resource, &ctx);
    peparse::DestructParsedPE(dll);

    for (uint32_t id : kResourceIds) {
        if (blobsByResId.find(id) == blobsByResId.end()) {
            LOGE("Missing resource id %u in Lossless.dll", id);
            return -2;
        }
    }

    mkdir(cacheDir.c_str(), 0755);

    int translated = 0;
    for (uint32_t resId : kResourceIds) {
        const auto &dxbc = blobsByResId.at(resId);
        std::vector<uint8_t> spirv;
        try {
            spirv = translate_dxbc_to_spirv(dxbc);
        } catch (const std::exception &e) {
            LOGE("DXBC->SPIR-V failed for resource %u: %s", resId, e.what());
            return -3;
        }
        if (spirv.empty()) {
            LOGE("Empty SPIR-V for resource %u", resId);
            return -3;
        }

        char path[512];
        std::snprintf(path, sizeof(path), "%s/%u.spv", cacheDir.c_str(), resId);
        if (!write_file(path, spirv)) {
            LOGE("Failed to write %s", path);
            return -4;
        }
        ++translated;
    }

    LOGI("Extracted and translated %d DXBC shaders into %s", translated, cacheDir.c_str());

    // FP16 SPIR-V variants
    const std::string fp16Dir = cacheDir + "/fp16";
    mkdir(fp16Dir.c_str(), 0755);
    int fp16Cached = 0;
    for (uint32_t dxbcId : kResourceIds) {
        const uint32_t fp16Id = dxbcId + kFp16IdOffset;
        const auto it = blobsByResId.find(fp16Id);
        if (it == blobsByResId.end()) continue;

        std::vector<uint8_t> blob = it->second;
        if (blob.size() < kSpirvMagic.size() ||
            !std::equal(kSpirvMagic.begin(), kSpirvMagic.end(), blob.begin())) {
            continue;
        }
        if (!rewrite_spirv_bindings_dense(blob)) {
            continue;
        }
        char path[512];
        std::snprintf(path, sizeof(path), "%s/%u.spv", fp16Dir.c_str(), fp16Id);
        if (write_file(path, blob)) {
            ++fp16Cached;
        }
    }
    LOGI("FP16 SPIR-V: %d variants cached", fp16Cached);

    // FP32 SPIR-V variants
    const std::string fp32Dir = cacheDir + "/fp32";
    mkdir(fp32Dir.c_str(), 0755);
    int fp32Cached = 0;
    for (uint32_t dxbcId : kResourceIds) {
        const uint32_t fp32Id = dxbcId + kFp32SpirvIdOffset;
        const auto it = blobsByResId.find(fp32Id);
        if (it == blobsByResId.end()) continue;

        std::vector<uint8_t> blob = it->second;
        if (blob.size() < kSpirvMagic.size() ||
            !std::equal(kSpirvMagic.begin(), kSpirvMagic.end(), blob.begin())) {
            continue;
        }
        if (!rewrite_spirv_bindings_dense(blob)) {
            continue;
        }
        char path[512];
        std::snprintf(path, sizeof(path), "%s/%u.spv", fp32Dir.c_str(), fp32Id);
        if (write_file(path, blob)) {
            ++fp32Cached;
        }
    }
    LOGI("FP32 SPIR-V: %d variants cached", fp32Cached);

    return 0;
}

} // namespace lsfg_mc

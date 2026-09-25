"""Execute real bridge discovery/control functions with an RTLD_LOCAL-only fake loader."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'native/lsfg-android/mc_vk_passive_hook.cpp'


def block(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


source = SOURCE.read_text(encoding='utf-8')
header = SOURCE.with_suffix('.hpp').read_text(encoding='utf-8')
structs = '\n'.join(block(header, 'struct ' + name) + ';' for name in ('LsfgRuntimeStatus', 'LsfgRuntimeConfig'))
functions = '\n'.join(block(source, signature) for signature in (
    'void init_passive_vulkan_diagnostics(', 'int32_t get_runtime_status(', 'int32_t set_runtime_config('))
test = r'''
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <thread>
#define LOGI(...) ((void)0)
#define LOGW(...) ((void)0)
#define LOGE(...) ((void)0)
#define RTLD_DEFAULT nullptr
''' + structs + r'''
struct LsfgBridgeSnapshotV2 {};
struct LsfgBridgeSwapchainImagesV2 {};
struct LsfgBridgePresentModesV2 {};
using PFN_lsfg_interposer_bridge_get_version = uint32_t (*)();
using PFN_lsfg_interposer_bridge_notify_content_discontinuity = int32_t (*)();
using PFN_lsfg_interposer_bridge_get_runtime_status = int32_t (*)(LsfgRuntimeStatus*);
using PFN_lsfg_interposer_bridge_set_runtime_config = int32_t (*)(const LsfgRuntimeConfig*);
using PFN_lsfg_interposer_register_present_observer_v1 = int32_t (*)(void (*)(), void*);
using PFN_lsfg_interposer_bridge_get_snapshot_v2 = void (*)();
using PFN_lsfg_interposer_bridge_get_swapchain_images_v2 = void (*)();
using PFN_lsfg_interposer_bridge_get_present_modes_v2 = void (*)();
static std::atomic<bool> g_v1ProbeEnabled{false}, g_v2ProbeEnabled{false}, g_v2a1WorkerStarted{false};
static std::atomic<PFN_lsfg_interposer_bridge_get_runtime_status> g_getRuntimeStatusFn{nullptr};
static std::atomic<PFN_lsfg_interposer_bridge_set_runtime_config> g_setRuntimeConfigFn{nullptr};
static std::atomic<PFN_lsfg_interposer_bridge_notify_content_discontinuity> g_notifyContentDiscontinuityFn{nullptr};
static std::atomic<PFN_lsfg_interposer_bridge_get_snapshot_v2> g_getSnapshotV2Fn{nullptr};
static std::atomic<PFN_lsfg_interposer_bridge_get_swapchain_images_v2> g_getSwapchainImagesV2Fn{nullptr};
static std::atomic<PFN_lsfg_interposer_bridge_get_present_modes_v2> g_getPresentModesV2Fn{nullptr};
static int registrations = 0, diagnosticLookups = 0, enabled = 0, factor = 2;
static bool exportsAvailable = true;
static uint32_t version = 1;
static void ensure_real_vulkan_loaded() {}
static void lsfg_present_observer_callback_v1() {}
static void v2a1_metadata_worker() {}
static uint32_t get_version() { return version; }
static int32_t cut() { return 0; }
static void diagnostic() {}
static int32_t reg(void (*)(), void*) { ++registrations; return 0; }
static int32_t configure(const LsfgRuntimeConfig *p) { enabled=p->enabled; factor=p->factor; return 0; }
static int32_t status(LsfgRuntimeStatus *p) { p->state=enabled ? 2 : 0; p->factor=factor; return 0; }
static void *dlsym(void *handle, const char *name) {
    // The interposer is RTLD_LOCAL, so default-scope lookups MUST fail.
    if (handle != (void*)1) return nullptr;
    if (!strcmp(name,"lsfg_interposer_bridge_get_version")) return (void*)get_version;
    if (!strcmp(name,"lsfg_interposer_bridge_notify_content_discontinuity")) return (void*)cut;
    if (!strcmp(name,"lsfg_interposer_bridge_get_runtime_status")) return exportsAvailable ? (void*)status : nullptr;
    if (!strcmp(name,"lsfg_interposer_bridge_set_runtime_config")) return exportsAvailable ? (void*)configure : nullptr;
    ++diagnosticLookups;
    if (!strcmp(name,"lsfg_interposer_register_present_observer_v1")) return (void*)reg;
    return (void*)diagnostic;
}
static void reset() {
    g_getRuntimeStatusFn=nullptr; g_setRuntimeConfigFn=nullptr; g_notifyContentDiscontinuityFn=nullptr;
    g_getSnapshotV2Fn=nullptr; g_getSwapchainImagesV2Fn=nullptr; g_getPresentModesV2Fn=nullptr;
    g_v2a1WorkerStarted=false; registrations=diagnosticLookups=enabled=0; factor=2;
}
''' + functions + r'''
int main() {
    _putenv_s("VULKAN_PTR", "1");
    for (bool v1 : {false,true}) for (bool v2 : {false,true}) {
        reset(); init_passive_vulkan_diagnostics(v1,v2);
        LsfgRuntimeConfig config{};
        LsfgRuntimeStatus result{};
        for (int on : {0,1}) for (int multiplier : {2,3}) {
            config.enabled=on; config.factor=multiplier;
            int rc=set_runtime_config(&config);
            if (rc || get_runtime_status(&result) || result.factor!=multiplier || result.state!=(on ? 2 : 0)) {
                printf("FAIL: probes v1=%d v2=%d: runtime config returned %d (RTLD_LOCAL)\n",v1,v2,rc);
                return 1;
            }
        }
        if (!v1 && !v2 && (registrations || diagnosticLookups || g_v2a1WorkerStarted)) return 2;
        if (g_v2a1WorkerStarted != v2) return 3;
        if (get_runtime_status(nullptr)!=-1 || set_runtime_config(nullptr)!=-1) return 4;
    }
    LsfgRuntimeConfig config{}; LsfgRuntimeStatus result{};
    for (int scenario : {0,1,2}) {
        reset(); exportsAvailable=scenario!=0; version=scenario==1 ? 99 : 1;
        if (scenario==2) _putenv_s("VULKAN_PTR", "");
        init_passive_vulkan_diagnostics(false,false);
        if (set_runtime_config(&config)!=-100 || get_runtime_status(&result)!=-100) return 5;
    }
    puts("PASS: all probe combinations control OFF/x2/x3; diagnostics stay gated; missing/unsupported bridge is safe");
}
'''

msvc = sorted(Path('C:/Program Files (x86)/Microsoft Visual Studio').glob('*/BuildTools/VC/Tools/MSVC/*'))[-1]
sdk = Path('C:/Program Files (x86)/Windows Kits/10')
sdk_version = sorted((sdk/'Include').iterdir())[-1].name
env = os.environ.copy()
env['INCLUDE'] = ';'.join(map(str,[msvc/'include']+[sdk/'Include'/sdk_version/p for p in ('ucrt','shared','um')]))
env['LIB'] = ';'.join(map(str,[msvc/'lib/x64']+[sdk/'Lib'/sdk_version/p/'x64' for p in ('ucrt','um')]))
with tempfile.TemporaryDirectory(prefix='lsfg-runtime-bridge-') as directory:
    path = Path(directory)
    cpp = path/'contract.cpp'; cpp.write_text(test,encoding='utf-8')
    exe = path/'contract.exe'
    subprocess.run([str(msvc/'bin/Hostx64/x64/cl.exe'),'/nologo','/std:c++17','/EHsc',str(cpp),'/Fe:'+str(exe),'/Fo:'+str(path/'contract.obj')],env=env,check=True)
    subprocess.run([str(exe)],check=True)

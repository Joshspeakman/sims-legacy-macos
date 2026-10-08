/* vulkan-1.dll for the recompiled game: the commands that need more than a structure conversion (vulkan_gen.c has
 * the rest). The host's Vulkan is the system loader on Linux and MoltenVK on macOS; the host program provides the
 * window's surface (w32_host_vk_*).
 *
 * Mapped memory. The guest can only address its own 4 GB, so a mapping must appear inside it:
 *  - placed (VK_EXT_map_memory_placed): the driver maps the allocation at a guest address we reserve. No copies.
 *  - shadowed (no such extension, e.g. MoltenVK): the guest gets a copy; it is written to the device memory before
 *    every submission and at flushes, and read back at invalidations and, for host-cached memory (where the GPU's
 *    results are read), after the waits that make them visible.
 * Every allocation is mapped whole the first time and stays mapped until vkUnmapMemory or vkFreeMemory. */
#include "vulkan_rt.h"
#include <dlfcn.h>
#include <sys/mman.h>

int vk_trace;
/* host hooks (host/linux.c, host/main.m) */
PFN_vkGetInstanceProcAddr (*w32_host_vk_loader)(void);                         /* the host's vkGetInstanceProcAddr */
unsigned (*w32_host_vk_extensions)(const char **names, unsigned cap);          /* instance extensions for surfaces */
int (*w32_host_vk_surface)(VkInstance instance, VkSurfaceKHR *surface);        /* the game window's surface */
void (*w32_host_vk_presented)(void);                                           /* a frame went to the screen */

static PFN_vkGetInstanceProcAddr gipa;
static int load_host(void)
{
    if (gipa) return 1;
    if (w32_host_vk_loader) gipa = w32_host_vk_loader();
    if (!gipa) {
#ifdef __APPLE__
        static const char *libs[] = {"libvulkan.1.dylib", "libMoltenVK.dylib", 0};
#else
        static const char *libs[] = {"libvulkan.so.1", "libvulkan.so", 0};
#endif
        for (int k = 0; libs[k] && !gipa; k++) { void *h = dlopen(libs[k], RTLD_NOW | RTLD_LOCAL); if (h) gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr"); }
    }
    vk_trace = getenv("W32_VKLOG") != 0;
    if (!gipa) fprintf(stderr, "vulkan: no Vulkan on this system\n");
    return gipa != 0;
}
static void load_procs(VkInstance inst)
{
    void **slot = (void **)&vkp;
    for (int k = 0; vk_proc_names[k]; k++) {
        const char *n = vk_proc_names[k]; PFN_vkVoidFunction f = gipa(inst, n);
        if (!f) {                                      /* a KHR name for what the core has (1.1+) */
            char core[96]; size_t l = strlen(n);
            if (l > 3 && !strcmp(n + l - 3, "KHR") && l < sizeof core) { memcpy(core, n, l - 3); core[l - 3] = 0; f = gipa(inst, core); }
        }
        slot[k] = (void *)f;
    }
}

/* ---- per-call arena ---- */
void *vk_arena(VkArena *a, size_t n)
{
    if (a->n == a->cap) { a->cap = a->cap ? a->cap * 2 : 16; a->blocks = realloc(a->blocks, a->cap * sizeof *a->blocks); }
    return a->blocks[a->n++] = calloc(1, n ? n : 1);
}
void vk_arena_free(VkArena *a) { for (unsigned k = 0; k < a->n; k++) free(a->blocks[k]); free(a->blocks); a->blocks = 0; a->n = a->cap = 0; }

/* ---- dispatchable handles: guest ids are 16-byte guest allocations, so they are unique and never 0 ---- */
#define NH 8192
static struct { uint32_t g; const void *h; } htab[NH]; static pthread_mutex_t h_m = PTHREAD_MUTEX_INITIALIZER;
uint32_t vkh_guest(const void *host)
{
    if (!host) return 0;
    pthread_mutex_lock(&h_m);
    for (int k = 0; k < NH; k++) if (htab[k].h == host) { uint32_t g = htab[k].g; pthread_mutex_unlock(&h_m); return g; }
    uint32_t g = heap_alloc(w32_process_heap, 8, 16);
    for (int k = 0; k < NH; k++) if (!htab[k].h) { htab[k].g = g; htab[k].h = host; break; }
    pthread_mutex_unlock(&h_m);
    return g;
}
void *vkh_host(uint32_t guest)
{
    if (!guest) return 0;
    uint32_t k = (guest >> 4) % NH;                    /* fast path: look where the id hashes first */
    if (htab[k].g == guest) return (void *)htab[k].h;
    pthread_mutex_lock(&h_m);
    for (int j = 0; j < NH; j++) if (htab[j].g == guest) { void *h = (void *)htab[j].h; pthread_mutex_unlock(&h_m); return h; }
    pthread_mutex_unlock(&h_m);
    fprintf(stderr, "vulkan: unknown handle %08x\n", guest);
    return 0;
}
void vkh_forget(const void *host)
{
    pthread_mutex_lock(&h_m);
    for (int k = 0; k < NH; k++) if (htab[k].h == host) { heap_free(w32_process_heap, htab[k].g); htab[k].h = 0; htab[k].g = 0; }
    pthread_mutex_unlock(&h_m);
}
void vk_unknown_stype(uint32_t stype)
{
    static uint32_t seen[64]; static int n;
    for (int k = 0; k < n; k++) if (seen[k] == stype) return;
    if (n < 64) seen[n++] = stype;
    fprintf(stderr, "vulkan: structure type %u in a pNext chain is not converted: left out\n", stype);
}

/* ---- proc addresses ---- */
static uint32_t proc(const char *name)
{
    extern int w32_thunk_implemented(uint32_t);
    if (!strcmp(name, "vkCreateDebugUtilsMessengerEXT") || !strcmp(name, "vkDestroyDebugUtilsMessengerEXT")) return 0;
    uint32_t t = w32_thunk_for("vulkan-1", name);
    if (!t || !w32_thunk_implemented(t)) { if (vk_trace) fprintf(stderr, "vulkan: %s not available\n", name); return 0; }
    return t;
}
IMPL(vulkan_1, vkGetInstanceProcAddr) { load_host(); RET(proc(GS(ARG(1))), 2); }
IMPL(vulkan_1, vkGetDeviceProcAddr) { RET(proc(GS(ARG(1))), 2); }

/* ---- instance ---- */
static int has_name(const char *const *v, uint32_t n, const char *s) { for (uint32_t k = 0; k < n; k++) if (!strcmp(v[k], s)) return 1; return 0; }
static VkExtensionProperties *host_inst_ext; static uint32_t host_inst_next;
static void host_instance_extensions(void)
{
    if (host_inst_ext || !load_host()) return;
    PFN_vkEnumerateInstanceExtensionProperties e = (PFN_vkEnumerateInstanceExtensionProperties)gipa(0, "vkEnumerateInstanceExtensionProperties");
    e(0, &host_inst_next, 0); host_inst_ext = calloc(host_inst_next + 1, sizeof *host_inst_ext); e(0, &host_inst_next, host_inst_ext);
}
static int host_has_inst_ext(const char *n) { host_instance_extensions(); for (uint32_t k = 0; k < host_inst_next; k++) if (!strcmp(host_inst_ext[k].extensionName, n)) return 1; return 0; }
/* what the game is told it can enable: surfaces as on Windows, and the 1.1 helpers it may use */
IMPL(vulkan_1, vkEnumerateInstanceExtensionProperties)                 /* (layer, uint32_t *count, VkExtensionProperties *) */
{
    static const char *offer[] = {"VK_KHR_surface", "VK_KHR_win32_surface", "VK_KHR_get_physical_device_properties2", "VK_KHR_get_surface_capabilities2", 0};
    if (ARG(0)) { rt_w32(G_MEM, ARG(1), 0); RET(VK_SUCCESS, 3); }
    host_instance_extensions();
    VkExtensionProperties list[8]; uint32_t n = 0;
    for (int k = 0; offer[k]; k++) if (!strcmp(offer[k], "VK_KHR_win32_surface") || host_has_inst_ext(offer[k])) {
        memset(&list[n], 0, sizeof list[n]); snprintf(list[n].extensionName, sizeof list[n].extensionName, "%s", offer[k]); list[n].specVersion = 1; n++;
    }
    uint32_t cap = rt_r32(G_MEM, ARG(1)), out = ARG(2);
    if (!out) { rt_w32(G_MEM, ARG(1), n); RET(VK_SUCCESS, 3); }
    uint32_t w = cap < n ? cap : n; memcpy(G_MEM + out, list, w * sizeof *list); rt_w32(G_MEM, ARG(1), w);
    RET(w < n ? VK_INCOMPLETE : VK_SUCCESS, 3);
}
IMPL(vulkan_1, vkEnumerateInstanceLayerProperties) { rt_w32(G_MEM, ARG(0), 0); RET(VK_SUCCESS, 2); }
static int portability;                                 /* MoltenVK: VK_KHR_portability_enumeration */
IMPL(vulkan_1, vkCreateInstance)                                        /* (create info, allocator, VkInstance *) */
{
    if (!load_host()) RET(VK_ERROR_INITIALIZATION_FAILED, 3);
    VkArena a = {0}; VkInstanceCreateInfo ci; cin_VkInstanceCreateInfo(&a, ARG(0), &ci);
    const char **ext = vk_arena(&a, sizeof *ext * (ci.enabledExtensionCount + 16)); uint32_t n = 0;
    for (uint32_t k = 0; k < ci.enabledExtensionCount; k++) {
        const char *e = ci.ppEnabledExtensionNames[k];
        if (!strcmp(e, "VK_KHR_win32_surface")) continue;                  /* replaced by the host's surface */
        if (!host_has_inst_ext(e)) { fprintf(stderr, "vulkan: instance extension %s not available: left out\n", e); continue; }
        if (!has_name(ext, n, e)) ext[n++] = e;
    }
    const char *hs[8]; unsigned nh = w32_host_vk_extensions ? w32_host_vk_extensions(hs, 8) : 0;
    for (unsigned k = 0; k < nh; k++) if (!has_name(ext, n, hs[k])) ext[n++] = hs[k];
    if (!has_name(ext, n, "VK_KHR_surface")) ext[n++] = "VK_KHR_surface";
    if (host_has_inst_ext("VK_KHR_portability_enumeration")) { ext[n++] = "VK_KHR_portability_enumeration"; ci.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR; portability = 1; }
    if (host_has_inst_ext("VK_KHR_get_physical_device_properties2") && !has_name(ext, n, "VK_KHR_get_physical_device_properties2")) ext[n++] = "VK_KHR_get_physical_device_properties2";
    ci.ppEnabledExtensionNames = ext; ci.enabledExtensionCount = n;
    ci.enabledLayerCount = 0; ci.ppEnabledLayerNames = 0;              /* layers: the host's own (VK_INSTANCE_LAYERS) */
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    if (ci.pApplicationInfo) app = *ci.pApplicationInfo;
    if (app.apiVersion < VK_API_VERSION_1_1) app.apiVersion = VK_API_VERSION_1_1;   /* properties2, map_memory2 */
    ci.pApplicationInfo = &app;
    if (vk_trace) for (uint32_t k = 0; k < n; k++) fprintf(stderr, "vulkan: instance extension %s\n", ext[k]);
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(0, "vkCreateInstance");
    VkInstance inst = 0; VkResult r = create(&ci, 0, &inst);
    vk_arena_free(&a);
    VK_TRACE("vkCreateInstance", r);
    if (r == VK_SUCCESS) { load_procs(inst); rt_w32(G_MEM, ARG(2), vkh_guest(inst)); }
    RET(r, 3);
}
IMPL(vulkan_1, vkDestroyInstance) { VkInstance i = vkh_host(ARG(0)); if (i) { vkp.vkDestroyInstance(i, 0); vkh_forget(i); } RET(0, 2); }
IMPL(vulkan_1, vkEnumeratePhysicalDevices)                              /* (instance, uint32_t *count, VkPhysicalDevice *) */
{
    VkInstance i = vkh_host(ARG(0)); uint32_t n = 0;
    VkResult r = vkp.vkEnumeratePhysicalDevices(i, &n, 0);
    if (r < 0) RET(r, 3);
    VkPhysicalDevice *pd = calloc(n + 1, sizeof *pd); r = vkp.vkEnumeratePhysicalDevices(i, &n, pd);
    uint32_t out = ARG(2);
    if (!out) rt_w32(G_MEM, ARG(1), n);
    else {
        uint32_t cap = rt_r32(G_MEM, ARG(1)), w = cap < n ? cap : n;
        for (uint32_t k = 0; k < w; k++) rt_w32(G_MEM, out + 4 * k, vkh_guest(pd[k]));
        rt_w32(G_MEM, ARG(1), w); if (w < n) r = VK_INCOMPLETE;
    }
    free(pd); VK_TRACE("vkEnumeratePhysicalDevices", r); RET(r, 3);
}
IMPL(vulkan_1, vkCreateWin32SurfaceKHR)                                 /* (instance, info, allocator, VkSurfaceKHR *) */
{
    VkInstance i = vkh_host(ARG(0)); VkSurfaceKHR s = 0;
    if (!w32_host_vk_surface || w32_host_vk_surface(i, &s)) { fprintf(stderr, "vulkan: no surface for the game window\n"); RET(VK_ERROR_INITIALIZATION_FAILED, 4); }
    rt_w64(G_MEM, ARG(3), (uint64_t)s); RET(VK_SUCCESS, 4);
}
IMPL(vulkan_1, vkCreateDebugUtilsMessengerEXT) { RET(VK_ERROR_EXTENSION_NOT_PRESENT, 4); }
IMPL(vulkan_1, vkDestroyDebugUtilsMessengerEXT) { RET(0, 4); }

/* ---- device ---- */
typedef struct DevInfo { VkDevice dev; VkPhysicalDevice pd; int placed; VkDeviceSize place_align; VkPhysicalDeviceMemoryProperties mem; } DevInfo;
static DevInfo devs[8]; static int ndevs;
static DevInfo *dev_info(VkDevice d) { for (int k = 0; k < ndevs; k++) if (devs[k].dev == d) return &devs[k]; return 0; }
IMPL(vulkan_1, vkEnumerateDeviceExtensionProperties)                   /* (pd, layer, uint32_t *count, VkExtensionProperties *) */
{
    VkPhysicalDevice pd = vkh_host(ARG(0));
    if (ARG(1)) { rt_w32(G_MEM, ARG(2), 0); RET(VK_SUCCESS, 4); }
    VkResult r = vkp.vkEnumerateDeviceExtensionProperties(pd, 0, VKPTR(ARG(2)), VKPTR(ARG(3)));
    VK_TRACE("vkEnumerateDeviceExtensionProperties", r); RET(r, 4);
}
IMPL(vulkan_1, vkEnumerateDeviceLayerProperties) { rt_w32(G_MEM, ARG(1), 0); RET(VK_SUCCESS, 3); }
static int dev_has_ext(VkPhysicalDevice pd, const char *name)
{
    uint32_t n = 0; vkp.vkEnumerateDeviceExtensionProperties(pd, 0, &n, 0);
    VkExtensionProperties *e = calloc(n + 1, sizeof *e); vkp.vkEnumerateDeviceExtensionProperties(pd, 0, &n, e);
    int found = 0; for (uint32_t k = 0; k < n; k++) if (!strcmp(e[k].extensionName, name)) found = 1;
    free(e); return found;
}
IMPL(vulkan_1, vkCreateDevice)                                          /* (pd, info, allocator, VkDevice *) */
{
    VkPhysicalDevice pd = vkh_host(ARG(0));
    VkArena a = {0}; VkDeviceCreateInfo ci; cin_VkDeviceCreateInfo(&a, ARG(1), &ci);
    const char **ext = vk_arena(&a, sizeof *ext * (ci.enabledExtensionCount + 8)); uint32_t n = 0;
    for (uint32_t k = 0; k < ci.enabledExtensionCount; k++) {
        const char *e = ci.ppEnabledExtensionNames[k];
        if (!dev_has_ext(pd, e)) { fprintf(stderr, "vulkan: device extension %s not available: left out\n", e); continue; }
        if (!has_name(ext, n, e)) ext[n++] = e;
    }
    if (portability && dev_has_ext(pd, "VK_KHR_portability_subset") && !has_name(ext, n, "VK_KHR_portability_subset")) ext[n++] = "VK_KHR_portability_subset";
    /* features the game asks for that this device lacks are switched off (logged) rather than failing */
    VkPhysicalDeviceFeatures have; vkp.vkGetPhysicalDeviceFeatures(pd, &have);
    VkPhysicalDeviceFeatures *want = (VkPhysicalDeviceFeatures *)ci.pEnabledFeatures, fix;
    if (want) {
        fix = *want; VkBool32 *w = (VkBool32 *)&fix; const VkBool32 *h = (const VkBool32 *)&have;
        for (unsigned k = 0; k < sizeof fix / sizeof *w; k++) if (w[k] && !h[k]) { fprintf(stderr, "vulkan: device feature %u not available: off\n", k); w[k] = 0; }
        ci.pEnabledFeatures = &fix;
    }
    /* mappings inside the guest's address space */
    int placed = !getenv("W32_VK_SHADOW") && dev_has_ext(pd, "VK_EXT_map_memory_placed") && dev_has_ext(pd, "VK_KHR_map_memory2") && vkp.vkGetPhysicalDeviceFeatures2;
    VkPhysicalDeviceMapMemoryPlacedFeaturesEXT pf = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAP_MEMORY_PLACED_FEATURES_EXT};
    if (placed) {
        VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &pf}; vkp.vkGetPhysicalDeviceFeatures2(pd, &f2);
        placed = pf.memoryMapPlaced && pf.memoryUnmapReserve;
    }
    if (placed) {
        if (!has_name(ext, n, "VK_KHR_map_memory2")) ext[n++] = "VK_KHR_map_memory2";
        ext[n++] = "VK_EXT_map_memory_placed";
        pf.pNext = (void *)ci.pNext; pf.memoryMapRangePlaced = VK_FALSE; ci.pNext = &pf;
    }
    ci.ppEnabledExtensionNames = ext; ci.enabledExtensionCount = n; ci.enabledLayerCount = 0; ci.ppEnabledLayerNames = 0;
    VkDevice d = 0; VkResult r = vkp.vkCreateDevice(pd, &ci, 0, &d);
    vk_arena_free(&a);
    VK_TRACE("vkCreateDevice", r);
    if (r == VK_SUCCESS && ndevs < 8) {
        DevInfo *di = &devs[ndevs++]; di->dev = d; di->pd = pd; di->placed = placed; di->place_align = 4096;
        vkp.vkGetPhysicalDeviceMemoryProperties(pd, &di->mem);
        if (placed) {
            VkPhysicalDeviceMapMemoryPlacedPropertiesEXT pp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAP_MEMORY_PLACED_PROPERTIES_EXT};
            VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &pp}; vkp.vkGetPhysicalDeviceProperties2(pd, &p2);
            if (pp.minPlacedMemoryMapAlignment) di->place_align = pp.minPlacedMemoryMapAlignment;
        }
        fprintf(stderr, "vulkan: device ready; mapped memory %s\n", placed ? "placed in guest memory" : "shadowed");
        rt_w32(G_MEM, ARG(3), vkh_guest(d));
    }
    RET(r, 4);
}
IMPL(vulkan_1, vkDestroyDevice) { VkDevice d = vkh_host(ARG(0)); if (d) { vkp.vkDestroyDevice(d, 0); vkh_forget(d); } RET(0, 2); }
IMPL(vulkan_1, vkGetDeviceQueue)                                        /* (device, family, index, VkQueue *) */
{
    VkQueue q = 0; vkp.vkGetDeviceQueue(vkh_host(ARG(0)), ARG(1), ARG(2), &q);
    rt_w32(G_MEM, ARG(3), vkh_guest(q)); RET(0, 4);
}
IMPL(vulkan_1, vkAllocateCommandBuffers)                                /* (device, info, VkCommandBuffer *) */
{
    VkArena a = {0}; VkCommandBufferAllocateInfo ai; cin_VkCommandBufferAllocateInfo(&a, ARG(1), &ai);
    VkCommandBuffer *cb = calloc(ai.commandBufferCount + 1, sizeof *cb);
    VkResult r = vkp.vkAllocateCommandBuffers(vkh_host(ARG(0)), &ai, cb);
    if (r == VK_SUCCESS) for (uint32_t k = 0; k < ai.commandBufferCount; k++) rt_w32(G_MEM, ARG(2) + 4 * k, vkh_guest(cb[k]));
    free(cb); vk_arena_free(&a); VK_TRACE("vkAllocateCommandBuffers", r); RET(r, 3);
}
IMPL(vulkan_1, vkFreeCommandBuffers)                                    /* (device, pool (2), count, const VkCommandBuffer *) */
{
    uint32_t n = ARG(3), p = ARG(4); VkCommandBuffer *cb = calloc(n + 1, sizeof *cb);
    for (uint32_t k = 0; k < n; k++) cb[k] = vkh_host(rt_r32(G_MEM, p + 4 * k));
    vkp.vkFreeCommandBuffers(vkh_host(ARG(0)), (VkCommandPool)((uint64_t)ARG(1) | (uint64_t)ARG(2) << 32), n, cb);
    for (uint32_t k = 0; k < n; k++) if (cb[k]) vkh_forget(cb[k]);
    free(cb); RET(0, 5);
}

/* ---- memory ---- */
typedef struct Mem { VkDeviceMemory m; VkDevice dev; VkDeviceSize size; uint32_t type; uint32_t guest, gsize; void *host; int placed; } Mem;
#define NMEM 16384
static Mem mems[NMEM]; static pthread_mutex_t mem_m = PTHREAD_MUTEX_INITIALIZER; static int nmapped_shadow;
static Mem *mem_find(VkDeviceMemory m) { for (int k = 0; k < NMEM; k++) if (mems[k].m == m) return &mems[k]; return 0; }
IMPL(vulkan_1, vkAllocateMemory)                                        /* (device, info, allocator, VkDeviceMemory *) */
{
    VkDevice d = vkh_host(ARG(0));
    VkArena a = {0}; VkMemoryAllocateInfo ai; cin_VkMemoryAllocateInfo(&a, ARG(1), &ai);
    static int checked;                                /* the guest layout, once: allocationSize at +8, type at +16 */
    if (!checked++ && vk_trace) fprintf(stderr, "vulkan: VkMemoryAllocateInfo size %llu type %u (guest dwords %08x %08x %08x %08x)\n",
        (unsigned long long)ai.allocationSize, ai.memoryTypeIndex, VKR32(ARG(1) + 8), VKR32(ARG(1) + 12), VKR32(ARG(1) + 16), VKR32(ARG(1) + 20));
    VkDeviceMemory m = 0; VkResult r = vkp.vkAllocateMemory(d, &ai, 0, &m);
    vk_arena_free(&a);
    if (r == VK_SUCCESS) {
        pthread_mutex_lock(&mem_m);
        Mem *e = mem_find(0); if (e) { memset(e, 0, sizeof *e); e->m = m; e->dev = d; e->size = ai.allocationSize; e->type = ai.memoryTypeIndex; }
        pthread_mutex_unlock(&mem_m);
        if (!e) fprintf(stderr, "vulkan: too many allocations to track\n");
        rt_w64(G_MEM, ARG(3), (uint64_t)m);
    }
    VK_TRACE("vkAllocateMemory", r); RET(r, 4);
}
static void unmap(Mem *e)                                              /* mem_m held */
{
    if (!e->guest) return;
    if (e->placed) {
        VkMemoryUnmapInfoKHR ui = {VK_STRUCTURE_TYPE_MEMORY_UNMAP_INFO_KHR, 0, VK_MEMORY_UNMAP_RESERVE_BIT_EXT, e->m};
        vkp.vkUnmapMemory2KHR(e->dev, &ui);
        mmap(G_MEM + e->guest, e->gsize, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);   /* ours again */
    } else {
        memcpy(e->host, G_MEM + e->guest, (size_t)e->size); vkp.vkUnmapMemory(e->dev, e->m); nmapped_shadow--;
    }
    vm_free(e->guest, 0, 0x8000);
    e->guest = 0; e->host = 0;
}
IMPL(vulkan_1, vkFreeMemory)                                            /* (device, memory (2), allocator) */
{
    VkDeviceMemory m = (VkDeviceMemory)((uint64_t)ARG(1) | (uint64_t)ARG(2) << 32);
    pthread_mutex_lock(&mem_m); Mem *e = m ? mem_find(m) : 0; if (e) { unmap(e); e->m = 0; } pthread_mutex_unlock(&mem_m);
    if (m) vkp.vkFreeMemory(vkh_host(ARG(0)), m, 0);
    RET(0, 4);
}
IMPL(vulkan_1, vkMapMemory)                                             /* (device, memory (2), offset (2), size (2), flags, void **) */
{
    VkDevice d = vkh_host(ARG(0)); DevInfo *di = dev_info(d);
    VkDeviceMemory m = (VkDeviceMemory)((uint64_t)ARG(1) | (uint64_t)ARG(2) << 32);
    VkDeviceSize off = (uint64_t)ARG(3) | (uint64_t)ARG(4) << 32;
    pthread_mutex_lock(&mem_m);
    Mem *e = mem_find(m); VkResult r = VK_SUCCESS;
    if (!e) { pthread_mutex_unlock(&mem_m); fprintf(stderr, "vulkan: vkMapMemory of unknown memory\n"); RET(VK_ERROR_MEMORY_MAP_FAILED, 9); }
    if (!e->guest) {
        VkDeviceSize al = di ? di->place_align : 4096; if (al < 65536) al = 65536;
        uint32_t gsize = (uint32_t)((e->size + al - 1) / al * al);
        uint32_t g = e->size < 0xc0000000ull ? vm_alloc(0, gsize, 0x3000, 4) : 0;
        if (!g) r = VK_ERROR_MEMORY_MAP_FAILED;
        else if (di && di->placed) {
            VkMemoryMapPlacedInfoEXT pi = {VK_STRUCTURE_TYPE_MEMORY_MAP_PLACED_INFO_EXT, 0, G_MEM + g};
            VkMemoryMapInfoKHR mi = {VK_STRUCTURE_TYPE_MEMORY_MAP_INFO_KHR, &pi, VK_MEMORY_MAP_PLACED_BIT_EXT, m, 0, VK_WHOLE_SIZE};
            void *p = 0; r = vkp.vkMapMemory2KHR(d, &mi, &p);
            if (r == VK_SUCCESS && p != G_MEM + g) { fprintf(stderr, "vulkan: placed mapping landed at %p, not %p\n", p, (void *)(G_MEM + g)); r = VK_ERROR_MEMORY_MAP_FAILED; }
            e->placed = 1;
        } else {
            void *p = 0; r = vkp.vkMapMemory(d, m, 0, VK_WHOLE_SIZE, 0, &p);
            if (r == VK_SUCCESS) { e->host = p; memcpy(G_MEM + g, p, (size_t)e->size); nmapped_shadow++; }
            e->placed = 0;
        }
        if (r == VK_SUCCESS) { e->guest = g; e->gsize = gsize; }
        else if (g) vm_free(g, 0, 0x8000);
    }
    if (r == VK_SUCCESS) rt_w32(G_MEM, ARG(8), e->guest + (uint32_t)off);
    pthread_mutex_unlock(&mem_m);
    VK_TRACE("vkMapMemory", r); RET(r, 9);
}
IMPL(vulkan_1, vkUnmapMemory)                                           /* (device, memory (2)) */
{
    VkDeviceMemory m = (VkDeviceMemory)((uint64_t)ARG(1) | (uint64_t)ARG(2) << 32);
    pthread_mutex_lock(&mem_m); Mem *e = mem_find(m); if (e) unmap(e); pthread_mutex_unlock(&mem_m);
    RET(0, 3);
}
/* shadowed mappings: guest -> device memory for every mapping (before submitting), or device -> guest for host-cached
 * ones (after the GPU is known to be done) */
static void shadow_out(void)
{
    if (!nmapped_shadow) return;
    pthread_mutex_lock(&mem_m);
    for (int k = 0; k < NMEM; k++) if (mems[k].guest && !mems[k].placed) memcpy(mems[k].host, G_MEM + mems[k].guest, (size_t)mems[k].size);
    pthread_mutex_unlock(&mem_m);
}
static void shadow_in(void)
{
    if (!nmapped_shadow) return;
    pthread_mutex_lock(&mem_m);
    for (int k = 0; k < NMEM; k++) {
        Mem *e = &mems[k]; if (!e->guest || e->placed) continue;
        DevInfo *di = dev_info(e->dev);
        if (di && (di->mem.memoryTypes[e->type].propertyFlags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT)) memcpy(G_MEM + e->guest, e->host, (size_t)e->size);
    }
    pthread_mutex_unlock(&mem_m);
}
static VkMappedMemoryRange *ranges(VkArena *a, uint32_t n, uint32_t g)
{
    VkMappedMemoryRange *v = vk_arena(a, sizeof *v * (n ? n : 1));
    for (uint32_t k = 0; k < n; k++) cin_VkMappedMemoryRange(a, g + VKG_VkMappedMemoryRange * k, &v[k]);
    return v;
}
IMPL(vulkan_1, vkFlushMappedMemoryRanges)                               /* (device, count, ranges) */
{
    VkArena a = {0}; VkMappedMemoryRange *v = ranges(&a, ARG(1), ARG(2));
    pthread_mutex_lock(&mem_m);
    for (uint32_t k = 0; k < ARG(1); k++) {
        Mem *e = mem_find(v[k].memory); if (!e || !e->guest || e->placed) continue;
        VkDeviceSize n = v[k].size == VK_WHOLE_SIZE ? e->size - v[k].offset : v[k].size;
        memcpy((uint8_t *)e->host + v[k].offset, G_MEM + e->guest + (uint32_t)v[k].offset, (size_t)n);
    }
    pthread_mutex_unlock(&mem_m);
    VkResult r = vkp.vkFlushMappedMemoryRanges(vkh_host(ARG(0)), ARG(1), v);
    vk_arena_free(&a); RET(r, 3);
}
IMPL(vulkan_1, vkInvalidateMappedMemoryRanges)
{
    VkArena a = {0}; VkMappedMemoryRange *v = ranges(&a, ARG(1), ARG(2));
    VkResult r = vkp.vkInvalidateMappedMemoryRanges(vkh_host(ARG(0)), ARG(1), v);
    pthread_mutex_lock(&mem_m);
    for (uint32_t k = 0; k < ARG(1); k++) {
        Mem *e = mem_find(v[k].memory); if (!e || !e->guest || e->placed) continue;
        VkDeviceSize n = v[k].size == VK_WHOLE_SIZE ? e->size - v[k].offset : v[k].size;
        memcpy(G_MEM + e->guest + (uint32_t)v[k].offset, (uint8_t *)e->host + v[k].offset, (size_t)n);
    }
    pthread_mutex_unlock(&mem_m);
    vk_arena_free(&a); RET(r, 3);
}

/* ---- queues and synchronisation ---- */
IMPL(vulkan_1, vkQueueSubmit)                                           /* (queue, count, submits, fence (2)) */
{
    shadow_out();
    VkArena a = {0}; uint32_t n = ARG(1), g = ARG(2);
    VkSubmitInfo *s = vk_arena(&a, sizeof *s * (n ? n : 1));
    for (uint32_t k = 0; k < n; k++) cin_VkSubmitInfo(&a, g + VKG_VkSubmitInfo * k, &s[k]);
    VkResult r = vkp.vkQueueSubmit(vkh_host(ARG(0)), n, s, (VkFence)((uint64_t)ARG(3) | (uint64_t)ARG(4) << 32));
    vk_arena_free(&a); VK_TRACE("vkQueueSubmit", r); RET(r, 5);
}
IMPL(vulkan_1, vkQueuePresentKHR)                                       /* (queue, present info) */
{
    VkArena a = {0}; VkPresentInfoKHR pi; cin_VkPresentInfoKHR(&a, ARG(1), &pi);
    VkResult r = vkp.vkQueuePresentKHR(vkh_host(ARG(0)), &pi);
    vk_arena_free(&a);
    if (r >= 0 && w32_host_vk_presented) w32_host_vk_presented();
    VK_TRACE("vkQueuePresentKHR", r); RET(r, 2);
}
IMPL(vulkan_1, vkWaitForFences)                                         /* (device, count, fences, waitAll, timeout (2)) */
{
    VkResult r = vkp.vkWaitForFences(vkh_host(ARG(0)), ARG(1), VKPTR(ARG(2)), ARG(3), (uint64_t)ARG(4) | (uint64_t)ARG(5) << 32);
    if (r == VK_SUCCESS) shadow_in();
    RET(r, 6);
}
IMPL(vulkan_1, vkGetFenceStatus)                                        /* (device, fence (2)) */
{
    VkResult r = vkp.vkGetFenceStatus(vkh_host(ARG(0)), (VkFence)((uint64_t)ARG(1) | (uint64_t)ARG(2) << 32));
    if (r == VK_SUCCESS) shadow_in();
    RET(r, 3);
}
IMPL(vulkan_1, vkQueueWaitIdle) { VkResult r = vkp.vkQueueWaitIdle(vkh_host(ARG(0))); if (r == VK_SUCCESS) shadow_in(); RET(r, 1); }
IMPL(vulkan_1, vkDeviceWaitIdle) { VkResult r = vkp.vkDeviceWaitIdle(vkh_host(ARG(0))); if (r == VK_SUCCESS) shadow_in(); RET(r, 1); }

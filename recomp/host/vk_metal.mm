// vk_metal.mm: the part of Vulkan The Sims Legacy Collection uses, implemented directly on Metal (no MoltenVK).
//
// runtime/win32/vulkan.c and vulkan_gen.c convert the 32-bit game's calls into ordinary 64-bit Vulkan calls; the host
// hands them this file's vkGetInstanceProcAddr (host/sims_mac.m) instead of a Vulkan driver's. What the game does was
// measured on Linux (a capture of a whole session: docs/SIMS-PORT.md, "What the game asks of Vulkan"): 2 render
// passes (load-op LOAD, cleared beforehand with vkCmdClear*Image), 30 graphics pipelines, 33 SPIR-V shaders, one
// combined image sampler per descriptor set, 64/80-byte push constants, about 7 submissions a frame chained by
// semaphores, no compute, subpasses, secondary command buffers or vkCmdClearAttachments, one unscaled blit.
//
// How it maps:
//  - Memory: one unified heap. Host-visible allocations are imported from the game's own pages (the runtime makes them
//    in guest memory: VK_EXT_external_memory_host) as shared MTLBuffers with no copy, so the game's writes are the
//    GPU's data, coherent, as it assumes. Images are MTLTextures of their own (memory binding is only bookkeeping).
//  - Command buffers are recorded into lists and encoded into MTLCommandBuffers at vkQueueSubmit, in order on one
//    MTLCommandQueue: semaphores and pipeline barriers need nothing more (Metal tracks the hazards), fences are
//    signalled when the last command buffer of a submission completes.
//  - Shaders: SPIR-V is translated to Metal Shading Language with SPIRV-Cross (third_party/spirv-cross) when a pipeline
//    is made, and compiled by Metal; nothing translated is stored. Resources: descriptor set s binding b is texture and
//    sampler s*4+b, push constants are buffer 30, vertex buffer bindings are buffers 0...
//  - The swapchain's images are textures the game renders into; vkQueuePresentKHR copies the image to the layer's
//    drawable and presents it.
// Commands the game never calls aren't here (VKM_LOG=1 logs those asked for, and every object made).
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <condition_variable>
#include <algorithm>
#include "spirv_msl.hpp"

static int vlog = -1;
#define LOG(...) do { if (vlog < 0) vlog = getenv("VKM_LOG") != 0; if (vlog) fprintf(stderr, "vkm: " __VA_ARGS__); } while (0)
static void once(const char *what)
{
    static std::mutex m; static std::vector<std::string> seen; std::lock_guard<std::mutex> g(m);
    for (auto &s : seen) if (s == what) return;
    seen.push_back(what); fprintf(stderr, "vkm: %s\n", what);
}

// ---------------------------------------------------------------- objects
struct VkInstance_T { int dummy; };
struct VkPhysicalDevice_T { id<MTLDevice> dev; };
struct VkQueue_T { struct VkDevice_T *d; };
struct VkDevice_T { id<MTLDevice> dev; id<MTLCommandQueue> q; VkQueue_T queue; id<MTLCommandBuffer> last; std::mutex m; };
struct VkSurfaceKHR_T { CAMetalLayer *layer; };
struct VkDeviceMemory_T { VkDeviceSize size; uint32_t type; id<MTLBuffer> buf; };
struct VkBuffer_T { VkDeviceSize size; VkBufferUsageFlags usage; VkDeviceMemory_T *mem; VkDeviceSize off; };
struct VkImage_T { VkImageCreateInfo ci; id<MTLTexture> tex; int swap; };
struct VkImageView_T { VkImage_T *img; id<MTLTexture> tex; };
struct VkSampler_T { id<MTLSamplerState> s; };
struct VkShaderModule_T { std::vector<uint32_t> spv; id<MTLLibrary> lib[2]; std::string entry[2]; };
struct VkDescriptorSetLayout_T { uint32_t nbind; };
struct VkDescriptorPool_T { int dummy; };
struct VkDescriptorSet_T { VkImageView_T *view[4]; VkSampler_T *smp[4]; };
struct VkPipelineLayout_T { uint32_t push; uint32_t nsets; };
struct VkRenderPass_T { uint32_t n; VkAttachmentDescription a[4]; int color, depth; };
struct VkFramebuffer_T { uint32_t n; VkImageView_T *a[4]; uint32_t w, h; };
struct VkPipeline_T { id<MTLRenderPipelineState> rps; id<MTLDepthStencilState> dss; MTLPrimitiveType prim; MTLCullMode cull; MTLWinding wind;
                      MTLTriangleFillMode fill; int bias; float bconst, bslope, bclamp; VkPipelineLayout_T *layout; };
struct VkFence_T { std::mutex m; std::condition_variable cv; bool signaled; };
struct VkSemaphore_T { int dummy; };
struct VkCommandPool_T { int dummy; };
struct VkSwapchainKHR_T { VkSurfaceKHR_T *surf; std::vector<VkImage_T *> img; VkExtent2D ext; uint32_t next; };

// a recorded command
enum Op { BEGIN_RP, END_RP, BIND_PIPE, BIND_VB, BIND_IB, BIND_SETS, PUSH, DRAW, DRAW_IDX, VIEWPORT, SCISSOR, CLEAR_COLOR, CLEAR_DEPTH,
          COPY_BUF, COPY_B2I, COPY_I2B, BLIT };
struct Cmd {
    Op op; uint32_t a[8]; uint64_t q[4]; void *p[4]; float f[6];
    VkClearValue clear[4]; std::vector<uint8_t> bytes; std::vector<VkBufferImageCopy> regions; std::vector<VkBufferCopy> bregions; std::vector<VkImageBlit> blits;
};
struct VkCommandBuffer_T { VkDevice_T *d; std::vector<Cmd> cmds; };

template <typename T> static T *H(uint64_t h) { return (T *)(uintptr_t)h; }

// ---------------------------------------------------------------- formats
static MTLPixelFormat pixfmt(VkFormat f)
{
    switch (f) {
    case VK_FORMAT_B8G8R8A8_UNORM: return MTLPixelFormatBGRA8Unorm;
    case VK_FORMAT_B8G8R8A8_SRGB: return MTLPixelFormatBGRA8Unorm_sRGB;
    case VK_FORMAT_R8G8B8A8_UNORM: return MTLPixelFormatRGBA8Unorm;
    case VK_FORMAT_R8G8B8A8_SRGB: return MTLPixelFormatRGBA8Unorm_sRGB;
    case VK_FORMAT_R8_UNORM: return MTLPixelFormatR8Unorm;
    case VK_FORMAT_R8_UINT: return MTLPixelFormatR8Uint;
    case VK_FORMAT_R8G8_UNORM: return MTLPixelFormatRG8Unorm;
    case VK_FORMAT_R16_UNORM: return MTLPixelFormatR16Unorm;
    case VK_FORMAT_R16_SFLOAT: return MTLPixelFormatR16Float;
    case VK_FORMAT_R16G16B16A16_SFLOAT: return MTLPixelFormatRGBA16Float;
    case VK_FORMAT_R32_SFLOAT: return MTLPixelFormatR32Float;
    case VK_FORMAT_R32_UINT: return MTLPixelFormatR32Uint;
    case VK_FORMAT_R32G32B32A32_SFLOAT: return MTLPixelFormatRGBA32Float;
    case VK_FORMAT_A2B10G10R10_UNORM_PACK32: return MTLPixelFormatRGB10A2Unorm;
    case VK_FORMAT_R5G6B5_UNORM_PACK16: return MTLPixelFormatB5G6R5Unorm;
    case VK_FORMAT_D32_SFLOAT: return MTLPixelFormatDepth32Float;
    case VK_FORMAT_D32_SFLOAT_S8_UINT: return MTLPixelFormatDepth32Float_Stencil8;
    case VK_FORMAT_D16_UNORM: return MTLPixelFormatDepth16Unorm;
    case VK_FORMAT_BC1_RGBA_UNORM_BLOCK: return MTLPixelFormatBC1_RGBA;
    case VK_FORMAT_BC2_UNORM_BLOCK: return MTLPixelFormatBC2_RGBA;
    case VK_FORMAT_BC3_UNORM_BLOCK: return MTLPixelFormatBC3_RGBA;
    default: return MTLPixelFormatInvalid;
    }
}
static uint32_t texel_bytes(VkFormat f)          /* bytes per texel (per 4x4 block for BCn) */
{
    switch (f) {
    case VK_FORMAT_R8_UNORM: case VK_FORMAT_R8_UINT: return 1;
    case VK_FORMAT_R8G8_UNORM: case VK_FORMAT_R16_UNORM: case VK_FORMAT_R16_SFLOAT: case VK_FORMAT_D16_UNORM: case VK_FORMAT_R5G6B5_UNORM_PACK16: return 2;
    case VK_FORMAT_R16G16B16A16_SFLOAT: case VK_FORMAT_D32_SFLOAT_S8_UINT: case VK_FORMAT_BC1_RGBA_UNORM_BLOCK: return 8;
    case VK_FORMAT_R32G32B32A32_SFLOAT: case VK_FORMAT_BC2_UNORM_BLOCK: case VK_FORMAT_BC3_UNORM_BLOCK: return 16;
    default: return 4;
    }
}
static int is_bc(VkFormat f) { return f >= VK_FORMAT_BC1_RGB_UNORM_BLOCK && f <= VK_FORMAT_BC7_SRGB_BLOCK; }
static int is_depth(VkFormat f) { return f == VK_FORMAT_D32_SFLOAT || f == VK_FORMAT_D32_SFLOAT_S8_UINT || f == VK_FORMAT_D16_UNORM; }
static MTLVertexFormat vtxfmt(VkFormat f)
{
    switch (f) {
    case VK_FORMAT_R32_SFLOAT: return MTLVertexFormatFloat;
    case VK_FORMAT_R32G32_SFLOAT: return MTLVertexFormatFloat2;
    case VK_FORMAT_R32G32B32_SFLOAT: return MTLVertexFormatFloat3;
    case VK_FORMAT_R32G32B32A32_SFLOAT: return MTLVertexFormatFloat4;
    case VK_FORMAT_R8G8B8A8_UNORM: return MTLVertexFormatUChar4Normalized;
    case VK_FORMAT_B8G8R8A8_UNORM: return MTLVertexFormatUChar4Normalized_BGRA;
    case VK_FORMAT_R8G8B8A8_UINT: return MTLVertexFormatUChar4;
    case VK_FORMAT_R16G16_UINT: return MTLVertexFormatUShort2;
    case VK_FORMAT_R16G16_SINT: return MTLVertexFormatShort2;
    case VK_FORMAT_R16G16_SFLOAT: return MTLVertexFormatHalf2;
    case VK_FORMAT_R16G16B16A16_SFLOAT: return MTLVertexFormatHalf4;
    case VK_FORMAT_R32_UINT: return MTLVertexFormatUInt;
    case VK_FORMAT_R32G32_UINT: return MTLVertexFormatUInt2;
    case VK_FORMAT_R32_SINT: return MTLVertexFormatInt;
    default: { char w[96]; snprintf(w, sizeof w, "vertex format %d not mapped", f); once(w); return MTLVertexFormatFloat4; }
    }
}

// ---------------------------------------------------------------- instance, physical device, surface
static VkInstance_T the_instance; static VkPhysicalDevice_T the_pd;
static VkResult enum_ext(const char *const *names, uint32_t n, uint32_t *count, VkExtensionProperties *p)
{
    if (!p) { *count = n; return VK_SUCCESS; }
    uint32_t w = *count < n ? *count : n;
    for (uint32_t k = 0; k < w; k++) { memset(&p[k], 0, sizeof p[k]); snprintf(p[k].extensionName, sizeof p[k].extensionName, "%s", names[k]); p[k].specVersion = 1; }
    *count = w; return w < n ? VK_INCOMPLETE : VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_EnumerateInstanceExtensionProperties(const char *layer, uint32_t *count, VkExtensionProperties *p)
{
    static const char *n[] = {"VK_KHR_surface", "VK_EXT_metal_surface", "VK_KHR_get_physical_device_properties2"};
    if (layer) { *count = 0; return VK_SUCCESS; }
    return enum_ext(n, 3, count, p);
}
static VkResult VKAPI_CALL vkm_EnumerateInstanceLayerProperties(uint32_t *count, VkLayerProperties *) { *count = 0; return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_CreateInstance(const VkInstanceCreateInfo *, const VkAllocationCallbacks *, VkInstance *i)
{
    if (!the_pd.dev) the_pd.dev = MTLCreateSystemDefaultDevice();
    if (!the_pd.dev) { fprintf(stderr, "vkm: no Metal device\n"); return VK_ERROR_INITIALIZATION_FAILED; }
    fprintf(stderr, "vkm: Vulkan on Metal (%s)\n", the_pd.dev.name.UTF8String);
    *i = &the_instance; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyInstance(VkInstance, const VkAllocationCallbacks *) {}
static VkResult VKAPI_CALL vkm_EnumeratePhysicalDevices(VkInstance, uint32_t *count, VkPhysicalDevice *p)
{
    if (!p) { *count = 1; return VK_SUCCESS; }
    if (*count < 1) return VK_INCOMPLETE;
    *p = &the_pd; *count = 1; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_GetPhysicalDeviceProperties(VkPhysicalDevice pd, VkPhysicalDeviceProperties *p)
{
    memset(p, 0, sizeof *p);
    p->apiVersion = VK_API_VERSION_1_1; p->driverVersion = 1; p->vendorID = 0x106b; p->deviceID = 1; p->deviceType = VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU;
    snprintf(p->deviceName, sizeof p->deviceName, "%s (Metal)", pd->dev.name.UTF8String);
    VkPhysicalDeviceLimits &l = p->limits;
    l.maxImageDimension1D = l.maxImageDimension2D = 16384; l.maxImageDimension3D = 2048; l.maxImageDimensionCube = 16384; l.maxImageArrayLayers = 2048;
    l.maxTexelBufferElements = 1 << 26; l.maxUniformBufferRange = 1 << 16; l.maxStorageBufferRange = 1u << 30; l.maxPushConstantsSize = 128;
    l.maxMemoryAllocationCount = 1 << 20; l.maxSamplerAllocationCount = 4000; l.bufferImageGranularity = 1; l.sparseAddressSpaceSize = 0;
    l.maxBoundDescriptorSets = 4; l.maxPerStageDescriptorSamplers = 16; l.maxPerStageDescriptorUniformBuffers = 12; l.maxPerStageDescriptorStorageBuffers = 12;
    l.maxPerStageDescriptorSampledImages = 16; l.maxPerStageDescriptorStorageImages = 8; l.maxPerStageResources = 64;
    l.maxDescriptorSetSamplers = 64; l.maxDescriptorSetUniformBuffers = 64; l.maxDescriptorSetUniformBuffersDynamic = 16; l.maxDescriptorSetStorageBuffers = 64;
    l.maxDescriptorSetStorageBuffersDynamic = 16; l.maxDescriptorSetSampledImages = 64; l.maxDescriptorSetStorageImages = 32; l.maxDescriptorSetInputAttachments = 8;
    l.maxVertexInputAttributes = 31; l.maxVertexInputBindings = 28; l.maxVertexInputAttributeOffset = 2047; l.maxVertexInputBindingStride = 2048;
    l.maxVertexOutputComponents = 124; l.maxFragmentInputComponents = 124; l.maxFragmentOutputAttachments = 8; l.maxFragmentCombinedOutputResources = 16;
    l.maxComputeSharedMemorySize = 32768; l.maxComputeWorkGroupCount[0] = l.maxComputeWorkGroupCount[1] = l.maxComputeWorkGroupCount[2] = 65535;
    l.maxComputeWorkGroupInvocations = 1024; l.maxComputeWorkGroupSize[0] = l.maxComputeWorkGroupSize[1] = 1024; l.maxComputeWorkGroupSize[2] = 64;
    l.subPixelPrecisionBits = 4; l.subTexelPrecisionBits = 4; l.mipmapPrecisionBits = 4; l.maxDrawIndexedIndexValue = 0xffffffffu; l.maxDrawIndirectCount = 1;
    l.maxSamplerLodBias = 16; l.maxSamplerAnisotropy = 16; l.maxViewports = 1; l.maxViewportDimensions[0] = l.maxViewportDimensions[1] = 16384;
    l.viewportBoundsRange[0] = -32768; l.viewportBoundsRange[1] = 32767; l.viewportSubPixelBits = 0; l.minMemoryMapAlignment = 64;
    l.minTexelBufferOffsetAlignment = 16; l.minUniformBufferOffsetAlignment = 256; l.minStorageBufferOffsetAlignment = 16;
    l.minTexelOffset = -8; l.maxTexelOffset = 7; l.minTexelGatherOffset = -8; l.maxTexelGatherOffset = 7; l.minInterpolationOffset = -0.5f; l.maxInterpolationOffset = 0.5f;
    l.subPixelInterpolationOffsetBits = 4; l.maxFramebufferWidth = l.maxFramebufferHeight = 16384; l.maxFramebufferLayers = 2048;
    l.framebufferColorSampleCounts = l.framebufferDepthSampleCounts = l.framebufferStencilSampleCounts = l.framebufferNoAttachmentsSampleCounts = VK_SAMPLE_COUNT_1_BIT | VK_SAMPLE_COUNT_4_BIT;
    l.maxColorAttachments = 8; l.sampledImageColorSampleCounts = l.sampledImageIntegerSampleCounts = l.sampledImageDepthSampleCounts = l.sampledImageStencilSampleCounts = VK_SAMPLE_COUNT_1_BIT | VK_SAMPLE_COUNT_4_BIT;
    l.storageImageSampleCounts = VK_SAMPLE_COUNT_1_BIT; l.maxSampleMaskWords = 1; l.timestampComputeAndGraphics = VK_FALSE; l.timestampPeriod = 1;
    l.maxClipDistances = 8; l.maxCullDistances = 0; l.maxCombinedClipAndCullDistances = 8; l.discreteQueuePriorities = 2;
    l.pointSizeRange[0] = 1; l.pointSizeRange[1] = 64; l.lineWidthRange[0] = l.lineWidthRange[1] = 1; l.pointSizeGranularity = 1; l.lineWidthGranularity = 0;
    l.strictLines = VK_FALSE; l.standardSampleLocations = VK_TRUE; l.optimalBufferCopyOffsetAlignment = 16; l.optimalBufferCopyRowPitchAlignment = 16; l.nonCoherentAtomSize = 64;
}
static void props2_chain(void *next)
{
    for (VkBaseOutStructure *s = (VkBaseOutStructure *)next; s; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT) ((VkPhysicalDeviceExternalMemoryHostPropertiesEXT *)s)->minImportedHostPointerAlignment = 16384;
}
static void VKAPI_CALL vkm_GetPhysicalDeviceProperties2(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) { vkm_GetPhysicalDeviceProperties(pd, &p->properties); props2_chain(p->pNext); }
static void VKAPI_CALL vkm_GetPhysicalDeviceFeatures(VkPhysicalDevice, VkPhysicalDeviceFeatures *f)
{
    memset(f, 0, sizeof *f);
    f->fullDrawIndexUint32 = f->imageCubeArray = f->independentBlend = f->sampleRateShading = f->dualSrcBlend = f->logicOp = VK_FALSE;
    f->fullDrawIndexUint32 = VK_TRUE; f->imageCubeArray = VK_TRUE; f->independentBlend = VK_TRUE; f->depthClamp = VK_TRUE; f->depthBiasClamp = VK_TRUE;
    f->fillModeNonSolid = VK_TRUE; f->samplerAnisotropy = VK_TRUE; f->textureCompressionBC = VK_TRUE; f->occlusionQueryPrecise = VK_TRUE;
    f->fragmentStoresAndAtomics = VK_TRUE; f->shaderClipDistance = VK_TRUE; f->drawIndirectFirstInstance = VK_TRUE;
}
static void VKAPI_CALL vkm_GetPhysicalDeviceFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) { vkm_GetPhysicalDeviceFeatures(pd, &f->features); }
static void VKAPI_CALL vkm_GetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice, uint32_t *count, VkQueueFamilyProperties *p)
{
    if (!p) { *count = 1; return; }
    if (*count < 1) return;
    memset(p, 0, sizeof *p); p->queueFlags = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT; p->queueCount = 1;
    p->timestampValidBits = 0; p->minImageTransferGranularity = {1, 1, 1}; *count = 1;
}
/* one heap; device-local (images), host-visible coherent (imported guest pages), and cached and device-local variants of it */
static void VKAPI_CALL vkm_GetPhysicalDeviceMemoryProperties(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *m)
{
    memset(m, 0, sizeof *m);
    m->memoryHeapCount = 1; m->memoryHeaps[0].size = pd->dev.recommendedMaxWorkingSetSize ? pd->dev.recommendedMaxWorkingSetSize : (8ull << 30);
    m->memoryHeaps[0].flags = VK_MEMORY_HEAP_DEVICE_LOCAL_BIT;
    m->memoryTypeCount = 4;
    m->memoryTypes[0].propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    m->memoryTypes[1].propertyFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    m->memoryTypes[2].propertyFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    m->memoryTypes[3].propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
}
static void VKAPI_CALL vkm_GetPhysicalDeviceMemoryProperties2(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties2 *m) { vkm_GetPhysicalDeviceMemoryProperties(pd, &m->memoryProperties); }
static void VKAPI_CALL vkm_GetPhysicalDeviceFormatProperties(VkPhysicalDevice, VkFormat f, VkFormatProperties *p)
{
    memset(p, 0, sizeof *p);
    MTLPixelFormat m = pixfmt(f);
    if (m != MTLPixelFormatInvalid) {
        VkFormatFeatureFlags t = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_BLIT_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
        if (is_depth(f)) t |= VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
        else if (f == VK_FORMAT_R8_UINT || f == VK_FORMAT_R32_UINT) t |= VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT;   /* integer: no filtering or blending */
        else if (!is_bc(f)) t |= VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
        else t |= VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
        p->optimalTilingFeatures = t; p->linearTilingFeatures = is_depth(f) || is_bc(f) ? 0 : t;
    }
    switch (f) {   /* vertex formats */
    case VK_FORMAT_R32_SFLOAT: case VK_FORMAT_R32G32_SFLOAT: case VK_FORMAT_R32G32B32_SFLOAT: case VK_FORMAT_R32G32B32A32_SFLOAT: case VK_FORMAT_R8G8B8A8_UNORM:
    case VK_FORMAT_B8G8R8A8_UNORM: case VK_FORMAT_R8G8B8A8_UINT: case VK_FORMAT_R16G16_UINT: case VK_FORMAT_R16G16_SINT: case VK_FORMAT_R16G16_SFLOAT:
    case VK_FORMAT_R16G16B16A16_SFLOAT: case VK_FORMAT_R32_UINT: case VK_FORMAT_R32G32_UINT: case VK_FORMAT_R32_SINT:
        p->bufferFeatures = VK_FORMAT_FEATURE_VERTEX_BUFFER_BIT; break;
    default: break;
    }
}
static VkResult VKAPI_CALL vkm_CreateMetalSurfaceEXT(VkInstance, const VkMetalSurfaceCreateInfoEXT *ci, const VkAllocationCallbacks *, VkSurfaceKHR *s)
{
    VkSurfaceKHR_T *o = new VkSurfaceKHR_T(); o->layer = (CAMetalLayer *)ci->pLayer; *s = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroySurfaceKHR(VkInstance, VkSurfaceKHR s, const VkAllocationCallbacks *) { delete s; }
static VkResult VKAPI_CALL vkm_GetPhysicalDeviceSurfaceSupportKHR(VkPhysicalDevice, uint32_t, VkSurfaceKHR, VkBool32 *ok) { *ok = VK_TRUE; return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_GetPhysicalDeviceSurfaceCapabilitiesKHR(VkPhysicalDevice, VkSurfaceKHR s, VkSurfaceCapabilitiesKHR *c)
{
    memset(c, 0, sizeof *c);
    CGSize sz = s->layer.drawableSize;                 /* a CAMetalLayer may be used from the game's thread */
    c->minImageCount = 2; c->maxImageCount = 3; c->currentExtent = {(uint32_t)sz.width, (uint32_t)sz.height};
    c->minImageExtent = {1, 1}; c->maxImageExtent = {16384, 16384}; c->maxImageArrayLayers = 1;
    c->supportedTransforms = c->currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR; c->supportedCompositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    c->supportedUsageFlags = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_GetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice, VkSurfaceKHR, uint32_t *count, VkSurfaceFormatKHR *p)
{
    if (!p) { *count = 1; return VK_SUCCESS; }
    if (*count < 1) return VK_INCOMPLETE;
    p[0] = {VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR}; *count = 1; return VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_GetPhysicalDeviceSurfacePresentModesKHR(VkPhysicalDevice, VkSurfaceKHR, uint32_t *count, VkPresentModeKHR *p)
{
    static const VkPresentModeKHR m[] = {VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_IMMEDIATE_KHR};
    if (!p) { *count = 2; return VK_SUCCESS; }
    uint32_t w = *count < 2 ? *count : 2; memcpy(p, m, w * sizeof *m); *count = w; return w < 2 ? VK_INCOMPLETE : VK_SUCCESS;
}

// ---------------------------------------------------------------- device and queue
static VkResult VKAPI_CALL vkm_EnumerateDeviceExtensionProperties(VkPhysicalDevice, const char *layer, uint32_t *count, VkExtensionProperties *p)
{
    static const char *n[] = {"VK_KHR_swapchain", "VK_KHR_external_memory", "VK_EXT_external_memory_host"};
    if (layer) { *count = 0; return VK_SUCCESS; }
    return enum_ext(n, 3, count, p);
}
static VkResult VKAPI_CALL vkm_EnumerateDeviceLayerProperties(VkPhysicalDevice, uint32_t *count, VkLayerProperties *) { *count = 0; return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *, const VkAllocationCallbacks *, VkDevice *d)
{
    VkDevice_T *o = new VkDevice_T(); o->dev = pd->dev; o->q = [pd->dev newCommandQueueWithMaxCommandBufferCount:256]; o->queue.d = o;
    *d = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyDevice(VkDevice, const VkAllocationCallbacks *) {}
static void VKAPI_CALL vkm_GetDeviceQueue(VkDevice d, uint32_t, uint32_t, VkQueue *q) { *q = &d->queue; }
static VkResult wait_idle(VkDevice d)
{
    id<MTLCommandBuffer> cb; { std::lock_guard<std::mutex> g(d->m); cb = d->last; }
    if (cb) [cb waitUntilCompleted];
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_DeviceWaitIdle(VkDevice d) { return wait_idle(d); }
static VkResult VKAPI_CALL vkm_QueueWaitIdle(VkQueue q) { return wait_idle(q->d); }

// ---------------------------------------------------------------- memory, buffers, images
static VkResult VKAPI_CALL vkm_GetMemoryHostPointerPropertiesEXT(VkDevice, VkExternalMemoryHandleTypeFlagBits, const void *, VkMemoryHostPointerPropertiesEXT *p)
{
    p->memoryTypeBits = (1u << 1) | (1u << 2) | (1u << 3); return VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_AllocateMemory(VkDevice d, const VkMemoryAllocateInfo *ai, const VkAllocationCallbacks *, VkDeviceMemory *m)
{
    VkDeviceMemory_T *o = new VkDeviceMemory_T(); o->size = ai->allocationSize; o->type = ai->memoryTypeIndex;
    const VkImportMemoryHostPointerInfoEXT *imp = 0;
    for (const VkBaseInStructure *s = (const VkBaseInStructure *)ai->pNext; s; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT) imp = (const VkImportMemoryHostPointerInfoEXT *)s;
    if (imp && imp->pHostPointer) {
        o->buf = [d->dev newBufferWithBytesNoCopy:imp->pHostPointer length:(NSUInteger)ai->allocationSize options:MTLResourceStorageModeShared deallocator:nil];
        if (!o->buf) { fprintf(stderr, "vkm: can't import %llu bytes at %p\n", (unsigned long long)ai->allocationSize, imp->pHostPointer); delete o; return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
    } else if (ai->memoryTypeIndex != 0) {
        o->buf = [d->dev newBufferWithLength:(NSUInteger)ai->allocationSize options:MTLResourceStorageModeShared];
        if (!o->buf) { delete o; return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
    }
    LOG("memory %p: %llu bytes, type %u%s\n", (void *)o, (unsigned long long)o->size, o->type, imp ? ", imported" : "");
    *m = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_FreeMemory(VkDevice, VkDeviceMemory m, const VkAllocationCallbacks *) { delete m; }
static VkResult VKAPI_CALL vkm_MapMemory(VkDevice, VkDeviceMemory m, VkDeviceSize off, VkDeviceSize, VkMemoryMapFlags, void **p)
{
    if (!m || !m->buf) { once("vkMapMemory of device-local memory"); return VK_ERROR_MEMORY_MAP_FAILED; }
    *p = (uint8_t *)m->buf.contents + off; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_UnmapMemory(VkDevice, VkDeviceMemory) {}
static VkResult VKAPI_CALL vkm_FlushMappedMemoryRanges(VkDevice, uint32_t, const VkMappedMemoryRange *) { return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_CreateBuffer(VkDevice, const VkBufferCreateInfo *ci, const VkAllocationCallbacks *, VkBuffer *b)
{
    VkBuffer_T *o = new VkBuffer_T(); o->size = ci->size; o->usage = ci->usage; *b = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyBuffer(VkDevice, VkBuffer b, const VkAllocationCallbacks *) { delete b; }
static void VKAPI_CALL vkm_GetBufferMemoryRequirements(VkDevice, VkBuffer b, VkMemoryRequirements *r)
{
    r->size = (b->size + 255) & ~255ull; r->alignment = 256; r->memoryTypeBits = 0xf;
}
static VkResult VKAPI_CALL vkm_BindBufferMemory(VkDevice d, VkBuffer b, VkDeviceMemory m, VkDeviceSize off)
{
    if (m && !m->buf) m->buf = [d->dev newBufferWithLength:(NSUInteger)m->size options:MTLResourceStorageModeShared];   /* a buffer in device-local memory */
    b->mem = m; b->off = off; return VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_CreateImage(VkDevice d, const VkImageCreateInfo *ci, const VkAllocationCallbacks *, VkImage *im)
{
    MTLPixelFormat pf = pixfmt(ci->format);
    if (pf == MTLPixelFormatInvalid) { char w[96]; snprintf(w, sizeof w, "image format %d not supported", ci->format); once(w); return VK_ERROR_FORMAT_NOT_SUPPORTED; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = ci->imageType == VK_IMAGE_TYPE_3D ? MTLTextureType3D : (ci->arrayLayers > 1 ? MTLTextureType2DArray : MTLTextureType2D);
    if ((ci->flags & VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT) && ci->arrayLayers == 6) td.textureType = MTLTextureTypeCube;
    if ((ci->usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) && ci->extent.width >= 640) LOG("render target %ux%u (format %d)\n", ci->extent.width, ci->extent.height, ci->format);
    td.pixelFormat = pf; td.width = ci->extent.width; td.height = ci->extent.height; td.depth = ci->imageType == VK_IMAGE_TYPE_3D ? ci->extent.depth : 1;
    td.mipmapLevelCount = ci->mipLevels; td.arrayLength = td.textureType == MTLTextureTypeCube ? 1 : (ci->imageType == VK_IMAGE_TYPE_3D ? 1 : ci->arrayLayers);
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    if (!is_bc(ci->format)) td.usage |= MTLTextureUsageRenderTarget;          /* also for vkCmdClear*Image */
    VkImage_T *o = new VkImage_T(); o->ci = *ci; o->ci.pNext = 0; o->ci.pQueueFamilyIndices = 0;
    o->tex = [d->dev newTextureWithDescriptor:td];
    if (!o->tex) { delete o; return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
    LOG("image %p: %ux%u format %d mips %u layers %u usage %#x\n", (void *)o, ci->extent.width, ci->extent.height, ci->format, ci->mipLevels, ci->arrayLayers, ci->usage);
    *im = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyImage(VkDevice, VkImage im, const VkAllocationCallbacks *) { if (im && !im->swap) delete im; }
static void VKAPI_CALL vkm_GetImageMemoryRequirements(VkDevice, VkImage im, VkMemoryRequirements *r)
{
    VkDeviceSize n = 0; uint32_t w = im->ci.extent.width, h = im->ci.extent.height, dd = im->ci.extent.depth ? im->ci.extent.depth : 1;
    for (uint32_t k = 0; k < im->ci.mipLevels; k++) {
        uint32_t mw = w > 1 ? w : 1, mh = h > 1 ? h : 1;
        n += is_bc(im->ci.format) ? (VkDeviceSize)((mw + 3) / 4) * ((mh + 3) / 4) * texel_bytes(im->ci.format) : (VkDeviceSize)mw * mh * texel_bytes(im->ci.format);
        w /= 2; h /= 2;
    }
    r->size = ((n * im->ci.arrayLayers * dd) + 4095) & ~4095ull; r->alignment = 4096; r->memoryTypeBits = (1u << 0) | (1u << 3);
}
static VkResult VKAPI_CALL vkm_BindImageMemory(VkDevice, VkImage, VkDeviceMemory, VkDeviceSize) { return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_CreateImageView(VkDevice, const VkImageViewCreateInfo *ci, const VkAllocationCallbacks *, VkImageView *v)
{
    VkImageView_T *o = new VkImageView_T(); o->img = ci->image;
    const VkImageSubresourceRange &r = ci->subresourceRange; id<MTLTexture> t = ci->image->tex;
    uint32_t levels = r.levelCount == VK_REMAINING_MIP_LEVELS ? (uint32_t)t.mipmapLevelCount - r.baseMipLevel : r.levelCount;
    uint32_t layers = r.layerCount == VK_REMAINING_ARRAY_LAYERS ? ci->image->ci.arrayLayers - r.baseArrayLayer : r.layerCount;
    MTLPixelFormat pf = pixfmt(ci->format); if (pf == MTLPixelFormatInvalid) pf = t.pixelFormat;
    MTLTextureType tt = ci->viewType == VK_IMAGE_VIEW_TYPE_2D_ARRAY ? MTLTextureType2DArray : ci->viewType == VK_IMAGE_VIEW_TYPE_CUBE ? MTLTextureTypeCube :
                        ci->viewType == VK_IMAGE_VIEW_TYPE_3D ? MTLTextureType3D : MTLTextureType2D;
    if (pf == t.pixelFormat && tt == t.textureType && r.baseMipLevel == 0 && levels == t.mipmapLevelCount && r.baseArrayLayer == 0 && layers == (tt == MTLTextureTypeCube ? 6 : t.arrayLength)) o->tex = t;
    else o->tex = [t newTextureViewWithPixelFormat:pf textureType:tt levels:NSMakeRange(r.baseMipLevel, levels) slices:NSMakeRange(r.baseArrayLayer, layers)];
    *v = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyImageView(VkDevice, VkImageView v, const VkAllocationCallbacks *) { delete v; }
static MTLSamplerAddressMode addr(VkSamplerAddressMode m)
{
    switch (m) {
    case VK_SAMPLER_ADDRESS_MODE_REPEAT: return MTLSamplerAddressModeRepeat;
    case VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT: return MTLSamplerAddressModeMirrorRepeat;
    case VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER: return MTLSamplerAddressModeClampToBorderColor;
    case VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE: return MTLSamplerAddressModeMirrorClampToEdge;
    default: return MTLSamplerAddressModeClampToEdge;
    }
}
static MTLCompareFunction cmpf(VkCompareOp o)
{
    static const MTLCompareFunction m[] = {MTLCompareFunctionNever, MTLCompareFunctionLess, MTLCompareFunctionEqual, MTLCompareFunctionLessEqual,
                                           MTLCompareFunctionGreater, MTLCompareFunctionNotEqual, MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways};
    return (unsigned)o < 8 ? m[o] : MTLCompareFunctionAlways;
}
static VkResult VKAPI_CALL vkm_CreateSampler(VkDevice d, const VkSamplerCreateInfo *ci, const VkAllocationCallbacks *, VkSampler *s)
{
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.magFilter = ci->magFilter == VK_FILTER_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sd.minFilter = ci->minFilter == VK_FILTER_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sd.mipFilter = ci->maxLod <= 0 ? MTLSamplerMipFilterNotMipmapped : ci->mipmapMode == VK_SAMPLER_MIPMAP_MODE_LINEAR ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
    sd.sAddressMode = addr(ci->addressModeU); sd.tAddressMode = addr(ci->addressModeV); sd.rAddressMode = addr(ci->addressModeW);
    sd.lodMinClamp = ci->minLod; sd.lodMaxClamp = ci->maxLod > ci->minLod ? ci->maxLod : ci->minLod;
    if (ci->anisotropyEnable && ci->maxAnisotropy > 1) sd.maxAnisotropy = (NSUInteger)(ci->maxAnisotropy > 16 ? 16 : ci->maxAnisotropy);
    if (ci->compareEnable) sd.compareFunction = cmpf(ci->compareOp);
    sd.borderColor = ci->borderColor == VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE || ci->borderColor == VK_BORDER_COLOR_INT_OPAQUE_WHITE ? MTLSamplerBorderColorOpaqueWhite :
                     ci->borderColor == VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK || ci->borderColor == VK_BORDER_COLOR_INT_OPAQUE_BLACK ? MTLSamplerBorderColorOpaqueBlack : MTLSamplerBorderColorTransparentBlack;
    VkSampler_T *o = new VkSampler_T(); o->s = [d->dev newSamplerStateWithDescriptor:sd]; *s = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroySampler(VkDevice, VkSampler s, const VkAllocationCallbacks *) { delete s; }

// ---------------------------------------------------------------- descriptors, layouts, render passes, framebuffers
static VkResult VKAPI_CALL vkm_CreateDescriptorSetLayout(VkDevice, const VkDescriptorSetLayoutCreateInfo *ci, const VkAllocationCallbacks *, VkDescriptorSetLayout *l)
{
    VkDescriptorSetLayout_T *o = new VkDescriptorSetLayout_T(); o->nbind = ci->bindingCount;
    for (uint32_t k = 0; k < ci->bindingCount; k++)
        if (ci->pBindings[k].descriptorType != VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER || ci->pBindings[k].binding > 3 || ci->pBindings[k].descriptorCount > 1) {
            char w[128]; snprintf(w, sizeof w, "descriptor binding %u type %d count %u: only single combined image samplers 0-3 are done", ci->pBindings[k].binding,
                                  ci->pBindings[k].descriptorType, ci->pBindings[k].descriptorCount); once(w);
        }
    *l = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyDescriptorSetLayout(VkDevice, VkDescriptorSetLayout l, const VkAllocationCallbacks *) { delete l; }
static VkResult VKAPI_CALL vkm_CreateDescriptorPool(VkDevice, const VkDescriptorPoolCreateInfo *, const VkAllocationCallbacks *, VkDescriptorPool *p) { *p = new VkDescriptorPool_T(); return VK_SUCCESS; }
static void VKAPI_CALL vkm_DestroyDescriptorPool(VkDevice, VkDescriptorPool p, const VkAllocationCallbacks *) { delete p; }
static VkResult VKAPI_CALL vkm_AllocateDescriptorSets(VkDevice, const VkDescriptorSetAllocateInfo *ai, VkDescriptorSet *s)
{
    for (uint32_t k = 0; k < ai->descriptorSetCount; k++) s[k] = new VkDescriptorSet_T();
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_FreeDescriptorSets(VkDevice, VkDescriptorPool, uint32_t n, const VkDescriptorSet *s) { for (uint32_t k = 0; k < n; k++) delete s[k]; return VK_SUCCESS; }
static void VKAPI_CALL vkm_UpdateDescriptorSets(VkDevice, uint32_t nw, const VkWriteDescriptorSet *w, uint32_t nc, const VkCopyDescriptorSet *c)
{
    for (uint32_t k = 0; k < nw; k++) {
        if (w[k].descriptorType != VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) { once("vkUpdateDescriptorSets: a descriptor that isn't a combined image sampler (left out)"); continue; }
        for (uint32_t j = 0; j < w[k].descriptorCount; j++) {
            uint32_t b = w[k].dstBinding + w[k].dstArrayElement + j; if (b > 3) continue;
            w[k].dstSet->view[b] = w[k].pImageInfo[j].imageView; w[k].dstSet->smp[b] = w[k].pImageInfo[j].sampler;
        }
    }
    for (uint32_t k = 0; k < nc; k++)
        for (uint32_t j = 0; j < c[k].descriptorCount; j++) {
            uint32_t sb = c[k].srcBinding + c[k].srcArrayElement + j, db = c[k].dstBinding + c[k].dstArrayElement + j; if (sb > 3 || db > 3) continue;
            c[k].dstSet->view[db] = c[k].srcSet->view[sb]; c[k].dstSet->smp[db] = c[k].srcSet->smp[sb];
        }
}
static VkResult VKAPI_CALL vkm_CreatePipelineLayout(VkDevice, const VkPipelineLayoutCreateInfo *ci, const VkAllocationCallbacks *, VkPipelineLayout *l)
{
    VkPipelineLayout_T *o = new VkPipelineLayout_T(); o->nsets = ci->setLayoutCount; o->push = 0;
    for (uint32_t k = 0; k < ci->pushConstantRangeCount; k++) { uint32_t e = ci->pPushConstantRanges[k].offset + ci->pPushConstantRanges[k].size; if (e > o->push) o->push = e; }
    *l = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyPipelineLayout(VkDevice, VkPipelineLayout l, const VkAllocationCallbacks *) { delete l; }
static VkResult VKAPI_CALL vkm_CreateRenderPass(VkDevice, const VkRenderPassCreateInfo *ci, const VkAllocationCallbacks *, VkRenderPass *rp)
{
    VkRenderPass_T *o = new VkRenderPass_T(); o->n = ci->attachmentCount > 4 ? 4 : ci->attachmentCount; o->color = o->depth = -1;
    for (uint32_t k = 0; k < o->n; k++) o->a[k] = ci->pAttachments[k];
    if (ci->subpassCount > 1) once("a render pass with more than one subpass (only the first is done)");
    if (ci->subpassCount) {
        const VkSubpassDescription &s = ci->pSubpasses[0];
        if (s.colorAttachmentCount > 1) once("a subpass with more than one colour attachment (only the first is done)");
        if (s.colorAttachmentCount && s.pColorAttachments[0].attachment != VK_ATTACHMENT_UNUSED) o->color = (int)s.pColorAttachments[0].attachment;
        if (s.pDepthStencilAttachment && s.pDepthStencilAttachment->attachment != VK_ATTACHMENT_UNUSED) o->depth = (int)s.pDepthStencilAttachment->attachment;
    }
    *rp = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyRenderPass(VkDevice, VkRenderPass rp, const VkAllocationCallbacks *) { delete rp; }
static VkResult VKAPI_CALL vkm_CreateFramebuffer(VkDevice, const VkFramebufferCreateInfo *ci, const VkAllocationCallbacks *, VkFramebuffer *f)
{
    VkFramebuffer_T *o = new VkFramebuffer_T(); o->n = ci->attachmentCount > 4 ? 4 : ci->attachmentCount; o->w = ci->width; o->h = ci->height;
    for (uint32_t k = 0; k < o->n; k++) o->a[k] = ci->pAttachments[k];
    *f = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyFramebuffer(VkDevice, VkFramebuffer f, const VkAllocationCallbacks *) { delete f; }

// ---------------------------------------------------------------- shaders and pipelines
static VkResult VKAPI_CALL vkm_CreateShaderModule(VkDevice, const VkShaderModuleCreateInfo *ci, const VkAllocationCallbacks *, VkShaderModule *m)
{
    VkShaderModule_T *o = new VkShaderModule_T(); o->spv.assign(ci->pCode, ci->pCode + ci->codeSize / 4); *m = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyShaderModule(VkDevice, VkShaderModule m, const VkAllocationCallbacks *) { delete m; }
/* the module's function for a stage (0 vertex, 1 fragment), translated and compiled the first time */
static id<MTLFunction> stage_function(id<MTLDevice> dev, VkShaderModule_T *m, int stage, const char *entry)
{
    if (!m->lib[stage]) {
        std::string msl;
        try {
            spirv_cross::CompilerMSL c(m->spv);
            spv::ExecutionModel model = stage ? spv::ExecutionModelFragment : spv::ExecutionModelVertex;
            c.set_entry_point(entry, model);
            spirv_cross::CompilerMSL::Options o = c.get_msl_options();
            o.platform = spirv_cross::CompilerMSL::Options::macOS; o.set_msl_version(2, 3); o.enable_decoration_binding = false;
            c.set_msl_options(o);
            spirv_cross::CompilerGLSL::Options g = c.get_common_options(); g.vertex.flip_vert_y = true; c.set_common_options(g);
            for (uint32_t set = 0; set < 4; set++)
                for (uint32_t b = 0; b < 4; b++) {
                    spirv_cross::MSLResourceBinding r; r.stage = model; r.desc_set = set; r.binding = b;
                    r.msl_texture = set * 4 + b; r.msl_sampler = set * 4 + b; r.msl_buffer = 16 + set * 4 + b; c.add_msl_resource_binding(r);
                }
            spirv_cross::MSLResourceBinding pc; pc.stage = model; pc.desc_set = spirv_cross::kPushConstDescSet; pc.binding = spirv_cross::kPushConstBinding; pc.msl_buffer = 30;
            c.add_msl_resource_binding(pc);
            msl = c.compile();
            m->entry[stage] = c.get_cleansed_entry_point_name(entry, model);
        } catch (const std::exception &e) { fprintf(stderr, "vkm: shader translation failed: %s\n", e.what()); return nil; }
        NSError *err = nil; MTLCompileOptions *co = [MTLCompileOptions new]; co.languageVersion = MTLLanguageVersion2_3; co.mathMode = MTLMathModeSafe;
        m->lib[stage] = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl.c_str()] options:co error:&err];
        if (!m->lib[stage]) { fprintf(stderr, "vkm: Metal didn't compile a %s shader: %s\n", stage ? "fragment" : "vertex", err.localizedDescription.UTF8String); return nil; }
        LOG("shader %p (%zu words): %s function %s\n", (void *)m, m->spv.size(), stage ? "fragment" : "vertex", m->entry[stage].c_str());
    }
    return [m->lib[stage] newFunctionWithName:[NSString stringWithUTF8String:m->entry[stage].c_str()]];
}
static MTLBlendFactor bfac(VkBlendFactor f)
{
    switch (f) {
    case VK_BLEND_FACTOR_ZERO: return MTLBlendFactorZero; case VK_BLEND_FACTOR_ONE: return MTLBlendFactorOne;
    case VK_BLEND_FACTOR_SRC_COLOR: return MTLBlendFactorSourceColor; case VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
    case VK_BLEND_FACTOR_DST_COLOR: return MTLBlendFactorDestinationColor; case VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
    case VK_BLEND_FACTOR_SRC_ALPHA: return MTLBlendFactorSourceAlpha; case VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
    case VK_BLEND_FACTOR_DST_ALPHA: return MTLBlendFactorDestinationAlpha; case VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
    case VK_BLEND_FACTOR_CONSTANT_COLOR: return MTLBlendFactorBlendColor; case VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
    case VK_BLEND_FACTOR_CONSTANT_ALPHA: return MTLBlendFactorBlendAlpha; case VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
    case VK_BLEND_FACTOR_SRC_ALPHA_SATURATE: return MTLBlendFactorSourceAlphaSaturated;
    default: return MTLBlendFactorOne;
    }
}
static MTLBlendOperation bop(VkBlendOp o)
{
    switch (o) {
    case VK_BLEND_OP_SUBTRACT: return MTLBlendOperationSubtract; case VK_BLEND_OP_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
    case VK_BLEND_OP_MIN: return MTLBlendOperationMin; case VK_BLEND_OP_MAX: return MTLBlendOperationMax; default: return MTLBlendOperationAdd;
    }
}
static VkResult make_pipeline(VkDevice d, const VkGraphicsPipelineCreateInfo *ci, VkPipeline *out)
{
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    for (uint32_t k = 0; k < ci->stageCount; k++) {
        const VkPipelineShaderStageCreateInfo &s = ci->pStages[k];
        int st = s.stage == VK_SHADER_STAGE_FRAGMENT_BIT ? 1 : s.stage == VK_SHADER_STAGE_VERTEX_BIT ? 0 : -1;
        if (st < 0) { once("a pipeline stage that isn't vertex or fragment (left out)"); continue; }
        if (s.pSpecializationInfo && s.pSpecializationInfo->mapEntryCount) once("specialisation constants (not applied)");
        id<MTLFunction> f = stage_function(d->dev, s.module, st, s.pName);
        if (!f) return VK_ERROR_INVALID_SHADER_NV;
        if (st) pd.fragmentFunction = f; else pd.vertexFunction = f;
    }
    /* vertex input: binding b is buffer b */
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    const VkPipelineVertexInputStateCreateInfo *vi = ci->pVertexInputState;
    for (uint32_t k = 0; vi && k < vi->vertexAttributeDescriptionCount; k++) {
        const VkVertexInputAttributeDescription &a = vi->pVertexAttributeDescriptions[k];
        vd.attributes[a.location].format = vtxfmt(a.format); vd.attributes[a.location].offset = a.offset; vd.attributes[a.location].bufferIndex = a.binding;
    }
    for (uint32_t k = 0; vi && k < vi->vertexBindingDescriptionCount; k++) {
        const VkVertexInputBindingDescription &b = vi->pVertexBindingDescriptions[k];
        vd.layouts[b.binding].stride = b.stride; vd.layouts[b.binding].stepFunction = b.inputRate == VK_VERTEX_INPUT_RATE_INSTANCE ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex;
        vd.layouts[b.binding].stepRate = 1;
    }
    pd.vertexDescriptor = vd;
    VkRenderPass_T *rp = ci->renderPass;
    if (rp->color >= 0) pd.colorAttachments[0].pixelFormat = pixfmt(rp->a[rp->color].format);
    if (rp->depth >= 0) { MTLPixelFormat df = pixfmt(rp->a[rp->depth].format); pd.depthAttachmentPixelFormat = df; if (df == MTLPixelFormatDepth32Float_Stencil8) pd.stencilAttachmentPixelFormat = df; }
    const VkPipelineColorBlendStateCreateInfo *cb = ci->pColorBlendState;
    if (cb && cb->attachmentCount && rp->color >= 0) {
        const VkPipelineColorBlendAttachmentState &a = cb->pAttachments[0];
        MTLRenderPipelineColorAttachmentDescriptor *c = pd.colorAttachments[0];
        c.blendingEnabled = a.blendEnable; c.sourceRGBBlendFactor = bfac(a.srcColorBlendFactor); c.destinationRGBBlendFactor = bfac(a.dstColorBlendFactor);
        c.rgbBlendOperation = bop(a.colorBlendOp); c.sourceAlphaBlendFactor = bfac(a.srcAlphaBlendFactor); c.destinationAlphaBlendFactor = bfac(a.dstAlphaBlendFactor);
        c.alphaBlendOperation = bop(a.alphaBlendOp);
        MTLColorWriteMask w = MTLColorWriteMaskNone;
        if (a.colorWriteMask & VK_COLOR_COMPONENT_R_BIT) w |= MTLColorWriteMaskRed; if (a.colorWriteMask & VK_COLOR_COMPONENT_G_BIT) w |= MTLColorWriteMaskGreen;
        if (a.colorWriteMask & VK_COLOR_COMPONENT_B_BIT) w |= MTLColorWriteMaskBlue; if (a.colorWriteMask & VK_COLOR_COMPONENT_A_BIT) w |= MTLColorWriteMaskAlpha;
        c.writeMask = w;
    }
    const VkPipelineInputAssemblyStateCreateInfo *ia = ci->pInputAssemblyState;
    VkPrimitiveTopology topo = ia ? ia->topology : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    pd.inputPrimitiveTopology = topo <= VK_PRIMITIVE_TOPOLOGY_POINT_LIST ? MTLPrimitiveTopologyClassPoint :
                                topo <= VK_PRIMITIVE_TOPOLOGY_LINE_STRIP ? MTLPrimitiveTopologyClassLine : MTLPrimitiveTopologyClassTriangle;
    NSError *err = nil;
    id<MTLRenderPipelineState> rps = [d->dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!rps) { fprintf(stderr, "vkm: pipeline not made: %s\n", err.localizedDescription.UTF8String); return VK_ERROR_INITIALIZATION_FAILED; }
    VkPipeline_T *o = new VkPipeline_T(); o->rps = rps; o->layout = ci->layout;
    static const MTLPrimitiveType prim[] = {MTLPrimitiveTypePoint, MTLPrimitiveTypeLine, MTLPrimitiveTypeLineStrip, MTLPrimitiveTypeTriangle, MTLPrimitiveTypeTriangleStrip};
    o->prim = (unsigned)topo < 5 ? prim[topo] : MTLPrimitiveTypeTriangle;
    if (topo > VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP) once("a primitive topology Metal lacks (triangle fans, adjacency, patches): drawn as triangles");
    const VkPipelineRasterizationStateCreateInfo *rs = ci->pRasterizationState;
    o->cull = !rs ? MTLCullModeNone : rs->cullMode == VK_CULL_MODE_BACK_BIT ? MTLCullModeBack : rs->cullMode == VK_CULL_MODE_FRONT_BIT ? MTLCullModeFront : MTLCullModeNone;
    int ccw = rs && rs->frontFace == VK_FRONT_FACE_COUNTER_CLOCKWISE; if (getenv("VKM_FLIP_WINDING")) ccw = !ccw;
    o->wind = ccw ? MTLWindingCounterClockwise : MTLWindingClockwise;
    o->fill = rs && rs->polygonMode == VK_POLYGON_MODE_LINE ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
    o->bias = rs && rs->depthBiasEnable; o->bconst = rs ? rs->depthBiasConstantFactor : 0; o->bslope = rs ? rs->depthBiasSlopeFactor : 0; o->bclamp = rs ? rs->depthBiasClamp : 0;
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    const VkPipelineDepthStencilStateCreateInfo *dz = ci->pDepthStencilState;
    if (dz && rp->depth >= 0) { ds.depthCompareFunction = dz->depthTestEnable ? cmpf(dz->depthCompareOp) : MTLCompareFunctionAlways; ds.depthWriteEnabled = dz->depthTestEnable && dz->depthWriteEnable; }
    if (dz && dz->stencilTestEnable) once("stencil test (not done)");
    o->dss = [d->dev newDepthStencilStateWithDescriptor:ds];
    *out = o; return VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_CreateGraphicsPipelines(VkDevice d, VkPipelineCache, uint32_t n, const VkGraphicsPipelineCreateInfo *ci, const VkAllocationCallbacks *, VkPipeline *p)
{
    VkResult r = VK_SUCCESS;
    for (uint32_t k = 0; k < n; k++) { VkResult e = make_pipeline(d, &ci[k], &p[k]); if (e != VK_SUCCESS) { p[k] = VK_NULL_HANDLE; r = e; } }
    return r;
}
static void VKAPI_CALL vkm_DestroyPipeline(VkDevice, VkPipeline p, const VkAllocationCallbacks *) { delete p; }

// ---------------------------------------------------------------- synchronisation
static VkResult VKAPI_CALL vkm_CreateFence(VkDevice, const VkFenceCreateInfo *ci, const VkAllocationCallbacks *, VkFence *f)
{
    VkFence_T *o = new VkFence_T(); o->signaled = (ci->flags & VK_FENCE_CREATE_SIGNALED_BIT) != 0; *f = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroyFence(VkDevice, VkFence f, const VkAllocationCallbacks *) { delete f; }
static VkResult VKAPI_CALL vkm_ResetFences(VkDevice, uint32_t n, const VkFence *f) { for (uint32_t k = 0; k < n; k++) { std::lock_guard<std::mutex> g(f[k]->m); f[k]->signaled = false; } return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_GetFenceStatus(VkDevice, VkFence f) { std::lock_guard<std::mutex> g(f->m); return f->signaled ? VK_SUCCESS : VK_NOT_READY; }
static void signal(VkFence_T *f)
{
    std::lock_guard<std::mutex> g(f->m); f->signaled = true;
    // A waiter may destroy the completed fence as soon as it observes signaled. Finish notifying before
    // releasing the mutex, so the callback never touches a condition variable that has already been freed.
    f->cv.notify_all();
}
static VkResult VKAPI_CALL vkm_WaitForFences(VkDevice, uint32_t n, const VkFence *f, VkBool32 all, uint64_t timeout)
{
    auto until = std::chrono::steady_clock::now() + std::chrono::nanoseconds(timeout > (uint64_t)INT64_MAX / 2 ? (uint64_t)INT64_MAX / 2 : timeout);
    for (;;) {
        uint32_t done = 0, pending = 0;
        for (uint32_t k = 0; k < n; k++) { std::lock_guard<std::mutex> g(f[k]->m); if (f[k]->signaled) done++; else pending = k; }
        if (all ? done == n : done > 0) return VK_SUCCESS;
        if (std::chrono::steady_clock::now() >= until) return VK_TIMEOUT;
        // Recheck under the same lock as signal(), closing the gap between the scan and the wait. Bound
        // polling of other fences by the caller's deadline; a short timeout must not incur a 50 ms sleep.
        auto wake = until;
        if (n > 1) wake = std::min(wake, std::chrono::steady_clock::now() + std::chrono::milliseconds(1));
        std::unique_lock<std::mutex> g(f[pending]->m);
        f[pending]->cv.wait_until(g, wake, [&] { return f[pending]->signaled; });
    }
}
static VkResult VKAPI_CALL vkm_CreateSemaphore(VkDevice, const VkSemaphoreCreateInfo *, const VkAllocationCallbacks *, VkSemaphore *s) { *s = new VkSemaphore_T(); return VK_SUCCESS; }
static void VKAPI_CALL vkm_DestroySemaphore(VkDevice, VkSemaphore s, const VkAllocationCallbacks *) { delete s; }

// ---------------------------------------------------------------- command buffers: recording
static VkResult VKAPI_CALL vkm_CreateCommandPool(VkDevice, const VkCommandPoolCreateInfo *, const VkAllocationCallbacks *, VkCommandPool *p) { *p = new VkCommandPool_T(); return VK_SUCCESS; }
static void VKAPI_CALL vkm_DestroyCommandPool(VkDevice, VkCommandPool p, const VkAllocationCallbacks *) { delete p; }
static VkResult VKAPI_CALL vkm_ResetCommandPool(VkDevice, VkCommandPool, VkCommandPoolResetFlags) { return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_AllocateCommandBuffers(VkDevice d, const VkCommandBufferAllocateInfo *ai, VkCommandBuffer *cb)
{
    if (ai->level != VK_COMMAND_BUFFER_LEVEL_PRIMARY) once("secondary command buffers (not done)");
    for (uint32_t k = 0; k < ai->commandBufferCount; k++) { cb[k] = new VkCommandBuffer_T(); cb[k]->d = d; }
    return VK_SUCCESS;
}
static void VKAPI_CALL vkm_FreeCommandBuffers(VkDevice, VkCommandPool, uint32_t n, const VkCommandBuffer *cb) { for (uint32_t k = 0; k < n; k++) delete cb[k]; }
static VkResult VKAPI_CALL vkm_BeginCommandBuffer(VkCommandBuffer cb, const VkCommandBufferBeginInfo *) { cb->cmds.clear(); return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_EndCommandBuffer(VkCommandBuffer) { return VK_SUCCESS; }
static VkResult VKAPI_CALL vkm_ResetCommandBuffer(VkCommandBuffer cb, VkCommandBufferResetFlags) { cb->cmds.clear(); return VK_SUCCESS; }
static Cmd &rec(VkCommandBuffer cb, Op op) { cb->cmds.emplace_back(); Cmd &c = cb->cmds.back(); c.op = op; return c; }
static void VKAPI_CALL vkm_CmdBeginRenderPass(VkCommandBuffer cb, const VkRenderPassBeginInfo *bi, VkSubpassContents)
{
    Cmd &c = rec(cb, BEGIN_RP); c.p[0] = bi->renderPass; c.p[1] = bi->framebuffer;
    for (uint32_t k = 0; k < bi->clearValueCount && k < 4; k++) c.clear[k] = bi->pClearValues[k];
}
static void VKAPI_CALL vkm_CmdEndRenderPass(VkCommandBuffer cb) { rec(cb, END_RP); }
static void VKAPI_CALL vkm_CmdNextSubpass(VkCommandBuffer, VkSubpassContents) { once("vkCmdNextSubpass (not done)"); }
static void VKAPI_CALL vkm_CmdBindPipeline(VkCommandBuffer cb, VkPipelineBindPoint, VkPipeline p) { rec(cb, BIND_PIPE).p[0] = p; }
static void VKAPI_CALL vkm_CmdBindVertexBuffers(VkCommandBuffer cb, uint32_t first, uint32_t n, const VkBuffer *b, const VkDeviceSize *off)
{
    for (uint32_t k = 0; k < n; k++) { Cmd &c = rec(cb, BIND_VB); c.a[0] = first + k; c.p[0] = b[k]; c.q[0] = off[k]; }
}
static void VKAPI_CALL vkm_CmdBindIndexBuffer(VkCommandBuffer cb, VkBuffer b, VkDeviceSize off, VkIndexType t)
{
    Cmd &c = rec(cb, BIND_IB); c.p[0] = b; c.q[0] = off; c.a[0] = t;
}
static void VKAPI_CALL vkm_CmdBindDescriptorSets(VkCommandBuffer cb, VkPipelineBindPoint, VkPipelineLayout, uint32_t first, uint32_t n, const VkDescriptorSet *s, uint32_t, const uint32_t *)
{
    for (uint32_t k = 0; k < n && first + k < 4; k++) { Cmd &c = rec(cb, BIND_SETS); c.a[0] = first + k; c.p[0] = s[k]; }
}
static void VKAPI_CALL vkm_CmdPushConstants(VkCommandBuffer cb, VkPipelineLayout, VkShaderStageFlags, uint32_t off, uint32_t size, const void *v)
{
    Cmd &c = rec(cb, PUSH); c.a[0] = off; c.bytes.assign((const uint8_t *)v, (const uint8_t *)v + size);
}
static void VKAPI_CALL vkm_CmdDraw(VkCommandBuffer cb, uint32_t vc, uint32_t ic, uint32_t fv, uint32_t fi)
{
    Cmd &c = rec(cb, DRAW); c.a[0] = vc; c.a[1] = ic; c.a[2] = fv; c.a[3] = fi;
}
static void VKAPI_CALL vkm_CmdDrawIndexed(VkCommandBuffer cb, uint32_t n, uint32_t ic, uint32_t first, int32_t vo, uint32_t fi)
{
    Cmd &c = rec(cb, DRAW_IDX); c.a[0] = n; c.a[1] = ic; c.a[2] = first; c.a[3] = (uint32_t)vo; c.a[4] = fi;
}
static void VKAPI_CALL vkm_CmdSetViewport(VkCommandBuffer cb, uint32_t, uint32_t n, const VkViewport *v)
{
    if (!n) return; Cmd &c = rec(cb, VIEWPORT); c.f[0] = v->x; c.f[1] = v->y; c.f[2] = v->width; c.f[3] = v->height; c.f[4] = v->minDepth; c.f[5] = v->maxDepth;
}
static void VKAPI_CALL vkm_CmdSetScissor(VkCommandBuffer cb, uint32_t, uint32_t n, const VkRect2D *r)
{
    if (!n) return; Cmd &c = rec(cb, SCISSOR); c.a[0] = (uint32_t)r->offset.x; c.a[1] = (uint32_t)r->offset.y; c.a[2] = r->extent.width; c.a[3] = r->extent.height;
}
static void VKAPI_CALL vkm_CmdClearColorImage(VkCommandBuffer cb, VkImage im, VkImageLayout, const VkClearColorValue *v, uint32_t, const VkImageSubresourceRange *)
{
    Cmd &c = rec(cb, CLEAR_COLOR); c.p[0] = im; c.clear[0].color = *v;
}
static void VKAPI_CALL vkm_CmdClearDepthStencilImage(VkCommandBuffer cb, VkImage im, VkImageLayout, const VkClearDepthStencilValue *v, uint32_t, const VkImageSubresourceRange *)
{
    Cmd &c = rec(cb, CLEAR_DEPTH); c.p[0] = im; c.clear[0].depthStencil = *v;
}
static void VKAPI_CALL vkm_CmdClearAttachments(VkCommandBuffer, uint32_t, const VkClearAttachment *, uint32_t, const VkClearRect *) { once("vkCmdClearAttachments (not done)"); }
static void VKAPI_CALL vkm_CmdCopyBuffer(VkCommandBuffer cb, VkBuffer s, VkBuffer d, uint32_t n, const VkBufferCopy *r)
{
    Cmd &c = rec(cb, COPY_BUF); c.p[0] = s; c.p[1] = d; c.bregions.assign(r, r + n);
}
static void VKAPI_CALL vkm_CmdCopyBufferToImage(VkCommandBuffer cb, VkBuffer s, VkImage d, VkImageLayout, uint32_t n, const VkBufferImageCopy *r)
{
    Cmd &c = rec(cb, COPY_B2I); c.p[0] = s; c.p[1] = d; c.regions.assign(r, r + n);
}
static void VKAPI_CALL vkm_CmdCopyImageToBuffer(VkCommandBuffer cb, VkImage s, VkImageLayout, VkBuffer d, uint32_t n, const VkBufferImageCopy *r)
{
    Cmd &c = rec(cb, COPY_I2B); c.p[0] = s; c.p[1] = d; c.regions.assign(r, r + n);
}
static void VKAPI_CALL vkm_CmdBlitImage(VkCommandBuffer cb, VkImage s, VkImageLayout, VkImage d, VkImageLayout, uint32_t n, const VkImageBlit *r, VkFilter)
{
    Cmd &c = rec(cb, BLIT); c.p[0] = s; c.p[1] = d; c.blits.assign(r, r + n);
}
static void VKAPI_CALL vkm_CmdCopyImage(VkCommandBuffer, VkImage, VkImageLayout, VkImage, VkImageLayout, uint32_t, const VkImageCopy *) { once("vkCmdCopyImage (not done)"); }
static void VKAPI_CALL vkm_CmdPipelineBarrier(VkCommandBuffer, VkPipelineStageFlags, VkPipelineStageFlags, VkDependencyFlags, uint32_t, const VkMemoryBarrier *,
                                              uint32_t, const VkBufferMemoryBarrier *, uint32_t, const VkImageMemoryBarrier *) {}   /* Metal tracks the hazards */

// ---------------------------------------------------------------- command buffers: encoding at submission
struct Enc {
    id<MTLCommandBuffer> cb; id<MTLRenderCommandEncoder> re; id<MTLBlitCommandEncoder> be;
    VkPipeline_T *pipe = 0; VkDescriptorSet_T *sets[4] = {}; uint8_t push[128] = {}; bool push_dirty = true, sets_dirty = true;
    VkBuffer_T *ib = 0; VkDeviceSize ib_off = 0; uint32_t ib_type = 0;
    MTLViewport vp = {0, 0, 1, 1, 0, 1}; MTLScissorRect sc = {0, 0, 1, 1}; bool have_vp = false, have_sc = false; uint32_t fw = 1, fh = 1;
    struct { VkBuffer_T *b; VkDeviceSize off; } vb[8] = {};
    void end_render() { if (re) { [re endEncoding]; re = nil; } }
    void end_blit() { if (be) { [be endEncoding]; be = nil; } }
    id<MTLBlitCommandEncoder> blit() { end_render(); if (!be) be = [cb blitCommandEncoder]; return be; }
};
static void apply_render_state(Enc &e)
{
    if (!e.re) return;
    if (e.have_vp) [e.re setViewport:e.vp];
    MTLScissorRect s = e.have_sc ? e.sc : MTLScissorRect{0, 0, e.fw, e.fh};    /* Metal wants the scissor inside the target */
    if (s.x >= e.fw) s.x = e.fw - 1; if (s.y >= e.fh) s.y = e.fh - 1;
    if (s.x + s.width > e.fw) s.width = e.fw - s.x; if (s.y + s.height > e.fh) s.height = e.fh - s.y;
    [e.re setScissorRect:s];
    if (e.pipe) {
        [e.re setRenderPipelineState:e.pipe->rps]; [e.re setDepthStencilState:e.pipe->dss]; [e.re setCullMode:e.pipe->cull];
        [e.re setFrontFacingWinding:e.pipe->wind]; [e.re setTriangleFillMode:e.pipe->fill];
        if (e.pipe->bias) [e.re setDepthBias:e.pipe->bconst slopeScale:e.pipe->bslope clamp:e.pipe->bclamp]; else [e.re setDepthBias:0 slopeScale:0 clamp:0];
    }
    for (int k = 0; k < 8; k++) if (e.vb[k].b && e.vb[k].b->mem) [e.re setVertexBuffer:e.vb[k].b->mem->buf offset:(NSUInteger)(e.vb[k].b->off + e.vb[k].off) atIndex:k];
    e.push_dirty = e.sets_dirty = true;
}
static void before_draw(Enc &e)
{
    if (e.push_dirty) { [e.re setVertexBytes:e.push length:sizeof e.push atIndex:30]; [e.re setFragmentBytes:e.push length:sizeof e.push atIndex:30]; e.push_dirty = false; }
    if (e.sets_dirty) {
        for (int s = 0; s < 4; s++) if (e.sets[s])
            for (int b = 0; b < 4; b++) {
                VkImageView_T *v = e.sets[s]->view[b]; VkSampler_T *sm = e.sets[s]->smp[b];
                if (v) { [e.re setFragmentTexture:v->tex atIndex:s * 4 + b]; [e.re setVertexTexture:v->tex atIndex:s * 4 + b]; }
                if (sm) { [e.re setFragmentSamplerState:sm->s atIndex:s * 4 + b]; [e.re setVertexSamplerState:sm->s atIndex:s * 4 + b]; }
            }
        e.sets_dirty = false;
    }
}
static MTLLoadAction load_of(VkAttachmentLoadOp o) { return o == VK_ATTACHMENT_LOAD_OP_CLEAR ? MTLLoadActionClear : o == VK_ATTACHMENT_LOAD_OP_LOAD ? MTLLoadActionLoad : MTLLoadActionDontCare; }
static void clear_image(Enc &e, VkImage_T *im, const VkClearValue &v, bool depth)
{
    e.end_render(); e.end_blit();
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (uint32_t layer = 0; layer < (uint32_t)im->tex.arrayLength; layer++) {
        if (depth) { rp.depthAttachment.texture = im->tex; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore;
                     rp.depthAttachment.clearDepth = v.depthStencil.depth; rp.depthAttachment.slice = layer;
                     if (im->tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) { rp.stencilAttachment.texture = im->tex; rp.stencilAttachment.loadAction = MTLLoadActionClear;
                         rp.stencilAttachment.storeAction = MTLStoreActionStore; rp.stencilAttachment.clearStencil = v.depthStencil.stencil; rp.stencilAttachment.slice = layer; } }
        else { rp.colorAttachments[0].texture = im->tex; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
               rp.colorAttachments[0].clearColor = MTLClearColorMake(v.color.float32[0], v.color.float32[1], v.color.float32[2], v.color.float32[3]); rp.colorAttachments[0].slice = layer; }
        [[e.cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    }
}
static void copy_buffer_image(Enc &e, VkBuffer_T *b, VkImage_T *im, const VkBufferImageCopy &r, bool to_image)
{
    if (!b->mem || !b->mem->buf) return;
    VkFormat f = im->ci.format; uint32_t bpp = texel_bytes(f);
    uint32_t rowlen = r.bufferRowLength ? r.bufferRowLength : r.imageExtent.width, rows = r.bufferImageHeight ? r.bufferImageHeight : r.imageExtent.height;
    NSUInteger bpr = is_bc(f) ? (rowlen + 3) / 4 * bpp : rowlen * bpp, bpi = is_bc(f) ? bpr * ((rows + 3) / 4) : bpr * rows;
    id<MTLBlitCommandEncoder> be = e.blit();
    for (uint32_t l = 0; l < r.imageSubresource.layerCount; l++) {
        NSUInteger off = (NSUInteger)(b->off + r.bufferOffset) + l * bpi;
        MTLOrigin o = MTLOriginMake(r.imageOffset.x, r.imageOffset.y, r.imageOffset.z); MTLSize s = MTLSizeMake(r.imageExtent.width, r.imageExtent.height, r.imageExtent.depth ? r.imageExtent.depth : 1);
        if (to_image) [be copyFromBuffer:b->mem->buf sourceOffset:off sourceBytesPerRow:bpr sourceBytesPerImage:bpi sourceSize:s toTexture:im->tex
                         destinationSlice:r.imageSubresource.baseArrayLayer + l destinationLevel:r.imageSubresource.mipLevel destinationOrigin:o];
        else [be copyFromTexture:im->tex sourceSlice:r.imageSubresource.baseArrayLayer + l sourceLevel:r.imageSubresource.mipLevel sourceOrigin:o sourceSize:s
                        toBuffer:b->mem->buf destinationOffset:off destinationBytesPerRow:bpr destinationBytesPerImage:bpi];
    }
}
static void encode(Enc &e, VkCommandBuffer_T *cb)
{
    for (Cmd &c : cb->cmds) switch (c.op) {
    case BEGIN_RP: {
        e.end_blit(); e.end_render();
        VkRenderPass_T *rp = (VkRenderPass_T *)c.p[0]; VkFramebuffer_T *fb = (VkFramebuffer_T *)c.p[1];
        MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
        if (rp->color >= 0 && (uint32_t)rp->color < fb->n) {
            const VkAttachmentDescription &a = rp->a[rp->color]; VkClearColorValue cv = c.clear[rp->color].color;
            d.colorAttachments[0].texture = fb->a[rp->color]->tex; d.colorAttachments[0].loadAction = load_of(a.loadOp);
            d.colorAttachments[0].storeAction = a.storeOp == VK_ATTACHMENT_STORE_OP_STORE ? MTLStoreActionStore : MTLStoreActionDontCare;
            d.colorAttachments[0].clearColor = MTLClearColorMake(cv.float32[0], cv.float32[1], cv.float32[2], cv.float32[3]);
        }
        if (rp->depth >= 0 && (uint32_t)rp->depth < fb->n) {
            const VkAttachmentDescription &a = rp->a[rp->depth];
            d.depthAttachment.texture = fb->a[rp->depth]->tex; d.depthAttachment.loadAction = load_of(a.loadOp);
            d.depthAttachment.storeAction = a.storeOp == VK_ATTACHMENT_STORE_OP_STORE ? MTLStoreActionStore : MTLStoreActionDontCare;
            d.depthAttachment.clearDepth = c.clear[rp->depth].depthStencil.depth;
        }
        e.fw = fb->w; e.fh = fb->h;
        e.re = [e.cb renderCommandEncoderWithDescriptor:d];
        apply_render_state(e);
        break; }
    case END_RP: e.end_render(); break;
    case BIND_PIPE: e.pipe = (VkPipeline_T *)c.p[0]; if (e.re && e.pipe) {
        [e.re setRenderPipelineState:e.pipe->rps]; [e.re setDepthStencilState:e.pipe->dss]; [e.re setCullMode:e.pipe->cull];
        [e.re setFrontFacingWinding:e.pipe->wind]; [e.re setTriangleFillMode:e.pipe->fill];
        if (e.pipe->bias) [e.re setDepthBias:e.pipe->bconst slopeScale:e.pipe->bslope clamp:e.pipe->bclamp]; else [e.re setDepthBias:0 slopeScale:0 clamp:0]; }
        break;
    case BIND_VB: if (c.a[0] < 8) { e.vb[c.a[0]].b = (VkBuffer_T *)c.p[0]; e.vb[c.a[0]].off = c.q[0];
        if (e.re && e.vb[c.a[0]].b && e.vb[c.a[0]].b->mem) [e.re setVertexBuffer:e.vb[c.a[0]].b->mem->buf offset:(NSUInteger)(e.vb[c.a[0]].b->off + c.q[0]) atIndex:c.a[0]]; }
        break;
    case BIND_IB: e.ib = (VkBuffer_T *)c.p[0]; e.ib_off = c.q[0]; e.ib_type = c.a[0]; break;
    case BIND_SETS: e.sets[c.a[0]] = (VkDescriptorSet_T *)c.p[0]; e.sets_dirty = true; break;
    case PUSH: if (c.a[0] + c.bytes.size() <= sizeof e.push) { memcpy(e.push + c.a[0], c.bytes.data(), c.bytes.size()); e.push_dirty = true; } break;
    case DRAW: if (e.re && e.pipe && c.a[0] && c.a[1]) { before_draw(e);
        [e.re drawPrimitives:e.pipe->prim vertexStart:c.a[2] vertexCount:c.a[0] instanceCount:c.a[1] baseInstance:c.a[3]]; }
        break;
    case DRAW_IDX: if (e.re && e.pipe && e.ib && e.ib->mem && c.a[0] && c.a[1]) { before_draw(e);
        uint32_t isz = e.ib_type == VK_INDEX_TYPE_UINT16 ? 2 : 4;
        [e.re drawIndexedPrimitives:e.pipe->prim indexCount:c.a[0] indexType:isz == 2 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32 indexBuffer:e.ib->mem->buf
                  indexBufferOffset:(NSUInteger)(e.ib->off + e.ib_off + (VkDeviceSize)c.a[2] * isz) instanceCount:c.a[1] baseVertex:(int32_t)c.a[3] baseInstance:c.a[4]]; }
        break;
    case VIEWPORT: e.vp = {c.f[0], c.f[1], c.f[2], c.f[3], c.f[4], c.f[5]}; e.have_vp = true; if (e.re) [e.re setViewport:e.vp]; break;
    case SCISSOR: e.sc = {c.a[0], c.a[1], c.a[2], c.a[3]}; e.have_sc = true; if (e.re) apply_render_state(e); break;
    case CLEAR_COLOR: clear_image(e, (VkImage_T *)c.p[0], c.clear[0], false); break;
    case CLEAR_DEPTH: clear_image(e, (VkImage_T *)c.p[0], c.clear[0], true); break;
    case COPY_BUF: { VkBuffer_T *s = (VkBuffer_T *)c.p[0], *d = (VkBuffer_T *)c.p[1]; if (!s->mem || !d->mem) break;
        id<MTLBlitCommandEncoder> be = e.blit();
        for (auto &r : c.bregions) [be copyFromBuffer:s->mem->buf sourceOffset:(NSUInteger)(s->off + r.srcOffset) toBuffer:d->mem->buf destinationOffset:(NSUInteger)(d->off + r.dstOffset) size:(NSUInteger)r.size];
        break; }
    case COPY_B2I: for (auto &r : c.regions) copy_buffer_image(e, (VkBuffer_T *)c.p[0], (VkImage_T *)c.p[1], r, true); break;
    case COPY_I2B: for (auto &r : c.regions) copy_buffer_image(e, (VkBuffer_T *)c.p[1], (VkImage_T *)c.p[0], r, false); break;
    case BLIT: {
        VkImage_T *s = (VkImage_T *)c.p[0], *d = (VkImage_T *)c.p[1]; id<MTLBlitCommandEncoder> be = e.blit();
        for (auto &r : c.blits) {
            int sw = r.srcOffsets[1].x - r.srcOffsets[0].x, sh = r.srcOffsets[1].y - r.srcOffsets[0].y, dw = r.dstOffsets[1].x - r.dstOffsets[0].x, dh = r.dstOffsets[1].y - r.dstOffsets[0].y;
            if (sw != dw || sh != dh || sw <= 0 || sh <= 0) { once("a scaled or flipped vkCmdBlitImage (copied unscaled)"); }
            int w = sw < dw ? sw : dw, h = sh < dh ? sh : dh; if (w <= 0 || h <= 0) continue;
            if (s->tex.pixelFormat != d->tex.pixelFormat) { once("vkCmdBlitImage between formats (left out)"); continue; }
            [be copyFromTexture:s->tex sourceSlice:r.srcSubresource.baseArrayLayer sourceLevel:r.srcSubresource.mipLevel sourceOrigin:MTLOriginMake(r.srcOffsets[0].x, r.srcOffsets[0].y, 0)
                     sourceSize:MTLSizeMake(w, h, 1) toTexture:d->tex destinationSlice:r.dstSubresource.baseArrayLayer destinationLevel:r.dstSubresource.mipLevel
              destinationOrigin:MTLOriginMake(r.dstOffsets[0].x, r.dstOffsets[0].y, 0)];
        }
        break; }
    }
    e.end_render(); e.end_blit();
}
/* development: VKM_TRACE_AT=<frame> (or VKM_TRACE_ON=<file>) prints the commands submitted for that presented frame (render passes and their
 * targets, pipelines, draws, the textures bound, copies), to see how the game builds a frame */
static uint32_t presented;
static void trace(VkCommandBuffer_T *cb)
{
    static long at = -2; if (at == -2) at = getenv("VKM_TRACE_AT") ? atol(getenv("VKM_TRACE_AT")) : -1;
    const char *on = getenv("VKM_TRACE_ON");                  /* or the frame after this file appears (it is removed) */
    if (on && !access(on, F_OK)) { unlink(on); at = presented + 1; fprintf(stderr, "vkm: trace of frame %ld\n", at); }
    if (at < 0 || presented != (uint32_t)at) return;
    auto tx = [](VkImageView_T *v) { static char b[64]; if (!v || !v->img) return "-"; snprintf(b, sizeof b, "%ux%u%s%s", v->img->ci.extent.width, v->img->ci.extent.height,
              v->img->swap ? " swap" : "", (v->img->ci.usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) ? " rt" : ""); return (const char *)b; };
    int draws = 0, prims = 0; void *pipe = 0;
    auto flush = [&]() { if (draws) fprintf(stderr, "    pipe %p: %d draws, %d vertices\n", pipe, draws, prims); draws = prims = 0; };
    for (Cmd &c : cb->cmds) switch (c.op) {
    case BEGIN_RP: { flush(); VkRenderPass_T *rp = (VkRenderPass_T *)c.p[0]; VkFramebuffer_T *fb = (VkFramebuffer_T *)c.p[1];
        fprintf(stderr, "  pass %ux%u color %s load %d%s\n", fb->w, fb->h, rp->color >= 0 ? tx(fb->a[rp->color]) : "-", rp->color >= 0 ? rp->a[rp->color].loadOp : -1, rp->depth >= 0 ? " +depth" : ""); break; }
    case END_RP: flush(); break;
    case BIND_PIPE: if (c.p[0] != pipe) { flush(); pipe = c.p[0]; } break;
    case BIND_SETS: { VkDescriptorSet_T *ds = (VkDescriptorSet_T *)c.p[0]; if (ds && ds->view[0] && ds->view[0]->img && (ds->view[0]->img->ci.usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) { flush(); fprintf(stderr, "    samples %s (set %u)\n", tx(ds->view[0]), c.a[0]); } break; }
    case VIEWPORT: flush(); fprintf(stderr, "    viewport %.0f,%.0f %.0fx%.0f\n", c.f[0], c.f[1], c.f[2], c.f[3]); break;
    case DRAW: draws++; prims += c.a[0] * c.a[1]; break;
    case DRAW_IDX: draws++; prims += c.a[0] * c.a[1]; break;
    case BLIT: flush(); fprintf(stderr, "  blit %ux%u -> %ux%u\n", ((VkImage_T *)c.p[0])->ci.extent.width, ((VkImage_T *)c.p[0])->ci.extent.height, ((VkImage_T *)c.p[1])->ci.extent.width, ((VkImage_T *)c.p[1])->ci.extent.height); break;
    case COPY_B2I: flush(); fprintf(stderr, "  upload to %ux%u\n", ((VkImage_T *)c.p[1])->ci.extent.width, ((VkImage_T *)c.p[1])->ci.extent.height); break;
    case COPY_I2B: flush(); fprintf(stderr, "  readback %ux%u\n", ((VkImage_T *)c.p[0])->ci.extent.width, ((VkImage_T *)c.p[0])->ci.extent.height); break;
    default: break;
    }
    flush();
}
static VkResult VKAPI_CALL vkm_QueueSubmit(VkQueue q, uint32_t n, const VkSubmitInfo *si, VkFence fence)
{
    for (uint32_t k = 0; k < n; k++) for (uint32_t j = 0; j < si[k].commandBufferCount; j++) trace(si[k].pCommandBuffers[j]);
    VkDevice_T *d = q->d; id<MTLCommandBuffer> last = nil;
    @autoreleasepool {
        for (uint32_t k = 0; k < n; k++) {
            if (!si[k].commandBufferCount) continue;
            Enc e; e.cb = [d->q commandBuffer];
            for (uint32_t j = 0; j < si[k].commandBufferCount; j++) encode(e, si[k].pCommandBuffers[j]);
            if (last) [last commit];                      /* each committed once the next exists: the last takes the fence first */
            last = e.cb;
        }
        if (!last && fence) last = [d->q commandBuffer];    /* a submission with nothing in it still signals its fence in order */
        if (fence) { VkFence_T *f = fence; [last addCompletedHandler:^(id<MTLCommandBuffer>) { signal(f); }]; }   /* before commit, as Metal requires */
        if (last) { [last commit]; std::lock_guard<std::mutex> g(d->m); d->last = last; }
    }
    return VK_SUCCESS;
}

// ---------------------------------------------------------------- swapchain and present
static VkResult VKAPI_CALL vkm_CreateSwapchainKHR(VkDevice d, const VkSwapchainCreateInfoKHR *ci, const VkAllocationCallbacks *, VkSwapchainKHR *out)
{
    VkSwapchainKHR_T *o = new VkSwapchainKHR_T(); o->surf = ci->surface; o->ext = ci->imageExtent; o->next = 0;
    uint32_t n = ci->minImageCount < 2 ? 2 : ci->minImageCount > 3 ? 3 : ci->minImageCount;
    CAMetalLayer *l = o->surf->layer; VkExtent2D ext = ci->imageExtent;
    l.framebufferOnly = NO; l.drawableSize = CGSizeMake(ext.width, ext.height); l.maximumDrawableCount = 3;   /* the present copies into the drawable */
    for (uint32_t k = 0; k < n; k++) {
        VkImageCreateInfo ic = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; ic.imageType = VK_IMAGE_TYPE_2D; ic.format = ci->imageFormat;
        ic.extent = {ci->imageExtent.width, ci->imageExtent.height, 1}; ic.mipLevels = 1; ic.arrayLayers = 1; ic.samples = VK_SAMPLE_COUNT_1_BIT;
        ic.tiling = VK_IMAGE_TILING_OPTIMAL; ic.usage = ci->imageUsage;
        VkImage im = 0; if (vkm_CreateImage(d, &ic, 0, &im) != VK_SUCCESS) { delete o; return VK_ERROR_INITIALIZATION_FAILED; }
        im->swap = 1; o->img.push_back(im);
    }
    if (ci->oldSwapchain) { for (auto *im : ci->oldSwapchain->img) delete im; delete ci->oldSwapchain; }
    fprintf(stderr, "vkm: swapchain %ux%u, %u images\n", ci->imageExtent.width, ci->imageExtent.height, n);
    *out = o; return VK_SUCCESS;
}
static void VKAPI_CALL vkm_DestroySwapchainKHR(VkDevice, VkSwapchainKHR s, const VkAllocationCallbacks *) { if (s) { for (auto *im : s->img) delete im; delete s; } }
static VkResult VKAPI_CALL vkm_GetSwapchainImagesKHR(VkDevice, VkSwapchainKHR s, uint32_t *count, VkImage *p)
{
    uint32_t n = (uint32_t)s->img.size();
    if (!p) { *count = n; return VK_SUCCESS; }
    uint32_t w = *count < n ? *count : n; for (uint32_t k = 0; k < w; k++) p[k] = s->img[k];
    *count = w; return w < n ? VK_INCOMPLETE : VK_SUCCESS;
}
static VkResult VKAPI_CALL vkm_AcquireNextImageKHR(VkDevice, VkSwapchainKHR s, uint64_t, VkSemaphore, VkFence f, uint32_t *index)
{
    *index = s->next; s->next = (s->next + 1) % (uint32_t)s->img.size();
    if (f) signal(f);
    return VK_SUCCESS;
}
/* SIMS_FPS=<n>: at most n frames a second (the launch window's Frame Rate row); otherwise the display's own rate, which
 * the drawables (vertical sync) set */
static void pace(void)
{
    static double period = -1, next; struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); double now = t.tv_sec + t.tv_nsec * 1e-9;
    if (period < 0) { const char *f = getenv("SIMS_FPS"); period = f && atof(f) >= 10 ? 1.0 / atof(f) : 0; next = now; }
    if (period <= 0) return;
    if (next > now) { double d = next - now; struct timespec w = {(time_t)d, (long)((d - (time_t)d) * 1e9)}; nanosleep(&w, 0); now = next; }
    next = (next + period > now - period) ? next + period : now + period;   /* fall behind by a frame at most */
}
static VkResult VKAPI_CALL vkm_QueuePresentKHR(VkQueue q, const VkPresentInfoKHR *pi)
{
    presented++;
    VkDevice_T *d = q->d;
    @autoreleasepool {
        for (uint32_t k = 0; k < pi->swapchainCount; k++) {
            VkSwapchainKHR_T *s = pi->pSwapchains[k]; VkImage_T *im = s->img[pi->pImageIndices[k]];
            CAMetalLayer *l = s->surf->layer;
            if (l.drawableSize.width != s->ext.width || l.drawableSize.height != s->ext.height) l.drawableSize = CGSizeMake(s->ext.width, s->ext.height);   /* a resized window: the game's size still */
            pace();
            id<CAMetalDrawable> dr = [l nextDrawable];
            if (!dr) { if (pi->pResults) pi->pResults[k] = VK_SUCCESS; continue; }
            id<MTLCommandBuffer> cb = [d->q commandBuffer];
            id<MTLTexture> t = dr.texture; NSUInteger w = t.width < im->tex.width ? t.width : im->tex.width, h = t.height < im->tex.height ? t.height : im->tex.height;
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromTexture:im->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                      toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [be endEncoding];
            [cb presentDrawable:dr]; [cb commit];
            { std::lock_guard<std::mutex> g(d->m); d->last = cb; }
            if (pi->pResults) pi->pResults[k] = VK_SUCCESS;
        }
    }
    return VK_SUCCESS;
}

// ---------------------------------------------------------------- the table
static PFN_vkVoidFunction VKAPI_CALL vkm_GetInstanceProcAddr(VkInstance, const char *name);
static PFN_vkVoidFunction VKAPI_CALL vkm_GetDeviceProcAddr(VkDevice, const char *name) { return vkm_GetInstanceProcAddr(0, name); }
#define E(n) {"vk" #n, (PFN_vkVoidFunction)vkm_##n}
static const struct { const char *name; PFN_vkVoidFunction fn; } table[] = {
    E(GetInstanceProcAddr), E(GetDeviceProcAddr), E(EnumerateInstanceExtensionProperties), E(EnumerateInstanceLayerProperties), E(CreateInstance), E(DestroyInstance),
    E(EnumeratePhysicalDevices), E(GetPhysicalDeviceProperties), E(GetPhysicalDeviceProperties2), E(GetPhysicalDeviceFeatures), E(GetPhysicalDeviceFeatures2),
    E(GetPhysicalDeviceQueueFamilyProperties), E(GetPhysicalDeviceMemoryProperties), E(GetPhysicalDeviceMemoryProperties2), E(GetPhysicalDeviceFormatProperties),
    E(CreateMetalSurfaceEXT), E(DestroySurfaceKHR), E(GetPhysicalDeviceSurfaceSupportKHR), E(GetPhysicalDeviceSurfaceCapabilitiesKHR), E(GetPhysicalDeviceSurfaceFormatsKHR),
    E(GetPhysicalDeviceSurfacePresentModesKHR), E(EnumerateDeviceExtensionProperties), E(EnumerateDeviceLayerProperties), E(CreateDevice), E(DestroyDevice), E(GetDeviceQueue),
    E(DeviceWaitIdle), E(QueueWaitIdle), E(GetMemoryHostPointerPropertiesEXT), E(AllocateMemory), E(FreeMemory), E(MapMemory), E(UnmapMemory), E(FlushMappedMemoryRanges),
    {"vkInvalidateMappedMemoryRanges", (PFN_vkVoidFunction)vkm_FlushMappedMemoryRanges},
    E(CreateBuffer), E(DestroyBuffer), E(GetBufferMemoryRequirements), E(BindBufferMemory), E(CreateImage), E(DestroyImage), E(GetImageMemoryRequirements), E(BindImageMemory),
    E(CreateImageView), E(DestroyImageView), E(CreateSampler), E(DestroySampler), E(CreateDescriptorSetLayout), E(DestroyDescriptorSetLayout), E(CreateDescriptorPool),
    E(DestroyDescriptorPool), E(AllocateDescriptorSets), E(FreeDescriptorSets), E(UpdateDescriptorSets), E(CreatePipelineLayout), E(DestroyPipelineLayout), E(CreateRenderPass),
    E(DestroyRenderPass), E(CreateFramebuffer), E(DestroyFramebuffer), E(CreateShaderModule), E(DestroyShaderModule), E(CreateGraphicsPipelines), E(DestroyPipeline),
    E(CreateFence), E(DestroyFence), E(ResetFences), E(GetFenceStatus), E(WaitForFences), E(CreateSemaphore), E(DestroySemaphore), E(CreateCommandPool), E(DestroyCommandPool),
    E(ResetCommandPool), E(AllocateCommandBuffers), E(FreeCommandBuffers), E(BeginCommandBuffer), E(EndCommandBuffer), E(ResetCommandBuffer), E(CmdBeginRenderPass),
    E(CmdEndRenderPass), E(CmdNextSubpass), E(CmdBindPipeline), E(CmdBindVertexBuffers), E(CmdBindIndexBuffer), E(CmdBindDescriptorSets), E(CmdPushConstants), E(CmdDraw),
    E(CmdDrawIndexed), E(CmdSetViewport), E(CmdSetScissor), E(CmdClearColorImage), E(CmdClearDepthStencilImage), E(CmdClearAttachments), E(CmdCopyBuffer), E(CmdCopyBufferToImage),
    E(CmdCopyImageToBuffer), E(CmdBlitImage), E(CmdCopyImage), E(CmdPipelineBarrier), E(QueueSubmit), E(CreateSwapchainKHR), E(DestroySwapchainKHR), E(GetSwapchainImagesKHR),
    E(AcquireNextImageKHR), E(QueuePresentKHR),
};
#undef E
static PFN_vkVoidFunction VKAPI_CALL vkm_GetInstanceProcAddr(VkInstance, const char *name)
{
    for (auto &t : table) if (!strcmp(t.name, name)) return t.fn;
    size_t l = strlen(name);                                /* a KHR name for the core command */
    if (l > 3 && !strcmp(name + l - 3, "KHR")) { std::string core(name, l - 3); for (auto &t : table) if (core == t.name) return t.fn; }
    if (getenv("VKM_LOG")) once((std::string(name) + ": not here (the game never calls it)").c_str());
    return 0;
}
extern "C" PFN_vkGetInstanceProcAddr vkm_loader(void) { return vkm_GetInstanceProcAddr; }

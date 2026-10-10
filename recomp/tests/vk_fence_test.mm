// Exercise the real Vulkan-on-Metal fence implementation without game assets.
#import "../host/vk_metal.mm"
#include <assert.h>
#include <thread>
using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point start) { return std::chrono::duration<double, std::milli>(Clock::now() - start).count(); }
int main(void)
{
    VkFenceCreateInfo ci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence f[2];
    assert(vkm_CreateFence(nullptr, &ci, nullptr, &f[0]) == VK_SUCCESS);
    assert(vkm_CreateFence(nullptr, &ci, nullptr, &f[1]) == VK_SUCCESS);
    auto t = Clock::now();
    assert(vkm_WaitForFences(nullptr, 1, f, VK_TRUE, 1000000) == VK_TIMEOUT);
    double elapsed = ms(t); printf("1 ms timeout took %.3f ms\n", elapsed); fflush(stdout);
    assert(elapsed < 30); // The old implementation unconditionally waited 50 ms.
    signal(f[0]); assert(vkm_WaitForFences(nullptr, 1, f, VK_TRUE, 0) == VK_SUCCESS);
    vkm_ResetFences(nullptr, 2, f);
    std::thread worker([&] { std::this_thread::sleep_for(std::chrono::milliseconds(2)); signal(f[1]); });
    assert(vkm_WaitForFences(nullptr, 2, f, VK_FALSE, 1000000000) == VK_SUCCESS); worker.join();
    t = Clock::now(); assert(vkm_WaitForFences(nullptr, 2, f, VK_TRUE, 1000000) == VK_TIMEOUT); assert(ms(t) < 30);
    signal(f[0]); assert(vkm_WaitForFences(nullptr, 2, f, VK_TRUE, 0) == VK_SUCCESS);
    for (int k = 0; k < 100; k++) {
        vkm_ResetFences(nullptr, 1, f);
        std::thread wake([&] { signal(f[0]); });
        assert(vkm_WaitForFences(nullptr, 1, f, VK_TRUE, 1000000000) == VK_SUCCESS); wake.join();
    }
    for (int k = 0; k < 300; k++) {
        VkFence temporary; assert(vkm_CreateFence(nullptr, &ci, nullptr, &temporary) == VK_SUCCESS);
        std::thread wake([temporary] { signal(temporary); });
        assert(vkm_WaitForFences(nullptr, 1, &temporary, VK_TRUE, 1000000000) == VK_SUCCESS);
        vkm_DestroyFence(nullptr, temporary, nullptr); // Legal once observed signaled; notification must be finished.
        wake.join();
    }
    vkm_DestroyFence(nullptr, f[0], nullptr); vkm_DestroyFence(nullptr, f[1], nullptr);
    puts("Vulkan fences: finite timeout, already signaled, wait-any/all and concurrent completion passed");
    return 0;
}

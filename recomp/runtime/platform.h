/* Host services shared by the Linux and macOS runtimes. */
#ifndef DS_PLATFORM_H
#define DS_PLATFORM_H
#include <stdint.h>
#include <time.h>
#include <unistd.h>
static inline uint64_t ds_clock_ns(void) {
    struct timespec ts;
#ifdef __APPLE__
    clock_gettime(CLOCK_UPTIME_RAW, &ts);              /* stops while the Mac sleeps (no false hang reports on waking) */
#else
    clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static inline uint32_t ds_page_size(void) { return (uint32_t)sysconf(_SC_PAGESIZE); }
static inline uint32_t ds_cpu_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n < 1 ? 1 : n > 32 ? 32 : (uint32_t)n;
}
#endif

// SimsNative: the recompiled The Sims Legacy Collection as a native macOS app. The game runs on its own thread
// (recompiled code + Win32 layer) and draws with Vulkan, which runtime/win32/vulkan.c hands to MoltenVK; this file
// provides the window (a CAMetalLayer the game's swapchain presents to), the Vulkan loader and surface, input (the
// system cursor and keyboard -> Windows messages and key state), and crash reports.
//   SimsNative --exe <unwrapped Sims.exe> --game <game folder> --data <folder for C: and saved files>
//   With no arguments (opened as an app) it reads them from Contents/Resources/launch.plist (install.sh writes it).
// Test mode (DS_TEST=1): a 1024x768 background window, the game's screen is that size; DS_SCRIPT="800:click:x,y;..."
// and DS_CMDFILE=<file> (move, click, rclick, key, shot lines) as on Linux (host/linux.c); W32_VK_SHOT as everywhere.
//
// NOTE (2026-10-07): written on Linux, where it couldn't be compiled; the first Mac session builds and fixes it.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#ifndef DS_BUILD
#define DS_BUILD "dev"
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <sys/stat.h>
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#include "../runtime/win32/w32.h"

int  w32_prepare(const char *exe, const char *game_dir, const char *drive_c, const char *overlay);
uint32_t w32_run(char *msg, size_t cap);
void w32_post(uint32_t tid, uint32_t hwnd, uint32_t msg, uint32_t wp, uint32_t lp);
void w32_set_cursor(int x, int y); void w32_get_cursor(int *x, int *y); void w32_relative_cursor(int enabled);
uint32_t w32_window_tid(uint32_t hwnd);
extern uint8_t w32_keys[256];
extern int w32_screen_w, w32_screen_h; extern double w32_screen_scale;
extern void (*w32_host_window_created)(uint32_t, int, int, int, int, uint32_t);
extern void (*w32_host_window_changed)(uint32_t, int, int, int, int, int);
extern PFN_vkGetInstanceProcAddr (*w32_host_vk_loader)(void);
extern unsigned (*w32_host_vk_extensions)(const char **names, unsigned cap);
extern int (*w32_host_vk_surface)(VkInstance instance, VkSurfaceKHR *surface);
extern void (*w32_host_vk_presented)(void);
extern char w32_vk_shot_req[1024];
void w32_crash_init(const char *data_dir, const char *build); void w32_crash_thread(const char *name);
void w32_crash_heartbeat(int which); const char *w32_crash_last_path(void);
const char *w32_crash_report(const char *kind, const char *reason, Ctx *c, uint32_t guest_pc);
void w32_registry_install(const char *data_dir);

static CAMetalLayer *layer; static NSWindow *win; static NSView *view; static uint32_t game_hwnd;
static volatile int game_running = 1; static int test_mode;
static char exe_dir[1024];

// ---------------------------------------------------------------- Vulkan: MoltenVK and the window's surface
static PFN_vkGetInstanceProcAddr gipa;
static PFN_vkGetInstanceProcAddr vk_loader(void)
{
    if (gipa) return gipa;
    char p[1200]; const char *env = getenv("SIMS_MOLTENVK");
    const char *tries[] = {env, "", "", "/opt/homebrew/lib/libMoltenVK.dylib", "/usr/local/lib/libMoltenVK.dylib",
                           "libvulkan.1.dylib", "/opt/homebrew/lib/libvulkan.1.dylib", "/usr/local/lib/libvulkan.1.dylib", 0};
    for (int k = 0; k < 8; k++) {
        const char *t = tries[k];
        if (k == 1) { snprintf(p, sizeof p, "%s/../Frameworks/libMoltenVK.dylib", exe_dir); t = p; }   // inside the app
        if (k == 2) { snprintf(p, sizeof p, "%s/libMoltenVK.dylib", exe_dir); t = p; }                // beside the binary
        if (!t || !*t) continue;
        void *h = dlopen(t, RTLD_NOW | RTLD_LOCAL); if (!h) continue;
        gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
        if (gipa) { fprintf(stderr, "SimsNative: Vulkan from %s\n", t); break; }
    }
    if (!gipa) fprintf(stderr, "SimsNative: MoltenVK not found (brew install molten-vk, or SIMS_MOLTENVK=<path>)\n");
    return gipa;
}
static unsigned vk_extensions(const char **names, unsigned cap)
{
    if (cap < 2) return 0;
    names[0] = "VK_KHR_surface"; names[1] = "VK_EXT_metal_surface"; return 2;
}
static int vk_surface(VkInstance instance, VkSurfaceKHR *surface)
{
    PFN_vkCreateMetalSurfaceEXT create = (PFN_vkCreateMetalSurfaceEXT)gipa(instance, "vkCreateMetalSurfaceEXT");
    if (!create) { fprintf(stderr, "SimsNative: no vkCreateMetalSurfaceEXT\n"); return -1; }
    VkMetalSurfaceCreateInfoEXT ci = {0}; ci.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT; ci.pLayer = layer;
    return create(instance, &ci, 0, surface) == VK_SUCCESS ? 0 : -1;
}

// ---------------------------------------------------------------- input
typedef struct { uint8_t vk, scan, ext; } Key;
static Key keymap[128];
static void init_keymap(void)
{
    static const uint8_t t[][4] = {   // macOS keycode, VK, scan, extended (as host/main.m)
        {0x00,'A',0x1e,0},{0x01,'S',0x1f,0},{0x02,'D',0x20,0},{0x03,'F',0x21,0},{0x04,'H',0x23,0},{0x05,'G',0x22,0},{0x06,'Z',0x2c,0},
        {0x07,'X',0x2d,0},{0x08,'C',0x2e,0},{0x09,'V',0x2f,0},{0x0b,'B',0x30,0},{0x0c,'Q',0x10,0},{0x0d,'W',0x11,0},{0x0e,'E',0x12,0},
        {0x0f,'R',0x13,0},{0x10,'Y',0x15,0},{0x11,'T',0x14,0},{0x12,'1',0x02,0},{0x13,'2',0x03,0},{0x14,'3',0x04,0},{0x15,'4',0x05,0},
        {0x16,'6',0x07,0},{0x17,'5',0x06,0},{0x18,0xbb,0x0d,0},{0x19,'9',0x0a,0},{0x1a,'7',0x08,0},{0x1b,0xbd,0x0c,0},{0x1c,'8',0x09,0},
        {0x1d,'0',0x0b,0},{0x1e,0xdd,0x1b,0},{0x1f,'O',0x18,0},{0x20,'U',0x16,0},{0x21,0xdb,0x1a,0},{0x22,'I',0x17,0},{0x23,'P',0x19,0},
        {0x24,0x0d,0x1c,0},{0x25,'L',0x26,0},{0x26,'J',0x24,0},{0x27,0xde,0x28,0},{0x28,'K',0x25,0},{0x29,0xba,0x27,0},{0x2a,0xdc,0x2b,0},
        {0x2b,0xbc,0x33,0},{0x2c,0xbf,0x35,0},{0x2d,'N',0x31,0},{0x2e,'M',0x32,0},{0x2f,0xbe,0x34,0},{0x30,0x09,0x0f,0},{0x31,0x20,0x39,0},
        {0x32,0xc0,0x29,0},{0x33,0x08,0x0e,0},{0x35,0x1b,0x01,0},{0x38,0x10,0x2a,0},{0x39,0x14,0x3a,0},{0x3a,0x12,0x38,0},{0x3b,0x11,0x1d,0},
        {0x3c,0x10,0x36,0},{0x3d,0x12,0x38,1},{0x3e,0x11,0x1d,1},{0x7a,0x70,0x3b,0},{0x78,0x71,0x3c,0},{0x63,0x72,0x3d,0},{0x76,0x73,0x3e,0},
        {0x60,0x74,0x3f,0},{0x61,0x75,0x40,0},{0x62,0x76,0x41,0},{0x64,0x77,0x42,0},{0x65,0x78,0x43,0},{0x6d,0x79,0x44,0},{0x67,0x7a,0x57,0},
        {0x6f,0x7b,0x58,0},{0x73,0x24,0x47,1},{0x74,0x21,0x49,1},{0x75,0x2e,0x53,1},{0x77,0x23,0x4f,1},{0x79,0x22,0x51,1},{0x7b,0x25,0x4b,1},
        {0x7c,0x27,0x4d,1},{0x7d,0x28,0x50,1},{0x7e,0x26,0x48,1},{0x52,0x60,0x52,0},{0x53,0x61,0x4f,0},{0x54,0x62,0x50,0},{0x55,0x63,0x51,0},
        {0x56,0x64,0x4b,0},{0x57,0x65,0x4c,0},{0x58,0x66,0x4d,0},{0x59,0x67,0x47,0},{0x5b,0x68,0x48,0},{0x5c,0x69,0x49,0},{0x41,0x6e,0x53,0},
        {0x43,0x6a,0x37,0},{0x45,0x6b,0x4e,0},{0x4e,0x6d,0x4a,0},{0x4b,0x6f,0x35,1},{0x4c,0x0d,0x1c,1}};
    for (size_t k = 0; k < sizeof t / sizeof *t; k++) { keymap[t[k][0]].vk = t[k][1]; keymap[t[k][0]].scan = t[k][2]; keymap[t[k][0]].ext = t[k][3]; }
}
static uint32_t buttons;               // MK_ flags
static void post(uint32_t msg, uint32_t wp, uint32_t lp) { if (game_hwnd) w32_post(w32_window_tid(game_hwnd), game_hwnd, msg, wp, lp); }
static uint32_t mk(void)
{
    NSEventModifierFlags f = NSEvent.modifierFlags;
    return buttons | ((f & NSEventModifierFlagShift) ? 4 : 0) | ((f & NSEventModifierFlagControl) ? 8 : 0);
}
static uint32_t pos_lp(void) { int x, y; w32_get_cursor(&x, &y); return ((uint32_t)y << 16) | ((uint32_t)x & 0xffff); }
static void key_event(uint16_t code, int down, int repeat)
{
    if (code >= 128 || !keymap[code].vk) return;
    Key k = keymap[code]; int alt = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    uint32_t prev = (w32_keys[k.vk] & 0x80) ? 1 : 0;
    w32_keys[k.vk] = down ? (uint8_t)(0x80 | ((w32_keys[k.vk] & 1) ^ (repeat ? 0 : 1))) : (uint8_t)(w32_keys[k.vk] & 1);
    if (k.vk == 0x10) w32_keys[code == 0x3c ? 0xa1 : 0xa0] = w32_keys[0x10];
    if (k.vk == 0x11) w32_keys[k.ext ? 0xa3 : 0xa2] = w32_keys[0x11];
    if (k.vk == 0x12) w32_keys[k.ext ? 0xa5 : 0xa4] = w32_keys[0x12];
    uint32_t lp = 1u | ((uint32_t)k.scan << 16) | ((uint32_t)k.ext << 24) | (prev << 30) | (down ? 0 : 0x80000000u);
    int sys = alt || k.vk == 0x12;
    post(down ? (sys ? 0x104u : 0x100u) : (sys ? 0x105u : 0x101u), k.vk, lp);
}

@interface GameWindow : NSWindow @end
@implementation GameWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
@interface GameView : NSView @end
@implementation GameView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer *)makeBackingLayer { return layer; }
/* The Sims shows the system cursor and reads GetCursorPos: the pointer's place in the view, scaled to the game's
 * screen (its window covers it) */
- (void)moved:(NSEvent *)e
{
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSSize s = self.bounds.size;
    if (s.width < 1 || s.height < 1) return;
    int x = (int)(p.x * w32_screen_w / s.width), y = (int)((s.height - p.y) * w32_screen_h / s.height);
    if (x < 0) x = 0; if (y < 0) y = 0; if (x >= w32_screen_w) x = w32_screen_w - 1; if (y >= w32_screen_h) y = w32_screen_h - 1;
    w32_set_cursor(x, y); post(0x200, mk(), pos_lp());
}
- (void)mouseMoved:(NSEvent *)e { [self moved:e]; }
- (void)mouseDragged:(NSEvent *)e { [self moved:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self moved:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self moved:e]; }
- (void)mouseDown:(NSEvent *)e { [self moved:e]; buttons |= 1; w32_keys[1] = 0x80; post(e.clickCount == 2 ? 0x203 : 0x201, mk(), pos_lp()); }
- (void)mouseUp:(NSEvent *)e { [self moved:e]; buttons &= ~1u; w32_keys[1] = 0; post(0x202, mk(), pos_lp()); }
- (void)rightMouseDown:(NSEvent *)e { [self moved:e]; buttons |= 2; w32_keys[2] = 0x80; post(e.clickCount == 2 ? 0x206 : 0x204, mk(), pos_lp()); }
- (void)rightMouseUp:(NSEvent *)e { [self moved:e]; buttons &= ~2u; w32_keys[2] = 0; post(0x205, mk(), pos_lp()); }
- (void)otherMouseDown:(NSEvent *)e { buttons |= 0x10; w32_keys[4] = 0x80; post(0x207, mk(), pos_lp()); }
- (void)otherMouseUp:(NSEvent *)e { buttons &= ~0x10u; w32_keys[4] = 0; post(0x208, mk(), pos_lp()); }
- (void)scrollWheel:(NSEvent *)e
{
    static double acc; acc += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 10.0 : e.scrollingDeltaY;
    while (acc >= 1 || acc <= -1) { int d = acc > 0 ? 1 : -1; acc -= d; post(0x20a, ((uint32_t)(int16_t)(120 * d) << 16) | mk(), pos_lp()); }
}
- (void)keyDown:(NSEvent *)e
{
    if (e.modifierFlags & NSEventModifierFlagCommand) { [super keyDown:e]; return; }
    key_event(e.keyCode, 1, e.ARepeat);
    NSString *s = e.characters;
    for (NSUInteger k = 0; k < s.length; k++) {
        unichar ch = [s characterAtIndex:k]; uint8_t b; uint16_t w = ch;
        if (ch >= 0xf700) continue;                                   // function keys
        if (w32_wide_to_mb(1252, &w, 1, &b, 1) == 1) post(0x102, b, 1);
    }
}
- (void)keyUp:(NSEvent *)e { key_event(e.keyCode, 0, 0); }
- (void)flagsChanged:(NSEvent *)e
{
    static const struct { uint16_t code; NSEventModifierFlags flag; } mods[] = {
        {0x38, NSEventModifierFlagShift}, {0x3c, NSEventModifierFlagShift}, {0x3b, NSEventModifierFlagControl}, {0x3e, NSEventModifierFlagControl},
        {0x3a, NSEventModifierFlagOption}, {0x3d, NSEventModifierFlagOption}, {0x39, NSEventModifierFlagCapsLock}};
    for (size_t k = 0; k < sizeof mods / sizeof *mods; k++) if (mods[k].code == e.keyCode)
        key_event(e.keyCode, (e.modifierFlags & mods[k].flag) != 0, 0);
}
@end

// ---------------------------------------------------------------- test scripts (a subset of host/linux.c's)
typedef struct { uint32_t frame; char kind[8]; int x, y, phase; char path[600]; } Act;
static Act acts[4096]; static int nacts; static pthread_mutex_t act_m = PTHREAD_MUTEX_INITIALIZER;
static void add_act(uint32_t frame, const char *kind, const char *rest)
{
    if (nacts >= 4096) return;
    Act *a = &acts[nacts]; memset(a, 0, sizeof *a); a->frame = frame; snprintf(a->kind, sizeof a->kind, "%s", kind);
    if (!strcmp(kind, "shot")) snprintf(a->path, sizeof a->path, "%s", rest); else sscanf(rest, "%d,%d", &a->x, &a->y);
    nacts++;
}
static void parse_script(void)
{
    const char *e = getenv("DS_SCRIPT"); if (!e) return;
    char *s = strdup(e), *save, *tok = strtok_r(s, ";", &save);
    while (tok) { unsigned f; char kind[8] = "", rest[600] = ""; if (sscanf(tok, "%u:%7[a-z]:%599[^\n]", &f, kind, rest) >= 2) add_act(f, kind, rest); tok = strtok_r(0, ";", &save); }
    free(s);
}
static void cmdfile_poll(uint32_t fno)
{
    static const char *path; static off_t pos; static int init;
    if (!init) { init = 1; path = getenv("DS_CMDFILE"); }
    if (!path || fno % 15) return;
    FILE *f = fopen(path, "r"); if (!f) return;
    fseeko(f, pos, SEEK_SET); char line[700];
    while (fgets(line, sizeof line, f)) {
        size_t l = strlen(line); if (!l || line[l - 1] != '\n') break;
        pos += (off_t)l; line[l - 1] = 0; char kind[8] = "", rest[600] = "";
        if (sscanf(line, "%7[a-z]:%599[^\n]", kind, rest) >= 1 && kind[0]) { add_act(fno + 1, kind, rest); fprintf(stderr, "host: command %s\n", line); }
    }
    fclose(f);
}
static void script_tick(uint32_t fno)                     // on the game thread, once per presented frame
{
    pthread_mutex_lock(&act_m);
    cmdfile_poll(fno);
    for (int k = 0; k < nacts; k++) {
        Act *a = &acts[k];
        if (!strcmp(a->kind, "move") && fno == a->frame) { w32_set_cursor(a->x, a->y); post(0x200, mk(), pos_lp()); }
        else if (!strcmp(a->kind, "click") || !strcmp(a->kind, "rclick")) {
            int r = a->kind[0] == 'r';
            if (fno == a->frame) { w32_set_cursor(a->x, a->y); post(0x200, mk(), pos_lp()); }
            if (fno == a->frame + 20) { w32_keys[r ? 2 : 1] = 0x80; post(r ? 0x204 : 0x201, r ? 2 : 1, pos_lp()); }
            if (fno == a->frame + 24) { w32_keys[r ? 2 : 1] = 0; post(r ? 0x205 : 0x202, 0, pos_lp()); }
        } else if (!strcmp(a->kind, "key")) {
            if (fno == a->frame) { w32_keys[a->x & 0xff] = 0x80; post(0x100, (uint32_t)a->x, 1); }
            if (fno == a->frame + 3) { w32_keys[a->x & 0xff] = 0; post(0x101, (uint32_t)a->x, 0xc0000001u); }
        } else if (!strcmp(a->kind, "shot") && fno == a->frame) snprintf(w32_vk_shot_req, sizeof w32_vk_shot_req, "%s", a->path);
    }
    pthread_mutex_unlock(&act_m);
}
static volatile uint32_t frames;
static void vk_presented(void)
{
    uint32_t f = __atomic_add_fetch(&frames, 1, __ATOMIC_RELEASE);
    w32_crash_heartbeat(3);
    if (test_mode) script_tick(f);
}

// ---------------------------------------------------------------- window
static void window_created(uint32_t hwnd, int x, int y, int w, int h, uint32_t style)
{
    (void)x; (void)y; (void)w; (void)h; (void)style;
    if (game_hwnd) return;                                            // the game has one top-level window
    game_hwnd = hwnd;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSRect f = NSScreen.mainScreen.frame;
        NSWindowStyleMask sm = NSWindowStyleMaskBorderless;
        if (test_mode) { f = NSMakeRect(80, 80, w32_screen_w, w32_screen_h); sm = NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable; }
        win = [[GameWindow alloc] initWithContentRect:f styleMask:sm backing:NSBackingStoreBuffered defer:NO];
        win.releasedWhenClosed = NO;
        f.origin = NSZeroPoint;
        win.title = @"The Sims"; win.backgroundColor = NSColor.blackColor; win.acceptsMouseMovedEvents = YES;
        view = [[GameView alloc] initWithFrame:f]; view.wantsLayer = YES;
        win.contentView = view; [win makeFirstResponder:view];
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    });
}
static void window_changed(uint32_t hwnd, int x, int y, int w, int h, int visible)
{
    (void)x; (void)y; (void)w; (void)h;
    if (hwnd != game_hwnd) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!win) return;
        if (visible && !win.visible) {
            if (test_mode) [win orderBack:nil];
            else {
                [NSApp setPresentationOptions:NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar];
                [win makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
            }
        }
        else if (!visible && win.visible) [win orderOut:nil];
    });
}

@interface AppDelegate : NSObject <NSApplicationDelegate> @end
@implementation AppDelegate
- (void)applicationDidBecomeActive:(NSNotification *)n { (void)n; post(0x1c, 1, 0); }
- (void)applicationDidResignActive:(NSNotification *)n { (void)n; post(0x1c, 0, 0); }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)s { (void)s; return NSTerminateNow; }
@end

static void show_report_alert(NSString *title, NSString *path)
{
    NSAlert *al = [NSAlert new]; al.alertStyle = NSAlertStyleWarning; al.messageText = title;
    al.informativeText = [NSString stringWithFormat:@"A report was saved:\n%@\n\nIt says what the game was doing, so the problem can be found and fixed.", path];
    [al addButtonWithTitle:@"Show Report"]; [al addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([al runModal] == NSAlertFirstButtonReturn) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
}
static void *game_thread(void *arg)
{
    (void)arg; char msg[256];
    uint32_t code = w32_run(msg, sizeof msg);
    fprintf(stderr, "SimsNative: game ended: %s\n", msg);
    game_running = 0;
    const char *rp = !strncmp(msg, "fault", 5) ? w32_crash_last_path() : 0;
    NSString *path = rp ? @(rp) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (path && !test_mode) {
            [win orderOut:nil]; [NSApp setPresentationOptions:NSApplicationPresentationDefault];
            show_report_alert(@"The Sims stopped unexpectedly.", path);
        }
        _exit((int)code);       // no teardown: the Vulkan device and the game's threads are still live
    });
    return 0;
}
static void on_objc_exception(NSException *e)
{
    char r[400]; snprintf(r, sizeof r, "The macOS side of the program raised an Objective-C exception: %s: %s.", e.name.UTF8String, e.reason.UTF8String ?: "");
    w32_crash_report("crash", r, 0, 0);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        const char *exe = 0, *game = 0, *data = 0;
        for (int k = 1; k + 1 < argc; k += 2) {
            if (!strcmp(argv[k], "--exe")) exe = argv[k + 1];
            else if (!strcmp(argv[k], "--game")) game = argv[k + 1];
            else if (!strcmp(argv[k], "--data")) data = argv[k + 1];
        }
        NSString *bin = [[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent];
        snprintf(exe_dir, sizeof exe_dir, "%s", bin.UTF8String);
        NSString *log = nil;
        if (!exe) {                                                   // opened as an app: install.sh's settings
            NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:[bin stringByAppendingPathComponent:@"../Resources/launch.plist"]];
            NSString *g = pl[@"game"], *d = pl[@"data"]; log = pl[@"log"];
            if (g && d) { game = strdup(g.UTF8String); data = strdup(d.UTF8String);
                          exe = strdup([bin stringByAppendingPathComponent:@"../Resources/Sims.exe"].UTF8String); }
        }
        if (!exe || !game || !data) { fprintf(stderr, "usage: SimsNative --exe <Sims.exe> --game <game folder> --data <data folder>\n"); return 1; }
        if (log && !getenv("DS_TEST")) {                              // the app's log, in the data folder
            NSString *lp = [NSString stringWithFormat:@"%s/%@.log", data, log]; mkdir(data, 0755);
            freopen(lp.UTF8String, "a", stderr); setenv("DS_LOG_FILE", lp.UTF8String, 1);
        }
        char drive_c[1024], overlay[1024];
        snprintf(drive_c, sizeof drive_c, "%s/drive_c", data); snprintf(overlay, sizeof overlay, "%s/game", data);
        mkdir(data, 0755); mkdir(drive_c, 0755); mkdir(overlay, 0755);
        test_mode = getenv("DS_TEST") && atoi(getenv("DS_TEST"));
        /* the game's screen: the display in points (the game sizes its frame and interface to it), the test window's
         * 1024x768 in test mode, or DS_RESOLUTION=WxH */
        NSRect sf = NSScreen.mainScreen.frame; w32_screen_w = (int)sf.size.width; w32_screen_h = (int)sf.size.height;
        if (test_mode) { w32_screen_w = 1024; w32_screen_h = 768; }
        { const char *r = getenv("DS_RESOLUTION"); int rw, rh; if (r && sscanf(r, "%dx%d", &rw, &rh) == 2 && rw >= 800 && rh >= 600) { w32_screen_w = rw; w32_screen_h = rh; } }
        w32_screen_scale = 1;
        init_keymap();
        w32_crash_init(data, DS_BUILD); w32_crash_thread("macOS UI thread");
        w32_registry_install(data);
        NSSetUncaughtExceptionHandler(on_objc_exception);
        if (test_mode) parse_script();

        [NSApplication sharedApplication]; [NSApp setActivationPolicy:test_mode ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular];
        AppDelegate *del = [AppDelegate new]; NSApp.delegate = del;
        NSMenu *bar = [NSMenu new], *appm = [NSMenu new]; NSMenuItem *it = [NSMenuItem new]; it.submenu = appm; [bar addItem:it];
        [appm addItemWithTitle:@"Quit The Sims" action:@selector(terminate:) keyEquivalent:@"q"]; NSApp.mainMenu = bar;

        /* The layer exists before the game makes its window, sized to the game's screen at one pixel per point, so the
         * surface the game queries (MoltenVK: the layer's bounds x contentsScale) is the screen it renders for */
        layer = [CAMetalLayer layer]; layer.device = MTLCreateSystemDefaultDevice(); layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.opaque = YES; layer.contentsGravity = kCAGravityResizeAspect; layer.contentsScale = 1;
        layer.frame = CGRectMake(0, 0, w32_screen_w, w32_screen_h); layer.drawableSize = CGSizeMake(w32_screen_w, w32_screen_h);
        layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

        w32_host_vk_loader = vk_loader; w32_host_vk_extensions = vk_extensions; w32_host_vk_surface = vk_surface; w32_host_vk_presented = vk_presented;
        w32_host_window_created = window_created; w32_host_window_changed = window_changed;
        w32_relative_cursor(0);
        if (!vk_loader()) {
            NSAlert *al = [NSAlert new]; al.messageText = @"MoltenVK is needed";
            al.informativeText = @"The Sims draws with Vulkan, which runs on MoltenVK. Install it with Homebrew (brew install molten-vk) and reinstall the app.";
            [al runModal]; return 1;
        }
        if (w32_prepare(exe, game, drive_c, overlay)) { fprintf(stderr, "SimsNative: cannot load %s\n", exe); return 1; }
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *tm) { (void)tm; w32_crash_heartbeat(2); }];   /* UI thread alive */
        if (getenv("DS_EXIT_AFTER") && atof(getenv("DS_EXIT_AFTER")) > 0)                              /* tests: stop after so many seconds */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(getenv("DS_EXIT_AFTER")) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fprintf(stderr, "host: %u frames presented\n", frames); _exit(0); });

        pthread_attr_t a; pthread_t t;
        pthread_attr_init(&a); pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INTERACTIVE, 0);
        pthread_attr_setstacksize(&a, 256u << 20);
        pthread_create(&t, &a, game_thread, 0);
        [NSApp run];
    }
    return 0;
}

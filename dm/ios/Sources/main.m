// iOS App entry: set the environment (game files, saves, shader libraries), write the host log to Documents/log.txt, create the window (front_ios.m), then run the host's dm_main on a big-stack thread.
// The game files (RomFS) ship inside the App at <App>/romfs; Documents/romfs placed through the Files app is also accepted (lets you swap them without reinstalling).
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include "game_profile.h"   // game profile constants (the RomFS marker path)
#include "dm_language.h"
#import <Metal/Metal.h>

void dm_ios_language_apply(void) {
    NSString *choice = [NSUserDefaults.standardUserDefaults stringForKey:@"NXLanguageChoice"];
    // A prior explicit env override remains valid until the native picker is used.
    const char *manual = getenv("DM_LANG");
    NSString *tag = choice.length && ![choice isEqualToString:@"system"] ? choice : NSLocale.preferredLanguages.firstObject;
    if (!choice.length && manual && *manual) tag = @(manual);
    char code[8]; dm_language_code(tag.UTF8String,code);
    setenv("DM_LANG",code,1);
    fprintf(stderr,"boot: 语言 %s（%s）\n",code,choice.length ? choice.UTF8String : "system / legacy env");
}

// Applied before the game starts. Explicit env overrides remain authoritative.
// These are game settings; they do not alter iOS device settings.
static int g_graphics_env, g_feedback_env, g_wide_env;
void dm_ios_graphics_apply(void) {
    static int initialized;
    if (!initialized++) { g_graphics_env = getenv("DM_OPMODE") != NULL; g_feedback_env = getenv("DM_NVN_FB_SNAP") != NULL; g_wide_env = getenv("DM_WONDER_NATIVE_WIDE") != NULL; }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *choice = [d stringForKey:@"NXGraphicsChoice"];
    id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();
    BOOL handheld = [choice isEqualToString:@"handheld"] || (![choice isEqualToString:@"console"] && !gpu.supportsBCTextureCompression);
    if (!g_graphics_env) setenv("DM_OPMODE",handheld ? "0" : "1",1);
    if (DM_GAME_PROGRAM_ID == 0x010015100B514000ull) {
        // Prototype is opt-in, and uses handheld height even if the saved mode was console.
        if (!g_wide_env) setenv("DM_WONDER_NATIVE_WIDE",[d boolForKey:@"NXWonderNativeWide"] ? "1" : "0",1);
        if (!g_graphics_env && getenv("DM_WONDER_NATIVE_WIDE") && !strcmp(getenv("DM_WONDER_NATIVE_WIDE"),"1"))
            setenv("DM_OPMODE","0",1);
    }
    // Opt-in diagnostic isolation of scene feedback, preserving existing game defaults.
    if (!g_feedback_env) {
        if ([d boolForKey:@"NXSceneColorCompatibility"]) setenv("DM_NVN_FB_SNAP",DM_GAME_COMPAT_FEEDBACK_SNAP,1);
        else unsetenv("DM_NVN_FB_SNAP");
    }
    fprintf(stderr,"boot: 画面模式 %s；场景颜色兼容 %s\n",getenv("DM_OPMODE") ?: "default",getenv("DM_NVN_FB_SNAP") ?: "game default");
}

int dm_main(int argc, char **argv);   // dm/host/main.c compiled in with -Dmain=dm_main
void dm_host_preload_start(int argc, char **argv);
UIViewController *front_ios_root(void);
void front_ios_focus_event(int ev);
void dm_a16_pack_prepare(NSString *doc, NSString *res, NSString *romfs);

static char *g_argv[4]; static int g_argc;

static NSString *romfs_locate(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    for (NSString *d in @[[doc stringByAppendingPathComponent:@"romfs"], [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs"]])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:@DM_GAME_ROMFS_MARKER]]) return d;   // only a directory containing the game profile's romfs_marker path counts (Mario: System/Resource, the resource size table)
    return nil;
}

// Boot prerequisites (done before UIApplicationMain): directories / environment variables / log -- the host's early load reads these
static int boot_env(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *res = NSBundle.mainBundle.resourcePath;
    for (NSString *d in @[@"save", @"temp"]) [fm createDirectoryAtPath:[doc stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
    // Log: the host only writes to stderr; redirect it to Documents/log.txt (the previous one is kept as log.prev.txt), retrieve it from the Files app when something goes wrong
    NSString *log = [doc stringByAppendingPathComponent:@"log.txt"], *prev = [doc stringByAppendingPathComponent:@"log.prev.txt"];
    [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    fprintf(stderr, "boot: version=%s build=%s iOS=%s physical_memory=%llu signing_mode=%s\n",
        [info[@"CFBundleShortVersionString"] UTF8String], [info[@"CFBundleVersion"] UTF8String],
        NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,
        (unsigned long long)NSProcessInfo.processInfo.physicalMemory,
        [info[@"NXSigningMode"] ?: @"unsigned-external-signing" UTF8String]);
    // Environment switch files (for on-device diagnostics: a sideloaded app cannot be given environment variables from outside): one KEY=VALUE per line, # starts a comment; Documents/env.txt takes precedence over dm/env.txt in the bundle (put there by build_ipa.sh's DM_ENV_FILE)
    for (NSString *ef in @[[doc stringByAppendingPathComponent:@"env.txt"], [[res stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"env.txt"]]) {
        NSString *txt = [NSString stringWithContentsOfFile:ef encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
            if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
            NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
            if (!getenv(k.UTF8String)) { setenv(k.UTF8String, v.UTF8String, 0); fprintf(stderr, "boot: 环境 %s=%s（%s）\n", k.UTF8String, v.UTF8String, ef.lastPathComponent.UTF8String); }
        }
    }
    dm_ios_language_apply();
    dm_ios_graphics_apply();
    NSString *romfs = romfs_locate();
    if (!romfs) { fprintf(stderr, "boot: 没找到游戏文件（<App>/romfs 或 Documents/romfs）\n"); return 0; }
    fprintf(stderr, "boot: 游戏文件 %s\n", romfs.fileSystemRepresentation);
    dm_a16_pack_prepare(doc,res,romfs);
    setenv("DM_ROMFS", romfs.fileSystemRepresentation, 0);
    setenv("DM_SAVE", [doc stringByAppendingPathComponent:@"save"].fileSystemRepresentation, 0);
    setenv("DM_TEMP", [doc stringByAppendingPathComponent:@"temp"].fileSystemRepresentation, 0);
    NSString *dm = [res stringByAppendingPathComponent:@"dm"];
    setenv("DM_NVN_SHMAP", [dm stringByAppendingPathComponent:@"shader_map.tsv"].fileSystemRepresentation, 0);
    setenv("DM_MSL_DIR", [res stringByAppendingPathComponent:@"msl"].fileSystemRepresentation, 0);
    setenv("DM_FONT_DIR", [dm stringByAppendingPathComponent:@"font"].fileSystemRepresentation, 0);   // Shared-font stand-ins (standard.ttf / nintendo_ext.ttf): iOS lacks the macOS font path
    NSString *aoc = [doc stringByAppendingPathComponent:@"aoc"];   // add-on content: build_ipa.sh puts the RomFS extracted from the player's DLC NSPs at <App>/aoc/<index>/
    if ([fm fileExistsAtPath:aoc]) setenv("DM_AOC_DIR", aoc.fileSystemRepresentation, 0);
    chdir(doc.fileSystemRepresentation);
    g_argv[0] = strdup("dmhost"); g_argv[1] = strdup(dm.fileSystemRepresentation); g_argc = 2;
    dm_host_preload_start(g_argc, g_argv);   // Module tables / relocation / takeover run early in the background, in parallel with UIKit startup
    return 1;
}
static int g_boot_ok;

static void *boot_thread(void *p) {
    (void)p;
    static char alt[65536]; stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);   // crash printing must work on the host thread too
    int rc = dm_main(g_argc, g_argv);
    fprintf(stderr, "boot: dm_main 返回 %d\n", rc);
    return NULL;
}
void front_ios_boot(void) {   // Called by front_ios.m once the window and Metal view exist
    static int once; if (once++ || !g_boot_ok) return;
    void front_ios_audio_session(void); front_ios_audio_session();   // set a short I/O buffer before the game opens audio output (front_ios.m)
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);   // the Switch main thread stack is set by npdm; the host gives plenty
    pthread_t t; pthread_create(&t, &a, boot_thread, NULL); pthread_detach(t);
}
int front_ios_boot_ok(void) { return g_boot_ok; }

@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
}
@end

// Scene lifecycle: create the window + hand focus events to front_ios.m
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = front_ios_root();
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)s { front_ios_focus_event(0); }
- (void)sceneDidEnterBackground:(UIScene *)s { front_ios_focus_event(1); }
- (void)sceneWillEnterForeground:(UIScene *)s { front_ios_focus_event(2); }
- (void)sceneDidBecomeActive:(UIScene *)s { front_ios_focus_event(3); }
@end

int main(int argc, char **argv) {
    @autoreleasepool { g_boot_ok = boot_env(); }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}

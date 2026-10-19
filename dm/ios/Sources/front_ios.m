// iOS front end: an aspect-fit Metal view (16:9 by default; guarded Wonder native-width experiment) and a full-screen virtual gamepad layer.
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#include <errno.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "dm_wonder_wide.h"
#include "nvn_prepare.h"
#include <stdatomic.h>

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
void front_ios_boot(void);
int front_ios_boot_ok(void);
void dm_ios_language_apply(void);
void dm_ios_graphics_apply(void);
NSString *dm_a16_pack_message(void);
BOOL dm_a16_pack_available(void);
void dm_a16_pack_set_enabled(BOOL enabled);

static _Atomic int g_thermal = -1;
static _Atomic double g_brightness = -1;
int dm_thermal_now(void) { return atomic_load(&g_thermal); }
double dm_brightness_now(void) { return atomic_load(&g_brightness); }
static void device_sample(void) {
    int thermal = (int)NSProcessInfo.processInfo.thermalState;
    int previous = atomic_exchange(&g_thermal,thermal);
    atomic_store(&g_brightness,(double)UIScreen.mainScreen.brightness);
    static unsigned ticks;
    if (thermal != previous || ++ticks % 30 == 0)
        LOG("[设备] 温控 %d（0正常/1较热/2严重/3危急），亮度 %.2f，低电量模式 %d",
            thermal,atomic_load(&g_brightness),NSProcessInfo.processInfo.lowPowerModeEnabled);
}

static CAMetalLayer *g_layer;
static _Atomic int g_guest_started;

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = UIScreen.mainScreen.nativeScale; l.framebufferOnly = NO; l.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.drawableSize = CGSizeMake(self.bounds.size.width * l.contentsScale, self.bounds.size.height * l.contentsScale);
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@property (nonatomic, strong) UIStackView *launchPanel;
@property (nonatomic, strong) UIButton *languageButton;
@property (nonatomic, strong) UIButton *graphicsButton;
@property (nonatomic, strong) UILabel *texturesLabel;
@property (nonatomic, strong) NSTimer *deviceTimer;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL preparing;
@property (nonatomic, strong) UIStackView *preparePanel;
@property (nonatomic, strong) UIProgressView *prepareProgress;
@property (nonatomic, strong) UILabel *prepareLabel;
@property (nonatomic, strong) UILabel *prepareDetail;
@property (nonatomic, strong) UIButton *prepareContinue;
@property (nonatomic, strong) NSTimer *prepareTimer;
- (void)updatePreparation;
- (void)enterPreparedGame;
@property (nonatomic) BOOL appliedWide;
- (void)refreshGameplayChrome;
@end
@implementation DmRootVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationBecameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    device_sample();
    self.deviceTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        (void)timer; device_sample();
        // Startup freezes the host capability on its thread, before guest init.
        // Pick it up on the main thread; never resize or change policy mid-game.
        BOOL wide = dm_wonder_wide_active();
        if (wide != self.appliedWide) { self.appliedWide = wide; [self.view setNeedsLayout]; }
    }];
    [NSRunLoop.mainRunLoop addTimer:self.deviceTimer forMode:NSRunLoopCommonModes];
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.text = @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart.\n\n没找到游戏文件：把 RomFS 文件夹以 romfs 为名放进本 App 的「文稿」后重开。";
        [self.view addSubview:lb]; return;
    }
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.game];
    g_layer = (CAMetalLayer *)self.game.layer;
    self.pad = dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pad];
    self.languageButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.languageButton.configuration = [UIButtonConfiguration tintedButtonConfiguration];
    self.languageButton.accessibilityLabel = @"语言 / Language";
    [self.languageButton addTarget:self action:@selector(chooseLanguage) forControlEvents:UIControlEventTouchUpInside];
    [self updateLanguageTitle];
    UILabel *title = [UILabel new];title.text = @"准备开始 / Ready to play";title.textAlignment = NSTextAlignmentCenter;title.textColor = UIColor.whiteColor;
    UILabel *textures = [UILabel new];self.texturesLabel=textures;textures.text=dm_a16_pack_message();textures.textAlignment=NSTextAlignmentCenter;textures.textColor=UIColor.lightGrayColor;textures.numberOfLines=0;textures.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    UIButton *start = [UIButton buttonWithType:UIButtonTypeSystem];start.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [start setTitle:@"开始游戏 / Start game" forState:UIControlStateNormal];
    [start addTarget:self action:@selector(startGame) forControlEvents:UIControlEventTouchUpInside];
    self.graphicsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.graphicsButton.configuration = [UIButtonConfiguration tintedButtonConfiguration];
    [self.graphicsButton addTarget:self action:@selector(chooseGraphics) forControlEvents:UIControlEventTouchUpInside];
    [self updateGraphicsTitle];
    self.launchPanel = [[UIStackView alloc] initWithArrangedSubviews:@[title,textures,self.languageButton,self.graphicsButton,start]];
    self.launchPanel.axis = UILayoutConstraintAxisVertical;self.launchPanel.spacing = 12;
    self.launchPanel.translatesAutoresizingMaskIntoConstraints = NO;[self.view addSubview:self.launchPanel];
    [NSLayoutConstraint activateConstraints:@[[self.launchPanel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.launchPanel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.launchPanel.widthAnchor constraintEqualToConstant:320]]];
    self.pad.hidden = YES;
}
- (void)updateGraphicsTitle {
    BOOL handheld = getenv("DM_OPMODE") && !strcmp(getenv("DM_OPMODE"),"0");
    BOOL wide = DM_GAME_PROGRAM_ID == 0x010015100B514000ull && handheld && getenv("DM_WONDER_NATIVE_WIDE") && !strcmp(getenv("DM_WONDER_NATIVE_WIDE"),"1");
    [self.graphicsButton setTitle:wide ? @"画面设置：掌机 · 宽屏实验" : handheld ? @"画面设置：掌机模式" : @"画面设置：主机模式" forState:UIControlStateNormal];
}
- (void)chooseGraphics {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"画面模式" message:DM_GAME_PROGRAM_ID == 0x010015100B514000ull ? @"宽屏为待验证实验：使用掌机模式，目标1560×720，像素约增加22%；人物比例、HUD与特殊关卡仍待验证。关闭可恢复16:9。其余画面设置均在开始游戏后生效。" : @"掌机模式降低渲染负载。颜色兼容可能增加负载。设置在开始游戏后生效。" preferredStyle:UIAlertControllerStyleAlert];
    for (NSArray *c in @[@[@"掌机模式（较低负载）",@"handheld"],@[@"主机模式（较高画质）",@"console"]])
        [menu addAction:[UIAlertAction actionWithTitle:c[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;[NSUserDefaults.standardUserDefaults setObject:c[1] forKey:@"NXGraphicsChoice"];
            if ([c[1] isEqualToString:@"console"]) [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"NXWonderNativeWide"];
            dm_ios_graphics_apply();[self updateGraphicsTitle];
        }]];
    if (DM_GAME_PROGRAM_ID == 0x010015100B514000ull) {
        BOOL wide = getenv("DM_WONDER_NATIVE_WIDE") && !strcmp(getenv("DM_WONDER_NATIVE_WIDE"),"1");
        [menu addAction:[UIAlertAction actionWithTitle:wide ? @"宽屏实验 1560×720：开（点此关闭）" : @"宽屏实验 1560×720：关（点此开启）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            [NSUserDefaults.standardUserDefaults setBool:!wide forKey:@"NXWonderNativeWide"];
            if (!wide) [NSUserDefaults.standardUserDefaults setObject:@"handheld" forKey:@"NXGraphicsChoice"];
            dm_ios_graphics_apply(); [self updateGraphicsTitle];
        }]];
    }
    BOOL compatibility = [NSUserDefaults.standardUserDefaults boolForKey:@"NXSceneColorCompatibility"];
    [menu addAction:[UIAlertAction actionWithTitle:compatibility ? @"场景颜色兼容：已开（点此关闭）" : @"场景颜色兼容：已关（点此开启）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;[NSUserDefaults.standardUserDefaults setBool:!compatibility forKey:@"NXSceneColorCompatibility"];dm_ios_graphics_apply();
    }]];
    if (dm_a16_pack_available()) {
        BOOL enabled = getenv("DM_ROMFS_OVERLAY") != NULL;
        [menu addAction:[UIAlertAction actionWithTitle:enabled ? @"A16 补充包：已开（点此用原版）" : @"A16 补充包：已关（点此开启）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;[NSUserDefaults.standardUserDefaults setBool:!enabled forKey:@"NXUseA16Overlay"];dm_a16_pack_set_enabled(!enabled);self.texturesLabel.text=dm_a16_pack_message();
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:menu animated:YES completion:nil];
}
- (void)updateLanguageTitle {
    const char *code = getenv("DM_LANG");
    [self.languageButton setTitle:[NSString stringWithFormat:@"语言 / Language：%s",code ? code : "system"] forState:UIControlStateNormal];
}
- (void)chooseLanguage {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"语言 / Language" message:@"选择本次启动使用的语言 / Choose the game language" preferredStyle:UIAlertControllerStyleAlert];
    NSArray *choices = @[@[@"跟随系统 / System",@"system"],@[@"简体中文",@"zh-Hans"],@[@"繁體中文",@"zh-Hant"],
        @[@"English",@"en-US"],@[@"日本語",@"ja"],@[@"한국어",@"ko"],@[@"Français",@"fr"],@[@"Deutsch",@"de"],
        @[@"Italiano",@"it"],@[@"Español",@"es"],@[@"Português",@"pt"],@[@"Português (Brasil)",@"pt-BR"],@[@"Nederlands",@"nl"],@[@"Русский",@"ru"]];
    for (NSArray *choice in choices) [menu addAction:[UIAlertAction actionWithTitle:choice[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;[NSUserDefaults.standardUserDefaults setObject:choice[1] forKey:@"NXLanguageChoice"];
        dm_ios_language_apply();[self updateLanguageTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消 / Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)startGame {
    if (self.started || self.preparing) return;
    self.preparing = YES; self.launchPanel.hidden = YES;
    UILabel *title = [UILabel new]; title.text = @"准备图形资源 / Preparing graphics";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; title.textColor = UIColor.whiteColor; title.textAlignment = NSTextAlignmentCenter;
    self.prepareLabel = [UILabel new]; self.prepareLabel.textColor = UIColor.whiteColor; self.prepareLabel.textAlignment = NSTextAlignmentCenter; self.prepareLabel.numberOfLines = 0;
    self.prepareProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.prepareDetail = [UILabel new]; self.prepareDetail.textColor = UIColor.lightGrayColor; self.prepareDetail.textAlignment = NSTextAlignmentCenter; self.prepareDetail.numberOfLines = 0;
    self.prepareDetail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.prepareContinue = [UIButton buttonWithType:UIButtonTypeSystem]; self.prepareContinue.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [self.prepareContinue setTitle:@"继续游戏 / Continue" forState:UIControlStateNormal];
    [self.prepareContinue addTarget:self action:@selector(enterPreparedGame) forControlEvents:UIControlEventTouchUpInside];
    self.prepareContinue.hidden = YES;
    self.preparePanel = [[UIStackView alloc] initWithArrangedSubviews:@[title,self.prepareLabel,self.prepareProgress,self.prepareDetail,self.prepareContinue]];
    self.preparePanel.axis = UILayoutConstraintAxisVertical; self.preparePanel.spacing = 16; self.preparePanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.preparePanel];
    [NSLayoutConstraint activateConstraints:@[[self.preparePanel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.preparePanel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.preparePanel.widthAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor multiplier:0.65],
        [self.preparePanel.widthAnchor constraintLessThanOrEqualToConstant:560]]];
    mtl_prepare_active(UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    mtl_prepare_start();
    __weak DmRootVC *weakSelf = self;
    self.prepareTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) { (void)timer; [weakSelf updatePreparation]; }];
    [NSRunLoop.mainRunLoop addTimer:self.prepareTimer forMode:NSRunLoopCommonModes];
    [self updatePreparation];
}
- (void)updatePreparation {
    if (!self.preparing) return;
    nvn_prepare_status s = {0}; mtl_prepare_snapshot(&s);
    self.prepareProgress.progress = s.total ? (float)s.completed / s.total : 0;
    BOOL active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (s.state == NVN_PREP_FAILED) {
        self.prepareLabel.text = @"图形资源缺失，无法准备 / Graphics files missing";
        self.prepareDetail.text = @"请检查安装包，关闭应用后重开。详情已记入 log.txt。\nCheck the installation and restart. See log.txt.";
        [self.prepareTimer invalidate]; return;
    }
    self.prepareLabel.text = s.state == NVN_PREP_LOADING ? @"正在读取本机缓存与已知清单… / Reading cache…" :
        s.state == NVN_PREP_SAVING ? @"正在保存可复用的编译结果… / Saving reusable binaries…" :
        [NSString stringWithFormat:@"已知项目 %u / %u · 失败 %u · 跳过 %u\nKnown entries · Failed · Skipped", s.completed, s.total, s.failed, s.skipped];
    self.prepareDetail.text = [NSString stringWithFormat:@"%@\n缓存命中 %llu · 编译未命中 %llu · 未归档 %llu\n首次准备可能较久，请保持应用在前台。新场景仍可能补充编译。\nFirst preparation may take a while. New scenes may need more pipelines.",
        active ? @"准备完成后自动进入游戏 / Starts when ready" : @"已暂停，返回应用后继续 / Paused until foreground", s.cache.hits, s.cache.misses, s.cache.bypassed];
    if (s.state == NVN_PREP_READY && active) { [self enterPreparedGame]; return; }
    if (s.state == NVN_PREP_PARTIAL) {
        self.prepareContinue.hidden = NO;
        self.prepareDetail.text = s.cache.write_failed ?
            @"本次已完成准备，但缓存未能保存。可继续游戏，下次可能需要重新编译。详情见 log.txt。\nCache could not be saved; continuing is available." :
            @"部分已知项目未能预热，可继续游戏并按需编译。详情见 log.txt。\nSome entries remain; the game can compile them as needed.";
    }
}
- (void)enterPreparedGame {
    nvn_prepare_status s = {0}; mtl_prepare_snapshot(&s);
    if (self.started || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        (s.state != NVN_PREP_READY && s.state != NVN_PREP_PARTIAL)) return;
    [self.prepareTimer invalidate]; self.prepareTimer = nil;
    self.preparing = NO; self.started = YES; self.preparePanel.hidden = YES; self.pad.hidden = NO;
    atomic_store(&g_guest_started, 1);
    [self refreshGameplayChrome]; front_ios_boot();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; if (!self.game) return;
    CGFloat w = b.size.width, h = b.size.height;
    // Match the native target aspect; retain aspect-fit (no cover crop or stretch).
    CGFloat aspect = dm_wonder_wide_active() ? (CGFloat)DM_WONDER_WIDE_WIDTH / DM_WONDER_WIDE_HEIGHT : 16.0 / 9.0;
    if (w / h > aspect) w = h * aspect; else h = w / aspect;
    self.game.frame = CGRectMake(floor((b.size.width - w) / 2), floor((b.size.height - h) / 2), w, h);
}
- (void)refreshGameplayChrome {
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setNeedsStatusBarAppearanceUpdate];
}
- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    if (self.started) [self refreshGameplayChrome];
    if (self.preparing) [self updatePreparation];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self refreshGameplayChrome]; }
- (BOOL)prefersHomeIndicatorAutoHidden { return self.started; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    // Gameplay requests automatic home-indicator hiding rather than bottom-edge deferral.
    // UIKit still controls visibility; user interaction/system gestures can reveal the indicator.
    return self.started ? UIRectEdgeTop | UIRectEdgeLeft | UIRectEdgeRight : UIRectEdgeNone;
}
- (void)dealloc { [self.prepareTimer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
UIViewController *front_ios_root(void) { return [DmRootVC new]; }

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
uint64_t front_game_res(int docked) {
    if (dm_wonder_wide_active()) return (uint64_t)DM_WONDER_WIDE_HEIGHT << 32 | DM_WONDER_WIDE_WIDTH;
    return docked ? 900ull << 32 | 1600 : 720ull << 32 | 1280;
}
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    guest_clock_freeze_for(2, 1);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    guest_clock_freeze_for(2, 0);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game (as d2r-mobile does). hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("前端：存档写失败 errno=%d，提示玩家", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG("【红】前端：存档失败提示没有窗口 errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"存储空间不足，进度没有存上。请清理空间后再存档。\nStorage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"存档写入失败（errno %d），进度没有存上。\nSaving failed (errno %d); progress was not saved.", err, err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"存档失败 / Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// the category stays the default SoloAmbient (silent switch and interrupting other apps' audio behave as before). Set once at boot and again on return to the foreground (the system may reset it after an interruption)
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategorySoloAmbient error:&e]) LOG("【红】音频会话类别设不上：%s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("【红】音频会话 I/O 缓冲时长设不上：%s", e.localizedDescription.UTF8String);
    if (![s setActive:YES error:&e]) LOG("【红】音频会话激活失败：%s", e.localizedDescription.UTF8String);
    LOG("音频会话：采样率 %.0f Hz，I/O 缓冲 %.2f ms（要 5 ms）", s.sampleRate, s.IOBufferDuration * 1000);
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed)
void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    mtl_prepare_active(ev == 3);
    if (ev == 1) {
        __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
        task = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Save pipeline cache" expirationHandler:^{
            if (task != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }
        }];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            nvn_cache_flush();
            dispatch_async(dispatch_get_main_queue(), ^{
                if (task != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }
            });
        });
    }
    // Do not enter the graphics suspend/drain path while startup owns mtl_init.
    if (!atomic_load(&g_guest_started)) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: dm_focus_set(3); dm_audio_suspend(1); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); dm_audio_suspend(0); dm_focus_set(2); break;
        case 3: dm_focus_set(1); break;
    }
}

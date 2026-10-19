// Hook points left behind by the game-specific modules split out of d2r-mobile (diagnostic tick gates, TACT/Granny, UI screen, touch UI interaction, ...):
// the generic host still calls them, and they get empty implementations here. When a feature is redone for this game, replace the matching stub with the real thing.
#include "dm.h"
#include "front.h"
#include "dm_wonder_wide.h"
#include <stdatomic.h>
#include <TargetConditionals.h>

static _Atomic int g_wonder_wide;
int dm_wonder_wide_capable(void) {
    if (DM_GAME_PROGRAM_ID != 0x010015100B514000ull) return 0;
    for (int i = 0; i < g_nmod; i++)
        if (!strcmp(g_mod[i].name, "main"))
            return g_mod[i].wonder_native_wide == 1 && !strcmp(g_mod[i].build_id, DM_WONDER_WIDE_BUILD);
    return 0;
}
int dm_wonder_wide_active(void) { return atomic_load_explicit(&g_wonder_wide, memory_order_acquire); }
void dm_wonder_wide_prepare(void) {
    // Called after the preload joins and before any guest instruction/thread starts.
    // Freeze the choice for this process: all guest threads receive identical parameters.
    const char *want = getenv("DM_WONDER_NATIVE_WIDE"), *mode = getenv("DM_OPMODE");
    int requested = want && !strcmp(want, "1");
    int enabled = TARGET_OS_IPHONE && requested && mode && !strcmp(mode, "0") && dm_wonder_wide_capable();
    atomic_store_explicit(&g_wonder_wide, enabled, memory_order_release);
    if (DM_GAME_PROGRAM_ID == 0x010015100B514000ull) {
        LOG("[宽屏实验] 请求=%d 启用=%d 模块=%s 改写能力=%d；%s",
            requested, enabled, dm_main_build(), dm_wonder_wide_capable(),
            enabled ? "内部目标1560x720；画面/剔除/HUD待实机验证" : "保留游戏原版分辨率/相机");
    }
}

void crash_sample_self(void) {}
void inflate_bench_maybe(void) {}
void ticks_install(void) {}
void target_rank_install(void) {}
void dm_padmode_boot(void) {}
void dm_prof_mark(const char *seg) { (void)seg; }
void dm_prof_add(int id, uint64_t ns, uint64_t bytes) { (void)id; (void)ns; (void)bytes; }
void tact_chk_init(void) {}
void tact_prefetch_start(const char *outdir) { (void)outdir; }
void tact_prefetch_stop(void) {}
void granny_prof_dump(void) {}
void uimsg_subscribe(void (*fn)(const char *cat, const char *act, const char *arg)) { (void)fn; }
void dm_ui_text_entered(const char *text) { (void)text; }
int dm_custom_lang_explicit(void) { return 0; }
int dm_ingame_now(void) { return 0; }
void dm_uiscreen_res_reread(void) {}
// Game resolution: whatever the front end gives (Mac window / iOS screen), without D2R's UI-screen rewriting
uint64_t dm_game_res(int docked) { return front_game_res(docked); }
int dm_screen_real(int *w, int *h) { *w = *h = 0; return 0; }
void dm_ui_rect(int *x, int *y, int *w, int *h) { *x = *y = *w = *h = 0; }
// svc #0x80.. host gates: only D2R's rewrite rules create them; they should not appear in this game's build output
uint64_t svc_host_call(int num, uint64_t *regs) { (void)regs; die("svc_host_call：本作没有宿主门 svc #%#x", num); }

// Miscellaneous service layer: add-on content / shop / error applet / profanity filter / server name resolution / parental controls / software keyboard.
// On the real device each goes through IPC or a system applet; the host gives results as single-player offline. Pure-computation SDK parts (hash, util, software Opus) are not taken over, the original implementation is used directly.
#include "hle.h"
#include <dirent.h>

// ---------- aoc add-on content (D2R's Reign of the Warlock; other games by the DLC NSPs in the player's folder) / ec shop (excluded) ----------
// Reign of the Warlock is the only add-on content in the Switch package: AOC 0100726014353001 = add-on content index 1 of the base 0100726014352000.
// This DLC is only an unlock ticket of about 100 KB, the content itself is already in the main RomFS; main does not import MountAddOnContent and only judges by "is index 1 present".
// The reimplementation scope requires keeping Reign of the Warlock, so index 1 is reported as owned; what is excluded is the shop (ec), not the DLC itself.
enum { AOC_WARLOCK = 1 };
// Owned add-on content indices (ascending), fixed at the first query:
//   numeric subdirectories of DM_AOC_DIR: each is one DLC's RomFS, which the packing script extracts only from DLC NSPs really in the player's folder (title ID = base + 0x1000 + index).
//     Engage: F001 → 1 (E0), F002 → 2 (H0); the content itself is in the 2.0.0 update's RomFS and each DLC package holds one empty marker file; the game calls MountAddOnContent for each index ListAddOnContent returns (hle_fs.c).
//   No DM_AOC_DIR: D2R (main build db0507f3…) reports {1} (the Warlock expansion, content in the main RomFS, main does not import MountAddOnContent); other builds none --
//     on a Switch 2 Mario 1.2.1 uses it to tell whether the upgrade pack is owned, and the user has no Mario add-on content files.
//   DM_AOC_OWNED=0: always none (test switch, for lockstep comparison against ground truth recorded without the DLC installed); DM_AOC_OWNED=1 without DM_AOC_DIR: reports {1}.
static int g_aoc[64], g_naoc = -1;
static int aoc_int_cmp(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }
static void aoc_load(void) {
    if (g_naoc >= 0) return;
    g_naoc = 0;
    const char *e = getenv("DM_AOC_OWNED"), *dir = getenv("DM_AOC_DIR"); const char *why = "按 main 构建号";
    if (e && !strcmp(e, "0")) why = "DM_AOC_OWNED=0";
    else if (dir && *dir) {
        why = dir; DIR *d = opendir(dir); struct dirent *ent;
        while (d && (ent = readdir(d)) && g_naoc < (int)(sizeof g_aoc / sizeof *g_aoc)) {
            char *end; long i = strtol(ent->d_name, &end, 10);
            if (ent->d_name[0] >= '1' && ent->d_name[0] <= '9' && !*end && i <= 2000) g_aoc[g_naoc++] = (int)i;
        }
        if (d) closedir(d);
        qsort(g_aoc, g_naoc, sizeof *g_aoc, aoc_int_cmp);
    } else {
        int d2r = 0;
        for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) d2r = !strcmp(g_mod[i].build_id, "db0507f36b84200ac05f75d76ed5026f");
        if (e) why = "DM_AOC_OWNED";
        if (d2r || e) g_aoc[g_naoc++] = AOC_WARLOCK;
    }
    char list[256] = ""; for (int i = 0; i < g_naoc; i++) snprintf(list + strlen(list), sizeof list - strlen(list), "%s%d", i ? "," : "", g_aoc[i]);
    LOG("aoc：报告 %d 个追加内容 {%s}（%s）", g_naoc, list, why);
}
HLE_FORCE("_ZN2nn3aoc17CountAddOnContentEv", "追加内容数：已拥有序号表的长度（D2R 术士君临 / DM_AOC_DIR）", int, h_aoc_Count, void) { aoc_load(); return g_naoc; }
// ListAddOnContent(out, start index, max count): writes out from the owned index list starting at the start index, returns the number written
HLE_FORCE("_ZN2nn3aoc16ListAddOnContentEPiii", "追加内容列表：已拥有序号表", int, h_aoc_List, int *out, int off, int n) {
    int w = 0; aoc_load();
    for (int i = off < 0 ? 0 : off; i < g_naoc && w < n; i++) out[w++] = g_aoc[i];
    return w;
}
// The event object is created on demand by the nn::os side table (not signaled), the game waiting on it only times out / gets not-signaled
HLE_FORCE("_ZN2nn3aoc31GetAddOnContentListChangedEventEPNS_2os11SystemEventE", "追加内容变更事件，排除范围；绑内核事件、恒不触发（游戏会 TryWait 轮询，未初始化即中止）", void, h_aoc_GetEv, void *ev) { hle_bind_system_event(ev, 0); }
HLE_FORCE("_ZN2nn2ec24ShowShopAddOnContentListEv", "商店小程序，排除范围；剪口：空操作", void, h_ec_ShowShop, void) { LOG("ec::ShowShopAddOnContentList（剪）"); }
// The other shop entry points (Engage's title menu item "DLC" calls ShowShopAddOnContentList(ApplicationId, UserHandle)): the original starts the shop applet through applet::CreateLibraryApplet,
// the host has no applet proxy (oe initialization is a no-op), and the SDK reads through the null proxy and crashes (sdk+0x38660). All return void: as if the player closed the shop at once, the game goes back to its menu.
HLE_FORCE("_ZN2nn2ec24ShowShopAddOnContentListENS_13ApplicationIdE", "商店小程序，排除范围；剪口：空操作", void, h_ec_AocList1, void) { LOG("ec::ShowShopAddOnContentList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec24ShowShopAddOnContentListENS_13ApplicationIdERKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_AocList2, void) { LOG("ec::ShowShopAddOnContentList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec30ShowShopApplicationInformationENS_13ApplicationIdE", "商店小程序，排除范围；剪口：空操作", void, h_ec_AppInfo1, void) { LOG("ec::ShowShopApplicationInformation（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec30ShowShopApplicationInformationENS_13ApplicationIdERKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_AppInfo2, void) { LOG("ec::ShowShopApplicationInformation（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec24ShowShopSubscriptionListENS_13ApplicationIdE", "商店小程序，排除范围；剪口：空操作", void, h_ec_Sub1, void) { LOG("ec::ShowShopSubscriptionList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec24ShowShopSubscriptionListENS_13ApplicationIdERKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_Sub2, void) { LOG("ec::ShowShopSubscriptionList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec24ShowShopSubscriptionListENS_13ApplicationIdERKNS0_8CourseIdE", "商店小程序，排除范围；剪口：空操作", void, h_ec_Sub3, void) { LOG("ec::ShowShopSubscriptionList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec24ShowShopSubscriptionListENS_13ApplicationIdERKNS0_8CourseIdERKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_Sub4, void) { LOG("ec::ShowShopSubscriptionList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec26ShowShopConsumableItemListENS_13ApplicationIdE", "商店小程序，排除范围；剪口：空操作", void, h_ec_ConsList1, void) { LOG("ec::ShowShopConsumableItemList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec26ShowShopConsumableItemListENS_13ApplicationIdERKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_ConsList2, void) { LOG("ec::ShowShopConsumableItemList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec28ShowShopConsumableItemDetailENS_13ApplicationIdERKNS0_12ConsumableIdENS0_5NsUidE", "商店小程序，排除范围；剪口：空操作", void, h_ec_ConsDet1, void) { LOG("ec::ShowShopConsumableItemDetail（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec28ShowShopConsumableItemDetailENS_13ApplicationIdERKNS0_12ConsumableIdENS0_5NsUidERKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_ConsDet2, void) { LOG("ec::ShowShopConsumableItemDetail（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec22ShowShopEnterCodeSceneEv", "商店小程序，排除范围；剪口：空操作", void, h_ec_Code1, void) { LOG("ec::ShowShopEnterCodeScene（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec22ShowShopEnterCodeSceneERKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_Code2, void) { LOG("ec::ShowShopEnterCodeScene（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec22ShowShopProductDetailsENS0_5NsUidE", "商店小程序，排除范围；剪口：空操作", void, h_ec_Prod1, void) { LOG("ec::ShowShopProductDetails（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec22ShowShopProductDetailsENS0_5NsUidERKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_Prod2, void) { LOG("ec::ShowShopProductDetails（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec19ShowShopProductListEPKNS0_5NsUidEiPKc", "商店小程序，排除范围；剪口：空操作", void, h_ec_ProdList1, void) { LOG("ec::ShowShopProductList（剪）：宿主没有商店"); }
HLE_FORCE("_ZN2nn2ec19ShowShopProductListEPKNS0_5NsUidEiPKcRKNS_7account10UserHandleE", "商店小程序，排除范围；剪口：空操作", void, h_ec_ProdList2, void) { LOG("ec::ShowShopProductList（剪）：宿主没有商店"); }
// The "add-on content lost" error screen is an applet too: logged only
HLE_FORCE("_ZN2nn3aoc25ShowAddOnContentLostErrorEPKii", "追加内容丢失错误小程序；宿主只记日志", void, h_aoc_LostErr, const int *idx, int n) { (void)idx; LOG("aoc::ShowAddOnContentLostError（%d 项）（剪）", n); }

// ---------- err error applet: printed by the host ----------
HLE_FORCE("_ZN2nn3err9ShowErrorENS_6ResultE", "错误显示小程序；宿主打印模块 / 描述号", void, h_err_ShowError, Result r) {
    LOG("err::ShowError Result=%#x（模块 %u，描述 %u）", r, r & 0x1ff, (r >> 9) & 0x1fff);
}

// ---------- ngc profanity filter: the word list is in a system data save (mounted via IPC); single-player has no text visible to others, always judged as no profanity ----------
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterC1Ev", "敏感词过滤，词库走系统存档；宿主不建", void, h_ngc_Ctor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterD1Ev", "敏感词过滤", void, h_ngc_Dtor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter10InitializeEPvm", "敏感词过滤初始化；宿主无词库", Result, h_ngc_Init, void *self, void *work, uint64_t sz) { (void)self; (void)work; (void)sz; return RES_OK; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter17GetContentVersionEv", "词库版本；宿主 0", uint32_t, h_ngc_Ver, void *self) { (void)self; return 0; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKcm", "敏感词检查；恒无命中", Result, h_ngc_Check, void *self, uint32_t *masks, uint32_t pat, const char **words, uint64_t n) {
    (void)self; (void)pat; (void)words;
    for (uint64_t i = 0; i < n; i++) masks[i] = 0;
    return RES_OK;
}

// ---------- nsd server name resolution / pctl free communication: networking, out of scope ----------
HLE_FORCE("_ZN2nn3nsd7ResolveEPNS0_4FqdnERKS1_", "服务器名解析，联网排除；剪口", Result, h_nsd_Resolve, void *out, const void *in) { (void)out; (void)in; return RES_FAIL; }
HLE_FORCE("_ZN2nn3nsd9ResolveExEPNS0_4FqdnERKS1_", "服务器名解析，联网排除；剪口", Result, h_nsd_ResolveEx, void *out, const void *in) { (void)out; (void)in; return RES_FAIL; }
// bool arguments only look at the low 8 bits; returns bool
// The permission query answers as TryBegin / IsFreeCommunicationAvailable do: the SDK's version calls the pctl service (pctl::detail::ipc::GetService), which the host never opens (DRAGON QUEST XI S imports it; from PR #38)
HLE_FORCE("_ZN2nn4pctl32CheckFreeCommunicationPermissionEb", "家长控制·与他人通信许可，联网排除；恒否，无系统界面", unsigned, h_pctl_CheckFree, unsigned show_ui) { (void)show_ui; return 0; }
HLE_FORCE("_ZN2nn4pctl25TryBeginFreeCommunicationEb", "家长控制·与他人通信，联网排除；恒不允许", unsigned, h_pctl_TryBegin, unsigned show_ui) { (void)show_ui; return 0; }
HLE_FORCE("_ZN2nn4pctl20EndFreeCommunicationEv", "家长控制·与他人通信", void, h_pctl_End, void) {}
// Engage asks on entering a battle map (no UI); without this the SDK connects to the pctl service through sm, which the host does not have, and aborts
HLE_FORCE("_ZN2nn4pctl28IsFreeCommunicationAvailableEv", "家长控制·与他人通信可用否，联网排除；恒否", unsigned, h_pctl_IsFree, void) { return 0; }
// The Legend of Zelda: Breath of the Wild: checks the parental-control permission for stereoscopic 3D before VR-related screens (returns bool; the argument = whether to show UI, the game passes 0). The host has no parental controls: permitted
HLE_FORCE("_ZN2nn4pctl27CheckStereoVisionPermissionEb", "家长控制·3D 立体显示许可；宿主无家长控制，允许", unsigned, h_pctl_Stereo, unsigned show_ui) { (void)show_ui; return 1; }

// swkbd software keyboard: see hle_swkbd.c

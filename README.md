# nxnative (iOS 17 & Apple A16 Port)

[中文说明](#中文说明)

An open-source fork of [nxnative](https://github.com/seedds/nxnative) adapted for **iOS 17.0+** and **Apple A16** devices, bringing native Nintendo Switch game execution to devices running iOS 17 without requiring Metal 4.

This project is built on the foundation of **[seedds/nxnative](https://github.com/seedds/nxnative)** (upstream baseline: commit `9579030e5b1f0443c12b7376559560915b6d4c4b`), which in turn builds upon **d2r-mobile**, **Ryujinx**, **Atmosphère**, **yuzu**, **LibHac**, and **SPIRV-Cross**. All upstream licenses, notices, and acknowledgments are preserved in full.

Nothing from any game or proprietary SDK is distributed in this repository. You must provide your own legitimately dumped Nintendo Switch game files (NSPs) and your own `prod.keys`. This project is not affiliated with, endorsed by, or associated with Nintendo or any game publisher.

---

## Key Differences from Upstream

1. **iOS 17 & Metal 3 Compatibility**: Upstream nxnative at the declared baseline states **Needs iOS / iPadOS 26 or later** and depends on Metal 4 primitives (command queues, argument buffers, residency sets, barriers). This fork adapts GPU and compute dispatch paths to traditional Metal 3, enabling native execution on iOS 17.0+ and Apple A16 hardware.
2. **Startup Graphics Preparation & Binary Archive Cache**:
   - Native startup progress panel prewarms known shaders and pipelines before guest code execution begins.
   - Persistent pipeline caching using traditional Metal `MTLBinaryArchive`.
   - **iOS 17 Cache Limitation**: Specialized pipelines with function constants bypass archive serialization on iOS < 18 to avoid OS-level serialization exceptions and compile on demand.
   - **Graceful Partial Fallback**: If certain pipelines fail or are skipped during prewarming, the UI state becomes `PARTIAL` and exposes a **Continue** button, allowing players to enter the game with on-demand runtime compilation.
   - Self-healing cache recovery detects and rebuilds corrupted archives in memory.
3. **Ergonomic Touch Controls**:
   - Floating virtual analog stick on the left half-screen with dynamic base positioning.
   - Enlarged, repositioned 2D face buttons (X/A/Y/B) shifted rightward for comfortable thumb reach on modern iPhone screens, with a 6.4 pt chord overlap for simultaneous Y+B run/jump actions.
   - Enlarged, fixed shoulder buttons (L/R/ZL/ZR) along the top screen corners.
4. **Home Indicator Auto-Hide Preference**: Configures UIKit root view controller preferences to request fading the home indicator bar during active gameplay. The actual fade-out and reveal behavior is governed by iOS.
5. **Startup Multi-Language Selector**: Native startup screen language picker offering 13 selectable languages plus a "Follow System" option (14 choices total), saving user preferences without altering game save files.
6. **Decoupled RomFS Architecture**: Game RomFS data is placed in the application's `Documents/romfs` directory rather than bundled into the IPA, keeping sideloaded application packages compact (~410 MB).
 7. **Selective Upstream Sync**: Backported continuous yield backoff, texture upload slot reuse, dirty page range caching, and display pacing from upstream commits.
8. **DisplayLink FIFO Ordering & App Switching Robustness (Build 2026102201 / 2026102202)**:
   - **FIFO Present Delivery**: Backported upstream PR #31 (`6400306`). Replaces naive "take newest frame" dequeuing with a FIFO ordering queue (at most 1 frame behind). Prevents frame drops when 16-17.5 ms frames land in the same refresh cycle, eliminating 33 ms hold hitches and smoothing frame presentation pacing.
   - **ZCull Storage Guard**: Synced upstream commit `7c490ed` calculating non-zero ZCull save bounds (8 bytes per 32x32 tile/layer, minimum 256 bytes) to prevent game pool allocator corruption (e.g. Unity / Cuphead).
   - **Background Clock Freeze & DisplayLink VSync**: Synced upstream commit `58eb1f8` adding guest clock wait on `GetSystemTick` while backgrounded, focus notification suppression under modes 0/3, and binding `vi::GetDisplayVsyncEvent` to display-link ticks.
   - **Multi-Mount Atomic Save Commit**: Synced upstream PR #25 (`f1b1f24`) providing safe multi-mount commit validation.
   - **Offline Parental Controls Stub**: Synced upstream PR #38 (`8e1e8d7`) for offline free communication permission queries.
9. **Cross-Repo Performance & Scheduling Optimizations (Build 2026102202)**:
   - **Metal Frame Arena Allocation Strong Reference (from sibling `d2r-mobile` PR #126)**: Eliminates ARC autorelease pool churn under high draw-call density by annotating buffer out-parameters with `__strong`.
   - **Same-Core Thread Startup Priority Handoff (from `seedds/nxnative` commit `c188131`)**: Honors Switch Mesosphère scheduling semantics on thread startup, yielding immediately when higher-priority threads are scheduled on the same core.
   - **DSP Service Audio Work-Buffer Calculation (from `seedds/nxnative` commit `435a231`)**: Preserves Horizon DSP service memory limits up through revision 15, preventing guest memory exhaustion while backing host CPU rendering.
   - **Thermal Throttling Protection (from `seedds/nxnative` commit `c4b74a6`)**: Automatically clamps present interval to 30 fps when iOS thermal state reaches serious/critical (`dm_thermal_now() >= 2`), avoiding severe thermal throttling stutters.

---

## Supported Games and Hardware Status

Upstream preserves profiles for seven titles in `dm/games/`:
- **Super Mario Bros. Wonder** (Title ID: `010015100B514000`, Update 1.2.1 / package `v327680`): **Primary verified target on iOS 17 / Apple A16.**
- *Other preserved profiles*: Fire Emblem Engage, Metroid Dread, 13 Sentinels: Aegis Rim, Super Mario 3D World + Bowser's Fury, The Legend of Zelda: Breath of the Wild, The Legend of Zelda: Link's Awakening. (Full shader chains and device runtime for other titles are preserved from upstream and remain to be validated individually on iOS 17).

### Device Testing & Build Status (Build 2026102202)
- **Device Target**: iPhone 14 Pro Max (Apple A16 Bionic, iOS 17.0, TrollStore installation).
- **Latest Candidate Build**: `2026102202` (`SMBWMobile-iOS17-v1.0.0-build2026102202.ipa`, 391.1 MB).
- **Status & Changes**:
  - Offline verification passing: `t_nvn` (63/63), `t_present_handoff` (35/35), `t_oe` (47/47).
  - Integrates upstream display link FIFO frame delivery (`DM_PRESENT_FIFO`), ZCull storage bounds, background guest clock freeze wait, and display link vsync tracking.
  - Integrates `d2r-mobile` PR #126 ARC arena optimization, `c188131` scheduler priority handoff, `435a231` audren service memory sizing, and `c4b74a6` thermal throttling protection.
  - Maintains all 7 upstream game profiles, deterministic shader chains, touch controls, and TrollStore memory entitlements.

---

## Build from Source

### Prerequisites (macOS with Xcode and Homebrew)

```bash
# 1. Install build tools
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk

# 2. Install Python dependencies
python3 -m pip install lz4 capstone fonttools
```

### Packaging an IPA

Place your dumped game NSPs (base game + update NSP) into a folder, and locate your `prod.keys`:

```bash
# Clean full build straight from NSPs
python3 scripts/build_ipa_from_nsp.py /path/to/game_nsp_folder -k /path/to/prod.keys

# Or with custom output path and build identifier:
scripts/build_game.sh 2026101906 /path/to/game_nsp_folder -k /path/to/prod.keys
```

### Signing and TrollStore Installation
- **Unsigned Default**: The build script outputs an unsigned IPA by default.
- **TrollStore Memory Entitlements**: Set `NX_TROLLSTORE=1` during packaging:
  ```bash
  NX_TROLLSTORE=1 python3 scripts/build_ipa_from_nsp.py /path/to/game_nsp_folder -k /path/to/prod.keys
  ```
  This applies a local ad-hoc code signature embedding `com.apple.developer.kernel.extended-virtual-addressing` and `com.apple.developer.kernel.increased-memory-limit` entitlements. Install via TrollStore to preserve these memory entitlements. Standard sideloading tools (AltStore, SideStore) without extended virtual memory entitlements may experience memory allocation failures.

### Optional Configurations
- **Widescreen 1560x720 Experiment (Opt-in, default-off)**:
  Before tapping Start Game, select the widescreen option on the launch screen. This enables internal 1560x720 rendering and adjusts shared perspective (0x3c0184) and orthographic (0xf190c) camera projections.
- **Texture Pack Overlay**:
  To bundle an external texture overlay descriptor during build, export `NX_A16_PACK=/path/to/romfs_a16`. Place the folder in `Documents/romfs_a16`. To disable the overlay and revert to original textures, add `DM_A16_OVERLAY=0` to `Documents/env.txt`.

### Offline Toolchain Verification

To verify the build toolchain and pipeline cache without game inputs:
```bash
# Verify iOS 17 arm64 cross-compilation across all 7 profiles
python3 scripts/check_ios17_compile.py --all-profiles

# Verify Metal binary archive persistence and concurrency invariants
python3 scripts/test_pipeline_cache.py
```

---

## Sideloading and Setup

1. **Install the IPA**: Install via TrollStore (recommended).
2. **Place Game Resources**:
   - Copy the extracted `RomFS` directory into the app's Documents folder:
     ```
     Documents/romfs/System/Resource
     ```
   - If add-on content (DLC) is present, place it into `Documents/aoc`.
3. **Launch the App**:
   - Open the app, choose your preferred language, and tap **Start Game**.
   - The native preparation screen will display shader prewarming progress. Once completed, the game starts automatically.

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details. Original copyright (c) 2026 jhaizhou, with upstream contributions from the nxnative, d2r-mobile, and Ryujinx projects.

---

# 中文说明

[nxnative](https://github.com/seedds/nxnative) 的开源分支，专为 **iOS 17.0+** 与 **Apple A16** 设备适配。无需 Metal 4 支持，即可在 iOS 17 设备上原生运行任天堂 Switch 游戏代码。

本项目基于 **[seedds/nxnative](https://github.com/seedds/nxnative)**（上游基线提交：`9579030e5b1f0443c12b7376559560915b6d4c4b`），融合了 **d2r-mobile**、**Ryujinx**、**Atmosphère**、**yuzu**、**LibHac** 与 **SPIRV-Cross** 的开源成果。完整保留原作者版权声明与许可证。

**免责声明**：本仓库不包含任何游戏数据、密钥、固件或专有代码。用户需自行提供合法导出的 NSP 文件与 `prod.keys`。本项目与任天堂或任何游戏发行商均无任何关联。

---

## 相比上游的核心改动

1. **iOS 17 与 Metal 3 兼容适配**：上游基线要求 **iOS / iPadOS 26 或更高版本**，依赖 Metal 4 特性（命令队列、参数表、驻留集与屏障指令）。本分支将图形管道与计算调度全面适配兼容至传统 Metal 3，支持在 iOS 17.0+ 及 Apple A16 硬件上原生执行。
2. **原生图形准备界面与二进制管线缓存**：
   - 启动前提供原生预热面板，统计已知着色器、预热进度、跳过与命中次数，完成后自动进入游戏。
   - 采用传统 Metal `MTLBinaryArchive` 进行磁盘持久化，按 ABI、Title ID、着色器链、GPU 与系统内核进行多维分区。
   - **iOS 17 缓存限制**：带常量的特化管线在 iOS 17 下主动绕过二进制归档直接走原生即时编译，避免引发系统底层归档异常。
   - **平滑部分失败降级**：若部分条目预热失败或跳过（`PARTIAL`），界面亮起“继续游戏”按钮，允许玩家手动跳过进入游戏并按需编译。
   - 支持损坏归档自动丢弃并在内存重建自愈。
3. **针对 2D 横版优化的触控体验**：
   - 左半屏浮动摇杆，落指即建立操作中心，底座动态跟随。
   - 扩大并右移 ABXY 按键组（适应大屏手感），Y+B 键间保留 6.4 pt 双键连击触发区。
   - 顶角固定大肩键（L/R/ZL/ZR），便于横屏食指触达。
4. **全屏指示条自动隐藏偏好**：通过配置 UIKit 视图控制器偏好请求在游戏时自动隐藏主屏幕指示条，实际淡出与显示行为由 iOS 系统策略决定。
5. **启动多语言选择**：原生启动页提供 13 种可选语言及 1 项“跟随系统”选项（共 14 项），在启动前选择并保存在应用偏好中，不修改游戏存档。
6. **外置 RomFS 架构**：游戏核心资源存放在 `Documents/romfs`，IPA 安装包仅约 410 MB，大幅缩短侧载安装耗时。
 7. **选择性同步主线上游改动**：同步主线连续 yield 退避、上传槽复用、脏页标记缓存及帧节拍控制。
8. **显示节拍 FIFO 队列与前后台稳定性（Build 2026102201 / 2026102202）**：
   - **FIFO 出图保序**：同步主线 PR #31（`6400306`），用至多落后 1 帧的 FIFO 出图替代每次直接取最新帧，彻底消除 16~17.5 ms 帧波动时前帧被丢弃导致的 33 ms 画面骤停。
   - **ZCull 存储尺寸保底**：同步主线 `7c490ed`，按 32×32 图块计算非零尺寸（保底 256 字节），防止 Unity 等引擎内部内存池管理损坏。
   - **后台时钟冻结等待与 VSync 锁定 DisplayLink**：同步主线 `58eb1f8`，切后台时挂起 `GetSystemTick` 客体时钟读取，抑制模式 0/3 冗余通知，垂直同步事件精准追随屏幕刷新节拍。
   - **多挂载点原子 Commit 与离线家长控制**：同步主线 PR #25 与 PR #38。
9. **多仓融合性能与调度优化（Build 2026102202）**：
   - **Metal 帧临时分配强引用优化（源自兄弟项目 `d2r-mobile` PR #126）**：通过 `__strong` 修饰指针消除 ARC 自动释放池高频进出开销。
   - **同核心线程启动优先级即时让步（源自 `seedds/nxnative` 提交 `c188131`）**：严格遵循 Switch Mesosphère 调度，线程启动时同核高优先级立即让步。
   - **音频渲染器 DSP 服务内存精确核算（源自 `seedds/nxnative` 提交 `435a231`）**：支持至修订版 15 的 DSP 服务尺寸计算，宿主兜底补齐本地 CPU 命令列表内存，避免客体显存虚高。
   - **设备高温 30 帧主动限频保护（源自 `seedds/nxnative` 提交 `c4b74a6`）**：在温控达到严重/危急（`>= 2`）时主动限频至 30 fps，消除持续过热剧烈降频引起的跳帧。

---

## 游戏支持与实机状态

本仓库保留了上游在 `dm/games/` 中的七个游戏档案：
- **《超级马力欧兄弟 惊奇》**（Title ID: `010015100B514000`，更新 1.2.1 / `v327680`）：**iOS 17 / A16 本次重点适配验证目标。**
- *其他保留档案*：《火焰之纹章 结合》、《银河战士 生存恐惧》、《十三机兵防卫圈》、《超级马力欧 3D 世界 + 狂怒世界》、《塞尔达传说 旷野之息》、《塞尔达传说 织梦岛》（其他档案保留自上游，iOS 17 下的实机表现需逐一验证）。

### 设备与测试状态（Build 2026102202）
- **测试机型**：iPhone 14 Pro Max（Apple A16 Bionic，iOS 17.0，TrollStore 安装）。
- **最新候选版本**：`2026102202`（`SMBWMobile-iOS17-v1.0.0-build2026102202.ipa`，391.1 MB）。
- **版本状态**：
  - 离线自动化测试全数通过：`t_nvn`（63/63）、`t_present_handoff`（35/35）、`t_oe`（47/47）。
  - 完整集成 DisplayLink FIFO 出图保序（`DM_PRESENT_FIFO`）、ZCull 尺寸保底、切后台客体时钟安全挂起与垂直同步对齐。
  - 融合 `d2r-mobile` PR #126 ARC 临时缓冲消除、`c188131` 同核调度、`435a231` audren 服务尺寸核算与 `c4b74a6` 高温主动防过热限频。
  - 保持 7 款游戏 profile 完整支持、确定性着色器链与 TrollStore 内核内存提权。

---

## 源码构建指南

### 1. 准备环境（macOS，已安装 Xcode 与 Homebrew）

```bash
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m pip install lz4 capstone fonttools
```

### 2. 打包 IPA

将游戏 NSP 文件（本体 + 更新补丁）放入文件夹，指定 `prod.keys` 路径：

```bash
python3 scripts/build_ipa_from_nsp.py /path/to/game_nsp_folder -k /path/to/prod.keys
```

### 3. 代码签名与 TrollStore 安装说明
- 默认出包为未签名 IPA。
- 设置 `NX_TROLLSTORE=1` 打包将内嵌本地 ad-hoc 签名及两项内核内存权限（`extended-virtual-addressing` 与 `increased-memory-limit`），通过 TrollStore 安装可保留该权限。未授权扩展虚拟内存的第三方签名工具可能遭遇内存分配异常。

### 4. 可选功能说明
- **宽屏实验（默认关闭）**：启动游戏前可在启动页勾选开启 1560×720 宽屏选项，对共享透视与正交相机横向投影进行补偿。
- **贴图补充包**：出包时可设置 `NX_A16_PACK=/path/to/romfs_a16`。若需停用补充包回退至原版贴图，在 `Documents/env.txt` 中加入 `DM_A16_OVERLAY=0`。

### 5. 离线工具链校验

```bash
# 验证全部 7 个档案的 iOS 17 arm64 交叉编译
python3 scripts/check_ios17_compile.py --all-profiles

# 验证 Metal 管道二进制归档与并发守恒
python3 scripts/test_pipeline_cache.py
```

---

## 安装与导入资源

1. **安装 IPA**：推荐通过 TrollStore 安装。
2. **放置游戏资源**：
   - 将提取出的 RomFS 文件夹整体拷贝至应用的 Documents 目录下：
     ```
     Documents/romfs/System/Resource
     ```
   - 如有 DLC 资源，放置在 `Documents/aoc` 下。
3. **启动游戏**：
   - 打开应用，在启动页选择语言并设置选项后点击“开始游戏”，启动面板将自动进行着色器预热，完成后进入游戏。

---

## 开源许可证

本项目基于 **MIT 许可证** 开源 — 详见 [LICENSE](LICENSE) 文件。
原始版权所有 (c) 2026 jhaizhou，保留上游 nxnative、d2r-mobile 与 Ryujinx 项目的一切版权与致谢声明。

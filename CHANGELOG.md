# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-10-19 (Build 2026101906)

### Added
- **iOS 17.0+ & Apple A16 Metal 3 Compatibility**: Replaced upstream Metal 4 command queues, command buffers, argument buffers, residency sets, and barrier calls with traditional Metal 3 primitives, enabling native execution on iOS 17 and Apple A16 devices.
- **Startup Graphics Preparation Gate & Binary Archive Cache**:
  - Implemented a native startup preparation panel displaying real-time prewarming progress, total known items, failures, skips, and cache hit metrics before guest execution begins.
  - Persistent pipeline caching utilizing traditional Metal `MTLBinaryArchive` partitioned by ABI (`nvn-ios17-pso-1`), title ID, shader chain, GPU identity, kernel OS version, and module fixup hashes.
  - Safe backgrounding handling that pauses warmup and asynchronously flushes cached pipelines via `beginBackgroundTaskWithName:`.
  - iOS 17 specialization guard: pipelines utilizing function constants bypass archive serialization on iOS < 18 to avoid OS-level serialization exceptions and compile directly on demand.
  - Self-healing recovery: corrupted archives on disk are detected, discarded in memory, and cleanly rewritten on subsequent atomic flushes.
- **Ergonomic Touch Controls**:
  - Floating virtual joystick on the left half-screen with neutral finger-drop positioning and dynamic base following.
  - Redesigned 2D action buttons: enlarged 92 pt face buttons (X/A/Y/B) shifted right by approximately 48 pt on iPhone 14 Pro Max for natural thumb rest, with a 6.4 pt chord overlap for Y+B run/jump actions.
  - Fixed top-edge shoulder buttons (140x70.4 pt visual / 156x88 pt touch hit) extended outward toward screen edges.
- **In-Game Automatic Home Indicator Hiding**: Configured root view controller UIKit preferences to automatically fade the home indicator bar during active gameplay.
- **Multi-Language Selector**: Native startup language picker offering 13 selectable languages plus a "Follow System" option (14 choices total), storing user choice in application preferences without altering game save data.
- **Opt-in 1560x720 Native Widescreen Experiment**:
  - Optional internal render target expansion to 1560x720 (disabled by default; selectable before starting game).
  - Projection adjustments for shared perspective matrices (0x3c0184) and shared orthographic 16:9 canvases (0xf190c) to compensate for horizontal stretching.
- **External RomFS Resource Architecture**: Separates game RomFS resources from the core executable, keeping the sideloaded application package compact (~410 MB).
- **Verification Tooling**: Included portable offline verification scripts (`scripts/check_ios17_compile.py` and `scripts/test_pipeline_cache.py`).

### Changed
- **Shader Translation Chain & Deterministic Rebuild**:
  - Deterministic build with path mapping applied to the in-repo translator (`dmsh_xlate.dll`), establishing clean chain version `8112c06188b4` (Super Mario Bros. Wonder) in `dmsh_chain.lock` and `dmsh_chain.h` for reproducible public source builds.
  - Fixed dynamic texture offset capability handling in the Ryujinx translator, preventing improper constant composite creation in compute shaders.
  - Targeted Metal Shading Language compilation for iOS 17.0 AIR targets with content-addressed compiler caching.
- **Upstream Optimizations (Selective Backports from `seedds/nxnative`)**:
  - Backported continuous yield backoff after 2 ms.
  - Reused texture upload slots and GPU-idle spares.
  - Cached dirty memory page ranges and batched memory unprotection.
  - Deferred fully covered uniform updates with conflict flushes.
  - Corrected display interval pacing and fixed thread/audio shutdown races.

### User-Reported Device Testing (2026-10-19)
- On 2026-10-19, user device testing of build `2026101906` on iPhone 14 Pro Max (Apple A16, iOS 17.0, installed via TrollStore) reported that this build ran with no operational problems.
- Note on historical items: earlier test builds noted a rendering color anomaly on characters in World 2 and visual stretching of menus in experimental widescreen mode; these remain documented from prior iterations with targeted retesting in 1906 pending.

### Verified Offline Scope
- 7 game profiles cross-compiled 3 modified units each for arm64 iOS 17.0 with 0 availability failures (21 units total).
- 9 isolated Metal pipeline cache fixture test cases verified with strict zero-exit-code subprocess checks and concurrency conservation invariants.
- Verified packaging integrity: valid ZIP CRC, 6 embedded Mach-O module sections, and ad-hoc memory entitlements (`extended-virtual-addressing` and `increased-memory-limit`).

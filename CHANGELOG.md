# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-10-22 (Build 2026102201)

### Added
- **DisplayLink FIFO Ordering (`DM_PRESENT_FIFO`)**:
  - Synced upstream PR #31 (`6400306`).
  - Solves the frame pacing regression where dequeuing the newest frame dropped earlier frames when two frames landed in the same refresh cycle (16–17.5 ms frame times), causing the following frame to stay on screen for 33 ms.
  - Keeps at most one frame behind the newest in FIFO order, smoothing frame delivery and eliminating 33 ms hold hitches.
  - Verified offline via `dm/gfx/tests/t_present_handoff` (35 checks, 0 failures).
- **ZCull Storage Allocation Size Guard**:
  - Synced upstream commit `7c490ed`.
  - Calculates non-zero ZCull save area based on 32x32 tiles (8 bytes per tile/layer, minimum 256 bytes) in `nvnTextureGetZCullStorageSize` and `nvnTextureBuilderGetZCullStorageSize`.
  - Prevents game-level memory pool corruption in engines that allocate ZCull storage (e.g. Cuphead / Unity).
  - Verified offline via `dm/gfx/tests/t_nvn` (63 checks, 0 failures).
- **App Switching Clock Pause & VSync Synchronization**:
  - Synced upstream commit `58eb1f8`.
  - Added `guest_clock_read_wait()` to `hle_svc.c` (SVC 0x1E `GetSystemTick`) to prevent guest loops from reading 0 clock delta when backgrounded.
  - Added `focus_notifies()` filter in `hle_oe.c` to suppress unnecessary focus notifications under modes 0 and 3.
  - Implemented `mtl_link_wait_vsync()` in `nvn_mtl.m` and `hle_sdk16.c` to bind `vi::GetDisplayVsyncEvent` to display-link ticks.
  - Verified offline via `dm/host/tests/build/t_oe` (47 checks, 0 failures).
- **Transactional Save Multi-Mount Commit**:
  - Synced upstream PR #25 (`f1b1f24`).
  - Added multi-mount `Commit` overload `_ZN2nn2fs6CommitEPKPKci` in `hle_fs.c`, validating mount list atomicity and guarding against partial/independent save commits.
- **Parental Control Free Communication Offline Query**:
  - Synced upstream PR #38 (`8e1e8d7`).
  - Added `_ZN2nn4pctl32CheckFreeCommunicationPermissionEb` returning false offline without opening missing IPC services.

### Changed
- **Metal Presentation Race Fix (Build 2026102106 retention)**:
  - Preserved the scheduled presentation in-flight counter and mutex wait guard in `nvn_mtl.m` to eliminate secondary boot crashes caused by CAMetalDisplayLink attachment races.
- **Header Definitions**:
  - Added `guest_clock_read_wait` prototype to `dm/host/dm.h` and `dm/host/hle.h`.

### Verified Offline Scope
- Built and published package `SMBWMobile-iOS17-v1.0.0-build2026102201.ipa` (391.1 MB) with TrollStore memory entitlements (`extended-virtual-addressing` and `increased-memory-limit`).
- Verified thin arm64 Mach-O structure, iOS 17.0 deployment target, absence of Metal 4 dependencies, and embedded warmup manifest (3,204 rows).
- Verified via unit test suites: `t_nvn` (63 passed), `t_present_handoff` (35 passed), `t_oe` (47 passed).

## [Unreleased] - 2026-10-22 (Build 2026102201)

### Added
- **DisplayLink FIFO Ordering (`DM_PRESENT_FIFO`)**:
  - Synced upstream PR #31 (`6400306`).
  - Solves the frame pacing regression where dequeuing the newest frame dropped earlier frames when two frames landed in the same refresh cycle (16–17.5 ms frame times), causing the following frame to stay on screen for 33 ms.
  - Keeps at most one frame behind the newest in FIFO order, smoothing frame delivery and eliminating 33 ms hold hitches.
  - Verified offline via `dm/gfx/tests/t_present_handoff` (35 checks, 0 failures).
- **ZCull Storage Allocation Size Guard**:
  - Synced upstream commit `7c490ed`.
  - Calculates non-zero ZCull save area based on 32x32 tiles (8 bytes per tile/layer, minimum 256 bytes) in `nvnTextureGetZCullStorageSize` and `nvnTextureBuilderGetZCullStorageSize`.
  - Prevents game-level memory pool corruption in engines that allocate ZCull storage (e.g. Cuphead / Unity).
  - Verified offline via `dm/gfx/tests/t_nvn` (63 checks, 0 failures).
- **App Switching Clock Pause & VSync Synchronization**:
  - Synced upstream commit `58eb1f8`.
  - Added `guest_clock_read_wait()` to `hle_svc.c` (SVC 0x1E `GetSystemTick`) to prevent guest loops from reading 0 clock delta when backgrounded.
  - Added `focus_notifies()` filter in `hle_oe.c` to suppress unnecessary focus notifications under modes 0 and 3.
  - Implemented `mtl_link_wait_vsync()` in `nvn_mtl.m` and `hle_sdk16.c` to bind `vi::GetDisplayVsyncEvent` to display-link ticks.
  - Verified offline via `dm/host/tests/build/t_oe` (47 checks, 0 failures).
- **Transactional Save Multi-Mount Commit**:
  - Synced upstream PR #25 (`f1b1f24`).
  - Added multi-mount `Commit` overload `_ZN2nn2fs6CommitEPKPKci` in `hle_fs.c`, validating mount list atomicity and guarding against partial/independent save commits.
- **Parental Control Free Communication Offline Query**:
  - Synced upstream PR #38 (`8e1e8d7`).
  - Added `_ZN2nn4pctl32CheckFreeCommunicationPermissionEb` returning false offline without opening missing IPC services.

### Changed
- **Metal Presentation Race Fix (Build 2026102106 retention)**:
  - Preserved the scheduled presentation in-flight counter and mutex wait guard in `nvn_mtl.m` to eliminate secondary boot crashes caused by CAMetalDisplayLink attachment races.
- **Header Definitions**:
  - Added `guest_clock_read_wait` prototype to `dm/host/dm.h` and `dm/host/hle.h`.

### Verified Offline Scope
- Built and published package `SMBWMobile-iOS17-v1.0.0-build2026102201.ipa` (391.1 MB) with TrollStore memory entitlements (`extended-virtual-addressing` and `increased-memory-limit`).
- Verified thin arm64 Mach-O structure, iOS 17.0 deployment target, absence of Metal 4 dependencies, and embedded warmup manifest (3,204 rows).
- Verified via unit test suites: `t_nvn` (63 passed), `t_present_handoff` (35 passed), `t_oe` (47 passed).

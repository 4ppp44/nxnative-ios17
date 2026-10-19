DM_ROOT ?= $(HOME)/dm-work
# Game profile (dm/games/<id>/): the host is built for it (make GAME=base game title ID, required: there is no default game). game_profile.h is generated from game.tsv into gen/<id>/, dmsh_chain.h lives in the profile folder
# without GAME only clean and a bare make (whose default goal only builds libvpx) pass; anything else stops and lists the profiles
ifeq ($(strip $(GAME)),)
ifneq ($(filter-out clean,$(MAKECMDGOALS)),)
$(error 没设 GAME | GAME is not set: make GAME=<基础版标题号 | base game title ID>: $(shell python3 ../games/game.py list | awk -F'\t' '{printf "%s (%s)  ", $$1, $$3}'))
endif
endif
GAME_DIR = ../games/$(GAME)
GAME_H = gen/$(GAME)/game_profile.h
CFLAGS=-O1 -g -Wall -Wno-unused-function
# Service-layer takeover hle_*.c files are included by wildcard: adding a file does not touch this line (avoids merge conflicts)
SRC=main.c loader.c hle.c host_stubs.c crash.c probe.c thread.c memstat.m ../ios/Sources/dm_touch_controls.c $(sort $(wildcard hle_*.c)) front_mac.m entry.S dm_i18n.c
# NVN null device + nn::vi (dm/gfx/)
# Sources under dm/gfx and dm/gfx/nvn are included by wildcard (tests/ and metal/ do not go into the host): adding a file does not touch this line
GFX=$(sort $(wildcard ../gfx/*.c ../gfx/nvn/*.c ../gfx/nvn/*.m ../gfx/nvn/*.S ../gfx/tex/*.c ../gfx/tex/*.m))
GFX_H=$(sort $(wildcard ../gfx/nvn/*.h ../gfx/nvn/include/*.h ../gfx/tex/*.h))
# Third party: only the decompression-related sources of libdeflate are built (TACT BLTE zlib blocks, hle_tact.c)
LIBDEFLATE=../third_party/libdeflate/lib/deflate_decompress.c ../third_party/libdeflate/lib/zlib_decompress.c ../third_party/libdeflate/lib/adler32.c ../third_party/libdeflate/lib/utils.c ../third_party/libdeflate/lib/arm/cpu_features.c
# Third party: libvpx ships only the VP9 decoder's sources (movie decoding, hle_movie.c), with its configuration headers in config/ (arm64, shared by Mac and iOS). Built separately into a static library, file by file, so host changes do not recompile it
VPX=../third_party/libvpx
VPX_SRC=$(sort $(shell find $(VPX) -name '*.c'))
VPX_OBJ=$(patsubst $(VPX)/%.c,gen/vpx/%.o,$(VPX_SRC))
VPX_LIB=gen/vpx/libvpx.a
gen/vpx/%.o: $(VPX)/%.c $(wildcard $(VPX)/config/*.h)
	@mkdir -p $(dir $@)
	clang -O2 -g -I$(VPX) -I$(VPX)/config -c $< -o $@
$(VPX_LIB): $(VPX_OBJ)
	rm -f $@; ar rcs $@ $^
.DEFAULT_GOAL := dmhost   # The header generation rules are written first below, so the default goal must be stated explicitly (otherwise make only generates the headers and does not build the host)
# Headers generated from the original game's tables: not checked into the repository, generated at build time from the player's own game files (Update/RomFS of Switch version 3.3.94012); the path is given by the environment variable DM_ROMFS_SRC
ROMFS?=$(or $(DM_ROMFS_SRC),$(DM_ROOT)/data/switch/3.3.94012/Update/RomFS)
GENH=dm_vault_tab.h dm_hud_exp.h dm_bright_levels.inc
NEED_ROMFS=@test -f "$(ROMFS)/data/build_manifest.psv" || { echo "🔴 没找到游戏文件：$(ROMFS)/data/build_manifest.psv。把 Switch 版 3.3.94012 的 Update/RomFS 放到这里，或用环境变量 DM_ROMFS_SRC 指过去（见 dm/README.md「从你的游戏文件生成资源」）"; exit 1; }
dm_vault_tab.h: ../ios/tools/gen_vault_table.py
	$(NEED_ROMFS)
	python3 ../ios/tools/gen_vault_table.py "$(ROMFS)" > $@.tmp && mv $@.tmp $@
dm_hud_exp.h: ../ios/tools/gen_hud_exp.py ../ios/tools/romfs_art.py
	$(NEED_ROMFS)
	python3 ../ios/tools/gen_hud_exp.py "$(ROMFS)" > $@.tmp && mv $@.tmp $@
dm_bright_levels.inc: ../tools/gen_bright_levels.py ../ios/tools/touch_layout.py
	$(NEED_ROMFS)
	python3 ../tools/gen_bright_levels.py "$(ROMFS)" > $@.tmp && mv $@.tmp $@
.PHONY: game_profile
game_profile: $(GAME_H)
$(GAME_H): $(GAME_DIR)/game.tsv ../games/game.py
	python3 ../games/game.py header $(GAME) $@
# Records which game the host was built for: changing GAME changes the stamp's content and rebuilds the host (otherwise make sees dmhost as newer than both headers and keeps the other game's host)
GAME_STAMP = gen/game.stamp
$(GAME_STAMP): FORCE
	@mkdir -p gen; echo $(GAME) | cmp -s - $@ || echo $(GAME) > $@
.PHONY: FORCE
FORCE:
dmhost: $(SRC) $(GFX) dm.h dm_wonder_wide.h hle.h dm_input.h front.h touch_mac.h ../ios/Sources/dm_touch_controls.[ch] $(GFX_H) $(GAME_H) $(GAME_DIR)/dmsh_chain.h $(GAME_STAMP) $(VPX_LIB)
	clang $(CFLAGS) -I../gfx/nvn/include -I$(dir $(GAME_H)) -I$(GAME_DIR) -I$(VPX) -I../third_party/stb_vorbis -fobjc-arc -o $@ $(SRC) $(GFX) $(VPX_LIB) -framework Cocoa -framework QuartzCore -framework Metal -framework AudioToolbox -framework ImageIO -framework UniformTypeIdentifiers

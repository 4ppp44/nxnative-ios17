#!/bin/bash
# Build an iOS17 IPA with external game resources. NX_TROLLSTORE=1 opts into
# local ad-hoc signing with the two memory entitlements, for TrollStore to preserve.
# Otherwise the IPA remains unsigned for an external signing tool.
# Prerequisites: the rewriter (patched directory) and the iOS shader build (IOSOUT) have been run as in the README; Xcode and xcodegen are installed.
# Usage: dm/ios/tools/build_ipa.sh [output.ipa]; environment: GAME=game profile (dm/games/<base game title ID>, required), W=the game's work folder (required: <NSP folder>/<title ID>-work, never the home folder), PATCHED / ROMFS / MSL_IOS can each be overridden
#   AOC=add-on content directory (default $W/data/aoc; when it exists it goes to DmIOS.app/aoc/<index>/; an empty string = none)
#   The app name is the game name in the base NSP's control data ($W/data/v0/control.nacp, else the one next to the RomFS), the bundle ID is org.nxnative.<base game title ID in lowercase> (DM_DISPLAY_NAME / DM_BUNDLE_ID override them);
#   the IPA name, code modules, RomFS marker and shader tables come from the game profile
set -eu
cd "$(dirname "$0")/.." || exit 1
IOS=$PWD; DM=$(cd .. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
[ -n "${GAME:-}" ] || die "GAME is not set: GAME=<base game title ID> $0; profiles: $(python3 "$DM/games/game.py" list | awk -F'\t' '{printf "%s (%s)  ", $1, $3}')"
export GAME; GD=$DM/games/$GAME   # the make that gen_build.py runs uses the same GAME
gp() { python3 "$DM/games/game.py" "$GAME" "$1" || die "game profile $GD: $1"; }   # read a key of the game profile
[ -f "$GD/game.tsv" ] || die "no game profile $GD/game.tsv"
[ -n "${W:-}" ] || die "W is not set: W=<NSP folder>/$GAME-work (the game's work folder) $0"
PKG=$(gp package)
PATCHED=${PATCHED:-$W/build/patched_$PKG}; ROMFS=${ROMFS:-$W/data/$PKG/RomFS}; MSL_IOS=${MSL_IOS:-$W/build/ios/dmsh_b}; AOC=${AOC-$W/data/aoc}
ROOT=$(cd "$DM/.." && pwd)
BUILD=${DM_BUILD_NUMBER:-$(date +%Y%m%d01)}
[[ "$BUILD" =~ ^[0-9]{10}$ ]] || die "invalid build identity: must be 10 digits YYYYMMDDNN"
OUT_IPA=${1:-$ROOT/releases/${DM_DISPLAY_NAME:-App}-iOS17-v1.0.0-build$BUILD.ipa}; O=$W/build/ios/pkg; DD=$O/dd
mkdir -p "$(dirname "$OUT_IPA")"
[ ! -e "$OUT_IPA" ] || die "release already exists: $OUT_IPA"

MODS=$(gp modules); MARKER=$(gp romfs_marker)
NACP=$W/data/v0/control.nacp; [ -f "$NACP" ] || NACP=$(dirname "$ROMFS")/control.nacp
[ -n "${DM_DISPLAY_NAME:-}" ] || DM_DISPLAY_NAME=$(python3 "$DM/tools/nacp.py" "$NACP") || die "no game name in $NACP (re-extract with nx_extract, or set DM_DISPLAY_NAME)"
export LC_ALL=C DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.nxnative.$(echo "$GAME" | tr 'A-Z' 'a-z')} DM_DISPLAY_NAME DM_APP_CATEGORY=$(gp app_category) DM_TEAM_ID=${DM_TEAM_ID:-0000000000}   # placeholder identity: unsigned, the install tool replaces it
for f in $MODS; do [ -f "$PATCHED/$f.patched.bin" ] && [ -f "$PATCHED/$f.fixups.tsv" ] || die "no rewritten module $PATCHED/$f (run dm/tools/patch_nso.py first)"; done
[ -e "$ROMFS/$MARKER" ] || die "no RomFS at $ROMFS (missing $MARKER)"
V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$GD/dmsh_chain.h")
EXPECTED_V=$(DM_GAME="$GAME" python3 "$DM/gfx/tools/dmsh_chain.py") || die "cannot calculate shader chain"
[ "$V" = "$EXPECTED_V" ] || die "stale shader chain for $GAME: header=$V source=$EXPECTED_V; rebuild this profile's header, Mac/iOS shaders and c1_full first"
[ -n "$V" ] && ls "$MSL_IOS/b-$V" 2> /dev/null | grep -q '_b.metallib$' || die "no iOS shader libraries $MSL_IOS/b-$V (IOSOUT=$MSL_IOS dmsh_build.py ...)"

if [ -n "${NX_SHADER_REFERENCE_IPA:-}" ]; then
  python3 tools/verify_retained_shaders.py "$MSL_IOS" "$V" "$GAME" "$NX_SHADER_REFERENCE_IPA" "${NX_SHADER_REPORT:-$W/shaders-$GAME.json}" || die "retained shader verification"
else
  python3 "$ROOT/scripts/verify_shaders17.py" "$MSL_IOS" "$V" "$GAME" || die "incomplete or wrong-target shader build"
fi

t "app: $DM_DISPLAY_NAME ($DM_BUNDLE_ID)"
t "generate Gen/ (host sources, embedded modules, tables, shader libraries)"
rm -rf Gen && mkdir -p Gen/dm Gen/msl || die "mkdir Gen"
python3 tools/gen_build.py ../host Gen > Gen/dm.xcconfig || die "gen_build"
F=$(python3 tools/gen_embed.py "$PATCHED" Gen/embed.S $MODS) || die "gen_embed"
echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $F" >> Gen/dm.xcconfig
cp "$PATCHED"/*.fixups.tsv "$PATCHED"/*.gates.tsv "$PATCHED"/*.params.tsv "$PATCHED"/*.cuts.tsv "$PATCHED"/*.obs.tsv Gen/dm/ || die "copy rewriter tables"
cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$GD/c1_full.tsv" Gen/dm/ || die "copy shader tables"
if [ -n "${NX_PSO_MANIFEST:-}" ]; then
  python3 "$ROOT/scripts/verify_pso_manifest.py" "$NX_PSO_MANIFEST" "$MSL_IOS/b-$V" || die "private pipeline warmup manifest"
  cp "$NX_PSO_MANIFEST" Gen/dm/pso_manifest.tsv || die "copy private pipeline warmup seed"
fi
if [ -n "${NX_A16_PACK:-}" ]; then
  python3 "$ROOT/scripts/verify_texture_pack.py" "$NX_A16_PACK" "$ROMFS" Gen/dm/a16_texture_pack.json || die "A16 texture pack"
fi
# Diagnostic build: DM_ENV_FILE=file → dm/env.txt in the bundle (main.m sets one environment variable per line at boot)
if [ -n "${DM_ENV_FILE:-}" ]; then cp "$DM_ENV_FILE" Gen/dm/env.txt || die "copy DM_ENV_FILE"; t "env: $(grep -v '^#' "$DM_ENV_FILE" | tr '\n' ' ')"; fi
cp -cR "$MSL_IOS/b-$V" Gen/msl/ || die "copy shader libraries"
# Shared-font stand-ins: standard = macOS's Arial Unicode (absent on iOS), Nintendo extension = button icons generated by make_ext_font.py (needs fontTools; FONT_PY names a python that has it)
mkdir -p Gen/dm/font && cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" Gen/dm/font/standard.ttf || die "copy standard font (STD_FONT=a TTF)"
${FONT_PY:-python3} "$DM/tools/make_ext_font.py" Gen/dm/font/nintendo_ext.ttf > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
# App icon: the game's own icon (icon.jpg saved from the control data by nx_extract, the English 256x256 one). DM_ICON can point at another image; by default the icon.jpg next to the RomFS is used.
# It is scaled to a 1024x1024 PNG in the asset catalog Gen/Assets.xcassets (a single-size app icon; actool generates the other sizes); with neither, no icon is set and the home-screen icon is blank.
# The catalog is always created (the project always lists it, see project.yml); without an icon it stays empty and DM_APPICON is not set
ICON=${DM_ICON:-$(dirname "$ROMFS")/icon.jpg}
mkdir -p Gen/Icons || die "icon directory"
if [ -f "$ICON" ]; then
  for spec in '120 Icon60@2x' '180 Icon60@3x' '76 Icon76' '152 Icon76@2x' '167 Icon83_5@2x'; do
    read -r size name <<< "$spec"
    sips -s format png -z "$size" "$size" "$ICON" --out "Gen/Icons/$name.png" > /dev/null || die "icon conversion"
  done
  t "legacy PNG icons: $ICON"
fi
xcodegen generate -q > /dev/null || die "xcodegen"

t "xcodebuild (Release, unsigned, iPhone + iPad)"
mkdir -p "$O"
xcodebuild -project DmIOS.xcodeproj -target DmIOS -configuration Release -sdk iphoneos -arch arm64 SYMROOT="$DD/Build/Products" OBJROOT="$DD/Build/Intermediates" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DM_BUILD_NUMBER="$BUILD" IPHONEOS_DEPLOYMENT_TARGET=17.0 build > "$O/build.log" 2>&1 \
  || { grep -E 'error:' "$O/build.log" | head -20; die "xcodebuild, log $O/build.log"; }
# When Xcode's Locations setting is a custom location, products ignore -derivedDataPath: take the actual path from this build's log
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app; [ -d "$APP" ] || APP=$(grep -o '/[^ ]*/Release-iphoneos/DmIOS\.app' "$O/build.log" | tail -1)
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app"; t "app: $APP"

t "assemble Payload (app; RomFS stays external)"
rm -rf "$O/Payload" && mkdir -p "$O/Payload" && cp -cR "$APP" "$O/Payload/DmIOS.app" || die "copy app"
A=$O/Payload/DmIOS.app; rm -rf "$A/_CodeSignature" "$A/embedded.mobileprovision"
if [ "${NX_TROLLSTORE:-0}" = 1 ]; then
  t "local ad-hoc signature with memory entitlements (TrollStore; no device action)"
  /usr/libexec/PlistBuddy -c 'Add :NXSigningMode string trollstore-adhoc-memory' "$A/Info.plist" || die "signing mode metadata"
  codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements Sources/DmIOS.entitlements "$A" || die "ad-hoc signing"
  codesign --verify --strict --verbose=2 "$A" || die "signature verification"
  python3 "$ROOT/scripts/verify_memory_signature.py" "$A/DmIOS" || die "embedded memory entitlements"
fi
# RomFS stays external; the app already accepts Documents/romfs.
# Add-on content: the RomFS extracted from the player's DLC NSPs, one subdirectory per index (the app sets DM_AOC_DIR at launch; the host reports them as owned and mounts them from it)
# Add-on content is external as Documents/aoc.

t "zip (already-compressed game files stored, everything else deflated)"
rm -f "$O/out.ipa"
( cd "$O" && zip -qry -n "$(gp zip_store)" out.ipa Payload ) || die "zip"
python3 "$ROOT/scripts/publish_game.py" "$O/out.ipa" "$OUT_IPA" "$ROMFS" "$AOC" "$GAME" "$BUILD" "$PKG" || die "release verification/publication"
rm -rf "$O/Payload"
t "done: $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"

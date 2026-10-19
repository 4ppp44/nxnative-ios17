#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${1:?Usage: scripts/build_game.sh YYYYMMDDNN /path/to/NSP-folder -k /path/to/prod.keys}
shift
[[ "$BUILD" =~ ^[0-9]{10}$ ]] || { echo 'Build must be 10 digits: YYYYMMDDNN' >&2; exit 2; }
[[ $# -gt 0 ]] || { echo 'NSP directory is required' >&2; exit 2; }

export DM_BUILD_NUMBER="$BUILD"
export DOTNET_ROOT=${DOTNET_ROOT:-$(python3 -c 'import pathlib,re,subprocess; s=subprocess.check_output(["dotnet","--list-runtimes"],text=True); print(pathlib.Path(re.search(r"\[([^]]+)\]",s)[1]).parent.parent)' 2>/dev/null || echo "/opt/homebrew/opt/dotnet/libexec")}

if [ "${1:-}" = "--package-existing" ]; then
  shift
  GAME=${1:?An already prepared game profile is required (e.g. 010015100B514000)}
  shift || true
  [[ "$GAME" =~ ^[0-9A-F]{16}$ ]] || { echo 'Invalid profile title ID' >&2; exit 2; }
  export GAME DM_GAME="$GAME"
  PKG=$(python3 "$ROOT/dm/games/game.py" "$GAME" package)
  IPA_NAME=$(python3 "$ROOT/dm/games/game.py" "$GAME" ipa)
  IPA_STEM=${IPA_NAME%.ipa}
  WORK=${DM_ROOT:-"$ROOT/${GAME}_build"}
  export W="$WORK/ipa" PATCHED="$WORK/patched_$PKG" ROMFS="$WORK/extract/$PKG/RomFS" MSL_IOS="$WORK/shader/ios" AOC=""
  [ ! -d "$WORK/aoc" ] || export AOC="$WORK/aoc"
  mkdir -p "$ROOT/releases"
  exec bash "$ROOT/dm/ios/tools/build_ipa.sh" "$ROOT/releases/$IPA_STEM-iOS17-v1.0.0-build$BUILD.ipa"
fi

exec python3 "$ROOT/scripts/build_ipa_from_nsp.py" "$@" --keep-extracted

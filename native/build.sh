#!/usr/bin/env bash
# Builds the combat core for the tests (Linux, template_debug) and the Windows test build (template_release).
#   native/build.sh            both
#   native/build.sh linux      Linux only (what the headless tests load)
#   native/build.sh windows    Windows only
# Needs: g++, scons (pip --user), mingw-w64 with the posix thread model. Runs at low priority with 4 jobs: the VPS also runs live games.
set -euo pipefail
cd "$(dirname "$0")"
GODOT_CPP_COMMIT=1e7926375b62b445fa79db6851f7105b644831f2
SCONS="${SCONS:-$HOME/.local/bin/scons}"
JOBS="${JOBS:-4}"
# godot-cpp lives in one shared cache per commit (compiled once, about 6 minutes), linked into each checkout as thirdparty/godot-cpp.
CACHE="${DM_NATIVE_CACHE:-$HOME/death-muffin/native-cache}/godot-cpp-${GODOT_CPP_COMMIT:0:7}"
if [ ! -d "$CACHE/.git" ]; then
  mkdir -p "$(dirname "$CACHE")"
  git clone -q https://github.com/godotengine/godot-cpp "$CACHE"
  git -C "$CACHE" checkout -q "$GODOT_CPP_COMMIT"
fi
mkdir -p thirdparty
[ "$(readlink thirdparty/godot-cpp 2>/dev/null)" = "$CACHE" ] || { rm -rf thirdparty/godot-cpp; ln -s "$CACHE" thirdparty/godot-cpp; }
# One build at a time against the shared cache: two scons runs regenerating godot-cpp together break each other (2026-10-16).
exec 8>"$CACHE.lock"
flock -w 1800 8 || { echo "native/build.sh: another build holds $CACHE.lock" >&2; exit 1; }
what="${1:-all}"
if [ "$what" = all ] || [ "$what" = linux ]; then
  nice -n 10 "$SCONS" -Q -j"$JOBS" platform=linux target=template_debug api_version=4.7
fi
if [ "$what" = all ] || [ "$what" = windows ]; then
  # Built with debug symbols, which then leave the shipped library for build/symbols/ (outside client/, so no export carries them): stripping
  # moves no code, so the offsets of a crash note (native/README.md "Crash notes") point into this symbols file; the publish keeps it per build.
  nice -n 10 "$SCONS" -Q -j"$JOBS" platform=windows target=template_release api_version=4.7 use_mingw=yes debug_symbols=yes
  DLL=../client/bin/libdmcore.windows.template_release.x86_64.dll
  mkdir -p build/symbols
  x86_64-w64-mingw32-objcopy --only-keep-debug "$DLL" "build/symbols/$(basename "$DLL").debug"
  x86_64-w64-mingw32-strip --strip-all "$DLL"  # the symbol table goes too: the shipped size stays what it was without symbols
fi

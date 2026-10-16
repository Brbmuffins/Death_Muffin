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
if [ ! -d thirdparty/godot-cpp/.git ]; then
  git clone -q https://github.com/godotengine/godot-cpp thirdparty/godot-cpp
fi
if [ "$(git -C thirdparty/godot-cpp rev-parse HEAD)" != "$GODOT_CPP_COMMIT" ]; then
  git -C thirdparty/godot-cpp fetch -q origin
  git -C thirdparty/godot-cpp checkout -q "$GODOT_CPP_COMMIT"
fi
what="${1:-all}"
if [ "$what" = all ] || [ "$what" = linux ]; then
  nice -n 10 "$SCONS" -Q -j"$JOBS" platform=linux target=template_debug api_version=4.7
fi
if [ "$what" = all ] || [ "$what" = windows ]; then
  nice -n 10 "$SCONS" -Q -j"$JOBS" platform=windows target=template_release api_version=4.7 use_mingw=yes
fi

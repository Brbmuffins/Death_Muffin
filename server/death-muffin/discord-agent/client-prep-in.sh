#!/usr/bin/env bash
# The sandboxed half of client-prep.sh (read that first). Runs INSIDE the caller's sandbox, from the worktree root, with PREP_CORE, PREP_BAKE,
# PREP_DIR and PREP_KEYS taken from client-prep.sh's last line (DM_PREP_WINDOWS=1: the Windows core too; SCR: the caller's scratch folder).
# Copies the cached core, import and bakes in; builds the combat core when the job changed native/ (on the job's own copy of godot-cpp: the
# shared one is read-only here); imports; bakes the crowd when the job changed its inputs. One line per step; exit 1 with the log's tail on a failure.
set -euo pipefail
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
SCR="${SCR:-$(mktemp -d)}"
IFS=, read -r CORE_KEY IMPORT_KEY BAKE_KEY <<<"$PREP_KEYS"
LIN=libdmcore.linux.template_debug.x86_64.so
DLL=libdmcore.windows.template_release.x86_64.dll
fail() { tail -20 "$1"; echo "prep: $2 failed"; exit 1; }
mkdir -p client/bin
if [ "$PREP_CORE" = cached ]; then
  cp --remove-destination "$PREP_DIR/$CORE_KEY/$LIN" "client/bin/$LIN"
  [ -z "${DM_PREP_WINDOWS:-}" ] || cp --remove-destination "$PREP_DIR/$CORE_KEY/$DLL" "client/bin/$DLL"
  echo "prep: the combat core from the cache"
else
  CPP=$(ls -d "${DM_NATIVE_CACHE:-/home/ubuntu/death-muffin/native-cache}"/godot-cpp-* | head -1)
  mkdir -p .dm-native-cache
  [ -d ".dm-native-cache/$(basename "$CPP")" ] || cp -a "$CPP" .dm-native-cache/
  DM_NATIVE_CACHE="$PWD/.dm-native-cache" bash native/build.sh "$([ -n "${DM_PREP_WINDOWS:-}" ] && echo all || echo linux)" > "$SCR/native.log" 2>&1 \
    || fail "$SCR/native.log" "building the combat core"
  echo "prep: the combat core built (this change touches native/)"
fi
# Godot's import, seeded from the cache on a fresh worktree; two passes as in client/setup.sh (the extension is listed before the first).
[ -d client/.godot/imported ] || { rm -rf client/.godot; cp -a "$PREP_DIR/$IMPORT_KEY/.godot" client/.godot; }
grep -qx 'res://bin/dmcore.gdextension' client/.godot/extension_list.cfg 2>/dev/null || echo 'res://bin/dmcore.gdextension' >> client/.godot/extension_list.cfg
"$GODOT" --headless --path client --import > /dev/null 2>&1 || true
"$GODOT" --headless --path client --import > "$SCR/import.log" 2>&1 || fail "$SCR/import.log" "the import"
echo "prep: imported"
if [ "$PREP_BAKE" = cached ]; then
  mkdir -p client/assets/crowd/baked
  rsync -a --delete "$PREP_DIR/$BAKE_KEY/baked/" client/assets/crowd/baked/
  echo "prep: the crowd's bakes from the cache"
else
  bash client/tools/bake_crowd.sh > "$SCR/bake.log" 2>&1 || fail "$SCR/bake.log" "baking the crowd"
  echo "prep: the crowd baked (this change touches what the bakes are made from)"
fi

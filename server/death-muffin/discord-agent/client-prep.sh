#!/usr/bin/env bash
# What the game (client/) needs that git does not hold, for a job's checks, screenshots or preview: the combat core library, Godot's import cache
# and the crowd's baked models (client/README.md, native/README.md). Two halves:
#   client-prep.sh <worktree> [--windows]   OUTSIDE the sandbox (check-godot.sh, shot-godot.sh, preview-godot.sh, the runner's trusted copies): makes
#     sure the cache holds them for the base revision (where the job's branch left origin/main: approved code), building any that is missing in
#     a scratch worktree of that revision, never from a job's files, so a job cannot plant a library, an imported scene or a bake that another
#     job then loads. It writes nothing into the job's worktree. Last line, for the caller:
#       PREP core=<cached|build> bake=<cached|build> dir=<cache folder> keys=<core key>,<import key>,<bake key>
#     core=build: the job changed native/; bake=build: it changed what the crowd's bakes are made from (the caller rebuilds those in the sandbox).
#   client-prep-in.sh   INSIDE the sandbox (the caller's payload, from the worktree root): copies what is cached into the worktree, builds what
#     the job changed, and imports.
#   --windows: the Windows core too (a preview's export).
# Cache: $DM_CLIENT_CACHE (default ~/death-muffin/client-cache), one folder per input key, the newest 6 of each kind kept; one build at a time (flock).
set -euo pipefail
TOP="${1:?usage: client-prep.sh <worktree> [--windows]}"
WIN=""; [ "${2:-}" = --windows ] && WIN=1
CACHE="${DM_CLIENT_CACHE:-/home/ubuntu/death-muffin/client-cache}"
NATIVE_CACHE="${DM_NATIVE_CACHE:-/home/ubuntu/death-muffin/native-cache}"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
BASE_REF="origin/${BASE_BRANCH:-main}"
g() { git -C "$TOP" "$@"; }
[ -f "$TOP/client/project.godot" ] || { echo "client-prep: $TOP has no client/project.godot" >&2; exit 2; }
MB=$(g merge-base HEAD "$BASE_REF") || { echo "client-prep: no merge-base with $BASE_REF" >&2; exit 2; }
BAKE_INPUTS=(client/crowd client/tools/bake_crowd.gd client/tools/bake_crowd.sh client/game/dm_creature.gd client/game/dm_creature_mat.gd
  client/game/dm_gear_props.gd client/world/dm_models.gd client/world/dm_animator.gd client/game/view_models.json client/data/content/enemies.json
  client/assets/slice/models)
key() { { for p in "$@"; do echo "$p $(git -C "$TOP" rev-parse "$MB:$p" 2>/dev/null || echo none)"; done; "$GODOT" --version; } | sha256sum | cut -c1-16; }
CORE_KEY="core-$(key native)"
IMPORT_KEY="import-$(key client/assets client/project.godot)"
BAKE_KEY="bake-$(key "${BAKE_INPUTS[@]}" native)"
changed() { [ -n "$(g diff --name-only "$MB" -- "$@")$(g ls-files --others --exclude-standard -- "$@")" ]; }

# ---- the cache: built from the base revision in a scratch worktree, once per key ----
mkdir -p "$CACHE"
exec 9>"$CACHE/.lock"
flock -w 3600 9 || { echo "client-prep: the cache is busy (another build holds $CACHE/.lock)" >&2; exit 1; }
LIN=libdmcore.linux.template_debug.x86_64.so; DLL=libdmcore.windows.template_release.x86_64.dll
NEED_CORE=; [ -s "$CACHE/$CORE_KEY/$LIN" ] || NEED_CORE=linux
[ -z "$WIN" ] || [ -s "$CACHE/$CORE_KEY/$DLL" ] || NEED_CORE=all
NEED_IMPORT=; [ -d "$CACHE/$IMPORT_KEY/.godot/imported" ] || NEED_IMPORT=1
NEED_BAKE=; [ -d "$CACHE/$BAKE_KEY/baked" ] || NEED_BAKE=1
if [ -n "$NEED_CORE$NEED_IMPORT$NEED_BAKE" ]; then
  SW="$CACHE/.scratch-$$"
  cleanup() { git -C "$TOP" worktree remove --force "$SW" >/dev/null 2>&1 || true; rm -rf "$SW"; git -C "$TOP" worktree prune >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  echo "client-prep: building the cache from ${MB:0:12}, the base of this job (a few minutes, once per change on main)"
  g worktree add -q --detach "$SW" "$MB" >/dev/null 2>&1
  ( cd "$SW" && DM_NATIVE_CACHE="$NATIVE_CACHE" bash native/build.sh "${NEED_CORE:-linux}" >/dev/null )
  if [ -n "$NEED_IMPORT$NEED_BAKE" ]; then
    # an earlier base's import (also built here) makes this one incremental
    SEED=$(ls -1dt "$CACHE"/import-*/.godot 2>/dev/null | head -1 || true)
    [ -z "$SEED" ] || cp -a "$SEED" "$SW/client/.godot"
    ( cd "$SW" && bash client/setup.sh >/dev/null )
    [ -z "$NEED_BAKE" ] || ( cd "$SW" && bash client/tools/bake_crowd.sh >/dev/null )
  fi
  mkdir -p "$CACHE/$CORE_KEY" "$CACHE/$IMPORT_KEY" "$CACHE/$BAKE_KEY"
  [ -z "$NEED_CORE" ] || cp -f "$SW/client/bin/$LIN" "$CACHE/$CORE_KEY/"
  [ "$NEED_CORE" != all ] || cp -f "$SW/client/bin/$DLL" "$CACHE/$CORE_KEY/"
  if [ -n "$NEED_IMPORT" ]; then rm -rf "$CACHE/$IMPORT_KEY/.godot"; cp -a "$SW/client/.godot" "$CACHE/$IMPORT_KEY/.godot"; fi
  if [ -n "$NEED_BAKE" ]; then rm -rf "$CACHE/$BAKE_KEY/baked"; cp -a "$SW/client/assets/crowd/baked" "$CACHE/$BAKE_KEY/baked"; fi
  cleanup; trap - EXIT
fi
touch "$CACHE/$CORE_KEY" "$CACHE/$IMPORT_KEY" "$CACHE/$BAKE_KEY"
for kind in core import bake; do ls -1dt "$CACHE/$kind"-* 2>/dev/null | tail -n +7 | xargs -r rm -rf || true; done

changed native && CORE=build || CORE=cached
changed "${BAKE_INPUTS[@]}" native && BAKE=build || BAKE=cached
echo "PREP core=$CORE bake=$BAKE dir=$CACHE keys=$CORE_KEY,$IMPORT_KEY,$BAKE_KEY"

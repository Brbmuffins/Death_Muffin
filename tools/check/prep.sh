#!/usr/bin/env bash
# The one setup of a checkout of the game (tools/check/README.md): what git does not hold, built once per input and shared through one cache.
#   tools/check/prep.sh [--windows] [--no-bake] [--read-only] [<checkout>]   sets up <checkout> (default: the one you are in)
#   tools/check/prep.sh --keys [<checkout>]                                   prints the cache keys (core=, win=, import=, bake=) and exits
#   tools/check/prep.sh --warm <rev> [--windows] [<checkout>]                fills the cache for <rev> (a scratch worktree of it, unless every
#                                                                             piece is cached already) and exits: the trusted half of the agent's prep
# It makes the combat core for Linux (client/bin, what the headless game loads; --windows also the Windows one and its symbols, for exports),
# Godot's import (client/.godot), the crowd's baked models (client/assets/crowd/baked; --no-bake skips them) and the lobby's packages
# (server/death-muffin/lobby/node_modules, for the co-op suites). Run it in every new checkout
# or worktree and after switching branches; it is quick when nothing changed.
# The cache: one folder per piece and key, $DM_BUILD_CACHE/<kind>-<key> (default /home/ubuntu/death-muffin/build-cache), kinds core, win,
# import, bake and lobby (that one keyed by the lockfile and the node version). A key is the git tree of the piece's inputs at the checkout's HEAD (Markdown left out) plus the Godot version, so a piece is reused exactly when
# what it is made of is the same. A piece whose inputs have uncommitted changes is built here and never stored, and --read-only (the Discord
# agent's sandbox) stores nothing. Godot's import always runs after the copy, so an import seeded from another key (the newest, when no exact
# key matches) only saves time and is never stale; an import made with the licensed flipbook sheets present is never stored. Entries appear
# whole (copied aside, then renamed); the newest $DM_PREP_KEEP (default 6) of each kind are kept. DM_PREP_SLOTS=<dir> (CI) uses one folder
# per kind, <dir>/<kind>, holding the key it was made for in .key (restored and saved by actions/cache), instead of the keyed folders.
# A checkout remembers which keys it holds (native/build/.prep-core, .prep-win; crowd/baked/.prep-bake; lobby/node_modules/.prep-lobby), so a
# second run skips what is current.
# Last line: PREP core=<kept|cached|built> win=<kept|cached|built|-> import=<cached|seeded|kept|fresh> bake=<kept|cached|built|skipped> lobby=<kept|cached|installed|missing|-> stored=<kinds|-> seconds=<n>
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
CACHE="${DM_BUILD_CACHE:-/home/ubuntu/death-muffin/build-cache}"
SLOTS="${DM_PREP_SLOTS:-}"
KEEP="${DM_PREP_KEEP:-6}"
WIN=""; BAKE=1; RO=""; MODE=prep; REV=""; TOP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --windows) WIN=1 ;;
    --no-bake) BAKE="" ;;
    --read-only) RO=1 ;;
    --keys) MODE=keys ;;
    --warm) MODE=warm; REV="${2:?prep.sh: --warm needs a revision}"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "prep.sh: unknown option $1" >&2; exit 2 ;;
    *) TOP="$1" ;;
  esac
  shift
done
TOP="$(cd "${TOP:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HERE")}" && pwd)"
# (--warm only reads the repository's history: the revision is checked out in a scratch worktree)
[ "$MODE" = warm ] || [ -f "$TOP/client/project.godot" ] || { echo "prep.sh: $TOP is not a checkout of the game (no client/project.godot)" >&2; exit 2; }
git -C "$TOP" rev-parse --git-dir >/dev/null 2>&1 || { echo "prep.sh: $TOP is not a git checkout" >&2; exit 2; }

# What each piece is made of. The bake also reads the combat core (it poses the bodies through the game's own code).
CORE_IN=(native)
IMPORT_IN=(client/assets client/project.godot)
BAKE_IN=(client/crowd client/tools/bake_crowd.gd client/tools/bake_crowd.sh client/game/dm_creature.gd client/game/dm_creature_mat.gd
  client/game/dm_gear_props.gd client/world/dm_models.gd client/world/dm_animator.gd client/game/view_models.json client/data/content/enemies.json
  client/assets/slice/models native)
LOBBY_IN=(server/death-muffin/lobby/package.json server/death-muffin/lobby/package-lock.json)
GV=$("$GODOT" --version)
KEYREV=HEAD
if [ "$MODE" = warm ]; then KEYREV=$(git -C "$TOP" rev-parse --verify "$REV^{commit}"); fi
# Docs (*.md) never count: a README edit next to the code does not cost a rebuild.
key() { { for p in "$@"; do echo "== $p"; git -C "$TOP" ls-tree -r "$KEYREV" -- "$p" 2>/dev/null | grep -v '\.md$' || true; done; echo "$GV"; } | sha256sum | cut -c1-16; }
K=$(key "${CORE_IN[@]}")
CORE_KEY="core-$K"; WIN_KEY="win-$K"
IMPORT_KEY="import-$(key "${IMPORT_IN[@]}")"
BAKE_KEY="bake-$(key "${BAKE_IN[@]}")"
LOBBY_KEY="lobby-$( { key "${LOBBY_IN[@]}"; node --version 2>/dev/null || echo no-node; } | sha256sum | cut -c1-16)"
if [ "$MODE" = keys ]; then printf 'core=%s\nwin=%s\nimport=%s\nbake=%s\nlobby=%s\n' "$CORE_KEY" "$WIN_KEY" "$IMPORT_KEY" "$BAKE_KEY" "$LOBBY_KEY"; exit 0; fi
if [ "$MODE" = warm ]; then
  # Nothing to do when every piece of that revision is cached already (the usual case: once per change on main).
  have() { if [ -n "$SLOTS" ]; then [ "$(cat "$SLOTS/$1/.key" 2>/dev/null)" = "$2" ]; else [ -d "$CACHE/$2" ]; fi; }
  if have core "$CORE_KEY" && have import "$IMPORT_KEY" && { [ -z "$BAKE" ] || have bake "$BAKE_KEY"; } && { [ -z "$WIN" ] || have win "$WIN_KEY"; } && have lobby "$LOBBY_KEY"; then
    echo "PREP warm ${KEYREV:0:12}: cached"; exit 0
  fi
  mkdir -p "$CACHE"
  SW="$CACHE/.warm-${KEYREV:0:12}-$$"
  trap 'git -C "$TOP" worktree remove --force "$SW" >/dev/null 2>&1 || rm -rf "$SW"; git -C "$TOP" worktree prune >/dev/null 2>&1 || true' EXIT
  git -C "$TOP" worktree add -q --detach "$SW" "$KEYREV"
  [ -f "$SW/client/project.godot" ] || { echo "prep.sh: ${KEYREV:0:12} has no client/project.godot" >&2; exit 2; }
  # The revision's own copy of this script, so its keys and steps are the ones that revision is tested with.
  P="$SW/tools/check/prep.sh"; [ -f "$P" ] || P="$0"
  args=(); [ -z "$WIN" ] || args+=(--windows); [ -n "$BAKE" ] || args+=(--no-bake)
  bash "$P" "${args[@]}" "$SW"
  exit 0
fi


T0=$(date +%s)
LOG=$(mktemp -d)
trap 'rm -rf "$LOG"' EXIT
STORED=""
LIN=libdmcore.linux.template_debug.x86_64.so
DLL=libdmcore.windows.template_release.x86_64.dll
fail() { tail -20 "$LOG/$1" >&2; echo "prep: $2 failed" >&2; exit 1; }
dirty() { [ -n "$(git -C "$TOP" status --porcelain -- "$@" 2>/dev/null | grep -v '\.md$' || true)" ]; }
secs() { echo "$(( $(date +%s) - $1 )) s"; }
# The folder holding exactly <key> of <kind>, or nothing.
entry() {
  if [ -n "$SLOTS" ]; then
    if [ "$(cat "$SLOTS/$1/.key" 2>/dev/null)" = "$2" ]; then echo "$SLOTS/$1"; fi
  elif [ -d "$CACHE/$2" ]; then
    [ -n "$RO" ] || touch "$CACHE/$2"
    echo "$CACHE/$2"
  fi
}
# Any import to seed from: the newest.
seed() {
  if [ -n "$SLOTS" ]; then [ ! -d "$SLOTS/import/.godot" ] || echo "$SLOTS/import"
  else { ls -1dt "$CACHE"/import-*/ 2>/dev/null || true; } | head -1 | sed 's#/$##' || true; fi
}
# store <kind> <key> <path>...: a new entry holding copies of the paths, appearing whole; a key another prep stored first is kept.
store() {
  local kind="$1" k="$2" dst tmp; shift 2
  [ -z "$RO" ] || return 0
  if [ -n "$SLOTS" ]; then dst="$SLOTS/$kind"; else dst="$CACHE/$k"; [ ! -d "$dst" ] || return 0; fi
  mkdir -p "$(dirname "$dst")"
  tmp="$(dirname "$dst")/.tmp-$kind-$$"
  rm -rf "$tmp"; mkdir -p "$tmp"
  cp -a "$@" "$tmp/"
  echo "$k" > "$tmp/.key"
  [ -z "$SLOTS" ] || rm -rf "$dst"
  if mv -T "$tmp" "$dst" 2>/dev/null; then STORED="$STORED,$kind"; else rm -rf "$tmp"; fi
}
build_native() {
  if [ -n "$RO" ]; then
    # The sandbox: the shared godot-cpp is read-only here, so the build uses a copy of it in the checkout.
    local cpp; cpp=$(ls -d "${DM_NATIVE_CACHE:-/home/ubuntu/death-muffin/native-cache}"/godot-cpp-*/ 2>/dev/null | head -1 || true)
    mkdir -p "$TOP/.dm-native-cache"
    [ -z "$cpp" ] || [ -d "$TOP/.dm-native-cache/$(basename "$cpp")" ] || cp -a "${cpp%/}" "$TOP/.dm-native-cache/"
    DM_NATIVE_CACHE="$TOP/.dm-native-cache" bash "$TOP/native/build.sh" "$1"
  else
    bash "$TOP/native/build.sh" "$1"
  fi
}
NATIVE_DIRTY=""; ! dirty "${CORE_IN[@]}" || NATIVE_DIRTY=1
mkdir -p "$TOP/client/bin"

# ---- the combat core (Linux) ----
t=$(date +%s); CORE=built; e=""
mkdir -p "$TOP/native/build"
if [ -z "$NATIVE_DIRTY" ] && [ -s "$TOP/client/bin/$LIN" ] && [ "$(cat "$TOP/native/build/.prep-core" 2>/dev/null)" = "$CORE_KEY" ]; then
  CORE=kept; echo "prep: the combat core is current ($(secs "$t"))"
else
[ -n "$NATIVE_DIRTY" ] || e=$(entry core "$CORE_KEY")
if [ -n "$e" ] && [ -s "$e/$LIN" ]; then
  cp --remove-destination "$e/$LIN" "$TOP/client/bin/$LIN"; CORE=cached
  echo "prep: the combat core from the cache ($(secs "$t"))"
else
  build_native linux > "$LOG/native.log" 2>&1 || fail native.log "building the combat core"
  [ -n "$NATIVE_DIRTY" ] || store core "$CORE_KEY" "$TOP/client/bin/$LIN"
  echo "prep: the combat core built ($(secs "$t"))"
fi
if [ -n "$NATIVE_DIRTY" ]; then rm -f "$TOP/native/build/.prep-core"; else echo "$CORE_KEY" > "$TOP/native/build/.prep-core"; fi
fi

# ---- the combat core (Windows) and its symbols, for exports ----
WINS=-
if [ -n "$WIN" ]; then
  t=$(date +%s); e=""
  if [ -z "$NATIVE_DIRTY" ] && [ -s "$TOP/client/bin/$DLL" ] && [ "$(cat "$TOP/native/build/.prep-win" 2>/dev/null)" = "$WIN_KEY" ]; then
    WINS=kept; echo "prep: the Windows combat core is current ($(secs "$t"))"
  else
  [ -n "$NATIVE_DIRTY" ] || e=$(entry win "$WIN_KEY")
  if [ -n "$e" ] && [ -s "$e/$DLL" ]; then
    cp --remove-destination "$e/$DLL" "$TOP/client/bin/$DLL"
    mkdir -p "$TOP/native/build/symbols"; cp -f "$e/symbols/"*.debug "$TOP/native/build/symbols/" 2>/dev/null || true
    WINS=cached; echo "prep: the Windows combat core from the cache ($(secs "$t"))"
  else
    build_native windows > "$LOG/native-win.log" 2>&1 || fail native-win.log "building the Windows combat core"
    [ -n "$NATIVE_DIRTY" ] || store win "$WIN_KEY" "$TOP/client/bin/$DLL" "$TOP/native/build/symbols"
    WINS=built; echo "prep: the Windows combat core built ($(secs "$t"))"
  fi
  if [ -n "$NATIVE_DIRTY" ]; then rm -f "$TOP/native/build/.prep-win"; else echo "$WIN_KEY" > "$TOP/native/build/.prep-win"; fi
  fi
fi

# ---- Godot's import ----
t=$(date +%s); IMP=kept
if [ ! -d "$TOP/client/.godot/imported" ]; then
  IMP=fresh; e=$(entry import "$IMPORT_KEY")
  if [ -n "$e" ]; then IMP=cached; else e=$(seed); [ -z "$e" ] || IMP=seeded; fi
  if [ -n "$e" ]; then rm -rf "$TOP/client/.godot"; cp -a "$e/.godot" "$TOP/client/.godot"; fi
fi
# The extension is listed before the first import: Godot 4.7.2 aborts on exit when it discovers a new GDExtension in the middle of a fresh
# import (seen 2026-10-16), and loads it cleanly when it is listed from the start.
mkdir -p "$TOP/client/.godot"
grep -qx 'res://bin/dmcore.gdextension' "$TOP/client/.godot/extension_list.cfg" 2>/dev/null || echo 'res://bin/dmcore.gdextension' >> "$TOP/client/.godot/extension_list.cfg"
# A fresh import takes two passes: the first may still abort on exit after importing, and loads the project theme before its fonts are
# imported; the second finishes what is left and leaves the project clean, so a failure there is a real one. An import that was already
# there (cached or kept) only needs the one pass that brings it up to this checkout's files, when that pass succeeds.
if nice -n 10 "$GODOT" --headless --path "$TOP/client" --import > "$LOG/import.log" 2>&1 && [ "$IMP" = cached -o "$IMP" = kept ]; then :
else nice -n 10 "$GODOT" --headless --path "$TOP/client" --import > "$LOG/import.log" 2>&1 || fail import.log "the import"; fi
if [ "$IMP" != cached ] && ! dirty "${IMPORT_IN[@]}" && [ -z "$(ls -A "$TOP/client/assets/fx/sheets" 2>/dev/null)" ]; then
  store import "$IMPORT_KEY" "$TOP/client/.godot"
fi
echo "prep: imported ($IMP, $(secs "$t"))"

# ---- the crowd's baked models ----
BK=skipped
if [ -n "$BAKE" ]; then
  t=$(date +%s); e=""; BAKE_DIRTY=""; ! dirty "${BAKE_IN[@]}" || BAKE_DIRTY=1
  B="$TOP/client/assets/crowd/baked"
  if [ -z "$BAKE_DIRTY" ] && [ "$(cat "$B/.prep-bake" 2>/dev/null)" = "$BAKE_KEY" ]; then
    BK=kept; echo "prep: the crowd's models are current ($(secs "$t"))"
  else
  [ -n "$BAKE_DIRTY" ] || e=$(entry bake "$BAKE_KEY")
  if [ -n "$e" ] && [ -d "$e/baked" ]; then
    mkdir -p "$TOP/client/assets/crowd/baked"
    rsync -a --delete --exclude .prep-bake "$e/baked/" "$TOP/client/assets/crowd/baked/"
    BK=cached; echo "prep: the crowd's models from the cache ($(secs "$t"))"
  else
    bash "$TOP/client/tools/bake_crowd.sh" > "$LOG/bake.log" 2>&1 || fail bake.log "baking the crowd"
    [ -n "$BAKE_DIRTY" ] || store bake "$BAKE_KEY" "$TOP/client/assets/crowd/baked"
    BK=built; echo "prep: the crowd's models baked ($(secs "$t"))"
  fi
  if [ -n "$BAKE_DIRTY" ]; then rm -f "$B/.prep-bake"; else echo "$BAKE_KEY" > "$B/.prep-bake"; fi
  fi
fi

# ---- the lobby's packages (ws, jsonwebtoken): the co-op and friends suites start the real lobby ----
LS=-; LB="$TOP/server/death-muffin/lobby"
if [ -f "$LB/package-lock.json" ]; then
  t=$(date +%s); e=""; LOBBY_DIRTY=""; ! dirty "${LOBBY_IN[@]}" || LOBBY_DIRTY=1
  if [ -z "$LOBBY_DIRTY" ] && [ ! -L "$LB/node_modules" ] && [ "$(cat "$LB/node_modules/.prep-lobby" 2>/dev/null)" = "$LOBBY_KEY" ]; then LS=kept
  else
    [ -n "$LOBBY_DIRTY" ] || e=$(entry lobby "$LOBBY_KEY")
    if [ -n "$e" ] && [ -d "$e/node_modules" ]; then
      rm -rf "$LB/node_modules"; cp -a "$e/node_modules" "$LB/node_modules"; LS=cached
    elif [ -n "$RO" ]; then
      LS=missing
      echo "prep: the lobby's packages for this package-lock.json are not cached and the sandbox cannot download them: the co-op suites will fail"
    else
      rm -rf "$LB/node_modules"
      (cd "$LB" && npm ci --no-audit --no-fund) > "$LOG/npm.log" 2>&1 || fail npm.log "installing the lobby's packages"
      [ -n "$LOBBY_DIRTY" ] || store lobby "$LOBBY_KEY" "$LB/node_modules"
      LS=installed
    fi
    if [ "$LS" != missing ]; then
      if [ -n "$LOBBY_DIRTY" ]; then rm -f "$LB/node_modules/.prep-lobby"; else echo "$LOBBY_KEY" > "$LB/node_modules/.prep-lobby"; fi
    fi
  fi
  echo "prep: the lobby's packages $LS ($(secs "$t"))"
fi

# ---- keep the newest few of each kind; drop what an interrupted prep left ----
if [ -z "$SLOTS$RO" ] && [ -d "$CACHE" ]; then
  for kind in core win import bake lobby; do { ls -1dt "$CACHE/$kind"-*/ 2>/dev/null || true; } | tail -n +$((KEEP + 1)) | xargs -r rm -rf; done
  find "$CACHE" -maxdepth 1 -name '.tmp-*' -mmin +180 -exec rm -rf {} + 2>/dev/null || true
fi
STORED="${STORED#,}"
echo "PREP core=$CORE win=$WINS import=$IMP bake=$BK lobby=$LS stored=${STORED:--} seconds=$(( $(date +%s) - T0 ))"

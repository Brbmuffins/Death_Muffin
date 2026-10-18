#!/usr/bin/env bash
# Playable preview of a proposal, Godot mode: preview-godot.sh <jobid>   (run by the RUNNER from the job's worktree, never by the AI).
# 1. The game's build products: client-prep.sh --windows (the trusted cache, built from the base revision), then inside the same sandbox as
#    check-godot.sh (no network, the whole filesystem read-only via sandbox-lib.sh, private /tmp, only the worktree writable, fresh HOME / XDG dirs so
#    Godot's user:// never touches the real home; the installed export templates are re-exposed read-only through XDG_DATA_HOME): client-prep-in.sh
#    (the combat core for Linux and Windows, the import, the crowd's bakes), and the export of the "Windows Desktop" preset to
#    <worktree>/.dm-preview/DeathMuffin.exe (+ .pck + the core's DLL).
# 2. The art: res://assets ships as its own pack (about 500 MB). When nothing it is made of (tools/godot/assets-fp.sh --paths, main's copy) differs from
#    the live build's revision, the preview carries none and its .bat points the game at the installed game's pack (the launcher's
#    %LOCALAPPDATA%\DeathMuffin\client); otherwise tools/godot/assets-pack.sh builds the branch's own pack into the zip.
# 3. Outside the sandbox: zip the build with "Play Preview (offline).bat" (DeathMuffin.exe -- --dev-offline: local testing backend, nothing saves to a
#    real character) and a README, and write it as <previewRoot>/<jobid>/DeathMuffin-Preview-<jobid>-win64.zip (644). Refuses any jobid that is
#    not 6 hex chars, a missing or symlinked preview root, and a symlinked destination; never writes outside <previewRoot>/<jobid>.
# Env: DM_PREVIEW_ROOT (default /var/www/death-muffin/preview), DM_PREVIEW_TITLE (README text), GODOT (default /home/ubuntu/tools/godot/godot),
#      GODOT_TEMPLATES (default /home/ubuntu/.local/share/godot/export_templates), CLIENT_MANIFEST (the live build's, default
#      /var/www/death-muffin/client/manifest.json), DM_CLIENT_CACHE (client-prep.sh), DM_CLIENT_PREP / DM_CLIENT_PREP_IN (tests: stand-ins).
set -euo pipefail
JOB=${1:-}
[[ "$JOB" =~ ^[0-9a-f]{6}$ ]] || { echo "bad job id"; exit 2; }
ROOT=${DM_PREVIEW_ROOT:-/var/www/death-muffin/preview}
export GODOT=${GODOT:-/home/ubuntu/tools/godot/godot}
export GODOT_TEMPLATES=${GODOT_TEMPLATES:-/home/ubuntu/.local/share/godot/export_templates}
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || { echo "preview root $ROOT is missing"; exit 2; }
[ -x "$GODOT" ] || { echo "Godot not found at $GODOT"; exit 2; }
TOP=$(git rev-parse --show-toplevel)
[ -f "$TOP/client/project.godot" ] || { echo "this branch has no client/project.godot"; exit 2; }
OUT="$TOP/.dm-preview"
SCR=$(mktemp -d /tmp/dmprevg.XXXXXX)
trap 'rm -rf "$SCR"' EXIT
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DM_SANDBOX_LIB="$TOOLS/sandbox-lib.sh" TOOLS
# the art: the same as the live build's? (the live revision from its manifest; the list from main's tools/godot/assets-fp.sh, not the branch's)
SAME_ART=""
LIVE_REV=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("rev", ""))' "${CLIENT_MANIFEST:-/var/www/death-muffin/client/manifest.json}" 2>/dev/null || true)
if [[ "$LIVE_REV" =~ ^[0-9a-f]{7,40}$ ]] && git -C "$TOP" cat-file -e "$LIVE_REV^{commit}" 2>/dev/null \
  && ART=$(git -C "$TOP" show "origin/${BASE_BRANCH:-main}:tools/godot/assets-fp.sh" 2>/dev/null | bash -s -- --paths) && [ -n "$ART" ]; then
  # shellcheck disable=SC2086
  git -C "$TOP" diff --quiet "$LIVE_REV" -- $ART && [ -z "$(git -C "$TOP" ls-files --others --exclude-standard -- $ART)" ] && SAME_ART=1
fi
PREP=$(bash "${DM_CLIENT_PREP:-$TOOLS/client-prep.sh}" "$TOP" --windows | tail -1)
[[ "$PREP" =~ ^PREP\ core=(cached|build)\ bake=(cached|build)\ dir=([^\ ]+)\ keys=([a-z0-9,-]+)$ ]] || { echo "client-prep failed: $PREP"; exit 1; }
export PREP_CORE=${BASH_REMATCH[1]} PREP_BAKE=${BASH_REMATCH[2]} PREP_DIR=${BASH_REMATCH[3]} PREP_KEYS=${BASH_REMATCH[4]} DM_PREP_WINDOWS=1
export TOP OUT SAME_ART
rm -rf "$OUT"; mkdir -p "$OUT"
export DM_PAYLOAD='
  set -euo pipefail
  SCR=$(mktemp -d /tmp/dmprevg.XXXXXX)    # inside the sandbox private /tmp
  export SCR HOME="$SCR/home" XDG_DATA_HOME="$SCR/data" XDG_CONFIG_HOME="$SCR/config" XDG_CACHE_HOME="$SCR/cache"
  mkdir -p "$HOME" "$XDG_DATA_HOME/godot" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
  ln -s "$GODOT_TEMPLATES" "$XDG_DATA_HOME/godot/export_templates"
  cd "$TOP"
  bash "${DM_CLIENT_PREP_IN:-$TOOLS/client-prep-in.sh}"
  "$GODOT" --headless --path client --export-release "Windows Desktop" "$OUT/DeathMuffin.exe" > "$SCR/export.log" 2>&1 || { tail -15 "$SCR/export.log"; echo "godot export failed"; exit 1; }
  if [ -z "$SAME_ART" ]; then
    echo "the art differs from the live build: the preview carries its own pack"
    bash tools/godot/assets-pack.sh "$TOP/client" "$OUT/DeathMuffin.assets.pck" "$GODOT" > "$SCR/assets.log" 2>&1 || { tail -15 "$SCR/assets.log"; echo "assets pack failed"; exit 1; }
  fi
'   # the sandboxed work; run by dm_sandbox_run inside the nested namespace (sandbox-lib.sh)
timeout -k 30 1800 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run' || { echo "preview build failed"; exit 1; }
rm -f "$OUT"/*.console.exe
[ -s "$OUT/DeathMuffin.exe" ] && [ "$(head -c2 "$OUT/DeathMuffin.exe")" = "MZ" ] || { echo "export produced no Windows executable"; exit 1; }
[ "$(stat -c %s "$OUT/DeathMuffin.pck" 2>/dev/null || echo 0)" -gt 100000 ] || { echo "export produced no usable DeathMuffin.pck"; exit 1; }
# launcher + readme (title: printable ASCII only, one line; it is text in a readme, never part of the .bat)
TITLE=$(printf '%s' "${DM_PREVIEW_TITLE:-this change}" | tr -c '[:print:]' ' ' | tr -s ' ' | cut -c1-120)
DLL=libdmcore.windows.template_release.x86_64.dll
[ -s "$OUT/$DLL" ] || { echo "export produced no $DLL (the combat core)"; exit 1; }
if [ -f "$OUT/DeathMuffin.assets.pck" ]; then
  printf '@echo off\r\ncd /d "%%~dp0"\r\nDeathMuffin.exe -- --dev-offline\r\n' > "$OUT/Play Preview (offline).bat"
else   # the live game's art: the launcher's install (Settings.InstallDir: %LOCALAPPDATA%\DeathMuffin\client)
  printf '@echo off\r\ncd /d "%%~dp0"\r\nset "PACK=%%LOCALAPPDATA%%\\DeathMuffin\\client\\DeathMuffin.assets.pck"\r\nif not exist "%%PACK%%" (\r\n  echo This preview uses the art of your installed Death Muffin. Install the game with the launcher first.\r\n  pause\r\n  exit /b 1\r\n)\r\nDeathMuffin.exe -- --dev-offline "--assets-pack=%%PACK%%"\r\n' > "$OUT/Play Preview (offline).bat"
fi
printf 'PREVIEW of %s, offline edition, nothing saves to your real character\r\nUnzip everything into one folder, then run "Play Preview (offline).bat".\r\n' "$TITLE" > "$OUT/README.txt"
ZIPNAME="DeathMuffin-Preview-$JOB-win64.zip"
rm -f "$SCR/$ZIPNAME"
ASSETS=""; [ -f "$OUT/DeathMuffin.assets.pck" ] && ASSETS=DeathMuffin.assets.pck
( cd "$OUT" && zip -q -X "$SCR/$ZIPNAME" DeathMuffin.exe DeathMuffin.pck "$DLL" $ASSETS "Play Preview (offline).bat" README.txt ) || { echo "zip failed"; exit 1; }
DEST="$ROOT/$JOB"
[ ! -L "$DEST" ] || { echo "refusing symlinked destination"; exit 2; }
mkdir -p "$DEST"
# replace atomically (mv swaps the directory entry, it never follows a symlink planted at the zip's name), drop anything else left from before
install -m 644 "$SCR/$ZIPNAME" "$DEST/.$ZIPNAME.new" && mv -f "$DEST/.$ZIPNAME.new" "$DEST/$ZIPNAME"
find "$DEST" -mindepth 1 -maxdepth 1 -not -name "$ZIPNAME" -exec rm -rf -- {} +
echo "RESULT: ok $JOB"

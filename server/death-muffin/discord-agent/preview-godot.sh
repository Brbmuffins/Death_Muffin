#!/usr/bin/env bash
# Playable preview of a proposal, Godot mode: preview-godot.sh <jobid>   (run by the RUNNER from the job's worktree, never by the AI).
# 1. Import the project and export the "Windows Desktop" preset to <worktree>/.dm-preview/DeathMuffin.exe (+ .pck), inside the same sandbox as
#    check-godot.sh (no network, the whole filesystem read-only via sandbox-lib.sh, private /tmp, only the worktree writable, fresh HOME / XDG dirs so Godot's user:// never touches the
#    real home; the installed export templates are re-exposed read-only through XDG_DATA_HOME).
# 2. Outside the sandbox: zip the build with "Play Preview (offline).bat" (DeathMuffin.exe -- --dev-offline: local testing backend, nothing saves to a
#    real character) and a README, and write it as <previewRoot>/<jobid>/DeathMuffin-Preview-<jobid>-win64.zip (644). Refuses any jobid that is
#    not 6 hex chars, a missing or symlinked preview root, and a symlinked destination; never writes outside <previewRoot>/<jobid>.
# Env: DM_PREVIEW_ROOT (default /var/www/death-muffin/preview), DM_PREVIEW_TITLE (README text), GODOT (default /home/ubuntu/tools/godot/godot),
#      GODOT_TEMPLATES (default /home/ubuntu/.local/share/godot/export_templates).
set -euo pipefail
JOB=${1:-}
[[ "$JOB" =~ ^[0-9a-f]{6}$ ]] || { echo "bad job id"; exit 2; }
ROOT=${DM_PREVIEW_ROOT:-/var/www/death-muffin/preview}
export GODOT=${GODOT:-/home/ubuntu/tools/godot/godot}
export GODOT_TEMPLATES=${GODOT_TEMPLATES:-/home/ubuntu/.local/share/godot/export_templates}
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || { echo "preview root $ROOT is missing"; exit 2; }
[ -x "$GODOT" ] || { echo "Godot not found at $GODOT"; exit 2; }
TOP=$(git rev-parse --show-toplevel)
[ -f "$TOP/godot/project.godot" ] || { echo "this branch has no godot/project.godot"; exit 2; }
OUT="$TOP/.dm-preview"
SCR=$(mktemp -d /tmp/dmprevg.XXXXXX)
trap 'rm -rf "$SCR"' EXIT
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export TOP OUT
rm -rf "$OUT"; mkdir -p "$OUT"
export DM_PAYLOAD='
  set -euo pipefail
  SCR=$(mktemp -d /tmp/dmprevg.XXXXXX)    # inside the sandbox private /tmp
  export HOME="$SCR/home" XDG_DATA_HOME="$SCR/data" XDG_CONFIG_HOME="$SCR/config" XDG_CACHE_HOME="$SCR/cache"
  mkdir -p "$HOME" "$XDG_DATA_HOME/godot" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
  ln -s "$GODOT_TEMPLATES" "$XDG_DATA_HOME/godot/export_templates"
  cd "$TOP/godot"
  "$GODOT" --headless --path . --import > "$SCR/import.log" 2>&1 || { tail -15 "$SCR/import.log"; echo "godot import failed"; exit 1; }
  "$GODOT" --headless --path . --export-release "Windows Desktop" "$OUT/DeathMuffin.exe" > "$SCR/export.log" 2>&1 || { tail -15 "$SCR/export.log"; echo "godot export failed"; exit 1; }
'   # the sandboxed work; run by dm_sandbox_run inside the nested namespace (sandbox-lib.sh)
timeout -k 30 1800 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run' || { echo "preview build failed"; exit 1; }
rm -f "$OUT"/*.console.exe
[ -s "$OUT/DeathMuffin.exe" ] && [ "$(head -c2 "$OUT/DeathMuffin.exe")" = "MZ" ] || { echo "export produced no Windows executable"; exit 1; }
[ "$(stat -c %s "$OUT/DeathMuffin.pck" 2>/dev/null || echo 0)" -gt 100000 ] || { echo "export produced no usable DeathMuffin.pck"; exit 1; }
# launcher + readme (title: printable ASCII only, one line; it is text in a readme, never part of the .bat)
TITLE=$(printf '%s' "${DM_PREVIEW_TITLE:-this change}" | tr -c '[:print:]' ' ' | tr -s ' ' | cut -c1-120)
printf '@echo off\r\ncd /d "%%~dp0"\r\nDeathMuffin.exe -- --dev-offline\r\n' > "$OUT/Play Preview (offline).bat"
printf 'PREVIEW of %s, offline edition, nothing saves to your real character\r\nUnzip everything into one folder, then run "Play Preview (offline).bat".\r\n' "$TITLE" > "$OUT/README.txt"
ZIPNAME="DeathMuffin-Preview-$JOB-win64.zip"
rm -f "$SCR/$ZIPNAME"
( cd "$OUT" && zip -q -X "$SCR/$ZIPNAME" DeathMuffin.exe DeathMuffin.pck "Play Preview (offline).bat" README.txt ) || { echo "zip failed"; exit 1; }
DEST="$ROOT/$JOB"
[ ! -L "$DEST" ] || { echo "refusing symlinked destination"; exit 2; }
mkdir -p "$DEST"
# replace atomically (mv swaps the directory entry, it never follows a symlink planted at the zip's name), drop anything else left from before
install -m 644 "$SCR/$ZIPNAME" "$DEST/.$ZIPNAME.new" && mv -f "$DEST/.$ZIPNAME.new" "$DEST/$ZIPNAME"
find "$DEST" -mindepth 1 -maxdepth 1 -not -name "$ZIPNAME" -exec rm -rf -- {} +
echo "RESULT: ok $JOB"

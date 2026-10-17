#!/usr/bin/env bash
# SMOKE step for a test-channel build of the rebuilt client, run by publish-godot-client.sh (SMOKE=<this>) after the export and before anything is published:
# exports a Linux debug copy of the same scratch project (code only, like the Windows build) and boots it headless next to the build's assets pack. The boot
# must reach its first screen (main.gd `--boot-smoke` prints "BOOT OK <screen>") with no script error and find every crowd model the PREPARE baked ("CROWD <n>"),
# or the publish stops. Catches what the editor-run tests cannot see: code that only breaks in an export (2026-10-16: the boot named a class from dev/, which
# the export leaves out, and every test build stopped on a grey screen; 2026-10-17: the crowd looked for its models by file name, which an export changes,
# and drew no enemy and no thrall).
#   smoke-rebuild.sh <project folder in the scratch worktree> <stage folder holding DeathMuffin.assets.pck>
set -euo pipefail
PROJ="$1"
STAGE="$2"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
nice -n 10 "$GODOT" --headless --path "$PROJ" --export-debug "Linux" "$TMP/DeathMuffin.x86_64" >"$TMP/export.log" 2>&1 \
  || { tail -20 "$TMP/export.log" >&2; echo "smoke: the Linux export failed" >&2; exit 1; }
[ -f "$STAGE/DeathMuffin.assets.pck" ] || { echo "smoke: no assets pack in $STAGE" >&2; exit 1; }
ln -s "$STAGE/DeathMuffin.assets.pck" "$TMP/DeathMuffin.assets.pck"
( cd "$TMP" && timeout 120 nice -n 10 ./DeathMuffin.x86_64 --headless -- --boot-smoke >"$TMP/boot.log" 2>&1 ) || true
if grep -qE "SCRIPT ERROR|Parse Error" "$TMP/boot.log" || ! grep -q "^BOOT OK" "$TMP/boot.log"; then
  grep -E "SCRIPT ERROR|Parse Error|ERROR|BOOT" "$TMP/boot.log" | head -20 >&2 || true
  echo "smoke: the exported build did not reach its first screen" >&2
  exit 1
fi
want=$(ls "$PROJ"/assets/crowd/baked/*/model.tres 2>/dev/null | wc -l)
got=$(sed -n 's/^CROWD \([0-9]*\)$/\1/p' "$TMP/boot.log" | head -1)
[ "$want" -gt 0 ] && [ "${got:-0}" -eq "$want" ] || { echo "smoke: the exported build finds ${got:-no} of the $want baked crowd models" >&2; exit 1; }
echo "smoke: $(grep '^BOOT OK' "$TMP/boot.log"), $got crowd models"

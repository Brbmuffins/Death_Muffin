#!/usr/bin/env bash
# Export an EXPERIMENTAL Windows client for the owner and a tester, from a COMMITTED revision, without touching the real release.
#
#   publish-test-build.sh <git-rev> <label>
#
# Like publish-godot-client.sh (same scratch `git worktree` of the rev, same flipbook-sheet copy, same Godot 4.7.2 export), but:
#  - in the scratch worktree ONLY, godot/project.godot is patched: its own user:// folder ("Death Muffin TEST", so the test build never
#    shares or overwrites the real client's saved login/settings) and a `dm_test_build="<label>"` setting (main.gd adds it to the window title);
#  - the result is ONE zip, DeathMuffin-TEST-<label>-<sha>.zip, in $OUT_ROOT/<random 16-hex token>/ (an unlisted URL; the folder has no
#    index.html and nginx has no autoindex, so /death-muffin/test/ cannot be listed);
#  - it never writes manifest.json, never runs announce-release.sh, never prunes client/ folders. Only the newest KEEP_TESTS (3) test
#    folders it created are kept.
# Holds ~/death-muffin/deploy/.deploy.lock while exporting (like deploy-release.sh), so it never races a deploy or a ship.
#
# One-time setup: /var/www/death-muffin is root-owned, so $OUT_ROOT is created once with sudo and handed to ubuntu (done here if sudo -n works).
# Test overrides (optional): REPO GODOT OUT_ROOT WORK BASE_URL RUNTIME KEEP_TESTS FX_SHEETS
set -euo pipefail

REV="${1:-}"; LABEL="${2:-}"
[ -n "$REV" ] && [ -n "$LABEL" ] || { echo "usage: $0 <git-rev> <label>" >&2; exit 2; }
[[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,23}$ ]] || { echo "label must be 1-24 chars of A-Z a-z 0-9 . _ - (got: $LABEL)" >&2; exit 2; }

REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
OUT_ROOT="${OUT_ROOT:-/var/www/death-muffin/test}"
RUNTIME="${RUNTIME:-/home/ubuntu/death-muffin}"
WORK="${WORK:-$RUNTIME/deploy}"
BASE_URL="${BASE_URL:-https://muffindevelopment.com/death-muffin/test}"
KEEP_TESTS="${KEEP_TESTS:-3}"
PRESET="Windows Desktop"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
[ -x "$GODOT" ] || { echo "Godot not found at $GODOT" >&2; exit 1; }
SHA=$(git -C "$REPO" rev-parse --short=12 "$REV^{commit}")

if [ ! -d "$OUT_ROOT" ]; then
  mkdir -p "$OUT_ROOT" 2>/dev/null || sudo -n install -d -m 755 -o "$(id -un)" -g "$(id -gn)" "$OUT_ROOT" \
    || { echo "cannot create $OUT_ROOT; run once: sudo install -d -m 755 -o ubuntu -g ubuntu $OUT_ROOT" >&2; exit 1; }
fi
[ -w "$OUT_ROOT" ] || { echo "$OUT_ROOT is not writable by $(id -un)" >&2; exit 1; }

mkdir -p "$WORK"
exec 9>"$WORK/.deploy.lock"
flock -w 1800 9 || { echo "another deploy holds $WORK/.deploy.lock" >&2; exit 1; }

WT="$WORK/godot-test-wt-$SHA"
STAGE="$WORK/godot-test-stage-$SHA"
cleanup() {
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$WT" "$STAGE"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
mkdir -p "$STAGE/pkg"

echo "== exporting test build $LABEL from $SHA"
git -C "$REPO" worktree add -q --detach "$WT" "$SHA" >/dev/null 2>&1
P="$WT/godot/project.godot"
[ -f "$P" ] && [ -f "$WT/godot/export_presets.cfg" ] || { echo "$SHA has no godot project / export presets" >&2; exit 1; }

# Patch the scratch copy only (never the repo): own user:// folder + the test-build marker, right after config/name in [application].
python3 - "$P" "$LABEL" <<'PY'
import sys, re
path, label = sys.argv[1:3]
s = open(path, encoding="utf-8").read()
for key in ("use_custom_user_dir", "custom_user_dir_name", "dm_test_build"):
    assert not re.search(r"^config/%s=" % key, s, re.M), key + " already set in project.godot"
m = re.search(r"^config/name=.*$", s, re.M)
assert m and "[application]" in s[:m.start()], "no [application] config/name line"
add = '\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name="Death Muffin TEST"\nconfig/dm_test_build="%s"' % label
open(path, "w", encoding="utf-8").write(s[:m.end()] + add + s[m.end():])
PY

[ ! -f "$WT/tools/godot/fx-sheets-sync.sh" ] || bash "$WT/tools/godot/fx-sheets-sync.sh" "$WT" >/dev/null
"$GODOT" --headless --path "$WT/godot" --import >"$STAGE/import.log" 2>&1 || { tail -30 "$STAGE/import.log" >&2; echo "godot import failed" >&2; exit 1; }
"$GODOT" --headless --path "$WT/godot" --export-release "$PRESET" "$STAGE/pkg/DeathMuffin.exe" >"$STAGE/export.log" 2>&1 || { tail -30 "$STAGE/export.log" >&2; echo "godot export failed" >&2; exit 1; }
rm -f "$STAGE"/pkg/*.console.exe
[ -s "$STAGE/pkg/DeathMuffin.exe" ] && [ "$(head -c2 "$STAGE/pkg/DeathMuffin.exe")" = "MZ" ] || { echo "DeathMuffin.exe missing or not a Windows executable" >&2; exit 1; }
[ "$(stat -c %s "$STAGE/pkg/DeathMuffin.pck" 2>/dev/null || echo 0)" -gt 100000 ] || { echo "DeathMuffin.pck missing or suspiciously small" >&2; exit 1; }

TOKEN=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
ZIP="DeathMuffin-TEST-$LABEL-$SHA.zip"
DEST="$OUT_ROOT/$TOKEN"
mkdir -p "$DEST"
python3 - "$STAGE/pkg" "$DEST/$ZIP.part" "DeathMuffin-TEST-$LABEL" <<'PY'
import os, sys, zipfile
src, out, top = sys.argv[1:4]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for n in sorted(os.listdir(src)):
        z.write(os.path.join(src, n), top + "/" + n)
PY
mv "$DEST/$ZIP.part" "$DEST/$ZIP"
chmod -R u=rwX,go=rX "$DEST"

# Keep only the newest KEEP_TESTS token folders (only 16-hex ones, i.e. the ones this script made).
ls -1dt "$OUT_ROOT"/*/ 2>/dev/null | while read -r d; do b=$(basename "$d"); [[ "$b" =~ ^[0-9a-f]{16}$ ]] && echo "$d"; done \
  | tail -n +"$((KEEP_TESTS + 1))" | while read -r d; do rm -rf "$d"; done

echo "== test build ready: $LABEL ($SHA), $(stat -c %s "$DEST/$ZIP") bytes"
echo "   $BASE_URL/$TOKEN/$ZIP"

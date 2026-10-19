#!/usr/bin/env bash
# Publish the lighting bake kit from a COMMITTED revision (client/addons/dm_bake/README.md):
#   publish-bake-kit.sh <git-rev> [scene ...]        (default: res://areas/graves.tscn)
# Builds the rebuilt client at <rev> in its own worktree (the combat core for Linux and Windows, one import), zips every tracked client file
# with Godot's import cache (so the baking PC uses the exact meshes and lightmap UVs this server built, and skips a long re-import) and the
# Windows core, and serves it with latest.json at https://muffindevelopment.com/death-muffin/bake-kit/ for Bake-Lighting.bat. Keeps 2 kits.
set -euo pipefail
REV_IN="${1:?usage: publish-bake-kit.sh <git-rev> [scene ...]}"
shift
SCENES=("$@")
[ ${#SCENES[@]} -gt 0 ] || SCENES=(res://areas/graves.tscn)
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
REV="$(git -C "$REPO" rev-parse --short=8 "$REV_IN^{commit}")"
OUT=/var/www/death-muffin/bake-kit
WORK=/home/ubuntu/death-muffin/bake-kit-work
WT="$WORK/src"
# Godot 4.7.2 for Windows: the official release and its published SHA-512 (SHA512-SUMS.txt of the 4.7.2-stable release).
GODOT_VERSION=4.7.2
GODOT_EXE=Godot_v4.7.2-stable_win64.exe
GODOT_URL=https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip
GODOT_SHA512=83decd58fdf67b9d657958a1ae6bf1929c20785315a81effe245874cdc57acb709bf868e00778a96984338c1b29dafdb453c6847747694621c6ecf5da2259993

mkdir -p "$WORK"
[ -d "$OUT" ] || { sudo mkdir -p "$OUT"; sudo chown ubuntu:ubuntu "$OUT"; }
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
git -C "$REPO" worktree add --quiet --detach "$WT" "$REV"
trap 'git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT
for s in "${SCENES[@]}"; do
  [ -f "$WT/client/${s#res://}" ] || { echo "publish-bake-kit: no ${s#res://} in client/ at $REV" >&2; exit 1; }
done

echo "publish-bake-kit: building $REV (core for Linux and Windows, import)..."
bash "$WT/tools/check/prep.sh" --windows --no-bake "$WT" >"$WORK/setup.log" 2>&1 || { tail -20 "$WORK/setup.log"; exit 1; }

ZIP="$WORK/kit-$REV.zip"
rm -f "$ZIP"
(
  cd "$WT"
  git ls-files client
  ls client/bin/*.dll client/bin/*.gdextension
  find client/.godot/imported -type f
  for f in client/.godot/uid_cache.bin client/.godot/global_script_class_cache.cfg client/.godot/extension_list.cfg; do [ -f "$f" ] && echo "$f"; done
) | sort -u | (cd "$WT" && zip -q -X -@ "$ZIP")
SHA=$(sha256sum "$ZIP" | cut -d' ' -f1)
MB=$(( ($(stat -c %s "$ZIP") + 1048575) / 1048576 ))
cp "$ZIP" "$OUT/kit-$REV.zip"
python3 - "$OUT/latest.json" "$REV" "$SHA" "$MB" "$GODOT_VERSION" "$GODOT_EXE" "$GODOT_URL" "$GODOT_SHA512" "${SCENES[@]}" <<'PY'
import json, sys, datetime
out, rev, sha, mb, ver, exe, url, sha512, *scenes = sys.argv[1:]
json.dump({"rev": rev, "file": f"kit-{rev}.zip", "sha256": sha, "mb": int(mb), "scenes": scenes,
           "made": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "godot": {"version": ver, "exe": exe, "url": url, "sha512": sha512}}, open(out + ".tmp", "w"), indent=1)
PY
mv "$OUT/latest.json.tmp" "$OUT/latest.json"
ls -t "$OUT"/kit-*.zip | tail -n +3 | xargs -r rm -f
rm -f "$ZIP"
echo "publish-bake-kit: $REV, ${MB} MB, scenes: ${SCENES[*]} -> https://muffindevelopment.com/death-muffin/bake-kit/latest.json"

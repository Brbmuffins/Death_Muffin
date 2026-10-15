#!/usr/bin/env bash
# Publish a Windows launcher release so running launchers update themselves (launcher/windows/SelfUpdate.cs, DECISIONS B33).
#
#   publish-launcher.sh <version>          e.g. 0.9.0 (the csproj <Version> that CI released as GitHub tag launcher-v<version>)
#
# 1. Downloads DeathMuffinLauncher-win-x64.zip from the GitHub release launcher-v<version> (built by .github/workflows/launcher-windows.yml)
#    and takes DeathMuffinLauncher.exe out of it (it must be a Windows PE file).
# 2. Refuses a version that is not newer than the live one: launchers never downgrade, so a rollback is the old code released under a
#    new version number (bump <Version>, push, publish that).
# 3. Copies the exe to $OUT_DIR/<version>/ (a folder per release: a launcher mid-download never sees its file change) and writes
#    $OUT_DIR/manifest.json LAST, atomically: {version, url, size, sha256, published_at}.
# 4. Keeps the newest two release folders.
#
# Served at https://muffindevelopment.com/death-muffin/launcher/ (static, nginx `location ^~ /death-muffin/`). Running launchers check it
# about once a minute and swap themselves when the game is not running or downloading. Launchers before 0.9.0 cannot update themselves;
# they only show a download link (GitHub latest release, which CI keeps current).
# Test overrides (all optional): OUT_DIR BASE_URL ZIP (a local zip instead of the GitHub download) KEEP=2
set -euo pipefail

VERSION="${1:?usage: publish-launcher.sh <version>, e.g. 0.9.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be three numbers like 0.9.0, got '$VERSION'" >&2; exit 2; }
OUT_DIR="${OUT_DIR:-/var/www/death-muffin/launcher}"
BASE_URL="${BASE_URL:-https://muffindevelopment.com/death-muffin/launcher}"
KEEP="${KEEP:-2}"
EXE=DeathMuffinLauncher.exe
RELEASE_ZIP="https://github.com/Brbmuffins/Death_Muffin/releases/download/launcher-v$VERSION/DeathMuffinLauncher-win-x64.zip"

if [ ! -d "$OUT_DIR" ]; then
  sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 755 "$OUT_DIR"
fi
exec 9>"$OUT_DIR/.publish-launcher.lock"
flock -w 120 9 || { echo "another launcher publish holds $OUT_DIR/.publish-launcher.lock" >&2; exit 1; }

LIVE=""
[ -f "$OUT_DIR/manifest.json" ] && LIVE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$OUT_DIR/manifest.json")
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }   # newer A B: A > B
if [ -n "$LIVE" ] && ! newer "$VERSION" "$LIVE"; then
  echo "Refusing: $VERSION is not newer than the live launcher $LIVE (launchers never downgrade; release the old code as a newer version)." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [ -n "${ZIP:-}" ]; then cp "$ZIP" "$TMP/launcher.zip"
else
  echo "== Downloading $RELEASE_ZIP"
  curl -fsSL --retry 3 -o "$TMP/launcher.zip" "$RELEASE_ZIP" || { echo "No GitHub release launcher-v$VERSION (did CI finish on main?)" >&2; exit 1; }
fi
python3 - "$TMP/launcher.zip" "$TMP/$EXE" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = [n for n in z.namelist() if n.rsplit('/', 1)[-1] == 'DeathMuffinLauncher.exe']
    if len(names) != 1: sys.exit('zip must hold exactly one DeathMuffinLauncher.exe, found %d' % len(names))
    open(sys.argv[2], 'wb').write(z.read(names[0]))
PY
[ "$(head -c 2 "$TMP/$EXE")" = "MZ" ] || { echo "$EXE in the zip is not a Windows executable" >&2; exit 1; }
SIZE=$(stat -c %s "$TMP/$EXE")
SHA=$(sha256sum "$TMP/$EXE" | cut -d' ' -f1)

echo "== Installing $VERSION ($SIZE bytes, sha256 $SHA)"
mkdir -p "$OUT_DIR/$VERSION"
install -m 644 "$TMP/$EXE" "$OUT_DIR/$VERSION/$EXE"
python3 - "$OUT_DIR/manifest.json.tmp" "$VERSION" "$BASE_URL/$VERSION/$EXE" "$SIZE" "$SHA" <<'PY'
import json, sys, datetime
path, version, url, size, sha = sys.argv[1:]
json.dump({"version": version, "url": url, "size": int(size), "sha256": sha,
           "published_at": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}, open(path, 'w'), indent=2)
PY
chmod 644 "$OUT_DIR/manifest.json.tmp"
mv -f "$OUT_DIR/manifest.json.tmp" "$OUT_DIR/manifest.json"

# Keep the newest $KEEP release folders.
ls -1 "$OUT_DIR" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | head -n -"$KEEP" | while read -r old; do rm -rf "${OUT_DIR:?}/$old"; done

echo "Launcher $VERSION published (was ${LIVE:-none}). Running launchers update themselves within about a minute of being idle."

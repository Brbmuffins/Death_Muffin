#!/usr/bin/env bash
# Publish a team app version so the installed apps update themselves (teamapp/README.md "Updating itself", DECISIONS B55).
#
#   publish-teamapp.sh <git-rev>     builds the app of <rev> (its teamapp/windows/DeathMuffinTeam.csproj <Version>) and makes it the live version
#   publish-teamapp.sh --prune       only removes all but the newest $KEEP versions
#
# 1. Refuses a revision GitHub CI has not passed (that revision's own tools/check/ci.sh; DM_CI_GATE=off only while GitHub is down) and a version
#    that is not newer than the live one (apps only update forward: a rollback is the old code released under a newer version).
# 2. Builds the net48 exe on Linux from `git archive <rev> teamapp` with the .NET SDK at $DOTNET (it must be a Windows PE file).
# 3. Copies DeathMuffinTeam.exe and .exe.config to $OUT_DIR/<version>/, writes DeathMuffinTeam-<version>.zip beside them (both files and a
#    README.txt, for a first install), then $OUT_DIR/version.json LAST, atomically: {version, url, sha256, size}.
# 4. Keeps the newest $KEEP versions (folders and zips).
#
# Served at https://muffindevelopment.com/death-muffin/teamapp/ (static). Installed apps read version.json 30 s after they start, every 15 minutes,
# after each job and when a job is offered, never while a job runs.
# Test overrides (all optional): REPO OUT_DIR BASE_URL DOTNET KEEP=2 EXE_FILE (a built exe: skips the build; its .config must sit beside it)
set -euo pipefail

REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
OUT_DIR="${OUT_DIR:-/var/www/death-muffin/teamapp}"
BASE_URL="${BASE_URL:-https://muffindevelopment.com/death-muffin/teamapp}"
DOTNET="${DOTNET:-/home/ubuntu/porchlite/.dotnet/dotnet}"
KEEP="${KEEP:-2}"
ARG="${1:?usage: publish-teamapp.sh <git-rev> | --prune}"

prune() {
  ls -1 "$OUT_DIR" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | head -n -"$KEEP" | while read -r old; do
    rm -rf "${OUT_DIR:?}/$old" "${OUT_DIR:?}/DeathMuffinTeam-$old.zip"; echo "removed $old"
  done
}

[ -d "$OUT_DIR" ] || { echo "$OUT_DIR does not exist" >&2; exit 1; }
exec 9>"$OUT_DIR/.publish-teamapp.lock"
flock -w 120 9 || { echo "another team app publish holds $OUT_DIR/.publish-teamapp.lock" >&2; exit 1; }
if [ "$ARG" = --prune ]; then prune; exit 0; fi

git -C "$REPO" fetch -q origin
SHA=$(git -C "$REPO" rev-parse --verify "$ARG^{commit}") || { echo "unknown revision $ARG" >&2; exit 2; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$REPO" archive "$SHA" teamapp tools/check 2>/dev/null | tar -x -C "$TMP" 2>/dev/null || { echo "${SHA:0:12} has no teamapp/ or tools/check/ (older than the team app)" >&2; exit 1; }

VERSION=$(sed -n 's:.*<Version>\([0-9][0-9.]*\)</Version>.*:\1:p' "$TMP/teamapp/windows/DeathMuffinTeam.csproj" | head -1)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "no three-number <Version> in $SHA's DeathMuffinTeam.csproj (got '$VERSION')" >&2; exit 1; }
LIVE=""
[ -f "$OUT_DIR/version.json" ] && LIVE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$OUT_DIR/version.json")
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }   # newer A B: A > B
if [ -n "$LIVE" ] && ! newer "$VERSION" "$LIVE"; then
  echo "Refusing: $VERSION is not newer than the live team app $LIVE (raise <Version> in teamapp/windows/DeathMuffinTeam.csproj)." >&2; exit 1
fi

if [ "${DM_CI_GATE:-}" = off ]; then echo "== CI gate: off (DM_CI_GATE=off), publishing $SHA without CI's verdict"
else
  V=$(cd "$REPO" && bash "$TMP/tools/check/ci.sh" status "$SHA" 2>&1 | tail -1)
  [ "${V%% *}" = passed ] || { echo "Refusing to publish $SHA: GitHub CI has not passed it ($V). Push it and wait for tools/check/ci.sh wait $SHA." >&2; exit 1; }
fi

if [ -n "${EXE_FILE:-}" ]; then BIN="$(dirname "$EXE_FILE")"
else
  echo "== Building team app $VERSION from ${SHA:0:12}"
  # no build servers (they would outlive this script holding the lock, fd 9, which is closed for the build too)
  "$DOTNET" build "$TMP/teamapp/windows/DeathMuffinTeam.csproj" -c Release -nologo -v quiet --disable-build-servers >"$TMP/build.log" 2>&1 9>&- || { tail -20 "$TMP/build.log" >&2; echo "the build failed" >&2; exit 1; }
  BIN="$TMP/teamapp/windows/bin/Release/net48"
fi
[ "$(head -c 2 "$BIN/DeathMuffinTeam.exe")" = "MZ" ] || { echo "DeathMuffinTeam.exe is not a Windows executable" >&2; exit 1; }
[ -f "$BIN/DeathMuffinTeam.exe.config" ] || { echo "DeathMuffinTeam.exe.config is missing beside the exe" >&2; exit 1; }
SIZE=$(stat -c %s "$BIN/DeathMuffinTeam.exe")
SHA256=$(sha256sum "$BIN/DeathMuffinTeam.exe" | cut -d' ' -f1)

echo "== Installing $VERSION ($SIZE bytes, sha256 $SHA256)"
mkdir -p "$OUT_DIR/$VERSION" "$TMP/zip"
install -m 644 "$BIN/DeathMuffinTeam.exe" "$BIN/DeathMuffinTeam.exe.config" "$OUT_DIR/$VERSION/"
cp "$BIN/DeathMuffinTeam.exe" "$BIN/DeathMuffinTeam.exe.config" "$TMP/zip/"
printf '%s\r\n' "Death Muffin Team app $VERSION, for the team PCs only (War, Muffins, Helix)." \
  'Put both files in a folder of their own (for example Documents\DeathMuffinTeam) and run DeathMuffinTeam.exe.' \
  'Sign in with your game account. It sits in the tray and updates itself.' >"$TMP/zip/README.txt"
(cd "$TMP/zip" && zip -q -X "$TMP/app.zip" DeathMuffinTeam.exe DeathMuffinTeam.exe.config README.txt)
install -m 644 "$TMP/app.zip" "$OUT_DIR/DeathMuffinTeam-$VERSION.zip"
python3 - "$OUT_DIR/version.json.tmp" "$VERSION" "$BASE_URL/$VERSION/DeathMuffinTeam.exe" "$SHA256" "$SIZE" <<'PY'
import json, sys
path, version, url, sha, size = sys.argv[1:]
json.dump({"version": version, "url": url, "sha256": sha, "size": int(size)}, open(path, "w"))
PY
chmod 644 "$OUT_DIR/version.json.tmp"
mv -f "$OUT_DIR/version.json.tmp" "$OUT_DIR/version.json"
prune
echo "Team app $VERSION published from ${SHA:0:12} (was ${LIVE:-none}). Installed apps update within 15 minutes, between jobs."

#!/usr/bin/env bash
# Publish the Godot Windows client for the launcher, from a COMMITTED revision (never the working tree).
#
#   publish-godot-client.sh <git-rev>
#
# 1. `git worktree add --detach` of <rev> into a scratch folder (removed on exit), runs its PREPARE (the combat core, the flipbook sheets kept outside
#    git, the import, the crowd's bakes), imports the project and exports the "Windows Desktop" preset with Godot 4.7.2 (DeathMuffin.exe + DeathMuffin.pck).
#    res://assets ships separately as DeathMuffin.assets.pck (tools/godot/assets-pack.sh, loaded by main/dm_packs.gd): it is fingerprinted
#    (tools/godot/assets-fp.sh: every file under client/assets incl. the flipbook sheets, the crowd baker's inputs, the export settings, the Godot
#    version, the pack tools) and reused from
#    $WORK/assets-cache/<fingerprint>.pck while unchanged, so it keeps its SHA-256 and the launcher skips it. Godot's export is not
#    byte-reproducible, so an unchanged pack must be reused, never rebuilt. A revision without assets-pack.sh ships one pck (rollbacks).
# 2. Hashes every file (SHA-256) and copies them to $OUT_DIR/<version>/ (a folder per build, so a player who is mid-download of the
#    previous build never sees its files change).
# 3. Writes $OUT_DIR/manifest.json LAST, atomically:
#      { version, built_at, rev, files:[{path,size,sha256,url}], online:{enabled,staff,message} }
#    The `online` block is carried over from the manifest that is live now, so republishing never opens or closes online play.
#    A first publish starts locked. Devs flip it with set-online.sh.
# 4. Keeps the newest two build folders (the previous one covers launchers that are mid-download).
# 5. announce-release.sh: launcher news + patch notes, the #build-alerts notice, fixed bug reports released (skipped for a rollback).
# 6. team-bench.sh: the team PCs' benchmark of this release, one `bench` job per team PC seen in the last 14 days (README.md "Team jobs"). Best effort: a failure
#    prints a line and never fails the publish. Only for the live folder (/var/www/death-muffin/client: the test channel and tests publish elsewhere; TEAM_BENCH=1
#    forces it, NO_TEAM_BENCH=1 skips it) and never for a rollback (a revision that is not newer than the build that was live).
#
# Served at https://muffindevelopment.com/death-muffin/client/ (static, see nginx-locations.conf).
# Refuses a forward release while the live lobby differs from <rev>'s (run deploy-lobby.sh first; LOBBY_SKEW_OK=1 overrides).
# Test overrides (all optional): REPO GODOT OUT_DIR WORK BASE_URL INCLUDE_CONSOLE=1 KEEP_BUILDS=2 FX_SHEETS LOBBY_DIR PREPARE SMOKE SYMBOLS_DIR SYMBOL_BUILDS TEAM_BENCH NO_TEAM_BENCH
# The game is client/ (DECISIONS B49): its PREPARE and SMOKE steps (test-channel/prepare-rebuild.sh, smoke-rebuild.sh) run by default.
set -euo pipefail

REV="${1:-}"
[ -n "$REV" ] || { echo "usage: $0 <git-rev>" >&2; exit 2; }

REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
OUT_DIR="${OUT_DIR:-/var/www/death-muffin/client}"
WORK="${WORK:-/home/ubuntu/death-muffin/deploy}"
BASE_URL="${BASE_URL:-https://muffindevelopment.com/death-muffin/client}"
KEEP_BUILDS="${KEEP_BUILDS:-2}"
PRESET="Windows Desktop"
PROJECT=client   # the Godot project folder in the repository
DEFAULT_MESSAGE="Online opens soon"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
[ -x "$GODOT" ] || { echo "Godot not found at $GODOT" >&2; exit 1; }

SHA=$(git -C "$REPO" rev-parse --short=12 "$REV^{commit}")
mkdir -p "$WORK" "$OUT_DIR"
# One publish at a time.
exec 9>"$WORK/.publish-client.lock"
flock -w 600 9 || { echo "another client publish holds $WORK/.publish-client.lock" >&2; exit 1; }

# The live lobby must already run what <rev> has (deploy-lobby.sh first): a client can depend on new lobby messages, and a skipped lobby
# deploy fails silently. Only for a forward release (<rev> contains origin/main): a rollback to an older client keeps the newer lobby.
LOBBY_DIR="${LOBBY_DIR:-/home/ubuntu/death-muffin/lobby}"
if [ -d "$LOBBY_DIR/src" ] && [ -z "${LOBBY_SKEW_OK:-}" ] && git -C "$REPO" merge-base --is-ancestor origin/main "$SHA" 2>/dev/null; then
  for f in $(git -C "$REPO" ls-tree --name-only "$SHA" server/death-muffin/lobby/src/ | grep -E '\.js$'); do
    git -C "$REPO" show "$SHA:$f" | cmp -s - "$LOBBY_DIR/src/$(basename "$f")" ||
      { echo "Refusing to publish $SHA: the live lobby differs from it ($(basename "$f")). Run deploy-lobby.sh $SHA first (LOBBY_SKEW_OK=1 publishes anyway)." >&2; exit 1; }
  done
fi

STAMP=$(date -u +%Y%m%d.%H%M%S)
VERSION="$STAMP-${SHA:0:7}"
WT="$WORK/godot-client-wt-$SHA"
STAGE="$WORK/godot-client-stage-$SHA"
cleanup() {
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$WT" "$STAGE"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
mkdir -p "$STAGE"
# The game's build steps come from the revision being published (its scratch worktree), so a saved copy of this script (a ship's rollback) finds them too.
PREPARE="${PREPARE-$WT/server/death-muffin/test-channel/prepare-rebuild.sh}"
SMOKE="${SMOKE-$WT/server/death-muffin/test-channel/smoke-rebuild.sh}"

echo "== exporting $SHA as $VERSION"
git -C "$REPO" worktree add -q --detach "$WT" "$SHA" >/dev/null 2>&1
[ -f "$WT/$PROJECT/project.godot" ] || { echo "$SHA has no $PROJECT/project.godot" >&2; exit 1; }
[ -f "$WT/$PROJECT/export_presets.cfg" ] || { echo "$SHA has no $PROJECT/export_presets.cfg (preset \"$PRESET\")" >&2; exit 1; }
# PREPARE=<script> (the test channel): adjusts the scratch worktree before the import, e.g. renderer and endpoints. Never the repository.
[ -z "${PREPARE:-}" ] || bash "$PREPARE" "$WT" || { echo "prepare step failed: $PREPARE" >&2; exit 1; }
"$GODOT" --headless --path "$WT/$PROJECT" --import >"$STAGE/import.log" 2>&1 || { tail -30 "$STAGE/import.log" >&2; echo "godot import failed" >&2; exit 1; }
bash "$WT/tools/godot/export-baked.sh" "$WT/$PROJECT" release "$PRESET" "$STAGE/DeathMuffin.exe" "$GODOT" || exit 1   # baked shaders when a renderer is free (the script says)
rm -f "$STAGE/import.log" "$STAGE/export.log"
if [ -f "$WT/tools/godot/assets-pack.sh" ]; then
  CACHE="$WORK/assets-cache"; mkdir -p "$CACHE"
  FP=$(bash "$WT/tools/godot/assets-fp.sh" "$WT" "$GODOT")
  if [ -s "$CACHE/$FP.pck" ]; then echo "== assets pack: unchanged ($FP), reused"
  else
    echo "== assets pack: building ($FP)"
    bash "$WT/tools/godot/assets-pack.sh" "$WT/$PROJECT" "$CACHE/$FP.pck.tmp" "$GODOT"
    mv -f "$CACHE/$FP.pck.tmp" "$CACHE/$FP.pck"
  fi
  cp "$CACHE/$FP.pck" "$STAGE/DeathMuffin.assets.pck"
  touch "$CACHE/$FP.pck"
  ls -1t "$CACHE"/*.pck 2>/dev/null | tail -n +4 | while read -r f; do rm -f "$f"; done   # keep the newest three
fi
[ -n "${INCLUDE_CONSOLE:-}" ] || rm -f "$STAGE"/*.console.exe

# Sanity: a real Windows exe and a non-trivial pck, both named the way the launcher expects.
[ -s "$STAGE/DeathMuffin.exe" ] && [ "$(head -c2 "$STAGE/DeathMuffin.exe")" = "MZ" ] || { echo "DeathMuffin.exe missing or not a Windows executable" >&2; exit 1; }
[ "$(stat -c %s "$STAGE/DeathMuffin.pck" 2>/dev/null || echo 0)" -gt 100000 ] || { echo "DeathMuffin.pck missing or suspiciously small" >&2; exit 1; }
# SMOKE=<script> (the test channel): boots an exported copy of the build before anything is published (test-channel/smoke-rebuild.sh).
[ -z "${SMOKE:-}" ] || bash "$SMOKE" "$WT/$PROJECT" "$STAGE" || { echo "boot smoke failed: $SMOKE" >&2; exit 1; }

# Carry the online lock over from the manifest that is live now (locked on a first publish or if the old one is unreadable).
ONLINE_JSON=$(python3 - "$OUT_DIR/manifest.json" "$DEFAULT_MESSAGE" <<'PY'
import json, sys
enabled, staff, message = False, False, sys.argv[2]
try:
    o = json.load(open(sys.argv[1])).get("online", {})
    enabled = o.get("enabled") is True
    staff = o.get("staff") is True
    message = o.get("message") if isinstance(o.get("message"), str) else message
except Exception:
    pass
print(json.dumps({"enabled": enabled, "staff": staff, "message": message}))
PY
)

# The revision that is live now (before the switch below): a rollback is not benchmarked (the team-bench hook at the end).
PREV_REV=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("rev", ""))' "$OUT_DIR/manifest.json" 2>/dev/null || true)
[[ "$PREV_REV" =~ ^[0-9a-f]{7,40}$ ]] || PREV_REV=""

# Copy into the versioned folder, then describe it.
DEST="$OUT_DIR/$VERSION"
mkdir -p "$DEST"
( cd "$STAGE" && find . -type f -printf '%P\n' | LC_ALL=C sort ) | while IFS= read -r f; do
  mkdir -p "$DEST/$(dirname "$f")"
  cp "$STAGE/$f" "$DEST/$f"
done
chmod -R u=rwX,go=rX "$DEST"
python3 - "$DEST" "$VERSION" "$SHA" "$BASE_URL" "$ONLINE_JSON" "$OUT_DIR/manifest.json.tmp" <<'PY'
import hashlib, json, os, sys, datetime
dest, version, rev, base, online, out = sys.argv[1:7]
files = []
for root, _, names in os.walk(dest):
    for n in names:
        p = os.path.join(root, n)
        rel = os.path.relpath(p, dest).replace(os.sep, "/")
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        files.append({"path": rel, "size": os.path.getsize(p), "sha256": h.hexdigest(), "url": f"{base}/{version}/{rel}"})
files.sort(key=lambda x: x["path"])
manifest = {
    "version": version,
    "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "rev": rev,
    "files": files,
    "online": json.loads(online),
}
with open(out, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
chmod 644 "$OUT_DIR/manifest.json.tmp"
mv -f "$OUT_DIR/manifest.json.tmp" "$OUT_DIR/manifest.json"   # the switch: clients see the new build only now

# The combat core's debug symbols for this build (native/build.sh splits them off the shipped library), kept per build so that a crash note
# from any build still running on players' PCs can be read (tools/crash/symbolize.mjs, native/README.md "Crash notes"). Newest 40 kept.
SYMBOLS_DIR="${SYMBOLS_DIR:-/home/ubuntu/death-muffin/symbols}"
if ls "$WT/native/build/symbols/"*.debug >/dev/null 2>&1; then
  mkdir -p "$SYMBOLS_DIR/$VERSION"
  cp -f "$WT/native/build/symbols/"*.debug "$SYMBOLS_DIR/$VERSION/"
  (cd "$OUT_DIR/$VERSION" && sha256sum libdmcore*.dll) >"$SYMBOLS_DIR/$VERSION/shipped.sha256" 2>/dev/null || true
  ls -1d "$SYMBOLS_DIR"/[0-9]*/ 2>/dev/null | sort -r | tail -n +"$((${SYMBOL_BUILDS:-40} + 1))" | while read -r d; do rm -rf "$d"; done
  echo "== the combat core's symbols kept in $SYMBOLS_DIR/$VERSION"
fi

# Prune old build folders, newest first, keeping KEEP_BUILDS.
ls -1d "$OUT_DIR"/[0-9]*/ 2>/dev/null | sort -r | tail -n +"$((KEEP_BUILDS + 1))" | while read -r d; do rm -rf "$d"; done

echo "== published $VERSION ($SHA) to $OUT_DIR"
echo "   online: $ONLINE_JSON"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); [print("   %10d  %s" % (f["size"], f["path"])) for f in m["files"]]' "$OUT_DIR/manifest.json"

# Launcher news + patch notes, the #build-alerts notice and bug reports marked "Fixed — live now" (announce-release.sh from the published
# revision itself; never fails the publish). A republish of an older revision (rollback) announces nothing. NO_ANNOUNCE=1 skips it.
if [ -z "${NO_ANNOUNCE:-}" ]; then
  ANN=$(mktemp)
  if git -C "$REPO" show "$SHA:server/death-muffin/announce-release.sh" >"$ANN" 2>/dev/null; then REPO="$REPO" HOOK_FILE="${HOOK_FILE:-/home/ubuntu/death-muffin/private/discord-build-alerts-webhook.url}" bash "$ANN" "$SHA" || true   # an older revision's copy still defaulted to #death-muffin
  else echo "release notes: $SHA has no announce-release.sh (older revision): skipped"; fi
  rm -f "$ANN"
fi

# --- team bench hook ---
# The team PCs' benchmark of this release: team-bench.sh from the published revision itself (with the clean-up rule it shares), one `bench` job per team PC seen
# lately. Best effort: a failure prints a line and never fails the publish (a run of more than 5 minutes is stopped).
LIVE_OUT=/var/www/death-muffin/client
if [ -z "${NO_TEAM_BENCH:-}" ] && { [ "$OUT_DIR" = "$LIVE_OUT" ] || [ -n "${TEAM_BENCH:-}" ]; }; then
  if [ -n "$PREV_REV" ] && git -C "$REPO" cat-file -e "$PREV_REV^{commit}" 2>/dev/null && ! git -C "$REPO" merge-base --is-ancestor "$PREV_REV" "$SHA" 2>/dev/null; then
    echo "team bench: $SHA is not newer than the build that was live ($PREV_REV): skipped (rollback?)"
  else
    TB=$(mktemp -d)
    if git -C "$REPO" archive "$SHA" server/death-muffin/team-bench.sh server/death-muffin/team-files-prune.sh 2>/dev/null | tar -x -C "$TB" 2>/dev/null; then
      timeout -k 10 300 bash "$TB/server/death-muffin/team-bench.sh" "$VERSION" || echo "team bench: failed (the publish itself is fine)"
    else echo "team bench: $SHA has no team-bench.sh (older revision): skipped"; fi
    rm -rf "$TB"
  fi
fi
# --- end team bench hook ---

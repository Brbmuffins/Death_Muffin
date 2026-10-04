#!/usr/bin/env bash
# Publish a full Death Muffin release from a COMMITTED revision (default HEAD), never the working tree.
#
#   deploy-release.sh [rev] [migration.sql ...]
#
# 1. Exports <rev> with `git archive` into deploy/candidate-<sha>/src and builds the play client there.
#    (Phones/tablets and the offline edition are NOT published here: they come from the `mobile` branch via deploy-mobile.sh,
#    which must be run FIRST when a release changes anything they depend on. This build redirects phones to /death-muffin/mobile/.)
# 2. Runs typecheck, client tests and server tests on that export.
# 3. Backs up the DB, runtime server files and public entry pages, and writes ROLLBACK.sh.
# 4. Applies the named migrations (each must be additive / idempotent), installs server code, restarts realtime then auth.
# 5. Publishes hashed assets first and entry pages last (plus precache.html/asset-manifest.json before, release-notes.json after index.html), then checks the public pages match the build.
# The deployed revision is written to /death-muffin/play/release.txt so "is live == HEAD?" is one curl.
set -euo pipefail

REPO=/home/ubuntu/vps-handoffs/DeathMuffin/game
RUNTIME=/home/ubuntu/death-muffin
# One deploy at a time, shared with the Discord dev agent's ship helper (which sets DEPLOY_LOCK_HELD=1 because it already holds the lock).
if [ -z "${DEPLOY_LOCK_HELD:-}" ]; then
  mkdir -p "$RUNTIME/deploy"
  exec 9>"$RUNTIME/deploy/.deploy.lock"
  flock -w 1800 9 || { echo "another deploy holds $RUNTIME/deploy/.deploy.lock" >&2; exit 1; }
fi
PUBLIC=/var/www/death-muffin
REV="${1:-HEAD}"
shift || true
SHA=$(git -C "$REPO" rev-parse --short=12 "$REV^{commit}")
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CAND="$RUNTIME/deploy/candidate-$SHA"
BK="$RUNTIME/deploy/backup-pre-release-$SHA-$STAMP"
SRC="$CAND/src"
# The release that is live before this one (for the Discord notice: what changed since).
PREV=$(curl -sf "https://muffindevelopment.com/death-muffin/play/release.txt?t=$STAMP" | cut -d" " -f1 || true)

echo "== Building $SHA from git (not the working tree)"
rm -rf "$CAND"
mkdir -p "$SRC"
git -C "$REPO" archive "$SHA" | tar -x -C "$SRC"
ln -s "$REPO/node_modules" "$SRC/node_modules"
[ -d "$REPO/server/realtime/node_modules" ] && ln -s "$REPO/server/realtime/node_modules" "$SRC/server/realtime/node_modules"
for m in "$@"; do test -f "$SRC/server/death-muffin/backend/migrations/$m"; done
(
  cd "$SRC"
  npx tsc --noEmit -p .
  npx vitest run --reporter=dot
  npm run -s test:server
  npm run -s build:death-muffin
)
B="$SRC/server/death-muffin/backend"
for f in "$B"/server.js "$B"/*.cjs "$B"/gathering/*.cjs "$SRC/server/vps-handoff/necro-progress/necro-rules.cjs" "$SRC/server/realtime/server.js"; do
  case "$f" in *.test.cjs) continue;; esac
  node --check "$f"
done
test -f "$SRC/dist/index.html"
test -f "$SRC/dist/precache.html"
test -f "$SRC/dist/asset-manifest.json"

echo "== Backup -> $BK"
mkdir -p "$BK/backend/gathering" "$BK/backend/necro-progress" "$BK/realtime" "$BK/play"
sudo mysqldump --single-transaction death_muffin > "$BK/death_muffin.sql"
cp -a "$RUNTIME/backend/server.js" "$RUNTIME/backend/"*.cjs "$BK/backend/"
cp -a "$RUNTIME/backend/gathering/"*.cjs "$BK/backend/gathering/"
cp -a "$RUNTIME/backend/necro-progress/"*.cjs "$BK/backend/necro-progress/"
cp -a "$RUNTIME/realtime/server.js" "$BK/realtime/"
sudo cp -a "$PUBLIC/play/index.html" "$BK/play/"
cat > "$BK/ROLLBACK.sh" <<EOF
#!/usr/bin/env bash
# Restores code and entry pages from before release $SHA. Additive tables and newer player data stay.
set -euo pipefail
cp -a '$BK/backend/'*.js '$BK/backend/'*.cjs '$RUNTIME/backend/'
cp -a '$BK/backend/gathering/'*.cjs '$RUNTIME/backend/gathering/'
cp -a '$BK/backend/necro-progress/'*.cjs '$RUNTIME/backend/necro-progress/'
cp -a '$BK/realtime/server.js' '$RUNTIME/realtime/'
sudo systemctl restart death-muffin-realtime.service death-muffin-auth.service
sudo cp -a '$BK/play/index.html' '$PUBLIC/play/index.html'
echo 'Rolled back to the pre-$SHA code. Full DB dump: $BK/death_muffin.sql'
EOF
chmod 700 "$BK/ROLLBACK.sh"

for m in "$@"; do
  echo "== Migration $m"
  sudo mysql death_muffin < "$SRC/server/death-muffin/backend/migrations/$m"
done

echo "== Server code"
for f in "$B"/server.js "$B"/*.cjs; do case "$f" in *.test.cjs) ;; *) cp "$f" "$RUNTIME/backend/";; esac; done
for f in "$B"/gathering/*.cjs; do case "$f" in *.test.cjs) ;; *) cp "$f" "$RUNTIME/backend/gathering/";; esac; done
for f in necro-rules.cjs necro-progress-routes.cjs mysql-store.cjs; do cp "$SRC/server/vps-handoff/necro-progress/$f" "$RUNTIME/backend/necro-progress/"; done
cp "$SRC/server/realtime/server.js" "$RUNTIME/realtime/"
node --check "$RUNTIME/backend/server.js"
sudo systemctl restart death-muffin-realtime.service
sudo systemctl restart death-muffin-auth.service
curl --silent --show-error --fail --retry 10 --retry-delay 1 --retry-all-errors http://127.0.0.1:5190/health >/dev/null
sudo systemctl is-active death-muffin-auth.service death-muffin-realtime.service

echo "== Clients (assets first, entry pages last)"
for d in assets art models fx audio; do [ -d "$SRC/dist/$d" ] && sudo cp -a "$SRC/dist/$d" "$PUBLIC/play/"; done
# Launcher "update before play" helpers: static, no game code; the manifest lists the files just published above.
sudo cp -a "$SRC/dist/precache.html" "$SRC/dist/asset-manifest.json" "$PUBLIC/play/"
sudo cp -a "$SRC/dist/index.html" "$PUBLIC/play/index.html"
# release-notes.json (news panel of the Windows launcher), published after index.html. Player-facing notes come from PATCH_NOTES.json
# (newest entry first, written by hand for each release); without it the commit subjects since the previous live release are used.
# patch-notes.json (the whole PATCH_NOTES.json history) feeds the site's patch-notes page and the launcher's "All patch notes".
RANGE="$SHA"; [ -n "$PREV" ] && git -C "$REPO" cat-file -e "$PREV^{commit}" 2>/dev/null && RANGE="$PREV..$SHA"
git -C "$REPO" log --no-merges --format='%s' -n 12 $RANGE | python3 -c '
import json, os, sys, datetime
sha, notes_path, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
commits = [l.strip()[:150] for l in sys.stdin if l.strip()]
history = []
if os.path.exists(notes_path):
    try:
        history = [e for e in json.load(open(notes_path)) if e.get("items")]
    except Exception as e:
        print("PATCH_NOTES.json unreadable, using commit subjects:", e, file=sys.stderr)
top = history[0] if history else None
notes = {"sha": sha, "date": now, "title": top["title"] if top else "", "items": top["items"] if top else commits, "commits": commits}
json.dump(notes, open(os.path.join(out_dir, "release-notes.json"), "w"))
json.dump({"sha": sha, "date": now, "releases": history[:30]}, open(os.path.join(out_dir, "patch-notes.json"), "w"))
' "$SHA" "$SRC/PATCH_NOTES.json" "$CAND" || echo '{"sha":"'"$SHA"'","date":"","items":[]}' > "$CAND/release-notes.json"
[ -f "$CAND/patch-notes.json" ] || echo '{"releases":[]}' > "$CAND/patch-notes.json"
sudo cp "$CAND/patch-notes.json" "$PUBLIC/play/patch-notes.json"
sudo cp "$CAND/release-notes.json" "$PUBLIC/play/release-notes.json"
# release.txt goes after index.html: open tabs auto-reload when it changes, and must then fetch the new page.
echo "$SHA $(date -u +%FT%TZ)" > "$CAND/release.txt"
sudo cp "$CAND/release.txt" "$PUBLIC/play/release.txt"
sudo chown -R root:root "$PUBLIC/play"
sudo chmod -R a+rX "$PUBLIC/play"

echo "== Verify"
curl -sSf https://muffindevelopment.com/death-muffin/play/ | cmp - "$SRC/dist/index.html"
curl -sSf https://muffindevelopment.com/death-muffin/api/health; echo
echo "Release $SHA published. Rollback: $BK/ROLLBACK.sh"

# Discord notice (optional): the webhook URL lives outside the repo (the repo is public). Never fails the deploy.
# The Death Muffin channel's webhook wins when it is set up; otherwise the older MuffinCore alerts webhook.
HOOK_FILE="$RUNTIME/private/discord-deathmuffin-webhook.url"
[ -r "$HOOK_FILE" ] || HOOK_FILE="$RUNTIME/private/discord-github-webhook.url"
if [ -r "$HOOK_FILE" ]; then
  git -C "$REPO" log --no-merges --format='%s' -n 12 $RANGE | python3 -c '
import json, sys, urllib.request
sha, prev, url = sys.argv[1], sys.argv[2], open(sys.argv[3]).read().strip()
lines = [l.strip() for l in sys.stdin if l.strip()]
body = "\n".join("• " + l[:150] for l in lines) or "• (no new commits)"
compare = f"https://github.com/Brbmuffins/Death_Muffin/compare/{prev}...{sha}" if prev else f"https://github.com/Brbmuffins/Death_Muffin/commit/{sha}"
embed = {"title": f"Death Muffin release {sha[:7]} is live", "url": "https://muffindevelopment.com/death-muffin/play/",
         "description": body[:3800] + f"\n\n[What changed]({compare})", "color": 0x7C3AED}
req = urllib.request.Request(url, data=json.dumps({"username": "Death Muffin", "embeds": [embed]}).encode(),
                             headers={"Content-Type": "application/json", "User-Agent": "death-muffin-deploy"})
urllib.request.urlopen(req, timeout=10)
' "$SHA" "${PREV:-}" "$HOOK_FILE" && echo "Discord: release notice sent" || echo "Discord: notice failed (deploy is fine)"
fi

# Player bug reports fixed by this release (commits "Bug report #<id>: ..."): mark them 'released' so the reporter sees
# "Fixed — live now" in Settings → Report a bug, and announce them. Never fails the deploy.
FIXES=$(git -C "$REPO" log --no-merges --format='%s' $RANGE | grep -E '^Bug report #[0-9]+: ' || true)
if [ -n "$FIXES" ]; then
  IDS=$(printf '%s\n' "$FIXES" | sed -E 's/^Bug report #([0-9]+):.*/\1/' | sort -un | paste -sd, -)
  NEWLY=$(node "$SRC/server/death-muffin/bug-agent/reports-cli.cjs" release "$IDS" 2>/dev/null || echo '[]')
  echo "Bug reports released: $NEWLY"
  if [ -r "$HOOK_FILE" ] && [ "$NEWLY" != "[]" ]; then
    printf '%s\n' "$FIXES" | python3 -c '
import json, sys, urllib.request
sha, newly, url = sys.argv[1], {r["id"] for r in json.loads(sys.argv[2])}, open(sys.argv[3]).read().strip()
lines = []
for l in sys.stdin:
    head, _, text = l.strip().partition(": ")
    rid = int(head.split("#")[1])
    if rid in newly: lines.append(f"• **#{rid}** {text[:150]}")
embed = {"title": f"\U0001F41E Player-reported bugs fixed — live now", "url": "https://muffindevelopment.com/death-muffin/play/",
         "description": "\n".join(lines)[:3800] + f"\n\nRelease {sha[:7]}. Thanks for the reports! Send more from Settings → Report a bug.", "color": 0x16A34A}
req = urllib.request.Request(url, data=json.dumps({"username": "Death Muffin", "embeds": [embed], "allowed_mentions": {"parse": []}}).encode(),
                             headers={"Content-Type": "application/json", "User-Agent": "death-muffin-deploy"})
urllib.request.urlopen(req, timeout=10)
' "$SHA" "$NEWLY" "$HOOK_FILE" && echo "Discord: bug-fix notice sent" || echo "Discord: bug-fix notice failed (deploy is fine)"
  fi
fi

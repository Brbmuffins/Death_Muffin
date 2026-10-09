#!/usr/bin/env bash
# Deploy the Death Muffin backend (auth server :5190) from a COMMITTED revision (default HEAD), never the working tree.
# The Godot client is published separately with publish-godot-client.sh; the web client was retired 2026-10-09.
#
#   deploy-release.sh [rev] [migration.sql ...]
#
# 1. Exports <rev> with `git archive` into deploy/candidate-<sha>/src.
# 2. Runs the shared-rules and server tests on that export.
# 3. Backs up the DB and runtime server files, and writes ROLLBACK.sh.
# 4. Applies the named migrations (each must be additive / idempotent), installs server code, restarts auth.
# 5. announce-release.sh: release notes for the launcher and site, the #deathmuffin notice, fixed bug reports released.
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
# Never publish a revision that is missing commits main already has (2026-10-04: a manual deploy that queued for the lock behind a Discord
# ship published afterwards and rolled the ship back). Checked while holding the lock. ALLOW_BEHIND_MAIN=1 only for a deliberate rollback.
if [ -z "${ALLOW_BEHIND_MAIN:-}" ]; then
  git -C "$REPO" fetch -q origin 2>/dev/null || true
  if ! git -C "$REPO" merge-base --is-ancestor origin/main "$SHA"; then
    echo "Refusing to deploy $SHA: it does not contain origin/main ($(git -C "$REPO" rev-parse --short=12 origin/main)). Rebase onto main first (or ALLOW_BEHIND_MAIN=1 for a deliberate rollback)." >&2
    exit 1
  fi
fi
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CAND="$RUNTIME/deploy/candidate-$SHA"
BK="$RUNTIME/deploy/backup-pre-release-$SHA-$STAMP"
SRC="$CAND/src"

echo "== Exporting $SHA from git (not the working tree)"
rm -rf "$CAND"
mkdir -p "$SRC"
git -C "$REPO" archive "$SHA" | tar -x -C "$SRC"
ln -s "$REPO/node_modules" "$SRC/node_modules"
for m in "$@"; do test -f "$SRC/server/death-muffin/backend/migrations/$m"; done
(
  cd "$SRC"
  npm run -s test:rules -- --reporter=dot
  npm run -s test:server
)
B="$SRC/server/death-muffin/backend"
for f in "$B"/server.js "$B"/*.cjs "$B"/gathering/*.cjs "$SRC/server/vps-handoff/necro-progress/necro-rules.cjs"; do
  case "$f" in *.test.cjs) continue;; esac
  node --check "$f"
done

echo "== Backup -> $BK"
sudo mysqldump --single-transaction death_muffin > "$BK/death_muffin.sql"
cp -a "$RUNTIME/backend/server.js" "$RUNTIME/backend/"*.cjs "$BK/backend/"
cp -a "$RUNTIME/backend/gathering/"*.cjs "$BK/backend/gathering/"
cp -a "$RUNTIME/backend/necro-progress/"*.cjs "$BK/backend/necro-progress/"
cat > "$BK/ROLLBACK.sh" <<EOF
#!/usr/bin/env bash
# Restores code and entry pages from before release $SHA. Additive tables and newer player data stay.
set -euo pipefail
cp -a '$BK/backend/'*.js '$BK/backend/'*.cjs '$RUNTIME/backend/'
cp -a '$BK/backend/gathering/'*.cjs '$RUNTIME/backend/gathering/'
cp -a '$BK/backend/necro-progress/'*.cjs '$RUNTIME/backend/necro-progress/'
sudo systemctl restart death-muffin-auth.service
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
node --check "$RUNTIME/backend/server.js"
sudo systemctl restart death-muffin-auth.service
curl --silent --show-error --fail --retry 10 --retry-delay 1 --retry-all-errors http://127.0.0.1:5190/health >/dev/null
sudo systemctl is-active death-muffin-auth.service

echo "== Verify"
curl -sSf https://muffindevelopment.com/death-muffin/api/health; echo
echo "Release $SHA published. Rollback: $BK/ROLLBACK.sh"

# Launcher news + patch notes, the #deathmuffin notice and fixed bug reports (shared with publish-godot-client.sh; never fails the deploy).
REPO="$REPO" bash "$SRC/server/death-muffin/announce-release.sh" "$SHA" || true

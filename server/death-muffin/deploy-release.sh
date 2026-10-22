#!/usr/bin/env bash
# Deploy the Death Muffin backend (auth server :5190) from a COMMITTED revision (default HEAD), never the working tree.
# The Godot client is published separately with publish-godot-client.sh; the web client was retired 2026-10-09.
#
#   deploy-release.sh [--if-changed] [rev] [migration.sql ...]
#
# Migrations: every backend/migrations/*.sql of <rev> that the database has not recorded in schema_migrations is applied by migrate.sh, in
# order. Naming files is optional (kept for callers that still pass them; each named file must exist in <rev>).
# --if-changed (the Discord agent's Godot ships, before the client publish): exit 0 doing nothing ("backend: unchanged") when every server file
# <rev> would install is byte-identical to the installed one and no migration is pending. Otherwise the normal deploy below.
#
# 1. Exports <rev> with `git archive` into deploy/candidate-<sha>/src.
# 2. Runs the shared-rules and server tests on that export.
# 3. Backs up the DB and runtime server files, and writes ROLLBACK.sh. After a good deploy only the newest KEEP_BACKUPS (default 5)
#    backup-pre-release-* folders stay (by their UTC stamp; the one just made is always kept).
# 4. Applies the pending migrations (migrate.sh; each must be additive), installs server code, restarts auth.
#    If anything fails after the code is installed (restart, health), ROLLBACK.sh runs on its own and the deploy exits 1.
# 5. announce-release.sh: release notes for the launcher and site, the #build-alerts notice, fixed bug reports released.
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
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
# Keep the newest $KEEP_BACKUPS deploy/<prefix>-<sha>-<UTC stamp> folders, newest by the stamp (the name's last field), never fewer than 1.
prune_backups() {
  local keep=$(( KEEP_BACKUPS < 1 ? 1 : KEEP_BACKUPS ))
  find "$RUNTIME/deploy" -maxdepth 1 -mindepth 1 -type d -name "$1-*" | awk -F- '{print $NF" "$0}' | sort -r | tail -n +"$((keep + 1))" |
    cut -d' ' -f2- | while read -r d; do rm -rf -- "$d"; done
}
IF_CHANGED=""; [ "${1:-}" = --if-changed ] && { IF_CHANGED=1; shift; }
REV="${1:-HEAD}"
shift || true
SHA=$(git -C "$REPO" rev-parse --short=12 "$REV^{commit}")
# The files "== Server code" installs: repo path -> installed path (one list for --if-changed and the install).
server_files() {
  git -C "$REPO" ls-tree --name-only "$SHA" server/death-muffin/backend/ server/death-muffin/backend/gathering/ |
    grep -E '^server/death-muffin/backend/(server\.js|[^/]+\.cjs|gathering/[^/]+\.cjs)$' | grep -v '\.test\.cjs$' |
    while read -r f; do echo "$f $RUNTIME/backend/${f#server/death-muffin/backend/}"; done
  for f in necro-rules.cjs necro-progress-routes.cjs mysql-store.cjs; do echo "server/vps-handoff/necro-progress/$f $RUNTIME/backend/necro-progress/$f"; done
}
# Migrations of <rev> the database has not recorded (migrate.sh --pending, from the rev's own copy of the runner and files).
pending_migrations() {
  local t; t=$(mktemp -d)
  git -C "$REPO" archive "$SHA" server/death-muffin/migrate.sh server/death-muffin/backend/migrations | tar -x -C "$t"
  bash "$t/server/death-muffin/migrate.sh" --pending "$t/server/death-muffin/backend/migrations"
  rm -rf "$t"
}
if [ -n "$IF_CHANGED" ] && [ $# -eq 0 ]; then
  CHANGED=$(server_files | while read -r f dst; do git -C "$REPO" show "$SHA:$f" 2>/dev/null | cmp -s - "$dst" || echo "${f#server/}"; done)
  PENDING=$(pending_migrations)
  [ -n "$CHANGED$PENDING" ] || { echo "backend: unchanged at $SHA, nothing to deploy"; exit 0; }
  [ -z "$PENDING" ] || echo "backend: pending migrations at $SHA: $(echo "$PENDING" | paste -sd' ' -)"
  [ -z "$CHANGED" ] || echo "backend: changed at $SHA: $(echo "$CHANGED" | head -8 | paste -sd' ' -)"
fi
# Never publish a revision that is missing commits main already has (2026-10-04: a manual deploy that queued for the lock behind a Discord
# ship published afterwards and rolled the ship back). Checked while holding the lock. ALLOW_BEHIND_MAIN=1 only for a deliberate rollback.
if [ -z "${ALLOW_BEHIND_MAIN:-}" ]; then
  git -C "$REPO" fetch -q origin 2>/dev/null || true
  if ! git -C "$REPO" merge-base --is-ancestor origin/main "$SHA"; then
    echo "Refusing to deploy $SHA: it does not contain origin/main ($(git -C "$REPO" rev-parse --short=12 origin/main)). Rebase onto main first (or ALLOW_BEHIND_MAIN=1 for a deliberate rollback)." >&2
    exit 1
  fi
  # The CI gate (DECISIONS B59): only a revision whose files GitHub CI passed is deployed, judged by that revision's own tools/check/ci.sh
  # (a revision from before the gate has none). DM_CI_GATE=off only while GitHub is down; a deliberate rollback (ALLOW_BEHIND_MAIN) skips it.
  if git -C "$REPO" cat-file -e "$SHA:tools/check/ci.sh" 2>/dev/null; then
    if [ "${DM_CI_GATE:-}" = off ]; then echo "CI gate: off (DM_CI_GATE=off), deploying $SHA without CI's verdict"
    else
      CIS=$(mktemp); git -C "$REPO" show "$SHA:tools/check/ci.sh" > "$CIS"
      V=$(cd "$REPO" && bash "$CIS" status "$SHA" 2>&1 | tail -1); rm -f "$CIS"
      [ "${V%% *}" = passed ] || { echo "Refusing to deploy $SHA: GitHub CI has not passed it ($V). Push it and wait for tools/check/ci.sh wait $SHA (DM_CI_GATE=off only while GitHub is down)." >&2; exit 1; }
      echo "CI: passed ($V)"
    fi
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
mkdir -p "$BK/backend/gathering" "$BK/backend/necro-progress"
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

# A failure from here on rolls itself back: before the code is installed nothing live has changed (a failed migration file is not recorded,
# the ones before it are additive and stay); after it, ROLLBACK.sh puts the previous code back and restarts auth.
STAGE=migrations
on_fail() {
  local rc=$?
  trap - ERR
  if [ "$STAGE" = installed ]; then
    echo "!! Deploy of $SHA failed after the code was installed: rolling back automatically" >&2
    if bash "$BK/ROLLBACK.sh" && curl --silent --fail --retry 10 --retry-delay 1 --retry-all-errors http://127.0.0.1:5190/health >/dev/null; then
      echo "!! Rolled back: the previous backend is running and healthy. Candidate kept for a look: $CAND" >&2
    else
      echo "!! ROLLBACK FAILED: the backend is down. Run $BK/ROLLBACK.sh by hand; DB dump: $BK/death_muffin.sql" >&2
    fi
  else
    echo "!! Deploy of $SHA failed during $STAGE: the live code was not changed. DB dump from before: $BK/death_muffin.sql" >&2
  fi
  exit "$rc"
}
trap on_fail ERR

echo "== Migrations"
bash "$SRC/server/death-muffin/migrate.sh" "$SRC/server/death-muffin/backend/migrations" "$SHA"

echo "== Server code"
STAGE=installed
server_files | while read -r f dst; do cp "$SRC/$f" "$dst"; done
node --check "$RUNTIME/backend/server.js"
sudo systemctl restart death-muffin-auth.service
curl --silent --show-error --fail --retry 10 --retry-delay 1 --retry-all-errors http://127.0.0.1:5190/health >/dev/null
sudo systemctl is-active death-muffin-auth.service

# The local health check passed: from here a failure (e.g. the public check through Cloudflare) stops the script but rolls nothing back.
trap - ERR
echo "== Verify"
curl -sSf https://muffindevelopment.com/death-muffin/api/health; echo
echo "Release $SHA published. Rollback: $BK/ROLLBACK.sh"
prune_backups "backup-pre-release" || echo "!! could not prune old backups in $RUNTIME/deploy (the release is fine)" >&2

# Launcher news + patch notes, the #build-alerts notice and fixed bug reports (shared with publish-godot-client.sh; never fails the deploy).
# NO_ANNOUNCE=1 (a Godot ship: the client publish right after announces the release once).
[ -n "${NO_ANNOUNCE:-}" ] || QUIET=1 REPO="$REPO" bash "$SRC/server/death-muffin/announce-release.sh" "$SHA" || true

# The rebuild's test backend runs the same server code and migrations (test-server/README.md). Best effort: never fails the live deploy.
if [ -f "$RUNTIME/backend-test/.env" ]; then
  bash "$SRC/server/death-muffin/test-server/sync.sh" "$SHA" || echo "!! test backend sync failed; live is unaffected (server/death-muffin/test-server/sync.sh)" >&2
fi

# The candidate export (~330 MB) is only needed until the release is live and announced; ROLLBACK.sh uses the backup folder.
rm -rf "$CAND"

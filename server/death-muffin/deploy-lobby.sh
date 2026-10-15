#!/usr/bin/env bash
# Deploy the Death Muffin lobby + packet relay (:5192) and the UDP relay next to it (`deathmuffin-relay`, :5193/udp, server/death-muffin/relay)
# from a COMMITTED revision (default HEAD), never the working tree.
# The backend has deploy-release.sh and the client publish-godot-client.sh; this is the lobby's.
#
#   deploy-lobby.sh [--if-changed] [--wait MIN] [--force] [rev]
#
# --if-changed  exit 0 doing nothing ("lobby: unchanged") when the lobby code and package files <rev> would install are byte-identical to the
#               installed ones (README.md alone never counts)
#               (the Discord agent's Godot ships run it that way before the client publish).
# --wait MIN    how long to wait for the lobby to have no sessions before restarting (default 30). A restart ends every party, because the
#               lobby keeps sessions in memory. Times out with exit 3 and changes nothing.
# --force       restart even if sessions are running (they end; the players land back in their own worlds).
#
# 1. Exports <rev>'s server/death-muffin/lobby with `git archive` into deploy/candidate-lobby-<sha>.
# 2. Runs the lobby tests and `node --check` on that export.
# 3. Waits until /health shows 0 sessions (or --force).
# 4. Backs up the installed lobby, writes ROLLBACK.sh, installs the lobby code, package files and README, `npm ci` only if the lockfile changed,
#    restarts deathmuffin-lobby and checks /health. A failure after the install began runs ROLLBACK.sh --force on its own (exit 1).
# The UDP relay's files (relay/project.godot, relay/relay_main.gd, godot/net/relay/dm_udp_relay.gd) go to $RUNTIME/relay and restart
# `deathmuffin-relay` when they changed and the unit is installed (installed by hand, see relay/README.md). Players on the UDP lane fall
# back to the WebSocket when it restarts; the lobby restart already waits for no running parties.
# Test overrides (all optional): REPO RUNTIME LOBBY_DIR LOBBY_URL LOBBY_UNIT POLL_S SYSTEMCTL RELAY_DIR RELAY_UNIT
set -euo pipefail

REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
RUNTIME="${RUNTIME:-/home/ubuntu/death-muffin}"
LOBBY_DIR="${LOBBY_DIR:-$RUNTIME/lobby}"
LOBBY_URL="${LOBBY_URL:-http://127.0.0.1:5192}"
LOBBY_UNIT="${LOBBY_UNIT:-deathmuffin-lobby.service}"
POLL_S="${POLL_S:-15}"
SYSTEMCTL="${SYSTEMCTL:-sudo systemctl}"
RELAY_DIR="${RELAY_DIR:-$RUNTIME/relay}"
RELAY_UNIT="${RELAY_UNIT:-deathmuffin-relay.service}"
IF_CHANGED=""; WAIT_MIN=30; FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --if-changed) IF_CHANGED=1; shift;;
    --wait) WAIT_MIN="${2:?--wait needs minutes}"; shift 2;;
    --force) FORCE=1; shift;;
    -*) echo "unknown option $1" >&2; exit 2;;
    *) break;;
  esac
done
REV="${1:-HEAD}"
# One deploy at a time, shared with deploy-release.sh and the Discord dev agent's ship helper (which sets DEPLOY_LOCK_HELD=1).
if [ -z "${DEPLOY_LOCK_HELD:-}" ]; then
  mkdir -p "$RUNTIME/deploy"
  exec 9>"$RUNTIME/deploy/.deploy.lock"
  flock -w 1800 9 || { echo "another deploy holds $RUNTIME/deploy/.deploy.lock" >&2; exit 1; }
fi
SHA=$(git -C "$REPO" rev-parse --short=12 "$REV^{commit}")

# The files this script installs: repo path -> installed path (one list for --if-changed and the install).
lobby_files() {
  git -C "$REPO" ls-tree -r --name-only "$SHA" server/death-muffin/lobby/src/ | grep -E '\.js$'
  for f in package.json package-lock.json README.md; do echo "server/death-muffin/lobby/$f"; done
}
installed_of() { echo "$LOBBY_DIR/${1#server/death-muffin/lobby/}"; }
# The UDP relay's files at <rev> (none before it existed): repo path -> installed path.
relay_files() {
  git -C "$REPO" cat-file -e "$SHA:server/death-muffin/relay/relay_main.gd" 2>/dev/null || return 0
  for f in project.godot relay_main.gd README.md; do echo "server/death-muffin/relay/$f $RELAY_DIR/$f"; done
  echo "godot/net/relay/dm_udp_relay.gd $RELAY_DIR/dm_udp_relay.gd"
}
relay_changed() { relay_files | grep -v '/README\.md ' | while read -r f dst; do git -C "$REPO" show "$SHA:$f" | cmp -s - "$dst" || echo "$f"; done; }
if [ -n "$IF_CHANGED" ]; then
  # README.md is installed but never decides: a docs-only edit must not restart the lobby (and end parties).
  CHANGED=$(lobby_files | grep -v '/README\.md$' | while read -r f; do git -C "$REPO" show "$SHA:$f" 2>/dev/null | cmp -s - "$(installed_of "$f")" || echo "${f#server/death-muffin/lobby/}"; done)
  # a code file the install has but <rev> no longer does counts as a change too
  for f in "$LOBBY_DIR"/src/*.js; do
    [ -e "$f" ] || continue
    git -C "$REPO" cat-file -e "$SHA:server/death-muffin/lobby/src/$(basename "$f")" 2>/dev/null || CHANGED="$CHANGED lobby/src/$(basename "$f") (removed)"
  done
  CHANGED="$CHANGED $(relay_changed | sed 's|^.*/|relay:|')"
  [ -n "$(echo "$CHANGED" | tr -d ' \n')" ] || { echo "lobby: unchanged at $SHA, nothing to deploy"; exit 0; }
  echo "lobby: changed at $SHA: $(echo $CHANGED | head -c 300)"
fi
# Never install a revision that is missing commits main already has (same rule as deploy-release.sh). ALLOW_BEHIND_MAIN=1 only for a rollback.
if [ -z "${ALLOW_BEHIND_MAIN:-}" ]; then
  git -C "$REPO" fetch -q origin 2>/dev/null || true
  if ! git -C "$REPO" merge-base --is-ancestor origin/main "$SHA"; then
    echo "Refusing to deploy $SHA: it does not contain origin/main ($(git -C "$REPO" rev-parse --short=12 origin/main)). Rebase onto main first (or ALLOW_BEHIND_MAIN=1 for a deliberate rollback)." >&2
    exit 1
  fi
fi
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CAND="$RUNTIME/deploy/candidate-lobby-$SHA"
BK="$RUNTIME/deploy/backup-lobby-$SHA-$STAMP"
trap 'rm -rf "$CAND"' EXIT

echo "== Exporting lobby at $SHA from git (not the working tree)"
rm -rf "$CAND"; mkdir -p "$CAND"
git -C "$REPO" archive "$SHA" server/death-muffin/lobby | tar -x -C "$CAND" --strip-components=3
LOCK_CHANGED=""
cmp -s "$CAND/package-lock.json" "$LOBBY_DIR/package-lock.json" || LOCK_CHANGED=1
if [ -n "$LOCK_CHANGED" ]; then (cd "$CAND" && npm ci --silent --no-audit --no-fund); else ln -s "$LOBBY_DIR/node_modules" "$CAND/node_modules"; fi
for f in "$CAND"/src/*.js; do node --check "$f"; done
(cd "$CAND" && npm test --silent)

sessions() { curl -sf "$LOBBY_URL/health" | python3 -c 'import json,sys; print(int(json.load(sys.stdin).get("sessions", 0)))' 2>/dev/null || echo 0; }
N=$(sessions)
if [ "$N" -gt 0 ] && [ -z "$FORCE" ]; then
  echo "== Waiting for the lobby to empty ($N session(s); up to $WAIT_MIN min)"
  DEADLINE=$(( $(date +%s) + WAIT_MIN * 60 ))
  while [ "$N" -gt 0 ]; do
    [ "$(date +%s)" -lt "$DEADLINE" ] || { echo "Lobby still has $N session(s) after $WAIT_MIN min: nothing installed. Rerun later, or with --force to end them." >&2; exit 3; }
    sleep "$POLL_S"; N=$(sessions)
  done
elif [ "$N" -gt 0 ]; then
  echo "== --force: restarting with $N session(s) running (they end)"
fi

echo "== Backup -> $BK"
mkdir -p "$BK"
cp -a "$LOBBY_DIR/." "$BK/lobby/"
[ ! -d "$RELAY_DIR" ] || { mkdir -p "$BK/relay"; for f in "$RELAY_DIR"/*.gd "$RELAY_DIR"/project.godot "$RELAY_DIR"/README.md; do [ -f "$f" ] && cp -a "$f" "$BK/relay/"; done; true; }
cat > "$BK/ROLLBACK.sh" <<EOF
#!/usr/bin/env bash
# Restores the lobby from before $SHA. Restarting ends every running party: by default it waits (up to 30 min) for 0 sessions; --force skips that.
set -euo pipefail
if [ "\${1:-}" != --force ]; then
  for _ in \$(seq 120); do
    n=\$(curl -sf '$LOBBY_URL/health' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sessions", 1))' 2>/dev/null || echo 1)
    [ "\$n" = 0 ] && break; echo "lobby has \$n session(s), waiting"; sleep 15
  done
  [ "\$n" = 0 ] || { echo 'lobby still busy; rerun with --force to end those sessions' >&2; exit 3; }
fi
rm -rf '$LOBBY_DIR/src'
cp -a '$BK/lobby/.' '$LOBBY_DIR/'
$SYSTEMCTL restart '$LOBBY_UNIT'
if [ -d '$BK/relay' ]; then cp -a '$BK/relay/.' '$RELAY_DIR/'; $SYSTEMCTL restart '$RELAY_UNIT' || true; fi
echo 'Rolled the lobby back to its pre-$SHA copy.'
EOF
chmod 700 "$BK/ROLLBACK.sh"

# From here a failure rolls itself back: ROLLBACK.sh --force restores the backed-up lobby (and relay files) and restarts them. No sessions are
# lost by forcing it: the lobby was empty (or --force) before the install began, and a failed restart has none.
on_fail() {
  local rc=$?
  trap - ERR
  echo "!! Lobby deploy of $SHA failed after the install began: rolling back automatically" >&2
  if bash "$BK/ROLLBACK.sh" --force && curl --silent --fail --retry 10 --retry-delay 1 --retry-all-errors "$LOBBY_URL/health" >/dev/null; then
    echo "!! Rolled back: the previous lobby is running and healthy." >&2
  else
    echo "!! ROLLBACK FAILED: the lobby is down. Run $BK/ROLLBACK.sh --force by hand." >&2
  fi
  exit "$rc"
}
trap on_fail ERR

echo "== Lobby code"
rm -rf "$LOBBY_DIR/src.new"
cp -a "$CAND/src" "$LOBBY_DIR/src.new"
rm -rf "$LOBBY_DIR/src"; mv "$LOBBY_DIR/src.new" "$LOBBY_DIR/src"
cp "$CAND/package.json" "$CAND/package-lock.json" "$CAND/README.md" "$LOBBY_DIR/"
[ -z "$LOCK_CHANGED" ] || (cd "$LOBBY_DIR" && npm ci --silent --omit=dev --no-audit --no-fund)
RELAY_NEW=$(relay_changed)
if [ -n "$(relay_files)" ]; then
  mkdir -p "$RELAY_DIR/home"
  relay_files | while read -r f dst; do git -C "$REPO" show "$SHA:$f" > "$dst.new" && mv -f "$dst.new" "$dst"; done
fi
$SYSTEMCTL restart "$LOBBY_UNIT"
curl --silent --show-error --fail --retry 10 --retry-delay 1 --retry-all-errors "$LOBBY_URL/health" >/dev/null
$SYSTEMCTL is-active "$LOBBY_UNIT"
if [ -n "$RELAY_NEW" ] && $SYSTEMCTL cat "$RELAY_UNIT" >/dev/null 2>&1; then
  echo "== UDP relay ($(echo $RELAY_NEW | wc -w) file(s) changed)"
  $SYSTEMCTL restart "$RELAY_UNIT"
  sleep 1
  $SYSTEMCTL is-active "$RELAY_UNIT"
elif [ -n "$RELAY_NEW" ]; then echo "== UDP relay files installed in $RELAY_DIR; $RELAY_UNIT is not installed (relay/README.md)"; fi
trap - ERR
echo "Lobby $SHA installed. Rollback: $BK/ROLLBACK.sh"

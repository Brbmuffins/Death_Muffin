#!/usr/bin/env bash
# Puts the lobby's and the relay's code of a committed revision on the TEST lobby and relay and restarts them (the live ones are never touched).
#   sync.sh [rev] [--no-restart]      default origin/main (of the shared checkout, like test-server/sync.sh)
# The lobby is server/death-muffin/lobby (src, package files); the relay is server/death-muffin/relay (project.godot, relay_main.gd) with the client's copy of
# dm_udp_relay.gd (client/net/relay). A restart ends the parties running on the test lobby.
set -euo pipefail
REV="${1:-origin/main}"
RESTART=1; [ "${2:-}" = "--no-restart" ] && RESTART=0
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"      # overrides (REPO LOBBY RELAY) are for trying the script in a scratch folder
LOBBY="${LOBBY:-/home/ubuntu/death-muffin/lobby-test}"
RELAY="${RELAY:-/home/ubuntu/death-muffin/relay-test}"
[ -d "$LOBBY" ] && [ -d "$RELAY" ] || { echo "not set up (coop/setup.sh)" >&2; exit 1; }
SRC=$(mktemp -d); trap 'rm -rf "$SRC"' EXIT
git -C "$REPO" archive "$REV" server/death-muffin/lobby server/death-muffin/relay client/net/relay/dm_udp_relay.gd | tar -x -C "$SRC"
L="$SRC/server/death-muffin/lobby"
R="$SRC/server/death-muffin/relay"
CHANGED=""
if ! cmp -s "$L/package-lock.json" "$LOBBY/package-lock.json" 2>/dev/null; then CHANGED=npm; fi
rsync -a --delete "$L/src/" "$LOBBY/src/"
cp "$L/package.json" "$L/package-lock.json" "$LOBBY/"
[ -n "$CHANGED" ] || [ -d "$LOBBY/node_modules/ws" ] || CHANGED=npm
[ -z "$CHANGED" ] || (cd "$LOBBY" && npm ci --omit=dev)
cp "$R/project.godot" "$R/relay_main.gd" "$RELAY/"
cp "$SRC/client/net/relay/dm_udp_relay.gd" "$RELAY/dm_udp_relay.gd"
echo "test lobby and relay code at $(git -C "$REPO" rev-parse --short=12 "$REV")"
[ "$RESTART" = 1 ] || exit 0
sudo systemctl restart death-muffin-relay-test.service death-muffin-lobby-test.service
curl --silent --show-error --fail --retry 10 --retry-delay 1 --retry-all-errors http://127.0.0.1:5195/health >/dev/null
echo "test lobby healthy on :5195, test relay restarted on udp 5196"

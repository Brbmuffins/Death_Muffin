#!/usr/bin/env bash
# A local trial of 2-player co-op (client/next/party/CORE-NETWORK.md): starts the repository's lobby service (node) and UDP relay (headless Godot) on THIS machine, on loopback
# ports and with a throwaway signing key, then prints the two commands that start a host and a guest. It reaches nothing else: the game accepts only a lobby on this machine or the
# test lobby (DmConfig), and the accounts are the local dev backend's. Stop it with Ctrl-C (it kills only the two processes it started).
#   bash client/tools/coop_local.sh                       # then run the printed commands in two terminals
# Needs the lobby's modules once:  cd server/death-muffin/lobby && npm ci
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
LOBBY_PORT="${LOBBY_PORT:-45195}"
RELAY_PORT="${RELAY_PORT:-45196}"
LOBBY="$ROOT/server/death-muffin/lobby"
[ -d "$LOBBY/node_modules/ws" ] || { echo "run first:  cd server/death-muffin/lobby && npm ci" >&2; exit 1; }
SECRET="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
TMP="$(mktemp -d)"
mkdir -p "$TMP/relay/home"
cp "$ROOT/server/death-muffin/relay/project.godot" "$ROOT/server/death-muffin/relay/relay_main.gd" "$ROOT/client/net/relay/dm_udp_relay.gd" "$TMP/relay/"
token() { S="$SECRET" LOBBY_DIR="$LOBBY" node -e "const j=require(process.env.LOBBY_DIR+'/node_modules/jsonwebtoken');console.log(j.sign({accountId:Number(process.argv[1]),username:process.argv[2]},process.env.S,{expiresIn:'2h'}))" "$1" "$2"; }
LOBBY_PID=""; RELAY_PID=""
cleanup() { [ -z "$LOBBY_PID" ] || kill "$LOBBY_PID" 2>/dev/null || true; [ -z "$RELAY_PID" ] || kill "$RELAY_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
DM_LOBBY_JWT_SECRET="$SECRET" DM_LOBBY_PORT="$LOBBY_PORT" DM_LOBBY_HOST=127.0.0.1 DM_RELAY_UDP="127.0.0.1:$RELAY_PORT" node "$LOBBY/src/index.js" & LOBBY_PID=$!
DM_RELAY_SECRET="$SECRET" DM_RELAY_PORT="$RELAY_PORT" DM_RELAY_BIND=127.0.0.1 HOME="$TMP/relay/home" nice -n 10 "$GODOT" --headless --path "$TMP/relay" --script relay_main.gd & RELAY_PID=$!
cat <<MSG

Lobby on ws://127.0.0.1:$LOBBY_PORT, relay on udp 127.0.0.1:$RELAY_PORT. In two other terminals (the host prints the party's code in its log and over the HUD):

  DM_LOBBY_TOKEN=$(token 1 host) $GODOT --path client -- --dev-offline --class=2 --lobby=ws://127.0.0.1:$LOBBY_PORT --host-party

  DM_LOBBY_TOKEN=$(token 2 guest) $GODOT --path client -- --dev-offline --class=2 --lobby=ws://127.0.0.1:$LOBBY_PORT --join-party=<the code>

MSG
wait

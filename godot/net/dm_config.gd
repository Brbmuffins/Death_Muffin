class_name DmConfig
extends RefCounted
## Endpoints and limits. Mirrors src/net/config.ts; the Godot client always talks to the production host unless overridden.

## Nginx strips the "/death-muffin/api" prefix, so every route below (/login, /api/...) is relative to this base.
const API_BASE := "https://muffindevelopment.com/death-muffin/api"
## Static site root (release.txt, patch notes, leaderboard page).
const SITE_BASE := "https://muffindevelopment.com/death-muffin/"
## deploy-release.sh writes "<sha> <iso-time>" here on every web deploy (web play page; the Godot builds have their own release channel later).
## The Godot client manifest (publish-godot-client.sh / set-online.sh): `online: {enabled, staff, message}` decides who may play online.
const CLIENT_MANIFEST_URL := SITE_BASE + "client/manifest.json"
const RELEASE_URL := SITE_BASE + "play/release.txt"
const PATCH_NOTES_URL := SITE_BASE + "play/patch-notes.json"
## Socket.io realtime (see REALTIME.md). Nginx routes WS_PATH to 127.0.0.1:5191.
const WS_BASE := "https://muffindevelopment.com"
const WS_PATH := "/death-muffin/rt/socket.io"
## Lobby + relay service (server/death-muffin/lobby): find / host / join a party session over WebSocket. Nginx maps the path to 127.0.0.1:5192.
## A launch arg `--lobby=<ws url>` overrides it (local tests, staging).
const LOBBY_URL := "wss://muffindevelopment.com/death-muffin/lobby/"
const MAX_PARTY_SIZE := 10
## Seconds before an HTTP request is abandoned (the TS client uses the browser default; the server answers in well under this).
const REQUEST_TIMEOUT_S := 30.0

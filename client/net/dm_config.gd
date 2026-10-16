class_name DmConfig
extends RefCounted
## Endpoints and limits of the REBUILT client (a port of godot/net/dm_config.gd; client/code.list "Ported"). Until launch day this client talks to the TEST server
## only (DECISIONS B38: it plays on copies of the team's accounts, so it can never touch a live character). This file is the one place that says where:
## the API, the manifest and the lobby below, and the allow-list the HTTP transport (net/dm_http_transport.gd) and the game scene (DmNextGame.start) enforce.
## tests/front.gd fails if any of it resolves to the live API. Launch day flips these constants and nothing else: client/README.md "The test server".

## Nginx strips the "/death-muffin/test-api" prefix, so every route (/login, /api/...) is relative to this base. The test backend: server/death-muffin/test-server/.
const API_BASE := "https://muffindevelopment.com/death-muffin/test-api"
## The test channel's folder (server/death-muffin/test-channel/): the manifest of the test build. Not the live site's root, which holds the live API's path too.
const SITE_BASE := "https://muffindevelopment.com/death-muffin/client-test/"
## The test channel's manifest: `online: {enabled, staff, message}` decides who may play online (DmOnlineGate).
const CLIENT_MANIFEST_URL := SITE_BASE + "manifest.json"
const PATCH_NOTES_URL := SITE_BASE + "play/patch-notes.json"
## No lobby or relay for the test build yet (they come with 2-player co-op, ROADMAP "Test build"): empty, so nothing can connect to the live lobby.
const LOBBY_URL := ""
const MAX_PARTY_SIZE := 10
## Seconds before an HTTP request is abandoned (the TS client uses the browser default; the server answers in well under this).
const REQUEST_TIMEOUT_S := 30.0


## True when `base_url` (a DmApi's) is an address this build may use: the test API, or "" (the local mock backend, whose transport never leaves the process).
static func allows_api_base(base_url: String) -> bool:
	return base_url == "" or base_url == API_BASE


## True when a request to `url` may leave the game: under the test API or in the test channel's folder, and no "/.." that a server would resolve to
## somewhere else (".../test-api/../api" is the live API).
static func allows_url(url: String) -> bool:
	if url.contains("/..") or url.to_lower().contains("%2e"):
		return false
	return url == API_BASE or url.begins_with(API_BASE + "/") or url.begins_with(SITE_BASE)

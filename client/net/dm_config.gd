class_name DmConfig
extends RefCounted
## Endpoints and limits of the game (a port of godot/net/dm_config.gd; client/code.list "Ported"). Since launch day (2026-10-18, DECISIONS B38/B40) this client is the game and
## plays on the LIVE server; the test server (its API, channel, lobby and relay) serves test builds only, and this build never reaches it. This file is the one place that says where:
## the API, the manifest and the lobby below, and the allow-list the HTTP transport (net/dm_http_transport.gd) and the game scene (DmNextGame.start) enforce.
## tests/front.gd fails if any of it resolves to the test server: client/README.md "The server".

## Nginx strips the "/death-muffin/api" prefix, so every route (/login, /api/...) is relative to this base.
const API_BASE := "https://muffindevelopment.com/death-muffin/api"
## The site's root: the launcher's manifest and the patch notes are under it.
const SITE_BASE := "https://muffindevelopment.com/death-muffin/"
## The live manifest: `online: {enabled, staff, message}` decides who may play online (DmOnlineGate).
const CLIENT_MANIFEST_URL := SITE_BASE + "client/manifest.json"
const PATCH_NOTES_URL := SITE_BASE + "play/patch-notes.json"
## The lobby of 2-player co-op. The relay is not a URL: the lobby hands out its address and a ticket when a session is made or joined, and this build uses it only on RELAY_PORT
## (below) or on this machine.
const LOBBY_URL := "wss://muffindevelopment.com/death-muffin/lobby/"
## The live relay's UDP port. A relay the lobby offers on any other port is ignored and the session stays on the lobby's WebSocket.
const RELAY_PORT := 5193
## The test relay's port: refused whatever the address (a lobby on this machine included), so this build can never open a lane to the test server's relay.
const TEST_RELAY_PORT := 5196
## The test server's paths under the site's root (its API, its channel, its lobby): never reached by this build.
const TEST_PATHS := ["/death-muffin/test-api", "/death-muffin/client-test", "/death-muffin/test-lobby"]
const MAX_PARTY_SIZE := 10
## Seconds before an HTTP request is abandoned (the TS client uses the browser default; the server answers in well under this).
const REQUEST_TIMEOUT_S := 30.0


## True when `base_url` (a DmApi's) is an address this build may use: the live API, or "" (the local mock backend, whose transport never leaves the process).
static func allows_api_base(base_url: String) -> bool:
	return base_url == "" or base_url == API_BASE


## True when a request to `url` may leave the game: under the site's root (the API, the manifest, the patch notes), never under a test-server path, and no "/.." that a
## server would resolve to somewhere else.
static func allows_url(url: String) -> bool:
	if url.contains("/..") or url.to_lower().contains("%2e"):
		return false
	if not (url == API_BASE or url.begins_with(SITE_BASE)):
		return false
	for p in TEST_PATHS:
		if url.contains(p):
			return false
	return true


## True when `url` is a lobby this build may connect to: the live lobby, or a lobby on this machine (the local trial and the tests start their own).
static func allows_lobby_url(url: String) -> bool:
	if url == LOBBY_URL:
		return true
	var re := RegEx.new()
	re.compile("^ws://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]{1,5}(/[^@]*)?$")
	return re.search(url) != null


## True when the relay a lobby offers (`addr`, `port`) may be used: the live relay's port, or a relay on this machine; never the test relay's port.
static func allows_relay(addr: String, port: int) -> bool:
	return port == RELAY_PORT or (port != TEST_RELAY_PORT and (addr == "127.0.0.1" or addr == "localhost" or addr == "::1"))

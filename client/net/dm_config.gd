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
## The TEST lobby for 2-player co-op (server/death-muffin/test-server/coop): its own service next to the live lobby, authenticating against the test backend, so a token of the
## test server opens it and a live token does not. Never the live lobby (tests/front.gd pins it). The relay is not a URL: the lobby hands out its address and a ticket when a
## session is made or joined, and this build uses it only on RELAY_PORT (below) or on this machine.
const LOBBY_URL := "wss://muffindevelopment.com/death-muffin/test-lobby/"
## The test relay's UDP port (the live relay listens on another one). A relay the lobby offers on any other port is ignored and the session stays on the lobby's WebSocket.
const RELAY_PORT := 5196
## The live relay's port: refused whatever the address (a lobby on this machine included), so a mistake in a trial can never open a lane to the live relay.
const LIVE_RELAY_PORT := 5193
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


## True when `url` is a lobby this build may connect to: the test lobby, or a lobby on this machine (the local trial and the tests start their own).
static func allows_lobby_url(url: String) -> bool:
	if url == LOBBY_URL:
		return true
	var re := RegEx.new()
	re.compile("^ws://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]{1,5}(/[^@]*)?$")
	return re.search(url) != null


## True when the relay a lobby offers (`addr`, `port`) may be used: the test relay's port, or a relay on this machine; never the live relay's port.
static func allows_relay(addr: String, port: int) -> bool:
	return port == RELAY_PORT or (port != LIVE_RELAY_PORT and (addr == "127.0.0.1" or addr == "localhost" or addr == "::1"))

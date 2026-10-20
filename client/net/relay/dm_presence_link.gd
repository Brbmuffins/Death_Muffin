class_name DmPresenceLink
extends Node
## The lobby link of a signed-in player who is not in the world yet (ROADMAP polish list, co-op gaps, "Friends online"): from the sign-in through character select and the world's
## loading, so friends see the player online whenever the game is open. It only connects (a 10 Hz timer polls the socket, no per-frame work) and reconnects after a drop (5 / 15 / 60 / 120 s);
## it asks for nothing and shows nothing. The game's own link (DmNextParty.go_online, after loading) replaces it on the lobby, which keeps the friends' view of the player unchanged
## (lobby README "Friends"), and this link then stops by itself. Child `Presence` of DmMain, which starts it at the sign-in (DmFrontFlow.signed_in) and after a hand-over that frees the game.
##
## Also holds the rules for which lobby this run may use and with which login (shared with DmNextParty): the live lobby (DmConfig.LOBBY_URL) or, for tests and the local trial, a lobby on this machine
## named by the opts `lobby_url` / `lobby_token` or the launch argument `--lobby=<ws url>` (DmConfig.allows_lobby_url accepts nothing else).

const POLL_EVERY := 0.1
const RECONNECT_S := [5.0, 15.0, 60.0, 120.0]

var state := "off"       ## off | connecting | ready | replaced (the game's link took over, or the account was opened elsewhere) | refused (login or access refused: no retry)
var lobby: DmLobbyClient

var _url := ""
var _token := ""
var _timer: Timer
var _retry_n := 0
var _retry_at := 0.0


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = POLL_EVERY
	_timer.timeout.connect(_tick)
	add_child(_timer)


func _exit_tree() -> void:
	stop()


## Keep the link for the signed-in `api`: connect now, unless it is already connecting or up for this login. Does nothing where no lobby may be used: a run that is not online and has no lobby
## override (tests, the dev-offline backend), an offline login, an address this build may not use. `online_mode`: DmMain's mode is "online".
func start(api: DmApi, opts: Dictionary, online_mode: bool) -> void:
	if not (online_mode or overridden(opts)):
		return
	var u := url_for(opts)
	var t := token_for(opts, api)
	if t == "" or not DmConfig.allows_lobby_url(u):
		return
	if (state == "connecting" or state == "ready") and t == _token and u == _url:
		return
	_close()
	_url = u
	_token = t
	_retry_n = 0
	_open()


## Close the link (log out, a quit): nothing is kept.
func stop() -> void:
	_close()
	state = "off"


func _close() -> void:
	if lobby != null:
		lobby.close()
	lobby = null
	_retry_at = 0.0
	if _timer != null:
		_timer.stop()


func _open() -> void:
	_retry_at = 0.0
	lobby = DmLobbyClient.new()
	lobby.authenticated.connect(func(_id: int, _name: String) -> void:
		state = "ready"
		_retry_n = 0)
	lobby.connection_failed.connect(_on_closed)
	lobby.disconnected.connect(_on_closed)
	if lobby.connect_to_lobby(_url, _token) != OK:
		lobby = null
		state = "off"
		_schedule()
		return
	state = "connecting"
	if _timer != null:
		_timer.start()


func _on_closed(reason: String) -> void:
	lobby = null
	if reason.contains("4402") or reason.contains("replaced"):
		state = "replaced"   # the game's link (or another PC) took the account's place: nothing to keep
	elif reason.contains("4401") or reason.contains("4403") or reason.contains("auth") or reason.contains("locked"):
		state = "refused"
	else:
		state = "off"
		_schedule()
		return
	if _timer != null:
		_timer.stop()


func _schedule() -> void:
	_retry_at = float(RECONNECT_S[mini(_retry_n, RECONNECT_S.size() - 1)])
	_retry_n += 1
	if _timer != null:
		_timer.start()


func _tick() -> void:
	if lobby != null:
		lobby.poll()
	elif _retry_at > 0.0:
		_retry_at -= POLL_EVERY
		if _retry_at <= 0.0:
			_open()
	else:
		_timer.stop()


# ---- which lobby, with which login -------------------------------------------------------------------------------------------------------

## The launch argument `--lobby=<ws url>` (a lobby on this machine for the local trial), "" for none.
static func arg_url() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--lobby="):
			return a.substr(8)
	return ""


## True when the run points the lobby at a process on this machine (opts `lobby_url` or `--lobby=`): tests and the local trial. DmConfig.allows_lobby_url accepts nothing but the live lobby and loopback
## addresses, so an override can never reach another server.
static func overridden(opts: Dictionary) -> bool:
	return String(opts.get("lobby_url", "")) != "" or arg_url() != ""


## The lobby's address: the override, else the live lobby.
static func url_for(opts: Dictionary) -> String:
	var u := String(opts.get("lobby_url", ""))
	if u == "":
		u = arg_url()
	return u if u != "" else DmConfig.LOBBY_URL


## The login the lobby is given: the override's token (opts `lobby_token`, the environment's `DM_LOBBY_TOKEN` for a launch argument), else the api's. "" for an offline login (the dev-offline backend's).
static func token_for(opts: Dictionary, api: DmApi) -> String:
	var t := String(opts.get("lobby_token", ""))
	if t == "" and overridden(opts):
		t = OS.get_environment("DM_LOBBY_TOKEN")
	if t == "" and api != null:
		t = String(api.get_token())
	return t if not t.begins_with("offline:") else ""

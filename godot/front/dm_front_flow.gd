class_name DmFrontFlow
extends Control
## Front-end scene router (archive/legacy-web:src/scenes/SceneManager.ts + the login / resume / select wiring of archive/legacy-web:src/main.ts).
##   start(): stored token -> resume(); otherwise the login screen.
##   resume(): GET /character -> 200 enter_world (or the discipline switch when its discipline is not playable yet), 404 discipline select,
##   anything else clears the token and shows login.
## The integrator connects `enter_world(character, session)` to the game scene. `session` is the authenticated DmApi
## (same object for the whole run: token, saves, lobby). Call `logout()` from the game's Log out button.
## Tokens live in user://dm_jwt.txt when `persist_token` (DmApi's own file); they are never printed or logged.

signal enter_world(character: Dictionary, session)
signal logged_out

var api: DmApi
## Web VITE_OFFLINE_BUILD: local-player wording, no password / email.
var standalone: bool = false
## Web ?offline / any build whose transport is the local mock: skips the claim_session round-trip at boot.
var dev_offline: bool = false
var persist_token: bool = true
## Online builds (D10): sign-in is checked against the manifest's online/staff mode (DmOnlineGate) before any character route is touched.
var online_gate: bool = false

var current: Control = null
var current_name: String = ""   # "login" | "select" | "" (while resuming / in the world)


func _init(api_: DmApi = null, standalone_: bool = false, dev_offline_: bool = false) -> void:
	api = api_
	standalone = standalone_
	dev_offline = dev_offline_


func _ready() -> void:
	theme = DmUi.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if api == null:
		var t := DmHttpTransport.new()
		add_child(t)
		api = DmApi.new(t.request_callable())
	api.persist_token = persist_token


## SceneManager.goto: unmount the current scene, mount the next.
func goto(scene: Control, scene_name: String) -> void:
	if current != null:
		current.queue_free()
		remove_child(current)
	current = scene
	current_name = scene_name
	add_child(scene)


func start() -> void:
	api.persist_token = persist_token
	if not api.get_token().is_empty():
		await boot()
	else:
		go_login()


## Web boot(): opening the game claims the session (not in offline), then resume().
func boot() -> void:
	if not await _gate_allows():
		return
	if not dev_offline and not standalone:
		var fresh := await api.claim_session(api.get_token())
		if fresh.is_empty() and api.get_token().is_empty():
			go_login()
			return
	await resume()


func go_login() -> void:
	var s := DmLoginScreen.new(api, standalone, dev_offline)
	s.succeeded.connect(func(_t): _after_login())
	goto(s, "login")


func _after_login() -> void:
	if await _gate_allows():
		await resume()


## D10 online gate. Denied: the token is dropped (nothing was claimed, created or loaded) and the login screen says why.
func _gate_allows() -> bool:
	if not online_gate:
		return true
	var r := await DmOnlineGate.check(api)
	if r["allowed"]:
		return true
	api.set_token("")
	go_login()
	if current is DmLoginScreen:
		current.show_notice(r["message"])
	return false


## `switching` = a character whose discipline is not playable yet: the select screen changes its discipline instead of creating one.
func go_select(switching: Dictionary = {}) -> void:
	var s := DmCharSelectScreen.new(api, switching)
	s.selected.connect(go_world)
	goto(s, "select")


func go_world(character: Dictionary) -> void:
	if current != null:
		current.queue_free()
		remove_child(current)
		current = null
	current_name = ""
	enter_world.emit(character, api)


func resume() -> void:
	var r := await api.get_character()
	if r.ok and r.data is Dictionary:
		if DmCharacterBuild.is_playable(float(r.data.get("class_index", 0))):
			go_world(r.data)
		else:
			go_select(r.data)
	elif r.status == 404:
		go_select()
	else:
		api.set_token("")
		go_login()


func logout() -> void:
	api.set_token("")
	logged_out.emit()
	go_login()

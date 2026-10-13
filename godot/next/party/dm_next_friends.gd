class_name DmNextFriends
extends Node
## Friends (owner 2026-10-13, the Social window's Friends tab): the account's mutual friends and the requests waiting either way, kept on the
## backend (server/death-muffin/backend/friends.cjs). Child `Friends` of DmNextGame. No socket and no per-frame work: one GET when the world is
## entered (to tell the player about waiting requests) and one per open of the tab; every write answers the whole list.

signal changed
signal requests_waiting(names: Array)   ## the first load found requests to answer (toast + tab pip); once per run of the game

var shell: DmNextGame
var friends: Array = []        ## [{accountId, username, disciplineIndex, level}] by name
var incoming: Array = []       ## [{accountId, username}]
var outgoing: Array = []
var loaded := false
var busy := false
var error := ""
var message := ""

static var _told := false      ## requests_waiting fired already (a joiner's game is a second DmNextGame in the same run)


func setup(shell_: DmNextGame) -> void:
	shell = shell_
	set_process(false)


## "" when friends can be used, else why not (shown in the tab instead of the controls).
func unavailable() -> String:
	if shell.is_offline and not shell.party.overridden():
		return "Friends need an online account. Offline characters stay on this device."
	if shell.api == null or shell.api.get_token().is_empty():
		return "Sign in to an online account to add friends."
	return ""


func view() -> Dictionary:
	return {"unavailable": unavailable(), "loaded": loaded, "busy": busy, "error": error, "message": message,
		"friends": friends, "incoming": incoming, "outgoing": outgoing}


## World entry: learn about waiting requests without opening anything.
func check_requests() -> void:
	if unavailable() != "" or _told:
		return
	await refresh()
	if incoming.is_empty() or _told:
		return
	_told = true
	var names: Array = []
	for r in incoming:
		names.append(String(r["username"]))
	requests_waiting.emit(names)


func refresh() -> void:
	if unavailable() != "" or busy:
		return
	busy = true
	changed.emit()
	var r: DmResult = await shell.api.get_friends()
	busy = false
	if r.ok:
		_take(r.data)
		error = ""
	else:
		error = r.error
	changed.emit()


## Add by login name. If they already asked you, you are friends at once.
func send_request(username: String) -> void:
	var n := username.strip_edges()
	if n == "":
		error = "Enter the name your friend logs in with."
		message = ""
		changed.emit()
		return
	await _write(func() -> DmResult: return await shell.api.friend_request(n))


func accept(account_id: int) -> void:
	await _write(func() -> DmResult: return await shell.api.friend_accept(account_id))


## Unfriend, decline their request or cancel yours.
func remove(account_id: int) -> void:
	await _write(func() -> DmResult: return await shell.api.friend_remove(account_id))


## The friend's class for the list: "Gravecaller · Lv 40", or "" before they made a character.
static func class_line(f: Dictionary) -> String:
	var idx: Variant = f.get("disciplineIndex")
	if idx == null:
		return ""
	var by: Dictionary = DmCombatData.disciplines()["by_index"]
	var d := DmContent.discipline(String(by.get(str(int(idx)), "")))
	var nm := String(d.get("name", ""))
	var lv: Variant = f.get("level")
	return nm if lv == null else "%s · Lv %d" % [nm, int(lv)]


func _write(call: Callable) -> void:
	if unavailable() != "" or busy:
		return
	busy = true
	message = ""
	changed.emit()
	var r: DmResult = await call.call()
	busy = false
	if r.ok:
		_take(r.data["view"])
		message = String(r.data["message"])
		error = ""
	else:
		error = r.error
	changed.emit()


func _take(v: Variant) -> void:
	var d: Dictionary = v if v is Dictionary else {}
	friends = d.get("friends", [])
	incoming = d.get("incoming", [])
	outgoing = d.get("outgoing", [])
	loaded = true

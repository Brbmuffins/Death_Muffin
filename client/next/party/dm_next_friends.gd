class_name DmNextFriends
extends Node
## Friends (owner 2026-10-13, the Social window's Friends tab): the account's mutual friends and the requests waiting either way, kept on the
## backend (server/death-muffin/backend/friends.cjs). Child `Friends` of DmNextGame. No socket of its own and no per-frame work: one GET when the
## world is entered (to tell the player about waiting requests), one per open of the tab and one when the lobby says a friendship changed; every
## write answers the whole list. Who is online, their class and party come from the lobby (DmNextParty.friends_online) and are merged in view().

signal changed
signal requests_waiting(names: Array)   ## new friend requests to answer (toast + tab pip): the first load, then any that arrive while playing

var shell: DmNextGame
var friends: Array = []        ## [{accountId, username, disciplineIndex, level}] by name
var incoming: Array = []       ## [{accountId, username}]
var outgoing: Array = []
var loaded := false
var busy := false
var error := ""
var message := ""

static var _told: Dictionary = {}   ## account ids whose request was announced already (a joiner's game is a second DmNextGame in the same run)


func setup(shell_: DmNextGame) -> void:
	shell = shell_
	set_process(false)
	shell.party.changed.connect(func() -> void: changed.emit())   # presence, invites and asks are part of the view
	shell.party.friends_list_changed.connect(refresh)


## "" when friends can be used, else why not (shown in the tab instead of the controls).
func unavailable() -> String:
	if shell.is_offline and not shell.party.overridden():
		return "Friends need an online account. Offline characters stay on this device."
	if shell.api == null or shell.api.get_token().is_empty():
		return "Sign in to an online account to add friends."
	return ""


## friends: each with `online` and, when online, `presence` (class, level, area, session); online friends first, then by name.
## party: {mode, session_id, full} of our own party, which decides each row's Join / Ask / Invite.
func view() -> Dictionary:
	var party := shell.party
	var rows: Array = []
	for f in friends:
		var r: Dictionary = (f as Dictionary).duplicate()
		var p: Dictionary = party.friends_online.get(int(f["accountId"]), {})
		r["online"] = not p.is_empty()
		r["presence"] = p
		rows.append(r)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["online"] != b["online"]:
			return a["online"]
		return String(a["username"]).nocasecmp_to(String(b["username"])) < 0)
	var mine := {"mode": String(party.mode), "session_id": String(party.info.get("id", "")) if party.in_party() else "", "linked": party.link == "ready",
		"full": int(party.info.get("players", 1)) >= DmSession.MAX_PLAYERS}
	return {"unavailable": unavailable(), "loaded": loaded, "busy": busy, "error": error, "message": message,
		"friends": rows, "incoming": incoming, "outgoing": outgoing, "invites": party.invites, "requests": party.requests, "party": mine}


## World entry: learn about waiting requests without opening anything (also connects the presence link).
func check_requests() -> void:
	if unavailable() != "":
		return
	await refresh()


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
		_announce_new()
	else:
		error = r.error
	changed.emit()


## Requests not announced yet in this run: a toast + the tab's pip.
func _announce_new() -> void:
	var names: Array = []
	for q in incoming:
		var id := int(q["accountId"])
		if not _told.has(id):
			_told[id] = true
			names.append(String(q["username"]))
	if not names.is_empty():
		requests_waiting.emit(names)


## Add by login name. If they already asked you, you are friends at once.
func send_request(username: String) -> void:
	var n := username.strip_edges()
	if n == "":
		error = "Enter the name your friend logs in with."
		message = ""
		changed.emit()
		return
	if await _write(func() -> DmResult: return await shell.api.friend_request(n)):
		for o in outgoing + friends:   # tell them now if they are online (the lobby nudges their game to reload)
			if String(o["username"]).to_lower() == n.to_lower():
				shell.party.friends_changed(int(o["accountId"]))


func accept(account_id: int) -> void:
	if await _write(func() -> DmResult: return await shell.api.friend_accept(account_id)):
		shell.party.friends_changed(account_id)


## Unfriend, decline their request or cancel yours.
func remove(account_id: int) -> void:
	if await _write(func() -> DmResult: return await shell.api.friend_remove(account_id)):
		shell.party.friends_changed(account_id)


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


## The host's world, shown everywhere a session is: its difficulty, "Hard" (also "Medium"). `d` is a session's info or presence. Heat
## (B26) left with Ascension (B36): "Heat 3 · Hard" again only once the redesign brings it back.
static func world_line(d: Dictionary) -> String:
	var diff := String(d.get("difficulty", "medium")) if d.get("difficulty") != null else "medium"
	var def := DmContent.difficulty(diff)
	var name := String(def.get("name", diff.capitalize())) if not def.is_empty() else diff.capitalize()
	if not DmAscension.OPEN:
		return name
	return "Heat %d · %s" % [int(d.get("heat", 0)) if d.get("heat") != null else 0, name]


## Where a friend is, for the list: "Sexton's Acre · in a party 2/4 · Hard" ("" offline).
static func where_line(p: Dictionary) -> String:
	if p.is_empty():
		return ""
	var parts: Array = []
	var area := String(p.get("area", "")) if p.get("area") != null else ""
	if area != "":
		var a := DmContent.area(area)
		parts.append(String(a.get("name", area)) if not a.is_empty() else area.replace("_", " ").replace("-", " ").capitalize())
	var sess: Variant = p.get("session")
	if sess is Dictionary:
		var sd: Dictionary = sess
		var who := "hosting" if bool(sd.get("isHost", false)) else "in %s's party" % String(sd.get("host", ""))
		parts.append("%s %d/%d%s · %s" % [who, int(sd.get("players", 1)), int(sd.get("max", 4)), " · closed" if bool(sd.get("private", false)) or not bool(sd.get("open", true)) else "",
			world_line(sd)])
	return " · ".join(parts)


## What a friend's row offers, in order: "join" (their Open party has room), "ask" (to be taken along: a Closed party, or they play solo),
## "invite" (into our party; playing solo, inviting hosts an Open one first).
static func actions_for(p: Dictionary, mine: Dictionary) -> Array:
	if p.is_empty() or not bool(mine.get("linked", false)):
		return []
	var sess: Variant = p.get("session")
	var their_id := String((sess as Dictionary).get("id", "")) if sess is Dictionary else ""
	var my_mode := String(mine.get("mode", "solo"))
	if their_id != "" and their_id == String(mine.get("session_id", "")):
		return []   # together already
	if my_mode == "host":
		return [] if bool(mine.get("full", false)) or their_id != "" else ["invite"]
	if my_mode != "solo":
		return []
	if not (sess is Dictionary):
		return ["invite", "ask"]
	var sd: Dictionary = sess
	if int(sd.get("players", 1)) >= int(sd.get("max", 4)):
		return []
	return ["join"] if not bool(sd.get("private", false)) and bool(sd.get("open", true)) else ["ask"]


func _write(call: Callable) -> bool:
	if unavailable() != "" or busy:
		return false
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
	return r.ok


func _take(v: Variant) -> void:
	var d: Dictionary = v if v is Dictionary else {}
	friends = d.get("friends", [])
	incoming = d.get("incoming", [])
	outgoing = d.get("outgoing", [])
	loaded = true

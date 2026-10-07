extends SceneTree
## Lobby + party suite (godot/next/party): the REAL lobby service (server/death-muffin/lobby, node, random local port, test JWT secret) and two
## DmNextGame instances in this process (SceneMultiplayer branches, one SHARED offline backend = one "server", two accounts).
##   godot --headless --path godot --script res://tests/next_lobby/run.gd
## A solo untouched . hosting a running solo session . listing / join by id / join by code . every lobby error text . open / closed . kick .
## a full session . the joiner's backend session, XP and loot on its own account . a dropped client / a dropped host leave both sides clean.

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var lobby: DmTestLobby
var mock: DmMockBackend
var api_h: DmApi
var api_j: DmApi
var ch_h: Dictionary
var ch_j: Dictionary
var hg: DmNextGame
var hroot: Node
var _n := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String, extra: String = "") -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what, " ", extra)


func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _account(api: DmApi, name: String, cls: int) -> Dictionary:
	var r := await api.register("%s%d" % [name, Time.get_ticks_usec() % 100000], "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(cls)
	return c.data


func _opts(extra: Dictionary = {}) -> Dictionary:
	var o := {"dressing": false, "persist": false, "waves": false, "audio": false, "world": false, "hud": false, "offline": true, "lobby_url": lobby.url, "warmup": false}
	o.merge(extra, true)
	return o


## Another process-local branch: its own SceneMultiplayer, the way a second machine would be.
func _branch() -> Node:
	_n += 1
	var r := Node.new()
	r.name = "Branch%d" % _n
	root.add_child(r)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/%s" % r.name))
	return r


func _game(branch: Node, ch: Dictionary, api: DmApi, opts: Dictionary) -> DmNextGame:
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	branch.add_child(g)
	await g.start(ch, api, opts)
	return g


## What main.gd does when the party says join_ready: free the solo game, start a client game on the same lobby socket.
func _join_as_client(solo: DmNextGame, branch: Node, ch: Dictionary, api: DmApi, lob: DmLobbyClient, extra: Dictionary = {}) -> DmNextGame:
	await solo.leave()
	solo.queue_free()
	await ticks(2)
	return await _game(branch, ch, api, _opts(extra.merged({"lobby": lob, "host": false, "name": api.get_token().trim_prefix("offline:")}, true)))


func _run() -> void:
	lobby = DmTestLobby.start()
	if lobby == null:
		print("next_lobby: SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm install`)")
		print("0 passed, 0 failed (skipped)")
		quit(0)
		return
	check(await lobby.wait_ready(self), "the local lobby service is up")
	mock = DmOffline.make_mock("")
	api_h = DmOffline.make_api(mock)
	api_j = DmOffline.make_api(mock)
	ch_h = await _account(api_h, "hostess", 2)
	ch_j = await _account(api_j, "joiner", 2)
	await _part_solo_and_errors()
	await _part_host_join()
	await _part_cost()
	lobby.stop()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ---- solo is untouched; errors with no session ------------------------------------------------------------------------------------------

func _part_solo_and_errors() -> void:
	hroot = _branch()
	hg = await _game(hroot, ch_h, api_h, _opts({"name": "hostess", "lobby_token": lobby.token(101, "hostess")}))
	var p := hg.party
	check(p.mode == DmNextParty.SOLO and p.lobby == null and p.link == "off", "solo: no lobby socket, no party state")
	check(hg.session.multiplayer.get_peers().is_empty() and hg.session.is_host() and hg.session.get_roster().size() == 1, "solo: a 1-player session on the offline peer")
	check(p.unavailable() == "", "solo + a lobby url: the lobby is usable")
	check(not p.view()["roster"].size() > 0, "solo: no roster")
	# errors before anything exists: a wrong code, an id that is gone, an empty code
	p.join_by_code("999999")
	check(await until(func() -> bool: return p.last_error.get("code", "") == "bad_code", 5.0), "error: a wrong code is bad_code")
	check(String(p.last_error["text"]) == String(DmNextParty.ERROR_TEXT["bad_code"]), "error: bad_code text is the player-readable one")
	check(p.busy == "" and p.mode == DmNextParty.SOLO, "error: nothing is left busy")
	p.last_error = {}
	p.join_session("deadbeef")
	check(await until(func() -> bool: return p.last_error.get("code", "") == "not_found", 5.0), "error: an id that is gone is not_found")
	check(String(p.last_error["text"]).contains("Refresh"), "error: not_found tells the player to refresh")
	p.last_error = {}
	p.join_by_code("   ")
	check(p.last_error.get("code", "") == "bad_code", "error: an empty code is refused before any request")
	p.set_watching(true)
	check(await until(func() -> bool: return p.listed, 5.0), "list: the window's watch fetches the public list")
	check(p.sessions.is_empty(), "list: empty lobby, empty list")
	p.set_watching(false)
	check(p.lobby == null and p.link == "off", "closing the window closes the idle lobby socket")
	# an offline account with no lobby override cannot use the lobby, and says why
	var off_branch := _branch()
	var off := await _game(off_branch, ch_j, api_j, _opts({"lobby_url": ""}))
	check(off.party.unavailable().contains("online account"), "offline: the lobby says online play needs an online account")
	off.party.host_session("x")
	check(off.party.last_error.get("code", "") == "unavailable" and off.party.lobby == null, "offline: hosting is refused with no socket opened")
	await off.leave()
	off.queue_free()


# ---- hosting, joining, kick, open/closed, full, rewards, drops ---------------------------------------------------------------------------

func _part_host_join() -> void:
	var p := hg.party
	# a public session
	var spawner_bodies_before := hg.session.get_bodies().size()
	var body_before := hg.local_body()
	p.host_session("Open Crypt", false)
	check(p.busy == "creating", "host: busy while the lobby answers")
	check(await until(func() -> bool: return p.mode == DmNextParty.HOST, 8.0), "host: solo becomes a hosted session", str(p.last_error) + " link=" + p.link + " busy=" + p.busy)
	check(p.code == "" and String(p.info.get("name", "")) == "Open Crypt" and not bool(p.info.get("private", true)), "host: a public session has no code")
	check(hg.local_body() == body_before and hg.session.get_bodies().size() == spawner_bodies_before, "host: the running world and the host's body are the same ones")
	check(hg.session.multiplayer.multiplayer_peer is DmRelayPeer and hg.session.is_host(), "host: the session now rides the relay peer")
	# a third party lobby client sees it listed
	var spy := await _spy("spy", 900)
	spy.request_list()
	var listed := [null]
	spy.sessions_listed.connect(func(s: Array) -> void: listed[0] = s)
	check(await _poll_until(spy, func() -> bool: return listed[0] != null), "list: a bystander can list")
	var row: Dictionary = listed[0][0] if listed[0] != null and listed[0].size() == 1 else {}
	check(row.get("name", "") == "Open Crypt" and row.get("host", "") == "hostess" and int(row.get("players", 0)) == 1 and int(row.get("max", 0)) == 4, "list: name, host, players x/4", str(listed[0]))
	spy.close()

	# the joiner: a solo game that joins from the list (the host stands somewhere away from the Chapterhouse: the joiner appears beside it)
	body_before.teleport(Vector3(30, 0, -22))
	await ticks(3)
	var jb := _branch()
	var jsolo := await _game(jb, ch_j, api_j, _opts({"name": "joiner", "lobby_token": lobby.token(102, "joiner")}))
	jsolo.party.set_watching(true)
	check(await until(func() -> bool: return jsolo.party.listed and jsolo.party.sessions.size() == 1, 6.0), "join: the joiner's window lists the public session")
	var ready := [null]
	jsolo.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: ready[0] = [l, i])
	jsolo.party.join_session(String(jsolo.party.sessions[0]["id"]))
	check(await until(func() -> bool: return ready[0] != null, 6.0), "join: the lobby seated the joiner (join_ready)")
	var jg := await _join_as_client(jsolo, jb, ch_j, api_j, ready[0][0])
	check(jg.party.mode == DmNextParty.CLIENT, "join: the joiner's party is a client")
	check(await until(func() -> bool: return jg.session.is_active() and hg.session.get_roster().size() == 2 and jg.session.get_bodies().size() == 2, 10.0), "join: both sides see both players", "host roster %d, joiner active %s bodies %d/%d" % [hg.session.get_roster().size(), jg.session.is_active(), jg.session.get_bodies().size(), hg.session.get_bodies().size()])
	check(hg.local_body() == body_before, "join: the host's body was not recreated")
	check(hg.body_of(2).position.distance_to(body_before.position) < 6.0, "join: the joiner appears beside the host, not at the Chapterhouse (%.1f m)" % hg.body_of(2).position.distance_to(body_before.position))
	_checks_after_join(jg)
	await _part_chat_and_open_closed(jg)
	await _part_rewards(jg)
	await _part_kick(jg, jb)
	await _part_private_and_full()
	await _part_drops()
	await hg.leave()
	hg.queue_free()


func _checks_after_join(jg: DmNextGame) -> void:
	var rows: Array = hg.party.view()["roster"]
	check(rows.size() == 2 and rows[0]["host"] and rows[1]["can_kick"] and not rows[0]["can_kick"], "roster: host view lists both, only the other can be removed")
	var crows: Array = jg.party.view()["roster"]
	check(crows.size() == 2 and crows[1]["you"] and not crows[0]["can_kick"] and not crows[1]["can_kick"], "roster: the joiner's view has no kick buttons")


func _part_chat_and_open_closed(jg: DmNextGame) -> void:
	# party chat both ways
	check(not DmNextParty.new().chat("x"), "chat: nothing to say to without a shell")
	var got_h := []
	var got_j := []
	hg.party.changed.connect(func() -> void: pass)
	check(jg.party.chat("hello host"), "chat: a joiner's line goes to the party")
	check(await until(func() -> bool: return hg.party.chat_log.size() == 1 and jg.party.chat_log.size() == 1, 5.0), "chat: the host and the joiner both show it")
	check(hg.party.chat_log[0] == "[%s] hello host" % api_j.get_token().trim_prefix("offline:"), "chat: line is [name] text", str(hg.party.chat_log))
	check(hg.party.chat("hi joiner") and await until(func() -> bool: return jg.party.chat_log.size() == 2, 5.0), "chat: the host's line reaches the joiner")
	# open / closed
	hg.party.set_open(false)
	check(await until(func() -> bool: return not bool(hg.party.info.get("open", true)), 5.0), "open/closed: the host closes the session")
	var spy := await _spy("spy2", 901)
	spy.request_list()
	var lst := [null]
	spy.sessions_listed.connect(func(s: Array) -> void: lst[0] = s)
	await _poll_until(spy, func() -> bool: return lst[0] != null)
	check(lst[0] != null and lst[0].size() == 0, "open/closed: a closed session leaves the public list")
	var err := [""]
	spy.lobby_error.connect(func(c: String, _m: String, _r: String) -> void: err[0] = c)
	spy.join_session(String(hg.party.info["id"]))
	await _poll_until(spy, func() -> bool: return err[0] != "")
	check(err[0] == "closed", "open/closed: a closed session refuses with closed")
	check(String(DmNextParty.ERROR_TEXT["closed"]).contains("not taking new players"), "open/closed: the closed text is readable")
	spy.close()
	hg.party.set_open(true)
	check(await until(func() -> bool: return bool(hg.party.info.get("open", false)), 5.0), "open/closed: and opens it again")


func _part_rewards(jg: DmNextGame) -> void:
	var j := jg.joiner
	check(j != null and jg.joiner.member.api == api_j, "joiner: a member of its own, on its own backend api")
	var hm := hg.rewards
	var key := int(ch_j["id"])
	check(await until(func() -> bool: return hm.members.has(key), 5.0), "rewards: the host made a member for the joiner's REAL character id")
	var m: DmRewardsMember = hm.members.get(key)
	check(m != null and m.remote and m.peer_id == 2 and m.api == null, "rewards: a remote member (no api on the host)")
	check(await until(func() -> bool: return j.session_id == hm.session_id and hm.session_id != "", 5.0), "joiner: got the host's backend session id")
	check(await until(func() -> bool: return j.backend_ok, 8.0), "joiner: session_join with its OWN token succeeded")
	check(await until(func() -> bool: return m.blocked == "" and m.joined, 5.0), "rewards: the host started crediting the joiner after its backend join")
	var hb := hg.body_of(2)
	check(int(hb.character.get("level", 0)) == int(ch_j["level"]) and hb.character_id == key, "rewards: the host's body of the joiner carries the joiner's character")
	var xp0 := int(jg.character["experience"])
	var gold0 := int(jg.character["gold"])
	var at := hb.position
	for i in 6:
		hm.on_kill({"def": "robber", "area": "graves", "level": 3.0, "elite": false, "x": at.x, "z": at.z, "killer": null})
	check(await until(func() -> bool: return j.drops_received > 0, 5.0), "loot: the host sent the joiner's drops to the joiner, not to a host-side view")
	check(m.loot_view.count() == 0, "loot: the host holds none of the joiner's drops")
	await hm.flush()
	check(await until(func() -> bool: return int(jg.character["experience"]) > xp0 or int(jg.character["level"]) > int(ch_j["level"]) - 0 and j.member.stats["kills_accepted"] > 0, 8.0), "xp: the accepted report reached the joiner's own character")
	check(j.member.stats["kills_accepted"] == 6 and j.kills_seen == 6, "xp: all 6 kills credited to the joiner (%d)" % j.member.stats["kills_accepted"])
	check(await until(func() -> bool: return j.member.loot_view.count() > 0 or int(jg.character["gold"]) > gold0, 5.0), "loot: drops stand on the joiner's own ground")
	check(await until(func() -> bool: return int(jg.character["gold"]) > gold0, 8.0), "loot: the joiner walked over its gold and it went to its own purse (%d -> %d)" % [gold0, int(jg.character["gold"])])
	var rolls: int = hm.gear_pending()
	check(rolls == 0, "loot: the host rolled nothing for the joiner")
	check(await until(func() -> bool: return j.rolls_pending == 0, 8.0), "loot: the joiner's own gear rolls finished")


func _part_kick(jg: DmNextGame, jb: Node) -> void:
	var ended := [null]
	jg.party.client_ended.connect(func(c: String, t: String) -> void: ended[0] = [c, t])
	hg.party.kick(2)
	check(await until(func() -> bool: return ended[0] != null, 8.0), "kick: the removed player's game ends the session")
	check(ended[0][0] == "kicked" and ended[0][1] == String(DmNextParty.CLOSE_TEXT["kicked"]), "kick: with the player-readable reason", str(ended[0]))
	check(await until(func() -> bool: return hg.session.get_roster().size() == 1 and hg.session.get_bodies().size() == 1, 5.0), "kick: the host is alone again, its body untouched")
	check(hg.party.mode == DmNextParty.HOST, "kick: and still hosting")
	check(hg.rewards.members.size() == 1, "kick: the joiner's member is gone")
	await jg.joiner.flush_all()
	await jg.leave()
	jg.queue_free()
	jb.queue_free()
	await ticks(2)


func _part_private_and_full() -> void:
	var p := hg.party
	var body_before := hg.local_body()
	# leaving a hosted session: the game goes on solo, the host's body and world untouched
	p.leave()
	check(p.mode == DmNextParty.SOLO and p.code == "" and hg.session.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "leave: the host is solo again on the offline peer")
	check(hg.local_body() == body_before and hg.session.is_host() and hg.session.get_roster().size() == 1, "leave: same body, same session, one player")
	var spy := await _spy("spy3", 902)
	spy.request_list()
	var lst := [null]
	spy.sessions_listed.connect(func(l: Array) -> void: lst[0] = l)
	await _poll_until(spy, func() -> bool: return lst[0] != null)
	check(lst[0] != null and lst[0].size() == 0, "leave: the public list no longer has it")
	# a private session: a six digit code, not in the list
	p.host_session("   ", true)   # an empty name takes the default one
	check(await until(func() -> bool: return p.mode == DmNextParty.HOST, 8.0), "private: hosting again from solo")
	check(p.code.length() == 6 and p.code.is_valid_int(), "private: a six digit code (%s)" % p.code)
	check(String(p.info.get("name", "")).ends_with("crypt"), "private: an empty name gets the default (%s)" % p.info.get("name", ""))
	lst[0] = null
	spy.request_list()
	await _poll_until(spy, func() -> bool: return lst[0] != null)
	check(lst[0] != null and lst[0].size() == 0, "private: not in the public list")
	var sid := String(p.info["id"])
	var errs := []
	spy.lobby_error.connect(func(c: String, _m: String, _r: String) -> void: errs.append(c))
	spy.join_session(sid)
	await _poll_until(spy, func() -> bool: return errs.size() == 1)
	spy.join_session(sid, "000000" if p.code != "000000" else "000001")
	await _poll_until(spy, func() -> bool: return errs.size() == 2)
	check(errs == ["bad_code", "bad_code"], "private: an id without the code, or with a wrong one, is bad_code", str(errs))
	# fill it: three bare relay clients take the other seats, then a real joiner is told it is full
	var seat: Array = []
	for i in 3:
		var c := await _spy("seat%d" % i, 910 + i)
		c.join_by_code(p.code)
		seat.append(c)
	var all_in := func() -> bool:
		for c in seat:
			c.poll()
		return int(p.info.get("players", 1)) >= 1 and hg.session.multiplayer.get_peers().size() == 3
	check(await until(all_in, 8.0), "full: three clients hold the other seats")
	var jb := _branch()
	var jsolo := await _game(jb, ch_j, api_j, _opts({"name": "joiner", "lobby_token": lobby.token(102, "joiner")}))
	jsolo.party.join_by_code(p.code)
	check(await until(func() -> bool:
		for c in seat:
			c.poll()
		return jsolo.party.last_error.get("code", "") == "full", 8.0), "full: the fifth player is refused with full")
	check(String(jsolo.party.last_error["text"]).contains("4 of 4"), "full: and told in words (%s)" % jsolo.party.last_error.get("text", ""))
	check(jsolo.party.mode == DmNextParty.SOLO and jsolo.party.busy == "", "full: the refused player is still solo and not busy")
	for c in seat:
		c.close()
	spy.close()
	check(await until(func() -> bool: return hg.session.multiplayer.get_peers().size() == 0 and hg.session.get_roster().size() == 1, 10.0), "full: the host is clean again once the bare clients are gone")
	# now join by code for real, then drop the joiner's connection
	var ready := [null]
	jsolo.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: ready[0] = [l, i])
	jsolo.party.join_by_code(p.code)
	check(await until(func() -> bool: return ready[0] != null, 8.0), "code: joining with the right code seats the player")
	var jg := await _join_as_client(jsolo, jb, ch_j, api_j, ready[0][0])
	check(await until(func() -> bool: return jg.session.is_active() and hg.session.get_roster().size() == 2 and jg.session.get_bodies().size() == 2, 10.0), "code: both sides see both players")
	_jg = jg
	_jb = jb


var _jg: DmNextGame
var _jb: Node


func _part_drops() -> void:
	var jg := _jg
	var p := hg.party
	var ended := [null]
	jg.party.client_ended.connect(func(c: String, t: String) -> void: ended[0] = [c, t])
	var hb := hg.local_body()
	# the joiner's connection dies (cable pulled): it ends cleanly and says why; the host plays on
	jg.party.lobby._ws.close(1006, "gone")
	check(await until(func() -> bool: return ended[0] != null, 8.0), "drop: the joiner's game ends its session")
	check(String(ended[0][1]).contains("Lost the connection"), "drop: with the lost-connection text (%s)" % ended[0][1])
	check(await until(func() -> bool: return hg.session.get_roster().size() == 1 and hg.session.get_bodies().size() == 1, 8.0), "drop: the host removed the joiner, same body, still hosting")
	check(hg.local_body() == hb and p.mode == DmNextParty.HOST and hg.rewards.members.size() == 1, "drop: host body, host mode and rewards are clean")
	await jg.leave()
	jg.queue_free()
	_jb.queue_free()
	await ticks(2)
	# a joiner again, then the HOST's connection dies: the host falls back to solo, the joiner is sent home with a reason
	var jb := _branch()
	var jsolo := await _game(jb, ch_j, api_j, _opts({"name": "joiner", "lobby_token": lobby.token(102, "joiner")}))
	var ready := [null]
	jsolo.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: ready[0] = [l, i])
	jsolo.party.join_by_code(p.code)
	await until(func() -> bool: return ready[0] != null, 8.0)
	var jg2 := await _join_as_client(jsolo, jb, ch_j, api_j, ready[0][0])
	await until(func() -> bool: return jg2.session.is_active() and hg.session.get_roster().size() == 2, 10.0)
	var ended2 := [null]
	jg2.party.client_ended.connect(func(c: String, t: String) -> void: ended2[0] = [c, t])
	var hosting := [true]
	p.hosting_changed.connect(func(on: bool) -> void: hosting[0] = on)
	p.lobby._ws.close(1006, "gone")
	check(await until(func() -> bool: return not hosting[0] and p.mode == DmNextParty.SOLO, 8.0), "host drop: the host falls back to solo")
	check(hg.local_body() == hb and hg.session.is_host() and hg.session.get_roster().size() == 1 and hg.session.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "host drop: same body, 1 player, offline peer")
	check(await until(func() -> bool: return ended2[0] != null, 8.0), "host drop: the joiner is sent home")
	check(String(ended2[0][1]) == String(DmNextParty.CLOSE_TEXT["host_left"]), "host drop: with the host-ended text (%s)" % ended2[0][1])
	await jg2.leave()
	jg2.queue_free()
	jb.queue_free()
	await ticks(2)


# ---- the cost of hosting: frame time with 25 chasing enemies, solo, then hosted with a joiner (both games in THIS process, so the hosted number is an upper bound)

func _frame_median(g: DmNextGame, hb: DmHeroBody, n: int) -> Array:
	var fc := DmFrameCost.attach(root)
	await ticks(5)
	fc.reset()
	for i in n:
		await physics_frame
		hb.heal(1e6)
	fc.queue_free()
	return [fc.median_ms(), fc.p95_ms(), fc.worst_busy_ms()]


func _part_cost() -> void:
	var b := _branch()
	var g := await _game(b, ch_h, api_h, _opts({"world": true, "name": "hostess", "lobby_token": lobby.token(103, "hostess")}))
	var hb := g.local_body()
	hb.teleport(Vector3(0, 0, -16))
	g.director.enabled = false
	g.director.clear()
	await ticks(5)
	for i in 25:
		g.director.spawn("robber", Vector3(sin(i * 0.5) * 11.0, 0.0, -16.0 + cos(i * 0.5) * 11.0), [hb])
	await ticks(60)
	var solo: Array = await _frame_median(g, hb, 150)
	g.party.host_session("Cost Crypt", true)
	await until(func() -> bool: return g.party.mode == DmNextParty.HOST, 8.0)
	# the hosting itself: nothing per frame except the relay peer's poll
	var empty: Array = await _frame_median(g, hb, 150)
	var jb := _branch()
	var jsolo := await _game(jb, ch_j, api_j, _opts({"name": "joiner", "lobby_token": lobby.token(104, "joiner")}))
	var ready := [null]
	jsolo.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: ready[0] = [l, i])
	jsolo.party.join_by_code(g.party.code)
	await until(func() -> bool: return ready[0] != null, 8.0)
	var jg := await _join_as_client(jsolo, jb, ch_j, api_j, ready[0][0], {"world": true})
	await until(func() -> bool: return jg.session.is_active() and g.session.get_roster().size() == 2, 12.0)
	await ticks(60)
	var lob := g.party.lobby
	var o0 := lob.bytes_out
	var p0 := lob.packets_out
	var t0 := Time.get_ticks_msec()
	var hosted: Array = await _frame_median(g, hb, 150)
	var secs := float(Time.get_ticks_msec() - t0) / 1000.0
	print("COST frame median ms (p95 / worst busy): solo %.2f (%.2f / %.1f); hosting, nobody joined %.2f (%.2f / %.1f); hosted with a joiner in this process %.2f (%.2f / %.1f); host -> relay %.1f KB/s %.0f packets/s" % [solo[0], solo[1], solo[2], empty[0], empty[1], empty[2], hosted[0], hosted[1], hosted[2], float(lob.bytes_out - o0) / secs / 1024.0, float(lob.packets_out - p0) / secs])
	check(empty[0] < solo[0] * 1.25 + 0.6, "cost: hosting with nobody joined costs ~nothing per frame (%.2f vs %.2f ms)" % [empty[0], solo[0]])
	check(hosted[0] < solo[0] * 1.8 + 3.0, "cost: hosted with a joiner stays near the solo cost (%.2f vs %.2f ms)" % [hosted[0], solo[0]])
	check(float(lob.packets_out - p0) / secs < 400.0 and float(lob.bytes_out - o0) / secs < 300.0 * 1024.0, "cost: under 400 packets/s and 300 KB/s to the relay with 25 enemies")
	await jg.leave()
	await g.leave()
	g.queue_free()
	jg.queue_free()
	b.queue_free()
	jb.queue_free()
	await ticks(3)


# ---- helpers ----------------------------------------------------------------------------------------------------------------------------------

## A bare lobby client (a bystander) for what the lobby shows to others.
func _spy(name: String, account: int) -> DmLobbyClient:
	var c := DmLobbyClient.new()
	c.connect_to_lobby(lobby.url, lobby.token(account, name))
	var ok := [false]
	c.authenticated.connect(func(_i: int, _n: String) -> void: ok[0] = true)
	await _poll_until(c, func() -> bool: return ok[0])
	return c


func _poll_until(c: DmLobbyClient, cond: Callable, limit_s: float = 6.0) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		c.poll()
		if cond.call():
			return true
		await create_timer(0.03).timeout
	return cond.call()

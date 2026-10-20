extends SceneTree
## Lobby + party suite (client/next/party): the REAL lobby service (server/death-muffin/lobby, node, random local port, test JWT secret) and two
## DmNextGame instances in this process (SceneMultiplayer branches, one SHARED offline backend = one "server", two accounts).
##   godot --headless --path client --script res://tests/lobby/run.gd
## A solo untouched . hosting a running solo session . listing / join by id / join by code . every lobby error text . open / closed . kick .
## a full session . the joiner's backend session, XP and loot on its own account . a dropped client / a dropped host leave both sides clean .
## a dropped client is offered the way back into the host's Closed party (Rejoin, Dismiss) and a removed one is not.
## (What hosting costs in packets and bytes is checked with separate processes in processes.gd.)

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
		print("lobby: SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm install`)")
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
	lobby.stop()
	print("%d passed, %d failed" % [passed, failed])
	print("%s lobby %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
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
	hg.session.spawn_resolve = func(pt: Vector3) -> Vector3: return Vector3(pt.x, 0.0, 7.0)
	check(hg.session._spawn_point(1).z == 7.0 and hg.session._spawn_point(0).z != 7.0, "spawn: a joiner's ring point goes through the walkable resolver, the host's own does not")
	hg.session.spawn_resolve = hg._walkable_spawn
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
	await _part_ground(jg)
	await _part_polish(jg)
	await _part_guest_belt_and_summon(jg)
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
	# a find (a new rune, a legendary): the host stamps the finder's roster name, everyone reads the line
	check(jg.party.announce("{who} found the Rune of Splinters."), "announce: a joiner's find goes to the party")
	var who_j := api_j.get_token().trim_prefix("offline:")
	check(await until(func() -> bool: return hg.party.chat_log.size() == 3 and jg.party.chat_log.size() == 3, 5.0), "announce: the host and the joiner both show it")
	check(hg.party.chat_log[2] == "%s found the Rune of Splinters." % who_j and jg.party.chat_log[2] == hg.party.chat_log[2], "announce: the finder is named, no [name] prefix", str(hg.party.chat_log))
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
	# the joiner's build comes from the server's record of it (gear, set bonuses, boons, vows), not from its client
	check(await until(func() -> bool: return hg.remote_builds.has(2), 5.0), "build: the host read the joiner's build from the server")
	if hg.remote_builds.has(2):
		var rb: Dictionary = hg.remote_builds[2]
		check(int(rb["character"]["id"]) == key and rb["slots"] is Array and rb["local"] is Dictionary, "build: character, worn slots and progression")
		check(hg.build_for(2)["stats"] is Dictionary, "build: the host builds the joiner's hero from it")
	var xp0 := int(jg.character["experience"])
	var gold0 := int(jg.character["gold"])
	var at := hb.position
	for i in 6:
		hm.on_kill({"def": "robber", "area": "graves", "level": 3.0, "elite": false, "x": at.x, "z": at.z, "killer": null})
	check(await until(func() -> bool: return j.drops_received > 0, 5.0), "loot: the host sent the joiner's drops to the joiner, not to a host-side view")
	check(m.loot_view.count() == 0, "loot: the host holds none of the joiner's drops")
	# server-decided drops (DECISIONS B20): the joiner rolls its own drops from its own tape and claims them itself
	check(m.rolls_own_drops, "tape: the joiner said it rolls its own drops")
	var jlv0: DmLootView = j.member.loot_view
	var tries := 0
	while not jlv0._drops.any(func(d: Dictionary) -> bool: return (d["item"] as Dictionary).has("claim")) and tries < 120:
		tries += 1
		hm.on_kill({"def": "robber", "area": "graves", "level": 3.0, "elite": true, "x": at.x, "z": at.z, "killer": null})
		await process_frame
	var jd: Array = jlv0._drops.filter(func(d: Dictionary) -> bool: return (d["item"] as Dictionary).has("claim"))
	check(not jd.is_empty(), "tape: an elite kill in the host's world dropped from the joiner's own tape (%d kills)" % tries)
	if not jd.is_empty():
		var want := String(jd[0]["item"]["item_id"])
		var cr: DmResult = await j.member.api.drops_claim(key, jd[0]["item"]["claim"], j.session_id)   # what the joiner's pickup sends (no HUD here)
		check(cr.ok and String(cr.data["item"]["item_id"]) == want, "tape: the joiner's own claim is granted the server's roll (%s, %s)" % [want, cr.error])
		var again: DmResult = await j.member.api.drops_claim(key, jd[0]["item"]["claim"], j.session_id)
		check(not again.ok, "tape: and only once")
	for d in jlv0._drops.duplicate():
		jlv0.take_claimed(d)
	await hm.flush()
	check(await until(func() -> bool: return int(jg.character["experience"]) > xp0 or int(jg.character["level"]) > int(ch_j["level"]) - 0 and j.member.stats["kills_accepted"] > 0, 8.0), "xp: the accepted report reached the joiner's own character")
	check(j.member.stats["kills_accepted"] == 6 + tries and j.kills_seen == 6 + tries, "xp: all %d kills credited to the joiner (%d)" % [6 + tries, j.member.stats["kills_accepted"]])
	check(await until(func() -> bool: return int(jg.character["gold"]) > gold0, 8.0), "loot: the joiner's gold went straight to its own purse (%d -> %d)" % [gold0, int(jg.character["gold"])])
	var rolls: int = hm.gear_pending()
	check(rolls == 0, "loot: the host rolled nothing for the joiner")
	check(await until(func() -> bool: return j.rolls_pending == 0, 8.0), "loot: the joiner's own gear rolls finished")


## Dropped gear (ground.cjs, DECISIONS B16): a piece found in the session and dropped by the host is drawn for the joiner, who picks it up
## through the server (the host's copy goes away); a piece found outside the session never reaches the joiner.
func _part_ground(jg: DmNextGame) -> void:
	var gear_id := ""
	for id in DmContent.items():
		if DmAffixRules.is_affix_gear(String(DmContent.item(id).get("type", ""))) and DmAffixes.can_roll(id):
			gear_id = id
			break
	var hcid := int(ch_h["id"])
	var jcid := int(ch_j["id"])
	var sid := hg.party_session_id()
	check(sid != "" and jg.party_session_id() == sid, "ground: host and joiner share one backend session")
	# two pieces in the host's bag: one rolled in the session, one without it
	var rows: Array = (await api_h.get_inventory(hcid)).data
	var bag: Array = []
	var used := {}
	for r in rows:
		if int(r["slot_index"]) < DmLoot.bag_size():
			bag.append({"slot_index": int(r["slot_index"]), "item_id": r["item_id"], "quantity": int(r["quantity"]), "instance_id": r.get("instance_id")})
			used[int(r["slot_index"])] = true
	var slots: Array = []
	for pass_ in 2:
		var roll: DmResult = await api_h.roll_loot(hcid, [{"item_id": gear_id, "level": 5, "source": "kill"}], sid if pass_ == 0 else "")
		var free := 0
		while used.has(free):
			free += 1
		used[free] = true
		slots.append(free)
		bag.append({"slot_index": free, "item_id": gear_id, "quantity": 1, "instance_id": roll.data[0]["instance_id"]})
	check((await api_h.save_inventory(hcid, bag, DmLoot.bag_size())).ok, "ground: both pieces in the host's bag")
	# the piece found in the session: dropped by the host, relayed to the joiner, picked up by the joiner through the server
	var dr: DmResult = await api_h.ground_drop(hcid, sid, slots[0], 1.0, 2.0)
	check(dr.ok and (dr.data["eligible"] as Array).has(jcid), "ground: the server lets the joiner take the piece found in the session", str(dr.data if dr.ok else dr.error))
	var entry := {"drop_id": String(dr.data["dropId"]), "item": dr.data["item"], "x": 1.0, "z": 2.0, "eligible": dr.data["eligible"]}
	hg.my_member().loot_view.shared_item(entry)
	hg.party.share_ground(entry)
	var jlv: DmLootView = jg.my_member().loot_view
	var hlv: DmLootView = hg.my_member().loot_view
	var shared := func(lv: DmLootView) -> int: return lv.debug_drops().filter(func(d: Dictionary) -> bool: return d["drop_id"] != "").size()
	check(await until(func() -> bool: return shared.call(jlv) == 1, 5.0), "ground: the host relayed it to the joiner")
	var pr: DmResult = await api_j.ground_pickup(jcid, entry["drop_id"])
	check(pr.ok and (pr.data["bag"] as Array).any(func(r: Dictionary) -> bool: return r["item_id"] == gear_id), "ground: the joiner picked it up into its own bag", str(pr.error))
	jlv.remove_shared(entry["drop_id"])
	jg.party.share_taken(entry["drop_id"])
	check(await until(func() -> bool: return shared.call(hlv) == 0, 5.0), "ground: the host's copy went away")
	check(not (await api_h.ground_pickup(hcid, entry["drop_id"])).ok, "ground: a second pickup finds it gone")
	# the piece found outside the session: only the dropper may take it, so nobody else is shown it
	var dr2: DmResult = await api_h.ground_drop(hcid, sid, slots[1], 1.0, 2.0)
	check(dr2.ok and dr2.data["eligible"] == [hcid], "ground: a piece found outside the session is for the dropper only")
	var e2 := {"drop_id": String(dr2.data["dropId"]), "item": dr2.data["item"], "x": 1.0, "z": 2.0, "eligible": dr2.data["eligible"]}
	hg.party.share_ground(e2)
	await ticks(30)
	check(shared.call(jlv) == 0, "ground: and the joiner is never shown it")
	check(not (await api_j.ground_pickup(jcid, e2["drop_id"])).ok, "ground: the server refuses the joiner anyway")
	check((await api_h.ground_pickup(hcid, e2["drop_id"])).ok, "ground: the dropper picks it back up")


## Co-op polish (owner playtest 2026-10-11): every peer shows every hero's level, the world scales to the party leader, a friend's rites leave
## another player's thralls and body alone.
func _part_polish(jg: DmNextGame) -> void:
	var hb := hg.body_of(1)
	var jbody := hg.body_of(2)
	var key := int(ch_j["id"])
	# ---- levels reach every peer (the joiner's puppets of the others carry no character)
	check(await until(func() -> bool: return jg.party.levels.has(1) and jg.party.levels.has(2), 5.0), "levels: the host sent its table to the joiner")
	check(jg.party.level_of(jg.body_of(2)) == int(jg.character["level"]) and jg.party.level_of(jg.body_of(1)) == int(hg.character["level"]), "levels: the joiner shows its own and the host's level")
	check(hg.party.level_of(jbody) == int(ch_j["level"]) and hg.party.level_of(hb) == int(hg.character["level"]), "levels: the host shows its own and the joiner's level")
	hg.character["level"] = 31
	hg.rewards.member_credited.emit(int(ch_h["id"]), {"levels": 1, "xp": 0, "kills": 0})   # the host levelled
	check(await until(func() -> bool: return jg.party.level_of(jg.body_of(1)) == 31, 5.0), "levels: the host's level-up reaches the joiner's party frame")
	var m: DmRewardsMember = hg.rewards.members[key]
	m.prog.character["level"] = 12
	hg.rewards.member_credited.emit(key, {"levels": 1, "xp": 0, "kills": 0})   # the joiner levelled
	check(await until(func() -> bool: return jg.party.levels.get(2, 0) == 12, 5.0), "levels: the joiner's level-up reaches every peer's table")
	check(hg.party.level_of(jbody) == 12 and jbody.character["level"] == 12, "levels: and on the host")
	# ---- shared objectives: a party kill counts for every member's own area tally, and a joiner's own seal breaks on its own account
	var hmem: DmRewardsMember = hg.rewards.members[int(ch_h["id"])]
	var jprog: DmProgression = jg.joiner.prog
	var seal: Dictionary = DmContent.area("ossuary")["unlock"]   # the Ossuary's seal: kills in another area
	var seal_area := String(seal["area"])
	var need := jprog.unlock_kills(float(seal["kills"]))
	var hk0 := hmem.prog.kills("graves")
	var jk0 := jprog.kills("graves")
	var warren_before := jprog.really_unlocked("ossuary")
	for i in 3:
		hg.rewards.on_kill({"def": "robber", "area": "graves", "level": 3.0, "elite": false, "x": hb.position.x, "z": hb.position.z, "killer": jbody})   # the JOINER's kill
	await hg.rewards.flush()
	check(await until(func() -> bool: return hmem.prog.kills("graves") >= hk0 + 3, 8.0), "objectives: the joiner's kills count on the host's own tally too (%d -> %d)" % [hk0, hmem.prog.kills("graves")])
	check(await until(func() -> bool: return jprog.kills("graves") >= jk0 + 3, 8.0), "objectives: and on the joiner's own account (%d -> %d)" % [jk0, jprog.kills("graves")])
	# the whole party counts: a joiner out of range of the kill gets no XP or loot, but its area tally and the host's both move
	var far := hb.position + Vector3(60.0, 0.0, 0.0)
	var xp_before: int = jg.joiner.member.stats["xp_applied"]
	var drops_before: int = jg.joiner.drops_received
	var jk1 := jprog.kills("graves")
	var hk1 := hmem.prog.kills("graves")
	jbody.teleport(far)
	await ticks(2)
	for i in 4:
		hg.rewards.on_kill({"def": "robber", "area": "graves", "level": 3.0, "elite": false, "x": hb.position.x, "z": hb.position.z, "killer": hb})
	await hg.rewards.flush()
	check(await until(func() -> bool: return jprog.kills("graves") >= jk1 + 4, 8.0), "party objective: an out-of-range joiner's tally still counts the 4 kills (%d -> %d)" % [jk1, jprog.kills("graves")])
	check(hmem.prog.kills("graves") >= hk1 + 4, "party objective: and the host's own tally")
	check(jg.joiner.member.stats["xp_applied"] == xp_before and jg.joiner.drops_received == drops_before, "party objective: but it earns no XP and no loot for them")
	check(hg.ui_host == null or hg.ui_host.kills_in("graves") >= 4, "party objective: the host's HUD tally agrees")
	jbody.teleport(hb.position + Vector3(2.0, 0.0, 0.0))
	jprog.local["areaKills"][seal_area] = need   # the seal check itself, on the joiner's account
	var toasts := []
	jg.joiner.event.connect(func(_id: String, ctx: Dictionary) -> void: toasts.append(String(ctx.get("text", ""))))
	jg.joiner._check_unlocks()   # (the backend owns the unlock: with only 9 real kills it takes the flag back at the next sync)
	check(not warren_before and toasts.any(func(t: String) -> bool: return t.contains("A seal breaks: ")), "objectives: the joiner's own seal check runs and announces a broken seal once its tally is in", str(toasts))
	# ---- the world scales to the party leader, wherever the stronger friend stands
	jbody.character["level"] = 60
	hb.character["level"] = 25
	var heroes: Array = [jbody, hb]
	check(hg.director.scaling_levels(heroes) == [25.0], "scaling: a party of 60 and 25 scales to the leader (%s)" % str(hg.director.scaling_levels(heroes)))
	check(hg.director.scaling_levels([jbody]) == [25.0], "scaling: and to the leader even when only the friend is in the area")
	var e := hg.director.spawn("robber", hb.position, heroes, false, {}, {"area": "cloister"})   # a body of the core: an id
	var e_level := int(hg.core_host.enemy_info(e)["level"]) if e > 0 else 0
	var at_leader := int(DmEnemyStats.area_level("cloister", [25.0], float(hg.director.vow_fx.get("levels", 0.0))))   # the area's level for a hero of 25 (its floor, or the hero's)
	var at_friend := int(DmEnemyStats.area_level("cloister", [60.0], float(hg.director.vow_fx.get("levels", 0.0))))
	check(e > 0 and e_level == at_leader and at_leader != at_friend, "scaling: a Cloister dead rises at the leader's level (%d), not the friend's (%d): %d" % [at_leader, at_friend, e_level])
	if e > 0:
		hg.core_host.remove_enemy(e)
	jbody.character["level"] = 12
	hb.character["level"] = 31

	# ---- a friend's rites do not hurt another player's thralls or body
	check(await until(func() -> bool: return jbody.get_node_or_null("Rites") != null and hb.get_node_or_null("Rites") != null, 5.0), "friendly fire: both bodies have their caster (the legion is the core's)")
	var th := (jbody.get_node("Rites") as DmRiteCaster).thralls()   # the joiner's legion on the host's core
	var spot := hb.position + Vector3(2.0, 0.0, 0.0)
	var mine: Array = []
	for i in 3:
		hg.core_host.corpses.add_corpse(spot.x + i * 0.4, spot.z, "normal", "robber", false, 0.0, 1.0, hg.area_id)
		var r := th.raise({"kind": "warrior", "cap": 6.0, "hp": 400.0, "damage": 10.0, "attackSpeedMult": 1.0}, spot)
		if r["ok"]:
			mine.append(int(r["thralls"][0]))
	check(mine.size() >= 2, "friendly fire: the joiner has thralls to protect (%d)" % mine.size())
	jbody.teleport(spot)
	hb.teleport(spot + Vector3(-1.0, 0.0, 0.0))
	var foe := hg.director.spawn("robber", spot + Vector3(1.0, 0.0, 0.0), [hb], false, {}, {})
	hg.core_host.core.stun(foe, 3600.0)   # the core's body stands where it is (the old game's was a still one too)
	await ticks(30)
	var hp0: Array = mine.map(func(t: int) -> float: return float(th.info(t)["hp"]))
	var jhp0 := jbody.hp
	var caster := hb.get_node("Rites") as DmRiteCaster
	for rite in DmRiteRegistry.MODULES.keys():
		if rite in ["black_litany", "grave_step", "veil_step", "wraith_walk"]:
			continue   # black litany spends the caster's OWN legion; the others only move the caster
		caster.p["resource"]["value"] = caster.p["resource"]["max"]
		caster.p["cooldowns"].clear()
		caster.request_cast(rite, spot, -1, 1)
		await ticks(4)
	await ticks(60)
	var hurt := 0
	for i in mine.size():
		var ti: Dictionary = th.info(mine[i])
		if not ti.is_empty() and float(ti["hp"]) < hp0[i] - 0.01:
			hurt += 1
	check(hurt == 0, "friendly fire: none of the joiner's thralls took damage from the host's rites (%d hurt)" % hurt)
	check(jbody.hp >= jhp0 - 0.01, "friendly fire: nor the joiner's body")
	var foe_info: Dictionary = hg.core_host.enemy_info(foe)
	check(foe_info.is_empty() or float(foe_info["hp"]) < float(foe_info["max_hp"]), "friendly fire: (the rites did hit the enemy, so they were cast)")
	for t in mine:
		hg.core_host.core.kill_thrall(t, "crumbled")


# ---- a guest's belt and boss summons: its own bag and shards pay, the host applies / wakes ----------------------------------------------

func _part_guest_belt_and_summon(jg: DmNextGame) -> void:
	var jbody := hg.body_of(2)
	var jprog: DmProgression = jg.joiner.prog
	# the belt: built as DmNextUiHost._make_guest_belt does (this joiner runs without a HUD), on the joiner's own bag
	await api_j.save_inventory(int(ch_j["id"]), [{"slot_index": 0, "item_id": "flask_hp_minor", "quantity": 2, "equipped": 0},
		{"slot_index": 1, "item_id": "flask_speed", "quantity": 1, "equipped": 0}], DmLoot.bag_size())
	var inv := DmInventory.new(api_j, int(ch_j["id"]))
	inv.replace((await api_j.get_inventory(int(ch_j["id"]))).data)
	var belt := DmNextBelt.new()
	belt.body = jg.local_body()
	belt.inventory = inv
	belt.prog = jprog
	belt.remote_use = jg.party.guest_use
	jbody.p["hp"] = 5.0
	jbody._mirror_from_state()
	var hp0 := float(jbody.p["hp"])
	belt.drink_flask()
	var want := jbody.max_hp * float(DmContent.healing_flasks()["flask_hp_minor"])
	check(inv.count("flask_hp_minor") == 1, "guest belt: Q takes the flask from the guest's own bag")
	check(await until(func() -> bool: return float(jbody.p["hp"]) >= hp0 + want - 0.5, 4.0), "guest belt: the host heals the guest's hero by the flask (%.1f -> %.1f, +%.1f wanted)" % [hp0, float(jbody.p["hp"]), want])
	belt.drink_flask()
	check(inv.count("flask_hp_minor") == 1, "guest belt: the sip cooldown holds on the guest too")
	var slot := String(DmContent.brews()["flask_speed"]["slot"])
	belt.drink_belt(slot)
	check(inv.count("flask_speed") == 0 and belt.guest_brews.has(slot), "guest belt: a brew is drunk from the guest's bag and its chip shows it active")
	check(await until(func() -> bool: return jbody.p["brews"].get(slot) != null and jbody.p["brews"][slot]["id"] == "flask_speed", 4.0), "guest belt: the brew acts on the guest's hero on the host")
	# boss summons: the guest's own shards
	hg.bosses.assume_area = "graves"
	var site := hg.bosses.site_pos("gravedigger")
	var cost := int(DmContent.boss("gravedigger")["shards"])
	jbody.teleport(site + Vector3(0.0, 0.0, 2.0))
	await ticks(60)   # an area change saves the progression: its reply restores the saved shards, so they are set after it
	jbody.teleport(site + Vector3(0.0, 0.0, 2.0))
	jprog.local["shards"] = cost - 1
	jg.bosses.request_summon("gravedigger")
	await ticks(30)
	check(hg.bosses.active_boss() == null and int(jprog.local["shards"]) == cost - 1, "guest summon: too few of its own shards is refused on the guest, nothing woken")
	for k in mock.db["accounts"]:   # the shared backend holds the guest's shards too, so its save keeps them
		if mock.db["accounts"][k]["character"]["id"] == int(ch_j["id"]):
			mock.db["accounts"][k]["necro"]["soulShards"] = cost + 3
	jprog.local["shards"] = cost + 3
	jg.bosses.request_summon("gravedigger")
	check(await until(func() -> bool: return hg.bosses.active_boss() != null, 4.0), "guest summon: the host wakes the boss the guest called (the host's copy of the guest holds no shards)")
	check(await until(func() -> bool: return int(jprog.local["shards"]) == 3, 4.0), "guest summon: the guest's own shards pay the boss's price (%d left)" % int(jprog.local["shards"]))
	var boss := hg.bosses.active_boss()
	if boss != null:
		hg.core_host.damage(boss.core_id, 1.0e9, hg.local_body().core_id)   # the host's hero ends the fight (the old game freed the boss node)
	hg.bosses.assume_area = ""
	await ticks(10)


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
	# a removed player is no dropped one: its next game is offered no way back
	var nb := _branch()
	var nsolo := await _game(nb, ch_j, api_j, _opts({"name": "joiner", "lobby_token": lobby.token(102, "joiner")}))
	nsolo.party.go_online()
	check(await until(func() -> bool: return nsolo.party.link == "ready", 8.0), "kick: the removed player's next game is on the lobby")
	await ticks(40)
	check(_rejoin_of(nsolo).is_empty(), "kick: and is offered no way back into the party it was removed from")
	await nsolo.leave()
	nsolo.queue_free()
	nb.queue_free()
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
	await _part_rejoin()
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


## The rejoin offer of a dropped player (client/next/party/README.md "Dropped players"): the host's party is Closed (private), the joiner's connection just died.
func _rejoin_of(g: DmNextGame) -> Dictionary:
	for v in g.party.invites:
		if bool((v as Dictionary).get("rejoin", false)):
			return v
	return {}


func _part_rejoin() -> void:
	var p := hg.party
	# the dropped player's next game (main.gd puts it back in its own world): its lobby link is offered the way back into the party, and nothing joins by itself
	var rb := _branch()
	var rsolo := await _game(rb, ch_j, api_j, _opts({"name": "joiner", "lobby_token": lobby.token(102, "joiner")}))
	var told: Array = []
	rsolo.party.social_notice.connect(func(t: String) -> void: told.append(t))
	rsolo.party.go_online()
	check(await until(func() -> bool: return not _rejoin_of(rsolo).is_empty(), 8.0), "rejoin: the dropped player's new game is offered the way back")
	var o := _rejoin_of(rsolo)
	check(not o.is_empty() and String(o["info"]["id"]) == String(p.info["id"]) and String(o["from"]) == "hostess" and int(o["until"]) > Time.get_ticks_msec(), "rejoin: into the same party, with the window it has left", str(o))
	check(told.size() == 1 and String(told[0]).contains("dropped out of hostess"), "rejoin: with a toast that says so (%s)" % [told])
	await ticks(30)
	check(rsolo.party.mode == DmNextParty.SOLO and rsolo.party.busy == "" and hg.session.get_roster().size() == 1, "rejoin: and it never joins by itself")
	# Rejoin: the Closed door opens without a code
	var ready := [null]
	rsolo.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: ready[0] = [l, i])
	rsolo.party.accept_invite(int(o["from_id"]))
	check(await until(func() -> bool: return ready[0] != null, 8.0), "rejoin: Rejoin seats the player in the Closed party, no code needed")
	var jg := await _join_as_client(rsolo, rb, ch_j, api_j, ready[0][0])
	check(await until(func() -> bool: return jg.session.is_active() and hg.session.get_roster().size() == 2 and jg.session.get_bodies().size() == 2, 10.0), "rejoin: both sides see both players again")
	# dropped once more: offered again (a joined party is a new party for the offer), and a dismissed offer stays dismissed on later connections
	var ended := [null]
	jg.party.client_ended.connect(func(c: String, t: String) -> void: ended[0] = [c, t])
	jg.party.lobby._ws.close(1006, "gone")
	check(await until(func() -> bool: return ended[0] != null and hg.session.get_roster().size() == 1, 8.0), "rejoin: dropped again")
	await jg.leave()
	jg.queue_free()
	rb.queue_free()
	await ticks(2)
	var rb2 := _branch()
	var rsolo2 := await _game(rb2, ch_j, api_j, _opts({"name": "joiner", "lobby_token": lobby.token(102, "joiner")}))
	var told2: Array = []
	rsolo2.party.social_notice.connect(func(t: String) -> void: told2.append(t))
	rsolo2.party.go_online()
	check(await until(func() -> bool: return not _rejoin_of(rsolo2).is_empty(), 8.0), "rejoin: offered again after the second drop")
	# the link reconnects (a blip): the lobby tells again while the window lasts; the same offer is not announced twice
	rsolo2.party.close_link()
	rsolo2.party.refresh()
	var repeated := [0]
	rsolo2.party.lobby.rejoin_offered.connect(func(_f: String, _i: int, _s: Dictionary, _ms: int) -> void: repeated[0] += 1)
	check(await until(func() -> bool: return repeated[0] == 1 and rsolo2.party.link == "ready", 8.0), "rejoin: the lobby repeats the offer on the next connection of the window")
	await ticks(10)
	check(rsolo2.party.invites.filter(func(v: Dictionary) -> bool: return bool(v.get("rejoin", false))).size() == 1 and told2.size() == 1, "rejoin: as the same row, announced once", str(told2))
	rsolo2.party.decline_invite(int(_rejoin_of(rsolo2)["from_id"]))
	check(_rejoin_of(rsolo2).is_empty() and rsolo2.party.mode == DmNextParty.SOLO, "rejoin: Dismiss removes it")
	rsolo2.party.close_link()
	rsolo2.party.refresh()
	repeated[0] = 0
	rsolo2.party.lobby.rejoin_offered.connect(func(_f: String, _i: int, _s: Dictionary, _ms: int) -> void: repeated[0] += 1)
	check(await until(func() -> bool: return repeated[0] == 1 and rsolo2.party.link == "ready", 8.0), "rejoin: the lobby still repeats it after a Dismiss")
	await ticks(10)
	check(_rejoin_of(rsolo2).is_empty() and told2.size() == 1, "rejoin: but a dismissed offer is not shown again", str(told2))
	await rsolo2.leave()
	rsolo2.queue_free()
	rb2.queue_free()
	await ticks(2)


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

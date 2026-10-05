extends SceneTree
## Co-op (Phase C), headless: two DmGame instances joined through an in-process relay (a fake DmRtClient pair, the real relay's roles:
## oldest = host publishes snapshots + events, guests send intents). godot --headless --path godot --script res://tests/game/coop_run.gd

class FakeRt extends DmRtClient:
	var peer: FakeRt
	var sid := ""
	var host := false
	var joined := false
	var info := {}
	var roster: Array = []
	var snapshot: Variant = null

	func is_connected_to_world() -> bool:
		return joined

	func is_host() -> bool:
		return joined and host

	func connect_to_world(_token: String, request: Dictionary) -> DmResult:
		joined = true
		self_id = sid
		instance = "party"
		host_id = peer.sid if not host else sid
		info = {"id": sid, "characterId": request["characterId"], "name": sid, "classIndex": request["classIndex"], "level": request["level"], "x": request["x"], "z": request["z"], "facing": 0.0, "moving": false, "hpFrac": 1.0, "gear": request.get("gear", {})}
		var players: Array = []
		if peer.joined:
			players.append(peer.info)
			peer.player_joined.emit(info)
		return DmResult.success({"self": info, "players": players, "hostId": host_id, "instance": "party", "solo": false, "snapshot": snapshot})

	func send_move(u: Dictionary) -> void:
		if joined and peer.joined:
			var d := u.duplicate()
			d["id"] = sid
			peer.player_moved.emit(d)

	func send_intent(i: Dictionary) -> void:
		if joined and peer.joined:
			peer.intent_received.emit({"from": sid, "intent": i})

	func send_snapshot(s: Dictionary) -> void:
		if joined and peer.joined:
			peer.snapshot_received.emit(s)

	func send_events(b: Array) -> void:
		if joined and peer.joined and not b.is_empty():
			peer.events_received.emit(b)

	func send_chat(t: String) -> void:
		if joined and peer.joined:
			peer.chat_received.emit({"id": sid, "name": sid, "text": t})
			chat_received.emit({"id": sid, "name": sid, "text": t})

	func disconnect_from_world() -> void:
		joined = false

var _pass := 0
var _fail := 0
var _mock: DmMockBackend

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _initialize() -> void:
	_run.call_deferred()

func _make_game(name: String) -> DmGame:
	var api := DmOffline.make_api(_mock)
	var r := await api.register(name, name + "@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": false, "persist": false, "local_progress": true, "seed": 5})
	return game

func _tick(games: Array, seconds: float) -> void:
	for i in int(seconds * 60.0):
		for g in games:
			g.tick(1.0 / 60.0)

func _run() -> void:
	_mock = DmOffline.make_mock("")
	var a := await _make_game("hosta%d" % (Time.get_ticks_usec() % 100000))
	var b := await _make_game("guestb%d" % (Time.get_ticks_usec() % 100000))
	var ra := FakeRt.new()
	var rb := FakeRt.new()
	ra.peer = rb
	rb.peer = ra
	ra.sid = "A"
	rb.sid = "B"
	ra.host = true
	a.coop = DmGameCoop.new(a, ra)
	b.coop = DmGameCoop.new(b, rb)
	for g in [a, b]:
		g.player.teleport(0.0, -10.0)
		g._enter_area("graves")
	var res := await a.coop.join_world("party", "first")
	_check(res.ok and a.coop.is_authority(), "A joins and keeps the world")
	res = await b.coop.join_world("party", "first")
	_check(res.ok and not b.coop.is_authority(), "B joins as a guest")
	_check(a.remotes.has("B") and b.remotes.has("A"), "both see each other")
	_check(a.self_id == "A" and b.self_id == "B", "self ids from the relay")
	_check(a.party_code == "party" and b.party_code == "party", "party code set")
	# the host's world reaches the guest
	var e: DmSimEnemy = a.sim.spawn_enemy("robber", "graves", a.player.x + 3.0, a.player.z - 4.0, false, false)
	_tick([a, b], 1.5)
	_check(b.sim.enemies.has(e.id), "the guest mirrors the host's enemy")
	_check(b.sim != a.sim, "the guest's sim is a facade, not the host's")
	# the guest's cast reaches the host (intent) and the kill pays the guest
	var xp0: int = int(b.character["experience"]) + int(b.character["level"]) * 1000
	for i in 400:
		if not a.sim.enemies.has(e.id):
			break
		var me: DmSimEnemy = b.sim.enemies.get(e.id)
		if me != null:
			b.p["castUntil"] = 0.0
			b.p["resource"]["value"] = 100.0
			b.abilities.cast(b.primary, {"x": me.x, "z": me.z, "enemyId": me.id}, b.now_ms)
		_tick([a, b], 0.05)
	_check(not a.sim.enemies.has(e.id), "the guest's rites killed the host's enemy (intent relayed)")
	_tick([a, b], 1.0)
	_check(int(b.character["experience"]) + int(b.character["level"]) * 1000 > xp0, "the kill paid the guest (death event relayed)")
	# movement + chat
	b.player.teleport(2.0, -12.0)
	_tick([a, b], 0.5)
	var rem: Dictionary = a.remotes["B"]
	_check(absf(rem["tx"] - b.player.x) < 0.5, "B's position reaches A: %f vs %f" % [rem["tx"], b.player.x])
	var chats: Array = []
	a.game_event.connect(func(id: String, ctx: Dictionary): if id == "chat": chats.append(ctx["text"]))
	b.send_chat("hello")
	_check(chats.size() >= 1 and String(chats[0]).contains("hello"), "chat relayed: %s" % str(chats))
	# host migration: A drops, B becomes the keeper with the world intact
	var e2: DmSimEnemy = a.sim.spawn_enemy("robber", "graves", a.player.x, a.player.z - 6.0, false, false)
	_tick([a, b], 1.0)
	_check(b.sim.enemies.has(e2.id), "second enemy mirrored")
	ra.disconnect_from_world()
	rb.host = true
	rb.host_changed.emit("B", null)
	_check(b.coop.is_authority(), "B became the keeper")
	_check(b.sim.enemies.has(e2.id), "the keeper's world kept the enemy")
	_tick([b], 1.0)
	_check(b.sim.enemies.has(e2.id), "the enemy lives on in the new sim")
	# leaving the party
	_check(b.party_code == "party", "still in the party")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

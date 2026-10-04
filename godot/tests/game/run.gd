extends SceneTree
## Game-core tests (headless): scripted sessions against DmApi's mock backend. godot --headless --path godot --script res://tests/game/run.gd

var _pass := 0
var _fail := 0

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _initialize() -> void:
	_run.call_deferred()

func _finish() -> void:
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

var _mock: DmMockBackend

func _api() -> DmApi:
	_mock = DmMockBackend.new("")
	var mock := _mock
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	return api

func _run() -> void:
	var api := _api()
	var r := await api.register("tester", "t@example.com", "pw1234")
	if not r.ok:
		printerr("register failed: ", r.error, " ", r.status)
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	_check(c.ok, "character created")
	var game := DmGame.new()
	root.add_child(game)
	print("starting")
	await game.start(c.data, api, {"visual": false, "persist": false, "seed": 7})
	_check(game.ready_, "game ready")
	_check(game.area_id == "acre", "starts in the acre: %s" % game.area_id)
	for i in 60:
		game.tick(1.0 / 60.0)
	_check(game.sim != null and game.player.alive, "alive after 1 s")
	await _combat(game)
	await _input(game)
	_finish()


func _key(game: DmGame, ch: String, pressed: bool = true) -> void:
	var ev := InputEventKey.new()
	ev.pressed = pressed
	ev.keycode = ch.unicode_at(0) - 32 if ch >= "a" and ch <= "z" else ch.unicode_at(0)
	ev.unicode = ch.unicode_at(0)
	game.input.handle(ev)


func _input(game: DmGame) -> void:
	game.respawn()
	game.player.teleport(0.0, 20.0)
	game.p["castUntil"] = 0.0
	var events: Array = []
	game.game_event.connect(func(id: String, ctx: Dictionary): events.append(id))
	# click-to-move on open ground
	game.input.set_ground(0.0, 14.0)
	game.input.hover = null
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	game.input.handle(click)
	_check(game.player.has_path(), "left click on the ground starts a path")
	_tick(game, 1.0)
	_check(game.player.z < 19.0, "hero followed the click: z=%f" % game.player.z)
	# WASD
	var z0: float = game.player.z
	_key(game, "w")
	_tick(game, 0.5)
	_key(game, "w", false)
	_check(game.player.z < z0, "W walks north")
	# rite on key 2 against a dummy foe
	var foe: DmSimEnemy = game.sim.spawn_enemy("robber", "chapterhouse", game.player.x, game.player.z - 4.0, false, false)
	game.input.set_ground(foe.x, foe.z)
	game.p["resource"]["value"] = 100.0
	var slot_ability: String = String(game.hotbar[0])
	_key(game, "1")
	_key(game, "1", false)
	_check(DmPlayerRules.on_cooldown(game.p, slot_ability, game.now_ms) or game.p["castUntil"] > game.now_ms, "key 1 cast %s" % slot_ability)
	# panel hotkey emits the event for the UI
	_key(game, "i")
	_check(events.has("panel_toggle"), "I asks the UI for the Reliquary")
	# recall (T) from the graves
	game.player.teleport(0.0, -10.0)
	game._enter_area("graves")
	_key(game, "t")
	_check(game.recall_at > 0.0, "T starts Recall")
	_tick(game, 2.0)
	_check(game.area_id == "chapterhouse", "Recall returned home: %s" % game.area_id)
	# right click casts slot 5, R casts the signature
	var rc := InputEventMouseButton.new()
	rc.button_index = MOUSE_BUTTON_RIGHT
	rc.pressed = true
	game.input.handle(rc)


func _tick(game: DmGame, seconds: float) -> void:
	for i in int(seconds * 60.0):
		game.tick(1.0 / 60.0)


func _combat(game: DmGame) -> void:
	# walk: click-to-move through the Chapterhouse door into the Graves
	game.player.teleport(0.0, 9.0)
	game.player.move_to(0.0, -8.0)
	_tick(game, 4.0)
	_check(game.area_id == "graves", "in the graves: %s" % game.area_id)
	_check(game.player.area == "graves", "player area graves: %s" % game.player.area)
	_check(game.player.z < 3.0, "hero walked north: z=%f" % game.player.z)
	# fight: spawn a robber in front of the hero and cast Bone Needle until it dies
	var e: DmSimEnemy = game.sim.spawn_enemy("robber", "graves", game.player.x, game.player.z - 5.0, false, false)
	var gold0: int = int(game.character["gold"])
	var xp0: int = int(game.character["experience"])
	for i in 600:
		if not game.sim.enemies.has(e.id):
			break
		game.input.set_ground(e.x, e.z)
		game.input.hover = {"kind": "enemy", "id": e.id}
		game.player.face(e.x, e.z)
		game.abilities.cast(game.primary, {"x": e.x, "z": e.z, "enemyId": e.id}, game.now_ms)
		game.player.hp = game.player.max_hp()
		game.tick(1.0 / 60.0)
	_check(not game.sim.enemies.has(e.id), "the robber died")
	_check(int(game.character["experience"]) > xp0 or int(game.character["level"]) > 1, "xp gained")
	_check(game.rewards.chain.count >= 1, "kill chain started")
	_check(game.prog.kills("graves") >= 1, "graves kill recorded")
	_check(game.sim.corpses.size() >= 1, "a corpse remained")
	# exhume the corpse into a thrall
	game.p["resource"]["value"] = 100.0
	var c: DmSimCorpse = game.sim.corpses.values()[0]
	game.p["x"] = c.x
	game.p["z"] = c.z + 1.0
	game.p["cooldowns"].erase("exhume")
	game.p["castUntil"] = 0.0
	var res: String = game.abilities.cast("exhume", {"x": c.x, "z": c.z}, game.now_ms)
	_check(res == "ok", "exhume ok: %s" % res)
	_tick(game, 1.0)
	_check(game.sim.thralls.size() == 1, "a thrall stands")
	# level up
	var lvl0: int = int(game.character["level"])
	game.rewards.gain_xp(5000.0, game.player.x, game.player.z)
	_check(int(game.character["level"]) > lvl0, "levelled up")
	# death and respawn
	game.combat.on_hurt(game.player.max_hp() * 5.0, "melee", game.player.x + 1.0, game.player.z)
	_check(not game.player.alive, "hero died")
	_tick(game, 4.5)
	_check(game.player.alive and game.area_id == "chapterhouse", "respawned in the chapterhouse: %s" % game.area_id)
	# save: server-side progress mirrors the character
	await game.psync.flush()
	var r := await game.api.get_character()
	_check(int(r.data["level"]) == int(game.character["level"]), "level saved on the server")
	# boss: summon the Prelate with shards, it wakes
	game.prog.local["shards"] = 10
	game.p["x"] = 0.0
	game.p["z"] = -108.0
	game.p["area"] = "sanctum"
	game.actions.summon_boss_normal("prelate")
	_tick(game, 3.0)
	_check(game.sim.boss.state.active, "prelate awake")
	_check(game.hud_state().has("boss") and game.hud_state()["boss"] != null, "boss in hud_state")
	var vm := game.hud_state()
	_check(vm["max_hp"] > 0 and vm["slots"].size() >= 5, "hud_state populated")

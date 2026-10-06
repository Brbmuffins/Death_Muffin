extends SceneTree
## Brews + elite-affix chips suite (godot/next/rewards, godot/next/hud). godot --headless --path godot --script res://tests/next_brews_affix/run.gd
## A wisdom / fortune from the active brew (DmRewardsMember.sync_brews, per member), expiry, per-member isolation.
## B lifesteal heal on the hero's damage dealt (numbers = DmBrews.lifesteal_heal, the current game's rule), host only.
## C target-frame affix chips on the host and on an in-process ENet client, cached per target (no per-frame allocation), DmFrameCost.

const DT := 1.0 / 60.0
var passed := 0
var failed := 0


func ok(c: bool, msg: String) -> void:
	if c:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("nb%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": false, "persist": false})
	await _a_rewards(g)
	await _b_lifesteal(g)
	await _c_chips(g)
	await g.leave()
	g.queue_free()
	await process_frame
	await _d_client()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _foe(g: DmNextGame, pos := Vector3(40, 0, 40)) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.rng_seed = 3
	e.rising = false
	e.hp_mult = 1e5
	e.position = pos
	e.set_meta(&"dm_area", "graves")
	g.add_child(e)
	return e


func _a_rewards(g: DmNextGame) -> void:
	var b := g.local_body()
	var m: DmRewardsMember = g.rewards.members[int(g.character.get("id", 0))]
	m.sync_brews()
	ok(m.wisdom == 0.0 and m.fortune == 0.0, "A: no brew, no bonus")
	var now := b.clock_ms()
	b.apply_brew("tonic_insight")
	m.sync_brews()
	ok(is_equal_approx(m.wisdom, DmBrews.brew_value(b.p["brews"], "wisdom", now)) and is_equal_approx(m.wisdom, 0.15) and m.fortune == 0.0, "A: tonic of insight -> wisdom 0.15 (%s)" % m.wisdom)
	b.apply_brew("tonic_graveluck")   # same slot: replaces
	m.sync_brews()
	ok(is_equal_approx(m.fortune, 0.15) and m.wisdom == 0.0, "A: grave-luck replaces insight (tonic slot): fortune 0.15, wisdom 0")
	# the kill path syncs by itself: the reward reads the member's multipliers
	m.fortune = 0.0
	m.wisdom = 0.0
	b.apply_brew("tonic_insight")
	var pos := b.global_position
	g.rewards.on_kill({"def": "robber", "x": pos.x, "z": pos.z, "area": "graves", "level": 1.0, "elite": false, "killer": b})
	ok(is_equal_approx(m.wisdom, 0.15), "A: a kill syncs wisdom before the reward (%s)" % m.wisdom)
	b.p["brews"]["tonic"]["until"] = 0.0   # expired
	m.sync_brews()
	ok(m.wisdom == 0.0 and m.fortune == 0.0, "A: expired brew clears the bonus")
	# per member: a second member's body keeps its own brews
	var other := DmRewardsMember.new()
	var stub := Node3D.new()
	g.add_child(stub)
	other.body = stub
	other.wisdom = 0.3
	other.sync_brews()
	ok(other.wisdom == 0.3, "A: a body without a rules state keeps hand-set values (stubs)")
	stub.queue_free()
	b.p["brews"]["tonic"] = null


func _b_lifesteal(g: DmNextGame) -> void:
	var b := g.local_body()
	var e := _foe(g)
	g.rewards.watch_enemy(e)
	var cap: float = float(DmCombatData.load_json("brews")["lifesteal_hit_cap"])
	b.p["hp"] = b.max_hp * 0.3
	b.heal(0.0)
	var hp0 := b.hp
	e.take_damage(100.0, b)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen
	ok(is_equal_approx(b.hp, hp0), "B: no brew, no heal")
	b.apply_brew("elixir_leechblood")   # 4%
	hp0 = b.hp
	e.take_damage(100.0, b)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen
	var want := DmBrews.lifesteal_heal(100.0, 1.0, 0.04, b.max_hp)
	ok(want >= 1.0 and is_equal_approx(b.hp - hp0, want), "B: leechblood 4%% of 100 (cap %.1f at max hp %.0f) = %.2f (got %.2f)" % [b.max_hp * cap, b.max_hp, want, b.hp - hp0])
	b.apply_brew("elixir_bloodmoon")   # same slot, 6% (replaces)
	hp0 = b.hp
	e.take_damage(100.0, b)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen
	ok(is_equal_approx(b.hp - hp0, DmBrews.lifesteal_heal(100.0, 1.0, 0.06, b.max_hp)), "B: bloodmoon 6%% (got %.2f)" % (b.hp - hp0))
	hp0 = b.hp
	e.take_damage(1e6, b)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen   # capped per hit
	ok(is_equal_approx(b.hp - hp0, minf(b.max_hp * cap, b.max_hp - hp0)), "B: huge hit heals at most %.0f%% max hp (got %.1f)" % [cap * 100.0, b.hp - hp0])
	b.p["hp"] = b.max_hp * 0.3
	b.heal(0.0)
	var e2 := _foe(g, Vector3(44, 0, 40))
	g.rewards.watch_enemy(e2)
	hp0 = b.hp
	e2.take_damage(100.0, null)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen   # not the hero's blow
	e2.take_damage(100.0, e)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen
	ok(is_equal_approx(b.hp, hp0), "B: damage from another source does not heal the hero")
	hp0 = b.hp
	e2.take_damage(10.0, b)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen   # 0.6 hp: under 1, dropped like the current game
	ok(is_equal_approx(b.hp, hp0), "B: a heal under 1 hp is dropped (current game)")
	b.p["brews"]["elixir"]["until"] = 0.0   # expired
	hp0 = b.hp
	e2.take_damage(100.0, b)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen
	ok(is_equal_approx(b.hp, hp0), "B: expired elixir heals nothing")
	b.p["brews"]["elixir"] = null
	e.queue_free()
	e2.queue_free()
	# one cast over two targets heals once (average hit x targets, one cap), and a DoT tick heals nothing (current game: direct hits only)
	b.apply_brew("elixir_leechblood")
	b.p["hp"] = b.max_hp * 0.3
	b.heal(0.0)
	var e3 := _foe(g, Vector3(46, 0, 40))
	var e4 := _foe(g, Vector3(47, 0, 40))
	g.rewards.watch_enemy(e3)
	g.rewards.watch_enemy(e4)
	hp0 = b.hp
	e3.take_damage(100.0, b)
	e4.take_damage(60.0, b)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen
	ok(is_equal_approx(b.hp - hp0, DmBrews.lifesteal_heal(80.0, 2.0, 0.04, b.max_hp)), "B: a two-target cast heals once by the current rule (got %.2f)" % (b.hp - hp0))
	hp0 = b.hp
	DmStatusSet._deal(e3, 100.0, b, false, "dot")
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen
	ok(is_equal_approx(b.hp, hp0), "B: a DoT tick does not heal")
	b.p["brews"]["elixir"] = null
	e3.queue_free()
	e4.queue_free()


func _c_chips(g: DmNextGame) -> void:
	var h := g.ui_host
	var e := _foe(g, g.local_body().position + Vector3(3, 0, 0))
	e.elite = true
	e.set_meta(&"dm_elite", true)
	var id := 90001
	e.set_meta(&"dm_id", id)
	g.director.enemies[id] = e
	h._target_id = id
	h._target_until = Time.get_ticks_msec() + 60000.0
	var hv := DmNextHudVm.new(h)
	var t0: Variant = hv._target(g)
	ok(t0 != null and (t0["affixes"] as Array).is_empty(), "C: a plain enemy has no chips (id %d: %s)" % [id, str(t0 != null)])
	DmAffixSet.attach(e, PackedStringArray(["hungering", "shrouded"]))
	var t1: Dictionary = hv._target(g)
	var ed: Dictionary = DmContent.get_export("enemies", "ELITE_AFFIXES")
	ok(t1["affixes"] == [{"id": "hungering", "name": ed["hungering"]["name"]}, {"id": "shrouded", "name": ed["shrouded"]["name"]}], "C: chips = DmGameHud's [{id, name}] (%s)" % str(t1["affixes"]))
	ok(String(t1["blurb"]) == ed["hungering"]["blurb"] + " " + ed["shrouded"]["blurb"], "C: blurb lists every affix, as the current game")
	var t2: Dictionary = hv._target(g)
	ok(is_same(t1["affixes"], t2["affixes"]), "C: the chip array is cached while the target is held (no per-frame rebuild)")
	var set_ := DmAffixSet.of(e)
	set_._host = true
	set_.e = e
	set_.strip_shroud()
	var t3: Dictionary = hv._target(g)
	ok((t3["affixes"] as Array).size() == 1 and t3["affixes"][0]["id"] == "hungering", "C: a stripped shroud drops its chip")
	# cost of the held-target read: no allocation of the chip array, just the dictionary the HUD wants
	var n := 20000
	var t := Time.get_ticks_usec()
	for i in n:
		hv._affix_chips(e, "")
	var per := float(Time.get_ticks_usec() - t) / float(n)
	print("PERF chips cached read %.3f us/call" % per)
	ok(per < 2.0, "C: cached chip read under 2 us (%.3f)" % per)
	# a real held-target frame: the HUD (20 Hz) reads the target every apply
	var fc := DmFrameCost.attach(root)
	var end := Engine.get_physics_frames() + 180
	while Engine.get_physics_frames() < end:
		await physics_frame
	print("PERF held elite target (2 chips) frame median %.2f ms p95 %.2f ms over %d frames" % [fc.pct(0.5), fc.pct(0.95), fc.samples()])
	fc.queue_free()
	h._target_until = 0.0
	g.director.enemies.erase(id)
	e.queue_free()


func _d_client() -> void:
	var port := DmTestPorts.free_port()
	var H := Node3D.new()
	H.name = "H"
	var C := Node3D.new()
	C.name = "C"
	root.add_child(H)
	root.add_child(C)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/H"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/C"))
	var sp := ENetMultiplayerPeer.new()
	ok(sp.create_server(port, 2) == OK, "D: server on %d" % port)
	H.multiplayer.multiplayer_peer = sp
	var cp := ENetMultiplayerPeer.new()
	ok(cp.create_client("127.0.0.1", port) == OK, "D: client")
	C.multiplayer.multiplayer_peer = cp
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000 and H.multiplayer.get_peers().is_empty():
		await process_frame
	ok(not H.multiplayer.get_peers().is_empty(), "D: peers connected")
	var list := PackedStringArray(["bellTolled", "vengeful"])
	var he: DmEnemy = _bare(H, list)
	var ce: DmEnemy = _bare(C, list)   # the replicated spawn data carries affix_list; each peer's spawn function attaches it
	ce.set_multiplayer_authority(2)
	ok(he.is_multiplayer_authority() and not ce.is_multiplayer_authority(), "D: the client's copy is a puppet")
	var hv := DmNextHudVm.new(null)
	var ch_host := hv._affix_chips(he, "")
	var ch_cli := DmNextHudVm.new(null)._affix_chips(ce, "")
	ok(ch_host.size() == 2 and ch_host == ch_cli, "D: the joined client's chips equal the host's (%s)" % str(ch_cli))
	H.queue_free()
	C.queue_free()
	await process_frame


func _bare(parent: Node, list: PackedStringArray) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.elite = true
	e.set_meta(&"dm_area", "graves")
	DmAffixSet.attach(e, list)
	parent.add_child(e)
	return e

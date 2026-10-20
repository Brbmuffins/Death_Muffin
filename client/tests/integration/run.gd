extends SceneTree
## Integration glue on the rebuilt client: the gaps the rebuild's tracks found between their systems, as far as they are left with the creatures in the combat core.
## godot --headless --path client --script res://tests/integration/run.gd
##   1 damage-taken multipliers applied once (the core's blows and its damage over time, a rite's, the hero's own, a zone's pulse on the hero)
##   2 the damage kind reaches kind-based rules (the game scene's hand-over of a core hit, the Veilwalker's Veil form, the zones' kinds, a real Mire Leech's rot bite)
##   3 the hero receives enemy effects (chill / root / pull): statuses, move multiplier, floats, the glide
##   5 Soul Harvest for a joiner: the host banks the joiner's own kills on its hero, the joiner's HUD meter follows (a host and a client game over ENet loopback)
##   6 one essence pool (what the HUD shows is what rites spend)    7 a damage over time on the hero
## Not here: a Risen asked of the wave director by the acolyte or the deacon, one enemy's cue drawn once on every peer, the cost of a creature's take_damage, and a thrall's
## blow-taken multiplier: those creatures are bodies of the core now (tests/core_kinds.gd, core_status.gd, core_thralls.gd, core_coop.gd, coop.gd).

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var character: Dictionary
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var caster: DmRiteCaster
var events: Array = []
var _foes: Array[int] = []


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func secs(s: float) -> void:
	await ticks(int(s / DT))


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func near(a: float, b: float, tol := 0.01) -> bool:
	return absf(a - b) <= tol


## A static enemy of the core: stunned for an hour (it stands where it is), harmless, with health to soak the cases. Returns its id.
func foe(def_id: String, at: Vector3) -> int:
	var id := host.spawn_enemy(def_id, at, 1, 100.0, 0.0, false, "graves", false)   # soak the test hits
	core.stun(id, 3600.0)
	_foes.append(id)
	return id


## What the core took from an enemy: its maximum health less its health (-1 when it is gone).
func loss(e: int) -> float:
	var i: Dictionary = core.enemy_info(e)
	return float(i["max_hp"]) - float(i["hp"]) if not i.is_empty() else -1.0


func clear_foes() -> void:
	for id in _foes:
		if not core.enemy_info(id).is_empty():
			host.remove_enemy(id)
	_foes.clear()


func _run() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("glue%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"areas": ["graves"], "dressing": false, "persist": false, "waves": false, "hud": true, "audio": false})
	host = g.core_host
	core = host.core
	hero = g.local_body()
	caster = hero.get_node("Rites") as DmRiteCaster
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))
	await ticks(3)
	await _gap1()
	await _gap2()
	await _gap3()
	await _gap6()
	await _gap7()
	g.queue_free()
	await ticks(3)
	await _gap5()
	print("%d passed, %d failed" % [passed, failed])
	print("%s integration %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


# ============================================================================================ 1: damage-taken multiplier, once, everywhere

func _gap1() -> void:
	var S: Dictionary = DmSimData.SANCTIFIED
	var k := float(S["damageTakenMult"])
	hero.teleport(Vector3(0, 0, -18))
	# a plain enemy: the core's damage applies the multiplier
	var e := foe("robber", Vector3(0, 0, -44))
	caster.apply_status(e, &"sanctified")
	core.damage(e, 100.0, hero.core_id)
	check(near(loss(e), 100.0 * k), "G1: the core's blow on a sanctified enemy applies it once (%.1f of 100 x %.2f)" % [loss(e), k])
	# fracture stacks (each once)
	var f := foe("robber", Vector3(4, 0, -44))
	caster.apply_status(f, &"fracture", 2)
	var fm := 1.0 + float(DmSimData.FRACTURE["perStack"]) * 2.0
	core.damage(f, 50.0, hero.core_id)
	check(near(loss(f), 50.0 * fm), "G1: fracture x%.2f once (%.1f)" % [fm, loss(f)])
	# DoT path: a bleed on a sanctified body ticks x multiplier once (not x multiplier^2)
	var d := foe("robber", Vector3(8, 0, -44))
	caster.apply_status(d, &"sanctified")
	caster.apply_status(d, &"bleed", 1, 1.0, {"dps": 10.0})
	await secs(1.5)
	check(near(loss(d), 10.0 * k, 1.5), "G1: DoT lumps x multiplier once (%.2f of %.2f)" % [loss(d), 10.0 * k])
	# rite path: Bone Prison hits a plain and a sanctified twin with the same roll; the ratio is the multiplier
	var a := foe("robber", Vector3(0, 0, -36))
	var b := foe("robber", Vector3(0.6, 0, -36))
	caster.apply_status(b, &"sanctified")
	hero.teleport(Vector3(0, 0, -30))
	caster.p["stats"]["level"] = 99.0
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	var ha := loss(a)
	var hb := loss(b)
	caster.request_cast("bone_prison", Vector3(0.3, 0, -36), -1)
	await ticks(2)
	var da := loss(a) - ha
	var db := loss(b) - hb
	check(da > 1.0 and near(db / da, k, 0.02), "G1: rite damage on a sanctified body is x%.2f of a plain one (%.1f vs %.1f)" % [k, db, da])
	# hero: sanctified on the hero scales what it takes (once, in take_damage). What a blow and a zone pulse take from this hero with no status on it comes first
	# (the hero's own mitigation, whatever it is), and the sanctified ones are compared with that.
	var blow := hero.max_hp * 0.25      # a blow and a zone that leave the hero standing, sanctified or not
	var zone_dps := hero.max_hp * 0.2
	hero.teleport(Vector3(0, 0, -18))
	hero.heal(1e6)
	var hh := hero.hp
	hero.take_damage(blow, null)
	var plain_hit := hh - hero.hp
	hero.heal(1e6)
	hh = hero.hp
	core.add_zone("dust", Vector2(hero.position.x, hero.position.z), 3.0, 1.5, zone_dps, 0)
	await until(func() -> bool: return hero.hp < hh, 3.0)
	var plain_zone := hh - hero.hp
	await secs(2.0)   # the zone ends
	check(plain_hit > 0.0 and plain_zone > 0.0, "G1: a plain blow (%.1f) and a plain zone pulse (%.1f) hurt the hero" % [plain_hit, plain_zone])
	DmStatusSet.ensure(hero).apply(&"sanctified")
	hero.heal(1e6)
	hh = hero.hp
	hero.take_damage(blow, null)
	check(near(hh - hero.hp, plain_hit * k, 0.5), "G1: hero.take_damage applies it once (%.1f of %.1f x %.2f)" % [hh - hero.hp, plain_hit, k])
	# a hostile zone's pulse on the hero (the core's zone, the game scene's hand-over of its hit) is scaled once
	hero.heal(1e6)
	hh = hero.hp
	core.add_zone("dust", Vector2(hero.position.x, hero.position.z), 3.0, 1.5, zone_dps, 0)
	await until(func() -> bool: return hero.hp < hh, 3.0)
	check(near(hh - hero.hp, plain_zone * k, 0.5), "G1: a hostile-zone tick on the hero is scaled once (%.1f of %.1f x %.2f)" % [hh - hero.hp, plain_zone, k])
	await secs(2.0)   # the zone ends
	DmStatusSet.of(hero).remove(&"sanctified")
	clear_foes()


# ============================================================================================ 2: the damage kind reaches kind-based rules

func _hit_kind(kind: String) -> int:
	return DmCoreEvents.HIT_KINDS.find(kind)


func _gap2() -> void:
	hero.heal(1e6)
	hero.teleport(Vector3(0, 0, -18))
	var kind0: String = hero.p["resource"]["kind"]
	hero.p["resource"]["kind"] = "veil"   # Veilwalker: untouchable in Veil form, except to burn / toxic (DmPlayerRules.take_damage)
	hero.p["veilForm"] = true
	hero.p["betweenUntil"] = hero.clock_ms() + 120000.0   # Veil form drains the pool it borrows here and would end within seconds; the Veil Step's window holds the same rule
	var src := foe("robber", Vector3(0, 0, -44))
	var hp0 := hero.hp
	g._on_target_hit(src, hero.core_id, _hit_kind("melee"), 40.0)   # the core's EV_TARGET_HIT, as the game scene takes it
	check(hero.hp == hp0, "G2: a melee blow does nothing to a Veilwalker in Veil form")
	for kind in ["burn", "toxic"]:
		hero.heal(1e6)
		hp0 = hero.hp
		g._on_target_hit(src, hero.core_id, _hit_kind(kind), 40.0)
		check(hp0 - hero.hp > 1.0, "G2: a %s blow still hurts a Veilwalker in Veil form (%.1f)" % [kind, hp0 - hero.hp])
	# the kinds the zones send (the core's pulses: each zone kind's own hit kind reaches the hero)
	for pair in [["ember", "burn"], ["toxic", "toxic"], ["dust", "dust"]]:   # the ember zone, the toxic pool, the moth's cloud
		g.hits_taken.clear()
		hero.heal(1e6)
		core.add_zone(String(pair[0]), Vector2(hero.position.x, hero.position.z), 3.0, 1.2, 1.0, 0)
		var got := await until(func() -> bool: return int(g.hits_taken.get(pair[1], 0)) >= 1, 3.0)
		check(got, "G2: a %s zone ticks as %s" % [pair[0], pair[1]])
		await secs(1.5)
	# a real Mire Leech beside the hero: its rot bite is toxic and reaches the Veil rule
	hero.heal(1e6)
	g.hits_taken.clear()
	hp0 = hero.hp
	var leech := host.spawn_enemy("mire_leech", hero.position + Vector3(1.5, 0, 0), 1, 1.0, 1.0, false, "graves", false)
	var bit := await until(func() -> bool: return int(g.hits_taken.get("toxic", 0)) >= 1, 8.0)
	check(bit and hp0 - hero.hp > 0.5, "G2: the Mire Leech's rot bite is toxic and reaches the Veil rule (%.1f)" % (hp0 - hero.hp))
	host.remove_enemy(leech)
	# a plain robber's blow stays melee and Veil form shrugs it off
	DmStatusSet.of(hero).clear()   # the leech's rot is over
	g.hits_taken.clear()
	hero.heal(1e6)
	var hurt_by: Array = []
	var on_hurt := func(_amount: float, source: Variant) -> void: hurt_by.append(source)
	hero.hurt.connect(on_hurt)
	var robber := host.spawn_enemy("robber", hero.position + Vector3(1.2, 0, 0), 1, 1.0, 1.0, false, "graves", false)
	var swung := await until(func() -> bool: return int(g.hits_taken.get("melee", 0)) >= 1, 8.0)
	await ticks(3)
	hero.hurt.disconnect(on_hurt)
	check(swung and int(g.hits_taken.get("toxic", 0)) == 0 and not hurt_by.has(robber), "G2: a plain blow stays melee and Veil form shrugs it off (swung %s, hits %s, hurt by %s)" % [swung, str(g.hits_taken), str(hurt_by)])
	host.remove_enemy(robber)
	hero.p["veilForm"] = false
	hero.p["betweenUntil"] = 0.0
	hero.p["resource"]["kind"] = kind0
	clear_foes()


# ============================================================================================ 3: the hero receives chill / root / pull

func floats_text(t: String) -> int:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == "float" and e["ctx"]["text"] == t).size()


func _effect(effect: String, enemy: int, seconds: float, at: Vector3 = Vector3.ZERO) -> void:
	g._on_target_effect(enemy, hero.core_id, DmCoreEvents.EFFECTS.find(StringName(effect)), seconds, at.x, at.z)   # the core's EV_TARGET_EFFECT


func _gap3() -> void:
	hero.teleport(Vector3(0, 0, -18))
	var hs := DmStatusSet.of(hero)
	check(hero.alive, "G3: the hero is alive for the effect tests")
	hero.heal(1e6)
	await ticks(3)
	events.clear()
	check("speed_mult" in hero and hero.speed_mult == 1.0, "G3: the hero has a speed_mult the status set owns")
	# Bog Hag: hex blow + chill
	var hag := foe("bog_hag", Vector3(0, 0, -21))
	_effect("chill", hag, float(DmSimData.CHILL["durationS"]))
	await ticks(2)
	check(hs.has(&"chill") and near(hero.speed_mult, float(DmSimData.CHILL["moveMult"])), "G3: the Bog Hag's hex chills the hero (move x%.2f)" % hero.speed_mult)
	check(floats_text("Chilled") == 1, "G3: the HUD floats Chilled once (%d)" % floats_text("Chilled"))
	hs.clear()
	await ticks(2)
	# Fen Wisp pulse: chill
	var wisp := foe("fen_wisp", Vector3(0, 0, -21))
	_effect("chill", wisp, float(DmSimData.CHILL["durationS"]))
	await ticks(2)
	check(hs.has(&"chill"), "G3: the Fen Wisp's pulse chills the hero")
	hs.clear()
	await ticks(2)
	# the chilled hero really walks slower
	hero.speed_mult = 1.0
	var x0 := hero.position.x
	g.session.request_move_dir(Vector3(1, 0, 0))
	await ticks(30)
	var free_run := hero.position.x - x0
	hs.apply(&"chill")
	x0 = hero.position.x
	await ticks(30)
	var chilled_run := hero.position.x - x0
	g.session.request_move_dir(Vector3.ZERO)
	var chill_mult := float(DmSimData.CHILL["moveMult"])
	check(free_run > 1.0 and chilled_run < free_run * (1.0 + chill_mult) * 0.5, "G3: a chilled hero covers less ground (%.2f vs %.2f m, move x%.2f)" % [chilled_run, free_run, chill_mult])
	hs.clear()
	await ticks(2)
	# Drowned Sexton hook: damage, a glide toward the sexton, then root
	hero.teleport(Vector3(0, 0, -16))   # open Graves ground: the hook is blocked by walls between the two
	await ticks(3)
	events.clear()
	var sexton := foe("drowned_sexton", Vector3(0, 0, -22))
	var sp := host.enemy_position(sexton)
	var hp0 := hero.hp
	var d0 := hero.position.distance_to(sp)
	var pull_to := hero.position + (sp - hero.position).normalized() * (d0 - 1.6)   # the core's chain stops 1.6 m short of the sexton
	g._on_target_hit(sexton, hero.core_id, _hit_kind("melee"), 20.0)
	_effect("pull", sexton, 0.0, pull_to)
	_effect("root", sexton, 1.5)
	check(hero.hp < hp0 and hero.dashing, "G3: the hook hurts the hero and starts a glide, not a teleport")
	check(hero.position.distance_to(sp) > d0 - 0.01, "G3: the drag has not jumped yet (%.2f of %.2f m)" % [hero.position.distance_to(sp), d0])
	await ticks(30)
	var d1 := hero.position.distance_to(sp)
	check(not hero.dashing and d1 < d0 - 2.0 and d1 >= 1.5, "G3: dragged toward the sexton, never closer than 1.6 m (%.2f -> %.2f)" % [d0, d1])
	check(hs.has(&"root") and hero.speed_mult == 0.0, "G3: the hook roots the hero (move x0)")
	check(floats_text("Dragged!") == 1 and floats_text("Rooted") == 1, "G3: HUD floats Dragged! and Rooted")
	_effect("root", sexton, 1.5)   # a fresh, longer root to watch the hero stand still in
	await ticks(2)
	var px := hero.position
	g.session.request_move_dir(Vector3(1, 0, 0))
	await ticks(12)
	check(hero.position.distance_to(px) < 0.05, "G3: a rooted hero does not walk")
	g.session.request_move_dir(Vector3.ZERO)
	await until(func() -> bool: return not hs.has(&"root"), 3.0)
	check(not hs.has(&"root") and hero.speed_mult == 1.0, "G3: the root ends and movement returns")
	hero.stop()
	clear_foes()


# ============================================================================================ 5: Soul Harvest for a joiner

## One host and one client DmNextGame over ENet loopback (each in its own SceneMultiplayer branch, like tests/coop.gd).
func _gap5() -> void:
	var hr := Node.new()
	hr.name = "HostRoot"
	root.add_child(hr)
	var cr := Node.new()
	cr.name = "ClientRoot"
	root.add_child(cr)
	var hg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	hr.add_child(hg)
	var cg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	cr.add_child(cg)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/HostRoot"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/ClientRoot"))
	var port := DmTestPorts.free_port()
	var sp := ENetMultiplayerPeer.new()
	check(sp.create_server(port, 4) == OK, "G5: ENet server on a free port (%d)" % port)
	await hg.start(character, api, {"peer": sp, "areas": ["graves"], "dressing": false, "waves": false, "hud": false, "persist": false, "audio": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", port)
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "waves": false, "hud": false, "persist": false, "audio": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "G5: client joined")
	var hh := hg.local_body()
	var cb := hg.body_of(cg.session.get_my_id())   # the client's body, simulated on the host
	# Soul Harvest for a joiner (bug report #9013): the host banks the joiner's own kills on its hero, and the joiner's HUD meter follows
	var jkey := -cg.session.get_my_id()   # the key of a joiner whose character id clashes with the host's (two test backends)
	check(await until(func() -> bool: return hg.rewards.members.has(jkey), 5.0), "G5: the joiner's profile made it a rewards member on the host")
	var jm: DmRewardsMember = hg.rewards.members[jkey]
	jm.blocked = ""   # the party flow keeps a clashing id uncredited (`no_character`); here it is paid
	check(await until(func() -> bool: return cb.get_node_or_null("Rites") != null and cb.alive, 3.0), "G5: the joiner's hero has its caster on the host")
	var cself := cg.local_body()
	var host_souls := float(hh.p["souls"])
	cb.p["souls"] = 0.0
	hg.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": cb.position.x, "z": cb.position.z, "killer": cb})
	check(float(cb.p["souls"]) == 1.0 and float(hh.p["souls"]) == host_souls, "G5: a joiner's own kill banks a soul on its hero (not the host's) (%s)" % str(cb.p["souls"]))
	check(await until(func() -> bool: return float(DmNextHudVm.soul_state(cself).get("souls", 0.0)) == 1.0, 3.0), "G5: the joiner's HUD meter reads 1 soul")
	cb.p["souls"] = float(cb.p["soulsMax"]) - 1.0
	hg.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": cb.position.x, "z": cb.position.z, "killer": cb})
	check(await until(func() -> bool:
		var s := DmNextHudVm.soul_state(cself)
		return s.has("soulsMax") and DmAbilities.empowered(s, "marrow_spear"), 3.0), "G5: the joiner's meter fills and its Marrow Spear shows as charged")
	hg.rewards.members.erase(jkey)
	hg.queue_free()
	cg.queue_free()
	await ticks(5)


# ============================================================================================ 6: one essence pool (what the HUD shows is what rites spend)

func _gap6() -> void:
	if not hero.alive:
		await until(func() -> bool: return hero.alive, 6.0)
	hero.teleport(Vector3(0, 0, -18))
	hero.heal(1e6)
	await ticks(3)
	check(caster.shares_vitals() and is_same(caster.p, hero.p), "G6: the caster works on the body's own state (one pool)")
	caster.p["stats"]["level"] = 99.0
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	await ticks(2)
	var full := hero.resource
	check(near(full, caster.essence(), 0.5) and near(g.ui_host.hud_state()["essence"], caster.essence(), 0.5), "G6: HUD essence = body = caster at full (%.1f / %.1f)" % [hero.resource, caster.essence()])
	var cost := float(DmAbilities.def("bone_prison")["essenceCost"])
	caster.request_cast("bone_prison", Vector3(0, 0, -28), -1)
	await ticks(2)
	check(near(hero.resource, full - cost, 3.0) and near(g.ui_host.hud_state()["essence"], caster.essence(), 0.5), "G6: a cast's cost shows on the HUD orb (%.1f -> %.1f, cost %.0f)" % [full, hero.resource, cost])
	# regeneration happens once (the body's tick_vitals): over two seconds the pool gains about essenceRegen x 2, not double
	caster.p["resource"]["value"] = 0.0
	var f0 := Engine.get_physics_frames()
	await ticks(120)
	var span := float(Engine.get_physics_frames() - f0) / 60.0
	var gained := float(caster.p["resource"]["value"])
	var want := float(caster.p["stats"]["essenceRegen"]) * span
	check(gained > want * 0.7 and gained < want * 1.3, "G6: essence regenerates once (%.1f in %.1f s, expected ~%.1f)" % [gained, span, want])
	# a brew drunk on the body acts on what the rites read; a death on the body is the caster's death
	hero.apply_brew("flask_damage")
	var brew_damage := 0.0   # what the flask adds to damage, from its data
	for e: Dictionary in DmContent.brews()["flask_damage"]["effects"]:
		if String(e["kind"]) == "damage":
			brew_damage += float(e["value"])
	check(brew_damage > 0.0 and near(DmPlayerRules.brew_value(caster.p, "damage", caster.now_ms), brew_damage, 0.001), "G6: a brew on the body is in force for the rites (one clock)")
	hero.take_damage(1e9, null)
	check(not caster.p["alive"] and not hero.alive, "G6: the body's death is the caster's death")
	Engine.time_scale = 4.0
	await until(func() -> bool: return hero.alive, DmHeroBody.RESPAWN_S + 4.0)
	Engine.time_scale = 1.0
	check(hero.alive and caster.p["alive"], "G6: respawn revives both")


# ============================================================================================ 7: a DoT on the hero

## A DoT on the hero (bleed through its DmStatusSet): the hero's take_damage takes a kind String, not the enemies' allow_stagger
## bool — a DoT on a player used to be a runtime error (DmStatusSet._deal).
func _gap7() -> void:
	var hb: DmHeroBody = hero
	var ss := hb.get_node_or_null("Statuses") as DmStatusSet
	check(ss != null, "7: the hero carries a DmStatusSet")
	if ss == null:
		return
	hb.heal(1e6)
	var hp0: float = hb.hp
	ss.apply(&"bleed", null, 1, 2.0, {"dps": 10.0})
	for i in 12:
		ss.advance(0.1)
	check(hb.hp < hp0 - 1.0 and hb.alive, "7: a bleed DoT damages the hero without an error (%.1f -> %.1f)" % [hp0, hb.hp])
	ss.remove(&"bleed")

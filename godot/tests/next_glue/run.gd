extends SceneTree
## Integration-glue suite (godot/next): the gaps the rebuild's tracks found between their systems.
## godot --headless --path godot --script res://tests/next_glue/run.gd
##   1 damage-taken multipliers applied once by take_damage   2 damage kinds in the hit contract   3 the hero receives enemy effects (chill/root/pull)
##   4 Risen requests (acolyte unbind, deacon raise)          5 host-only cues reach clients           6 one essence pool

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var character: Dictionary
var events: Array = []
var _ids := 0


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


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func near(a: float, b: float, tol := 0.01) -> bool:
	return absf(a - b) <= tol


## A brain-off enemy (no model, no nav) under the game node, with its replicated-style status set.
func foe(def_id: String, at: Vector3) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/%s.tscn" % def_id).instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.def_id = def_id
	e.hp_mult = 100.0   # soak the test hits
	e.position = at
	g.add_child(e)
	e.set_physics_process(false)
	DmStatusSet.attach(e)
	_ids += 1
	e.set_meta(&"dm_id", 9000 + _ids)   # the rites find enemies through the director's table
	g.director.enemies[9000 + _ids] = e
	var key := 9000 + _ids
	e.tree_exiting.connect(func() -> void: g.director.enemies.erase(key))
	return e


func _run() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("glue%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"dressing": false, "persist": false, "waves": false})
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))
	await ticks(3)
	await _gap1()
	await _gap2()
	await _gap3()
	await _gap4()
	await _gap6()
	await _gap7()
	await _perf()
	g.queue_free()
	await ticks(3)
	await _gap5()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ============================================================================================ 1: damage-taken multiplier, once, everywhere

func _gap1() -> void:
	var S: Dictionary = DmSimData.SANCTIFIED
	var k := float(S["damageTakenMult"])
	var hero := g.local_body()
	var caster := hero.get_node("Rites") as DmRiteCaster
	# a plain enemy: take_damage itself applies the multiplier (it used to be only DmStatusSet.hit)
	var e := foe("robber", Vector3(0, 0, 40))
	DmStatusSet.of(e).apply(&"sanctified", null)
	var h0 := e.hp
	e.take_damage(100.0, hero)
	check(near(h0 - e.hp, 100.0 * k), "G1: enemy.take_damage applies sanctified once (%.1f of 100 x %.2f)" % [h0 - e.hp, k])
	h0 = e.hp
	DmStatusSet.hit(e, 100.0, hero)
	check(near(h0 - e.hp, 100.0 * k), "G1: DmStatusSet.hit does not apply it a second time (%.1f)" % [h0 - e.hp])
	# fracture stacks and a hit through the Templar override (shield + multiplier, each once)
	var f := foe("robber", Vector3(4, 0, 40))
	DmStatusSet.of(f).apply(&"fracture", null, 2)
	var fm := 1.0 + float(DmSimData.FRACTURE["perStack"]) * 2.0
	h0 = f.hp
	f.take_damage(50.0, hero)
	check(near(h0 - f.hp, 50.0 * fm), "G1: fracture x%.2f once (%.1f)" % [fm, h0 - f.hp])
	# DoT path: a bleed on a sanctified body ticks x multiplier once (not x multiplier^2)
	var d := foe("robber", Vector3(8, 0, 40))
	var ds := DmStatusSet.of(d)
	ds.apply(&"sanctified", null)
	ds.apply(&"bleed", hero, 1, 1.0, {"dps": 10.0})
	h0 = d.hp
	for i in 50:
		ds.advance(0.02)
	check(near(h0 - d.hp, 10.0 * k, 1.5), "G1: DoT lumps x multiplier once (%.2f of %.2f)" % [h0 - d.hp, 10.0 * k])
	# rite path: Bone Prison hits a plain and a sanctified twin with the same roll; the ratio is the multiplier
	var a := foe("robber", Vector3(0, 0, 36))
	var b := foe("robber", Vector3(0.6, 0, 36))
	DmStatusSet.of(b).apply(&"sanctified", null)
	hero.teleport(Vector3(0, 0, 30))
	caster.p["stats"]["level"] = 99.0
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	var ha := a.hp
	var hb := b.hp
	caster.request_cast("bone_prison", Vector3(0.3, 0, 36), -1)
	await ticks(2)
	var da := ha - a.hp
	var db := hb - b.hp
	check(da > 1.0 and near(db / da, k, 0.02), "G1: rite damage on a sanctified body is x%.2f of a plain one (%.1f vs %.1f)" % [k, db, da])
	# thralls: an enemy blow on a sanctified thrall
	var th := hero.get_node("Thralls") as DmThrallHost
	var got := th.raise_bonded({"kind": "warrior", "cap": 4.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0})
	var t: DmThrall = got["thralls"][0] if got["ok"] else null
	check(t != null, "G1: a thrall to hit")
	if t != null:
		t.set_physics_process(false)
		t.state = DmThrall.S.IDLE
		DmStatusSet.of(t).apply(&"sanctified", null)
		var ht := t.hp
		t.dm_take_enemy_hit(100.0, e)
		check(near(ht - t.hp, 100.0 * k), "G1: thrall takes an enemy blow x multiplier once (%.1f)" % [ht - t.hp])
		t.kill("crumbled")
	# hero: sanctified on the hero scales what it takes; a zone tick (the zone calls dm_take_enemy_hit) is scaled once
	DmStatusSet.of(hero).apply(&"sanctified", null)
	hero.heal(1e6)
	var hh := hero.hp
	hero.take_damage(100.0, null)
	check(near(hh - hero.hp, 100.0 * k, 0.5), "G1: hero.take_damage applies it once (%.1f)" % [hh - hero.hp])
	hero.heal(1e6)
	hh = hero.hp
	var zone := DmHostileZone.spawn(g, hero.position, &"dust", 3.0, 3.0, 50.0, null)
	await until(func() -> bool: return hero.hp < hh, 2.0)
	check(near(hh - hero.hp, 50.0 * k, 0.5), "G1: a hostile-zone tick on the hero is scaled once (%.1f)" % [hh - hero.hp])
	zone.queue_free()
	DmStatusSet.of(hero).remove(&"sanctified")
	for n in [e, f, d, a, b]:
		n.queue_free()


# ============================================================================================ 2: the damage kind reaches kind-based rules

class OldTarget:   ## a target that predates `kind`: two-parameter dm_take_enemy_hit
	extends Node3D
	var got: Array = []
	func dm_take_enemy_hit(d: float, from: Node) -> void:
		got.append([d, from])


func _gap2() -> void:
	var hero := g.local_body()
	hero.heal(1e6)
	var kind0: String = hero.p["resource"]["kind"]
	hero.p["resource"]["kind"] = "veil"   # Veilwalker: untouchable in Veil form, except to burn / toxic (DmPlayerRules.take_damage)
	hero.p["veilForm"] = true
	var src := foe("robber", Vector3(0, 0, 44))
	var hp0 := hero.hp
	DmEnemy.deliver(hero, 40.0, src, "melee")
	check(hero.hp == hp0, "G2: a melee blow does nothing to a Veilwalker in Veil form")
	for kind in ["burn", "toxic"]:
		hero.heal(1e6)
		hp0 = hero.hp
		DmEnemy.deliver(hero, 40.0, src, kind)
		check(hp0 - hero.hp > 1.0, "G2: a %s blow still hurts a Veilwalker in Veil form (%.1f)" % [kind, hp0 - hero.hp])
	# the kinds the real enemies and zones send
	check(DmHostileZone.spawn(g, Vector3(0, 0, 60), &"ember", 1.0, 0.1, 1.0, null).damage_kind() == "burn", "G2: an ember zone ticks as burn")
	check(DmHostileZone.spawn(g, Vector3(0, 0, 60), &"toxic", 1.0, 0.1, 1.0, null).damage_kind() == "toxic", "G2: a toxic pool ticks as toxic")
	check(DmHostileZone.spawn(g, Vector3(0, 0, 60), &"dust", 1.0, 0.1, 1.0, null).damage_kind() == "dust", "G2: the moth's cloud ticks as dust")
	var leech := foe("mire_leech", Vector3(0, 0, 44))
	hero.heal(1e6)
	hp0 = hero.hp
	leech.hit_target(hero, 40.0)
	check(leech.blow_kind == "toxic" and hp0 - hero.hp > 1.0, "G2: the Mire Leech's rot bite is toxic and reaches the Veil rule (%.1f)" % (hp0 - hero.hp))
	var robber := foe("robber", Vector3(2, 0, 44))
	hp0 = hero.hp
	robber.hit_target(hero, 40.0)
	check(robber.blow_kind == "melee" and hero.hp == hp0, "G2: a plain blow stays melee and Veil form shrugs it off")
	# ember bolt (the pyre priest) and a hex blow reach the hero with their own kind (ember: fire-resist brews; curse)
	var tg := DmTargetDummy.new()
	tg.controllable = false
	g.add_child(tg)
	var priest := foe("pyre_priest", Vector3(0, 0, 44))
	priest.hit_target(tg, 1.0, "ember")
	check(tg.last_kind == "ember", "G2: hit_target carries an explicit kind (%s)" % tg.last_kind)
	robber.hit_target(tg, 1.0)
	check(tg.last_kind == "melee", "G2: and defaults to the body's blow kind (%s)" % tg.last_kind)
	var old := OldTarget.new()
	g.add_child(old)
	robber.hit_target(old, 5.0, "burn")
	check(old.got.size() == 1 and near(float(old.got[0][0]), 5.0), "G2: a target that takes no kind still gets the blow")
	hero.p["veilForm"] = false
	hero.p["resource"]["kind"] = kind0
	for n in [src, leech, robber, priest, tg, old]:
		n.queue_free()


# ============================================================================================ 3: the hero receives chill / root / pull

func floats_text(t: String) -> int:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == "float" and e["ctx"]["text"] == t).size()


func _gap3() -> void:
	var hero := g.local_body()
	var hs := DmStatusSet.of(hero)
	hero.teleport(Vector3(0, 0, 24))
	check(hero.alive, "G3: the hero is alive for the effect tests")
	hero.heal(1e6)
	await ticks(3)
	events.clear()
	check("speed_mult" in hero and hero.speed_mult == 1.0, "G3: the hero has a speed_mult the status set owns")
	# Bog Hag: hex blow + chill
	var hag := foe("bog_hag", Vector3(0, 0, 21))
	hag.aim = hero.position
	hag.strike()
	await ticks(2)
	check(hs.has(&"chill") and near(hero.speed_mult, float(DmSimData.CHILL["moveMult"])), "G3: the Bog Hag's hex chills the hero (move x%.2f)" % hero.speed_mult)
	check(floats_text("Chilled") == 1, "G3: the HUD floats Chilled once (%d)" % floats_text("Chilled"))
	hs.clear()
	await ticks(2)
	# Fen Wisp pulse: chill
	var wisp := foe("fen_wisp", Vector3(0, 0, 21))
	wisp.aim = hero.position
	wisp.strike()
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
	check(free_run > 1.0 and chilled_run < free_run * 0.8, "G3: a chilled hero covers less ground (%.2f vs %.2f m)" % [chilled_run, free_run])
	hs.clear()
	await ticks(2)
	# Drowned Sexton hook: damage, a glide toward the sexton, then root
	hero.teleport(Vector3(0, 0, -16))   # open Graves ground: the hook is blocked by walls between the two
	await ticks(3)
	events.clear()
	var sexton := foe("drowned_sexton", Vector3(0, 0, -22))
	sexton.aim = hero.position
	var hp0 := hero.hp
	var d0 := hero.position.distance_to(sexton.position)
	sexton._hook_strike()
	check(hero.hp < hp0 and hero.dashing, "G3: the hook hurts the hero and starts a glide, not a teleport")
	check(hero.position.distance_to(sexton.position) > d0 - 0.01, "G3: the drag has not jumped yet (%.2f of %.2f m)" % [hero.position.distance_to(sexton.position), d0])
	await ticks(30)
	var d1 := hero.position.distance_to(sexton.position)
	check(not hero.dashing and d1 < d0 - 2.0 and d0 - d1 <= float(DmSimData.SEXTON_HOOK["pullM"]) + 0.2 and d1 >= 1.5, "G3: dragged toward the sexton, at most pullM, never closer than 1.6 m (%.2f -> %.2f)" % [d0, d1])
	check(hs.has(&"root") and hero.speed_mult == 0.0, "G3: the hook roots the hero (move x0)")
	check(floats_text("Dragged!") == 1 and floats_text("Rooted") == 1, "G3: HUD floats Dragged! and Rooted")
	hero.dm_enemy_effect(&"root", {"seconds": 1.5, "from": sexton})   # a fresh, longer root to watch the hero stand still in
	await ticks(2)
	var px := hero.position
	g.session.request_move_dir(Vector3(1, 0, 0))
	await ticks(12)
	check(hero.position.distance_to(px) < 0.05, "G3: a rooted hero does not walk")
	g.session.request_move_dir(Vector3.ZERO)
	await until(func() -> bool: return not hs.has(&"root"), 3.0)
	check(not hs.has(&"root") and hero.speed_mult == 1.0, "G3: the root ends and movement returns")
	hero.stop()
	for n in [hag, wisp, sexton]:
		n.queue_free()


# ============================================================================================ 4: Risen requests (acolyte unbind, deacon raise)

func risen_of(level: float) -> Array:
	return g.director.enemies.values().filter(func(e: Variant) -> bool: return is_instance_valid(e) and (e as DmEnemy).def_id == "risen" and float((e as DmEnemy).get_meta(&"dm_level", 0.0)) == level)


func _gap4() -> void:
	var hero := g.local_body()
	hero.teleport(Vector3(0, 0, 24))   # far from the fight: the casters idle
	Engine.time_scale = 4.0
	# Lich Acolyte: a thrall of the player's killed within UNBIND.range is claimed; a Risen climbs out UNBIND.delayS later (as the acolyte's scaling)
	var ac := g.director.spawn("acolyte", Vector3(0, 0, -30), [], false, {"level": 7.0, "hp": 2.5, "dmg": 1.7}) as DmEnemyClstAcolyte
	check(ac != null and ac.hp_mult == 2.5 and ac.damage_mult == 1.7 and float(ac.get_meta(&"dm_level")) == 7.0, "G4: DmWaveDirector.spawn takes a multiplier override and returns the enemy")
	var th := hero.get_node("Thralls") as DmThrallHost
	var got := th.raise_bonded({"kind": "warrior", "cap": 4.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0})
	var t: DmThrall = got["thralls"][0]
	t.set_physics_process(false)
	t.global_position = Vector3(2, 0, -30)
	check(await until(func() -> bool: return ac.sm.id() != DmEnemyState.Id.RISING and t.died.is_connected(ac._on_thrall_died), 10.0), "G4: the acolyte watches the thrall")
	t.kill("killed")
	check(await until(func() -> bool: return not risen_of(7.0).is_empty(), 8.0), "G4: the acolyte's claim raised a Risen through the wave director")
	var r: DmEnemy = risen_of(7.0)[0] if not risen_of(7.0).is_empty() else null
	check(r != null and r.hp_mult == 2.5 and r.damage_mult == 1.7 and r.get_parent() == g.director.get_node("Bodies"), "G4: the Risen carries the acolyte's level / hp / damage multipliers (%.1f / %.1f)" % [r.hp_mult if r != null else -1.0, r.damage_mult if r != null else -1.0])
	check(ac.unbound.size() == 1 and ac.unbound[0] == r and r.get_meta(&"unbound_by") == ac, "G4: the acolyte adopted it (counts toward maxAlive)")
	# Crypt Deacon: a corpse within 8 m is consumed and a Risen rises there, scaled like the deacon (and only once: the deacon no longer spawns it itself)
	var dc := g.director.spawn("deacon", Vector3(30, 0, -30), [], false, {"level": 5.0, "hp": 3.0, "dmg": 1.4}) as DmEnemyDeacon
	g.corpses.add_corpse(33.0, -30.0, "normal", "robber", false, 0.0, 1.0, "graves")
	check(await until(func() -> bool: return not risen_of(5.0).is_empty(), 12.0), "G4: the deacon's raise spawned a Risen through the wave director")
	await ticks(30)
	var rs := risen_of(5.0)
	check(rs.size() == 1 and (rs[0] as DmEnemy).hp_mult == 3.0 and (rs[0] as DmEnemy).damage_mult == 1.4, "G4: exactly one Risen, with the deacon's multipliers (%d)" % rs.size())
	Engine.time_scale = 1.0
	for n in [ac, dc, r]:
		if is_instance_valid(n):
			n.queue_free()


# ============================================================================================ 5: host-only cues reach clients, once

## One host and one client DmNextGame over ENet loopback (each in its own SceneMultiplayer branch, like tests/next part B).
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
	await hg.start(character, api, {"peer": sp, "dressing": false, "waves": false, "hud": false, "persist": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", port)
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "waves": false, "hud": false, "persist": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "G5: client joined")
	hg.enemy_fx.scope = hg   # two games in one process: each peer's fx watches only its own enemies (a real process has one)
	cg.enemy_fx.scope = cg
	var hh := hg.local_body()
	var cb := hg.body_of(cg.session.get_my_id())   # the client's body, simulated on the host
	Engine.time_scale = 2.0
	# the scene: heroes 18 m from the casters (inside the fx range, outside aggro), a frozen templar, an acolyte, a deacon with a wounded ally
	for b in [hh, cb]:
		b.teleport(Vector3(0, 0, -12))
	var tp := hg.director.spawn("templar", Vector3(-30, 0, -30), [], false)
	var ac := hg.director.spawn("acolyte", Vector3(0, 0, -30), [], false, {"level": 9.0, "hp": 1.0, "dmg": 1.0}) as DmEnemyClstAcolyte
	var dc := hg.director.spawn("deacon", Vector3(30, 0, -30), [], false)
	var ally := hg.director.spawn("robber", Vector3(32, 0, -30), [], false)
	for e in [ac, dc]:   # stand still and ignore the heroes: only their support / unbind logic runs
		e.wander_enabled = false
		e.aggro_range = 1.0
	var ids := [DmWaveDirector.id_of(tp), DmWaveDirector.id_of(ac), DmWaveDirector.id_of(dc), DmWaveDirector.id_of(ally)]
	check(await until(func() -> bool: return ids.all(func(i: int) -> bool: return cg.director.enemy_by_id(i) != null), 8.0), "G5: the client has all four enemies")
	var ctp := cg.director.enemy_by_id(ids[0])
	var cac := cg.director.enemy_by_id(ids[1])
	var cdc := cg.director.enemy_by_id(ids[2])
	var seen := {"c": {}, "h": {}}
	for pair in [[ctp, "c"], [cac, "c"], [cdc, "c"], [tp, "h"], [ac, "h"], [dc, "h"]]:
		(pair[0] as DmEnemy).cue.connect(func(k: StringName, _a: Vector3, _r: float) -> void:
			seen[pair[1]][k] = int(seen[pair[1]].get(k, 0)) + 1)
	check(await until(func() -> bool: return tp.sm.id() != DmEnemyState.Id.RISING and ac.sm.id() != DmEnemyState.Id.RISING and dc.sm.id() != DmEnemyState.Id.RISING, 8.0), "G5: the enemies finished rising")
	await until(func() -> bool: return ally.sm.id() != DmEnemyState.Id.RISING, 3.0)
	ally.set_physics_process(false)
	var h0: int = hg.enemy_fx.stats["cue"]
	var c0: int = cg.enemy_fx.stats["cue"]
	# Templar: a directed blow from the front glances off the shield -> one spark + chime on every peer
	tp.set_physics_process(false)
	tp.rotation.y = 0.0
	hh.teleport(Vector3(-30, 0, -26))
	await ticks(2)
	tp.take_damage(10.0, hh)
	check(await until(func() -> bool: return int(seen["c"].get(&"shield_block", 0)) >= 1, 3.0), "G5: the shield glance cue reached the client")
	await ticks(40)
	check(int(seen["h"].get(&"shield_block", 0)) == 1 and int(seen["c"].get(&"shield_block", 0)) == 1, "G5: shield_block seen once on the host (%d) and once on the client (%d)" % [seen["h"].get(&"shield_block", 0), seen["c"].get(&"shield_block", 0)])
	hh.teleport(Vector3(0, 0, -12))
	# Deacon: sanctifies the most wounded ally (no corpse to raise): the thread + halo on both peers
	ally.hp = ally.max_hp * 0.4
	check(await until(func() -> bool: return int(seen["c"].get(&"sanctify", 0)) >= 1, 12.0), "G5: the Sanctify cue reached the client")
	await ticks(40)
	check(int(seen["h"].get(&"sanctify", 0)) == 1 and int(seen["c"].get(&"sanctify", 0)) == 1, "G5: sanctify seen once on the host and once on the client (%d / %d)" % [seen["h"].get(&"sanctify", 0), seen["c"].get(&"sanctify", 0)])
	# Acolyte: the reach ring shows (every peer) while a thrall stands inside it; killing the thrall claims it: Unbind beam + sigil, then a Risen
	var th := hh.get_node("Thralls") as DmThrallHost
	var t: DmThrall = th.raise_bonded({"kind": "warrior", "cap": 4.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0})["thralls"][0]
	t.set_physics_process(false)
	t.global_position = Vector3(3, 0, -30)
	var reach_on := func(g_: DmNextGame, id: int) -> bool:
		var sl: Variant = g_.enemy_fx._slots.get(g_.director.enemy_by_id(id).get_instance_id())
		return sl != null and sl.reach != null
	check(await until(func() -> bool: return reach_on.call(hg, ids[1]) and reach_on.call(cg, ids[1]), 8.0), "G5: the acolyte's reach ring is drawn on host and client while a thrall is inside it")
	check(await until(func() -> bool: return t.died.is_connected(ac._on_thrall_died), 5.0), "G5: the acolyte watches the thrall")
	t.kill("killed")
	check(await until(func() -> bool: return int(seen["c"].get(&"unbind", 0)) >= 1, 4.0), "G5: the Unbind cue reached the client")
	await ticks(60)
	check(int(seen["h"].get(&"unbind", 0)) == 1 and int(seen["c"].get(&"unbind", 0)) == 1, "G5: unbind seen once on the host and once on the client (%d / %d)" % [seen["h"].get(&"unbind", 0), seen["c"].get(&"unbind", 0)])
	check(not ac.unbound.is_empty() and cg.director.enemy_by_id(DmWaveDirector.id_of(ac.unbound[0])) != null, "G5: the Risen from the unbind exists on the client too")
	check(hg.enemy_fx.stats["cue"] - h0 == 3 and cg.enemy_fx.stats["cue"] - c0 == 3, "G5: each peer's DmEnemyFx drew exactly the 3 cues (%d host / %d client)" % [hg.enemy_fx.stats["cue"] - h0, cg.enemy_fx.stats["cue"] - c0])
	Engine.time_scale = 1.0
	hg.queue_free()
	cg.queue_free()
	await ticks(5)


# ============================================================================================ 6: one essence pool (what the HUD shows is what rites spend)

func _gap6() -> void:
	var hero := g.local_body()
	var caster := hero.get_node("Rites") as DmRiteCaster
	if not hero.alive:
		await until(func() -> bool: return hero.alive, 6.0)
	hero.teleport(Vector3(0, 0, 24))
	hero.heal(1e6)
	await ticks(3)
	check(caster.shares_vitals() and is_same(caster.p, hero.p), "G6: the caster works on the body's own state (one pool)")
	caster.p["stats"]["level"] = 99.0
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	await ticks(2)
	var full := hero.resource
	check(near(full, caster.essence(), 0.5) and near(g.ui_host.hud_state()["essence"], caster.essence(), 0.5), "G6: HUD essence = body = caster at full (%.1f / %.1f)" % [hero.resource, caster.essence()])
	var cost := float(DmAbilities.def("bone_prison")["essenceCost"])
	caster.request_cast("bone_prison", Vector3(0, 0, 14), -1)
	await ticks(2)
	check(near(hero.resource, full - cost, 3.0) and near(g.ui_host.hud_state()["essence"], caster.essence(), 0.5), "G6: a cast's cost shows on the HUD orb (%.1f -> %.1f, cost %.0f)" % [full, hero.resource, cost])
	# regeneration happens once (the body's tick_vitals): over two seconds the pool gains about essenceRegen x 2, not double
	caster.p["resource"]["value"] = 0.0
	var f0 := Engine.get_physics_frames()
	await ticks(120)
	var secs := float(Engine.get_physics_frames() - f0) / 60.0
	var gained := float(caster.p["resource"]["value"])
	var want := float(caster.p["stats"]["essenceRegen"]) * secs
	check(gained > want * 0.7 and gained < want * 1.3, "G6: essence regenerates once (%.1f in %.1f s, expected ~%.1f)" % [gained, secs, want])
	# a brew drunk on the body acts on what the rites read; a death on the body is the caster's death
	hero.apply_brew("flask_damage")
	check(near(DmPlayerRules.brew_value(caster.p, "damage", caster.now_ms), 0.15, 0.001), "G6: a brew on the body is in force for the rites (one clock)")
	hero.take_damage(1e9, null)
	check(not caster.p["alive"] and not hero.alive, "G6: the body's death is the caster's death")
	Engine.time_scale = 4.0
	await until(func() -> bool: return hero.alive, 8.0)
	Engine.time_scale = 1.0
	check(hero.alive and caster.p["alive"], "G6: respawn revives both")


# ============================================================================================ perf: what the glue adds per hit / per frame

## A DoT on the hero (bleed through its DmStatusSet): the hero's take_damage takes a kind String, not the enemies' allow_stagger
## bool — a DoT on a player used to be a runtime error (DmStatusSet._deal).
func _gap7() -> void:
	var hb: DmHeroBody = g.local_body()
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


func _perf() -> void:
	var hero := g.local_body()
	hero.teleport(Vector3(0, 0, 24))
	hero.heal(1e6)
	# per hit: take_damage now looks the status set up (scale_taken); measured on a body with a set and some statuses
	var e := foe("robber", Vector3(0, 0, 50))
	e.hp_mult = 1e6
	e.hp = 1e12
	e.max_hp = 1e12
	DmStatusSet.of(e).apply(&"sanctified", null)
	var n := 5000
	var t0 := Time.get_ticks_usec()
	for i in n:
		e.take_damage(1.0, null, false)
	var per_hit := float(Time.get_ticks_usec() - t0) / float(n)
	var t1 := Time.get_ticks_usec()
	for i in n:
		DmStatusSet.scale_taken(e, 1.0)
	var per_scale := float(Time.get_ticks_usec() - t1) / float(n)
	print("perf: take_damage %.2f us/hit, of which scale_taken %.2f us" % [per_hit, per_scale])
	check(per_scale < 20.0 and per_hit < 80.0, "perf: scale_taken %.2f us, take_damage %.2f us per hit (generous caps)" % [per_scale, per_hit])
	# per frame: 40 chasing-free enemies incl. 4 acolytes with a thrall inside the reach, the 5 Hz fx pass and the net cue flush
	g.director.enabled = false
	var heroes := [hero]
	for i in 36:
		g.director.spawn("robber", Vector3(-20.0 + float(i % 12) * 3.0, 0.0, -40.0 - float(i / 12) * 3.0), heroes)
	for i in 4:
		g.director.spawn("acolyte", Vector3(-6.0 + float(i) * 4.0, 0.0, -30.0), heroes)
	var th := hero.get_node("Thralls") as DmThrallHost
	var t: DmThrall = th.raise_bonded({"kind": "warrior", "cap": 4.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0})["thralls"][0]
	t.set_physics_process(false)
	t.global_position = Vector3(-4.0, 0.0, -30.0)
	hero.teleport(Vector3(0, 0, -18))
	await ticks(90)
	var fc := DmFrameCost.attach(root)
	await ticks(5)
	fc.reset()
	for i in 120:
		await physics_frame
		hero.heal(1e6)
	fc.queue_free()
	var t2 := Time.get_ticks_usec()
	for i in 200:
		g.enemy_fx._ambient(0.2)
	var per_pass := float(Time.get_ticks_usec() - t2) / 200.0
	print("perf: 40 enemies (4 acolytes): frame median %.2f ms (p95 %.2f, worst %.2f); fx ambient pass %.1f us (5 Hz)" % [fc.median_ms(), fc.p95_ms(), fc.worst_ms(), per_pass])
	check(fc.median_ms() < 14.0 and fc.worst_busy_ms() < 150.0, "perf: 40 enemies + acolyte rings: frame median %.2f ms under 14, worst %.1f under 150" % [fc.median_ms(), fc.worst_ms()])
	check(per_pass < 2000.0, "perf: the 5 Hz fx pass (reach rings included) costs %.0f us" % per_pass)
	g.director.clear()
	t.kill("crumbled")

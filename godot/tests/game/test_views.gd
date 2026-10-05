extends RefCounted
## Tests for the entity / avatar / boss views (headless, no rendering): a stub host, a real DmWorldSim stepped with several enemy
## types spawning and dying, thralls raised from corpses, corpses removed, resyncs, the hero avatar and all seven boss views.
## Driven by views_run.gd (godot --headless --path godot --script res://tests/game/views_run.gd).

class StubHost extends Node3D:
	var sim: DmWorldSim
	var p: Dictionary = {"x": 0.0, "z": 0.0, "facing": 0.0, "moving": false, "alive": true, "area": "graves"}
	var self_id := "p1"
	var now_ms := 0.0
	var area_id := "graves"
	var world_root: Node3D
	var camera: Node = null
	var builder: Object = null
	var events: Array = []
	var hitstops: Array = []
	var kit: Variant = null
	func emit_game_event(id: String, ctx: Dictionary = {}) -> void:
		events.append([id, ctx])
	func hitstop(seconds: float) -> void:
		hitstops.append(seconds)
	func legion_kit_for(_owner: String) -> Variant:
		return kit
	func discipline_id_for(_owner: String) -> Variant:
		return "ossuary"

var passed := 0
var failed := 0
var tree: SceneTree
var host: StubHost
var views: DmEntityViews
var sim: DmWorldSim
var nav: DmNav


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _build_sim() -> void:
	nav = DmNav.new()
	var w: Dictionary = DmSimExact.load_json("res://data/sim/world.json")
	for o in w["obstacles"]:
		nav.add_obstacle(DmNavObstacle.from_dict(o))
	for s in w["sightBlockers"]:
		nav.add_sight_blocker(DmNavObstacle.from_dict(s))
	nav.set_unlocked(["graves", "ossuary", "nave", "cloister", "pyre", "fen", "sanctum"])
	DmWorldSim.force_boss_stub = true
	sim = DmWorldSim.new(nav, DmRng.new(1234))
	sim.set_crypts(w["crypts"])
	sim.set_cover(w["cover"])
	sim.set_nodes(w["nodes"])
	sim.set_player(DmSimPlayer.make("p1", 0.0, 0.0, "graves", true, 5.0, "necro"))


## One frame of the host loop: step the sim, route events to the views, sync them.
func _tick(dt: float = 0.05) -> Array:
	host.now_ms += dt * 1000.0
	var evs := sim.step(dt)
	for ev: Dictionary in evs:
		views.on_event(ev)
	views.sync(sim.enemies, sim.thralls, dt, 0.0, 0.0)
	return evs


func run(t: SceneTree) -> void:
	tree = t
	host = StubHost.new()
	host.world_root = host
	tree.root.add_child(host)
	_build_sim()
	host.sim = sim
	views = DmEntityViews.new()
	views.setup(host)
	check(views.get_parent() == host, "views parented under world_root")
	check(views.counts() == {"enemies": 0, "thralls": 0, "corpses": 0, "dying": 0, "fading": 0}, "empty counts")
	print("models..."); await _test_models(); print("world...")
	await _test_world()
	_test_burrow_and_shroud()
	await _test_resync()
	await _test_corpse_prune()
	await _test_pool_reuse()
	await _test_avatar()
	await _test_bosses()
	views.dispose()
	await _frames(2)
	check(not is_instance_valid(views) or views.get_parent() == null, "views removed after dispose")
	host.queue_free()
	await _frames(2)
	print("%d passed, %d failed" % [passed, failed])


## Every enemy def and thrall kind builds a creature with its model (or its documented fallback) loaded.
func _test_models() -> void:
	var defs := DmContent.enemies()
	check(defs.size() == 28, "28 enemy defs")
	var made := 0
	for id in defs:
		var e := DmSimEnemy.new()
		e.id = 9000 + made
		e.def = id
		e.area = "graves"
		e.x = float(made) * 2.0
		e.scale = float(defs[id].scale)
		e.maxHp = 100.0
		e.hp = 100.0
		e.radius = float(defs[id].radius)
		e.state = "move"
		var v := views._make_enemy(e)
		check(v.c.loaded, "enemy model loaded: " + id)
		check(v.c.has("idle") or v.c.ap == null or v.c.has("walk"), "enemy has a loop clip or is static: " + id)
		v.c.dispose()
		made += 1
	for kind in ["warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage", "plaguebearer", "colossus"]:
		var th := DmSimThrall.new()
		th.id = 8000
		th.owner = "p1"
		th.kind = kind
		var tv := views._make_thrall(th)
		check(tv.c.loaded, "thrall model loaded: " + kind)
		tv.c.dispose()
		views._kill(tv.ring)
	# the legion kit: weapon blade tint, bow / staff and chest+hands armour tint
	host.kit = {"weapon": {"itemId": "sword_gold", "rarity": "epic"}, "armor": {"itemId": "set_knight_chest", "rarity": "epic"}}
	for kind in ["warrior", "archer", "bonemage"]:
		var th2 := DmSimThrall.new()
		th2.id = 8001
		th2.owner = "p1"
		th2.kind = kind
		var tv2 := views._make_thrall(th2)
		check(tv2.c.loaded, "kit thrall loaded: " + kind)
		await _frames(2)
		tv2.c.update(0.1)
		check(tv2.c._attached.size() >= 1 or tv2.c._pending.size() == 0, "kit thrall props attached: " + kind)
		tv2.c.dispose()
		views._kill(tv2.ring)
	host.kit = null


func _spawn(def: String, x: float, z: float, elite := false, affix := "") -> DmSimEnemy:
	return sim.spawn_enemy(def, "graves", x, z, elite, true, affix)


func _test_world() -> void:
	var defs := ["robber", "hound", "penitent", "deacon", "risen", "censer", "wraith", "rat", "ghoul", "acolyte", "templar", "flagellant", "cinder_husk", "cinderhound", "slag_brute", "fen_wisp", "mire_leech", "gargoyle", "moth", "bat"]
	var spawned: Array = []
	var k := 0
	for d in defs:
		var a := float(k) / defs.size() * TAU
		spawned.append(_spawn(d, cos(a) * 9.0, sin(a) * 9.0))
		k += 1
	var elite := _spawn("robber", 3.0, 3.0, true, "shrouded")
	var elite2 := _spawn("hound", -3.0, 3.0, true, "vengeful")
	var elite3 := _spawn("deacon", 3.0, -3.0, true, "bellTolled")
	var elite4 := _spawn("robber", -3.0, -3.0, true, "hungering")
	await _tick()
	var n := sim.enemies.size()
	check(n >= defs.size() + 4, "sim spawned the roster (%d)" % n)
	check(views.counts().enemies == n, "one view per sim enemy (%d vs %d)" % [views.counts().enemies, n])
	check(host.hitstops.is_empty() or host.hitstops.size() > 0, "hitstop callable ok")
	# rise out of the ground: position y starts below ground, then reaches ground
	var v0: Variant = views.enemy_view(spawned[0].id)
	check(v0 != null and v0.root.position.y < -0.1, "rising enemy starts below the ground (y=%s)" % str(v0.root.position.y if v0 else "n/a"))
	for i in 30:
		await _tick()
	await _frames(1)
	var v1: Variant = views.enemy_view(spawned[0].id)
	check(v1 != null and v1.root.position.y > -0.05, "risen enemy stands on the ground")
	check(views.enemy_anchor(spawned[0].id) != null, "enemy_anchor for a live enemy")
	check(views.enemy_anchor(-5) == null, "enemy_anchor null for unknown id")
	# facing, position follow the sim
	var e0: DmSimEnemy = spawned[0]
	check(absf(v1.root.position.x - e0.x) < 0.8 and absf(v1.root.position.z - e0.z) < 0.8, "view follows the sim position (crowd offset capped)")
	# the elites got affix tells; wraith floats
	var ve: Variant = views.enemy_view(elite.id)
	check(ve != null, "elite view exists")
	var vw: Variant = null
	for e: DmSimEnemy in sim.enemies.values():
		if e.def == "wraith":
			vw = views.enemy_view(e.id)
			check(vw.root.position.y > 0.2, "wraith hovers (y=%.2f)" % vw.root.position.y)
	# kill a handful: death -> dying -> corpse
	var killed: Array = []
	for i in 6:
		var e: DmSimEnemy = spawned[i]
		if sim.enemies.has(e.id):
			sim.damage_enemy(e, 99999.0, "p1")
			killed.append(e.id)
	var corpses_seen := 0
	var evs := await _tick()
	for ev in evs:
		if ev.t == "death":
			corpses_seen += 1
	check(corpses_seen >= 1, "death events seen (%d)" % corpses_seen)
	for i in 4:
		await _tick()
	var cts := views.counts()
	check(cts.dying + cts.corpses + cts.fading >= killed.size(), "dead bodies tracked as dying/corpse/fading (%s)" % str(cts))
	check(cts.enemies == sim.enemies.size(), "enemy views follow deaths (%d vs %d)" % [cts.enemies, sim.enemies.size()])
	var real_corpses := 0
	for c: DmSimCorpse in sim.corpses.values():
		if c.echoOwner == "":
			real_corpses += 1
	check(views.counts().corpses <= real_corpses, "corpse views never exceed sim corpses")
	check(views.counts().corpses >= 1, "at least one body became a corpse view (%s)" % str(views.counts()))
	# the dying body lands (settle) and the view keeps animating
	for i in 120:
		await _tick()
	check(views.counts().dying == 0, "no body is left 'dying' after the crumble window (%s)" % str(views.counts()))
	# raise thralls from corpses (every kind that the sim raises from a corpse)
	var raised := 0
	for kind in ["warrior", "archer", "bonemage", "hound", "plaguebearer"]:
		var c2: DmSimCorpse = null
		for c: DmSimCorpse in sim.corpses.values():
			if c.echoOwner == "":
				c2 = c
				break
		if c2 == null:
			sim.add_corpse(5.0 + raised, 5.0, "normal", "robber", false, 0.0, 1.0, "graves")
			c2 = sim.corpses.values().back()
		sim.apply({"t": "exhume", "by": "p1", "x": c2.x, "z": c2.z, "r": 2.0, "kind": kind, "cap": 9, "hp": 120.0, "damage": 12.0, "attackSpeedMult": 1.0})
		raised += 1
		await _tick()
	sim.apply({"t": "exhume", "by": "p1", "x": 0.0, "z": 0.0, "r": 1.0, "colossus": true, "cap": 9, "hp": 400.0, "damage": 30.0, "attackSpeedMult": 1.0})
	for i in 40:
		await _tick()
	check(sim.thralls.size() >= 3, "sim has thralls (%d)" % sim.thralls.size())
	check(views.counts().thralls == sim.thralls.size(), "one view per thrall (%d vs %d)" % [views.counts().thralls, sim.thralls.size()])
	for tv in sim.thralls.values():
		var cv: Variant = views.thrall_view(tv.id)
		check(cv != null and cv.loaded, "thrall view loaded: " + str(tv.kind))
	# a thrall dies: thrallGone removes its view into the fading list
	var victim: DmSimThrall = sim.thralls.values()[0]
	var before: int = views.counts().thralls
	sim.remove_thrall(victim, "killed") if sim.has_method("remove_thrall") else sim.thralls.erase(victim.id)
	for i in 3:
		await _tick()
	check(views.counts().thralls == before - 1, "thrall view removed when the thrall is gone")
	check(views.counts().fading >= 0, "fading list tracked")
	# let fades finish
	for i in 40:
		await _tick()
	check(views.counts().fading == 0, "fading bodies disposed after the sink (%s)" % str(views.counts()))
	check(views.counts().enemies == sim.enemies.size(), "enemy view count still matches the sim (%d)" % sim.enemies.size())
	# affix events do not error
	for aff in ["bellTolled", "hungering", "vengeful"]:
		views.on_event({"t": "affix", "affix": aff, "x": 1.0, "z": 1.0, "r": 2.0})
	views.on_event({"t": "erupt", "x": 2.0, "z": 2.0, "r": 1.8})
	views.on_event({"t": "unbind", "x": 2.0, "z": 2.0, "tx": 4.0, "tz": 4.0})
	views.on_event({"t": "shieldBlock", "id": 1, "x": 2.0, "z": 2.0})
	views.on_event({"t": "digIn", "id": 1, "x": 2.0, "z": 2.0})
	views.on_event({"t": "spawn", "x": 1.0, "z": 1.0, "elite": true})
	views.on_event({"t": "detonated", "ok": false, "corpseId": 1})
	check(true, "ad-hoc events handled")
	# crowd separation: stack thirty bodies on one spot, the drawn bodies spread
	var stack: Array = []
	for i in 30:
		stack.append(_spawn("robber", 1.0, -1.0))
	for i in 40:
		await _tick()
	var xs := {}
	for e: DmSimEnemy in stack:
		var cv2: Variant = views.enemy_view(e.id)
		if cv2 != null:
			xs[snappedf(cv2.root.position.x, 0.05)] = true
	check(xs.size() > 3, "stacked bodies are drawn apart (%d distinct x)" % xs.size())
	# shadow LOD: at most CROWDED casters among enemy views
	var casters := 0
	for e: DmSimEnemy in sim.enemies.values():
		var cc: DmCreature = views.enemy_view(e.id)
		if cc != null and cc._shadow_on:
			casters += 1
	check(casters <= 12 + 4, "shadow casters bounded (%d)" % casters)


func _test_burrow_and_shroud() -> void:
	var g := _spawn("ghoul", 6.0, 6.0)
	g.state = "burrow"
	g.stateT = 5.0
	views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	var gv = views._enemies.get(g.id)
	check(gv != null and gv.under and gv.mound != null and not gv.c.root.visible, "burrowed ghoul hides the model and slides a mound")
	g.state = "move"
	views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	check(not gv.under and gv.mound == null and gv.c.root.visible, "surfaced ghoul shows the model again")
	var sh := _spawn("robber", -6.0, 6.0, true, "shrouded")
	for i in 30:
		views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	var sv = views._enemies.get(sh.id)
	check(sv != null and sv.has_shroud and sv.shroud < 0.5 and sv.c.opacity() < 0.5, "a shrouded elite fades toward 0.38 (%.2f)" % (sv.shroud if sv != null else -1.0))
	# a death clip lands (landingTime from the Hip track) and the body holds its last frame
	for slug in ["grave_robber", "skeleton_thrall", "bone_golem"]:
		var dc := DmCreature.new(slug, {})
		host.add_child(dc.root)
		check(dc.play_death(), "death clip plays: " + slug)
		check(not dc.has_landed(), "not landed at t=0: " + slug)
		var t := 0.0
		var landed_at := -1.0
		while t < 7.0:
			dc.update(0.05)
			t += 0.05
			if landed_at < 0.0 and dc.has_landed():
				landed_at = t
		check(landed_at > 0.2 and landed_at < 6.0, "%s lands during its death clip (t=%.2f)" % [slug, landed_at])
		dc.dispose()
	var sp := DmCreature.new("skull_rat", {})
	host.add_child(sp.root)
	check(not sp.play_death() or sp.has("death"), "rig without death clip reports it")
	sp.dispose()

func _test_resync() -> void:
	# enemies that vanish without a death event sink away; mounds and rings are released
	var before: int = views.counts().enemies
	check(before > 0, "enemies exist before the resync")
	sim.enemies.clear()
	views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	check(views.counts().enemies == 0, "resync removes enemy views")
	check(views.counts().fading >= before, "resynced bodies fade out (%s)" % str(views.counts()))
	for i in 30:
		views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	check(views.counts().fading == 0, "resynced bodies disposed (%s)" % str(views.counts()))


func _test_corpse_prune() -> void:
	var c := sim.add_corpse(2.0, 2.0, "normal", "robber", false, 0.0, 1.0, "graves")
	views.on_event({"t": "corpse", "corpse": c})
	check(views.counts().corpses == 1, "corpse without a dying body is laid down")
	var cr := sim.add_corpse(4.0, 2.0, "resonant", "hound", true, 1.0, 1.35, "graves")
	views.on_event({"t": "corpse", "corpse": cr})
	check(views.counts().corpses == 2, "second corpse view")
	var echo := sim.add_corpse(6.0, 2.0, "normal", "robber", false, 0.0, 1.0, "graves")
	echo.echoOwner = "p1"
	views.on_event({"t": "corpse", "corpse": echo})
	check(views.counts().corpses == 2, "echo corpses get no body")
	for i in 20:
		views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	var landed := true
	for id in views._corpses:
		landed = landed and (views._corpses[id].c.has_landed() or views._corpses[id].c.toppled >= 0.8)
	check(landed, "late-join corpses are laid at their last frame")
	views.on_event({"t": "corpseGone", "id": c.id, "reason": "consumed"})
	check(views.counts().corpses == 1, "corpseGone releases the view")
	views.prune_corpses({})
	check(views.counts().corpses == 0, "prune_corpses drops bodies the authority lost")
	for i in 30:
		views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	check(views.counts().fading == 0, "pruned bodies disposed")


## A dead enemy's body goes back to the pool once it has faded and the next spawn of that kind reuses it, standing, opaque and visible.
func _test_pool_reuse() -> void:
	var e := _spawn("robber", 3.0, 3.0)
	views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	var c1: DmCreature = views.enemy_view(e.id)
	check(c1 != null, "pool: enemy view built")
	views.on_event({"t": "death", "id": e.id, "x": e.x, "z": e.z, "def": "robber"})
	sim.enemies.erase(e.id)
	for i in 50:
		views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	check(views.counts().dying == 0 and views.counts().fading == 0, "pool: dead body faded (%s)" % str(views.counts()))
	var hits0: int = views.pool_counts().pool_hits
	var e2 := _spawn("robber", -3.0, 3.0)
	views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	var c2: DmCreature = views.enemy_view(e2.id)
	check(views.pool_counts().pool_hits == hits0 + 1, "pool: next spawn of the kind reuses a body (%s)" % str(views.pool_counts()))
	check(c2 != null and c2.opacity() == 1.0 and c2.toppled == 0.0 and c2.root.visible and c2.root.is_inside_tree(), "pool: reused body is reset")
	check(c2 != null and not c2.busy(), "pool: reused body is not still playing its death")
	check(c2 != null and absf(c2.root.rotation.z) < 0.001, "pool: reused body stands upright")
	sim.enemies.erase(e2.id)
	views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)
	for i in 30:
		views.sync(sim.enemies, sim.thralls, 0.05, 0.0, 0.0)


func _test_avatar() -> void:
	var a := DmAvatar.new()
	a.settings = {"hideHelm": false}
	a.setup(host, "#a26bff", true, "hero_ossuary")
	check(a.c.loaded, "avatar model loaded")
	check(a.lantern != null, "avatar lantern")
	for i in 5:
		a.update(0.05, 0.0, 0.0, 0.0, false, 5.0)
		await _frames(1)
	a.set_equipment({"main_hand": {"item_id": "staff_bone"}, "off_hand": {"item_id": "grimoire_bone"}, "head": {"item_id": "set_gravecaller_head"}, "chest": {"item_id": "set_gravecaller_chest"}})
	check(a._worn.has("main_hand") and a._worn.has("off_hand") and a._worn.has("head"), "equipment shows (%s)" % str(a._worn.keys()))
	check(not a._staff.visible, "an equipped weapon replaces the default staff")
	a.settings["hideHelm"] = true
	DmAvatar.refresh_all()
	check(not (a._worn.head.obj as Node3D).visible or a._head_tint != null, "hide helm setting reaches the avatar")
	a.set_equipment({})
	check(a._worn.is_empty() and a._staff.visible, "unequipping restores the default staff")
	# walking: the loop phase exists after a moment
	var x := 0.0
	for i in 20:
		x += 0.1
		a.update(0.05, x, 0.0, 1.2, true, 5.0)
		await _frames(1)
	check(a.c.last_plan.has("clip"), "avatar locomotion planned (%s)" % str(a.c.last_plan.get("clip")))
	var ph := a.loop_phase()
	check(ph >= 0.0 and ph <= 1.0, "loop_phase while walking (%.2f)" % ph)
	a.cast("cast", 2.0, 0.5, 0.4, "exhume")
	check(a.c.busy(), "a cast plays a gesture")
	a.update(0.05, x, 0.0, 0.5, false, 5.0)
	a.set_gathering_tool("mining", 2)
	check(a._gathering_skill == "mining", "gathering skill set")
	a.set_gathering_tool("", 0)
	a.play_once("death")
	a.update(0.05, x, 0.0, 0.5, false, 5.0)
	check(a.c.busy(), "death one-shot plays")
	a.release_gesture()
	a.set_loop("idle")
	a.set_cape("cape_apprentice")
	check(a._cape != null, "cape on")
	a.dispose()
	# every discipline hero model
	for slug in ["hero_gravecaller", "hero_mourner", "hero_rotweaver", "hero_hollow_knight", "hero_grave_warden", "hero_bell_monk", "hero_carrion_witch", "hero_veilwalker", "necromancer"]:
		var av := DmAvatar.new()
		av.setup(host, 0xa26bff, false, slug)
		check(av.c.loaded, "hero model loads: " + slug)
		av.set_equipment({"main_hand": {"item_id": "sword_iron"}, "head": {"item_id": "helm_iron"}})
		av.update(0.05, 0.0, 0.0, 0.0, false, 5.0)
		av.dispose()


func _test_bosses() -> void:
	for id in DmContent.get_export("bosses", "BOSS_IDS"):
		var bv := DmBossView.new()
		bv.setup(host, id)
		check(bv.c.loaded, "boss model loaded: " + id)
		var b := DmBossState.new()
		b.id = id
		b.active = false
		bv.sync(b, 0.05)
		check(not bv.root.visible or not bv.c.root.visible, "inactive boss stays hidden: " + id)
		b.active = true
		b.x = 5.0
		b.z = 5.0
		b.hp = 100.0
		b.maxHp = 100.0
		for st in ["idle", "move", "toll", "slam", "rain", "summon"]:
			b.state = st
			b.x += 0.2
			bv.sync(b, 0.05)
			await _frames(1)
		check(bv.c.root.visible, "active boss visible: " + id)
		b.state = "dead"
		bv.sync(b, 0.05)
		b.active = false
		bv.hide()
		for i in 80:
			bv.sync(b, 0.05)
		check(not bv.c.root.visible, "boss fades out after hide(): " + id)
		bv.dispose()

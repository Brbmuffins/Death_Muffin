extends SceneTree
## Rune variants and legendary-set mechanics on the rebuilt client (client/next/rites, client/core, client/next/hero). godot --headless --path client --script res://tests/runes/run.gd
## The enemies are static bodies of the combat core (stunned for an hour, harmless, with health to spare), the corpses and the legion are the core's, as tests/rites.gd has them.
##   A  the runes with a gameplay test below (table-driven: every key is a rune the data defines), each proving its effect against the same cast without it; a rune the data
##      gains has no case until one is written, and is only checked for the properties every rune has (a rune of a rite that exists)
##   B  Grimoire rune picks: the bag -> the Grimoire panel shows them, socketing through the panel's own path reaches the caster, taking one out removes it
##   C  worn legendary sets feed the legion + caster on every gear change (and strip again), and every legend mod that exists in the data does its job
##   E  cost: per-frame cost with a creeping/contagion circle + volley casts, and a gear change (printed, never asserted)
## Not here: Bonded Dead (a Covenant Boon: no boon acts in the rebuilt game, DECISIONS B36; tests/value.gd checks they do nothing).

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var hero: DmHeroBody
var caster: DmRiteCaster
var host: DmCoreHost
var core: RefCounted
var mock: DmMockBackend
var cid := 0
var foes: Array[int] = []
var hits: Array = []   ## [{rite, t, ev}] every event the caster played since reset
var blows: Array = []  ## [rite, enemy id, amount] every blow a rite dealt since reset (the damage over time of a status is not one)


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func frames(n: int) -> void:
	for i in n:
		await process_frame


func secs(s: float) -> void:
	await ticks(int(s / DT))


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


## A static enemy of the core: stunned for an hour (it stands where it is), harmless, with health to soak the cases. Returns its id.
func foe(at: Vector3, def_id := "robber") -> int:
	var id := host.spawn_enemy(def_id, at, 1, 1000.0, 0.0, false, "graves", false)
	core.stun(id, 3600.0)
	foes.append(id)
	return id


func eid(e: int) -> int:
	return e


## What the core took from an enemy: its maximum health less its health (-1 when it is gone).
func loss(e: int) -> float:
	var i: Dictionary = core.enemy_info(e)
	return float(i["max_hp"]) - float(i["hp"]) if not i.is_empty() else -1.0


func pos_of(e: int) -> Vector3:
	return host.enemy_position(e)


func corpse(at: Vector3, kind := "normal") -> int:
	return g.corpses.add_corpse(at.x, at.z, kind, "robber", false, 0.0, 1.0, "graves")


func legion() -> DmCoreLegion:
	return caster.thralls()


## A status of a body from the core's wire (4 bytes each: wire id, stacks, tenths of a second left): the stacks, 0 when it has none.
func stacks_of(id: int, name: StringName) -> int:
	var b: PackedByteArray = core.statuses(id)
	var want := DmStatusSet.IDS.find(name)
	for i in range(0, b.size(), 4):
		if int(b[i]) == want:
			return int(b[i + 1])
	return 0


func has_status(id: int, name: StringName) -> bool:
	return stacks_of(id, name) > 0


func clear_world() -> void:
	for id in core.enemy_ids():
		host.remove_enemy(int(id))
	foes.clear()
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "consumed")
	for id in core.thrall_ids():
		core.kill_thrall(id, "crumbled")
	caster._pending.clear()
	caster._mem.clear()
	if caster._legends != null:
		caster._legends.wisps.clear()


func reset(rite := "", rune := "") -> void:
	clear_world()
	hero.teleport(Vector3(0, 0, -18))
	caster.set_runes({rite: rune} if rune != "" else {})
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.p["rootedUntil"] = 0.0
	hero.heal(1e6)
	hits.clear()
	blows.clear()


## The first blow a rite dealt enemy `e` since the last reset: its amount, or -1.
func blow(e: int) -> float:
	for b in blows:
		if int(b[1]) == e:
			return float(b[2])
	return -1.0


func evs(rite: String, t: String) -> Array:
	return hits.filter(func(h: Dictionary) -> bool: return h["rite"] == rite and h["t"] == t)


## Wear / strip a whole legendary set through the bag's real equip path, then let the next frame refresh the stats.
func wear(set_id: String) -> void:
	await strip()
	for part in ["head", "chest", "hands", "legs", "feet"]:
		await g.ui.inv.toggle_equip(row("leg_%s_%s" % [set_id, part]))
	await frames(3)


func strip() -> void:
	for s in g.ui_host.inventory.slots.duplicate():
		if int(s.get("equipped", 0)) != 0 and String(s["item_id"]).begins_with("leg_"):
			await g.ui.inv.toggle_equip(s)
	await frames(3)


func row(id: String) -> Dictionary:
	for s in g.ui_host.inventory.slots:
		if s["item_id"] == id:
			return s
	return {}


func _run() -> void:
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("runes%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var ch := await api.load_or_create_character(0)
	cid = int(ch.data["id"])
	var bag: Array = []
	var n := 0
	for set_id in ["legion_unburied", "plague_choir", "colossus_mantle", "requiem_wraiths"]:
		for part in ["head", "chest", "hands", "legs", "feet"]:
			bag.append({"slot_index": n, "item_id": "leg_%s_%s" % [set_id, part], "quantity": 1, "equipped": 0})
			n += 1
	for rid in DmCombatData.abilities()["rune_ids"]:
		bag.append({"slot_index": n, "item_id": rid, "quantity": 1, "equipped": 0})
		n += 1
	check((await api.save_inventory(cid, bag, 48)).ok, "seed the bag: 20 legendary pieces + every rune (%d rows)" % bag.size())
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start((await api.load_or_create_character(0)).data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "hud": true, "areas": ["graves"]})
	host = g.core_host
	core = host.core
	hero = g.local_body()
	await ticks(3)
	caster = hero.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	caster.random = func() -> float: return 0.5   # jitter 1.0, no crit: damage is exact
	caster.event_played.connect(func(ev: Dictionary) -> void: hits.append({"rite": String(ev["rite"]), "t": String(ev["t"]), "ev": ev}))
	g.rite_hit.connect(func(rite: String, id: int, amount: float, _crit: bool, _killed: bool) -> void: blows.append([rite, id, amount]))
	await g.ui_host.refresh_inventory()
	check(hero.discipline_id == "gravecaller", "setup: a Gravecaller")

	# =================================================================== A: every rune, against the same cast without it
	var cases := {
		"rune_splinter": _rune_splinter, "rune_marrow_tap": _rune_marrow_tap, "rune_volley": _rune_volley,
		"rune_ossuary_ring": _rune_ring, "rune_impale": _rune_impale,
		"rune_mass_grave": _rune_mass_grave, "rune_bone_colossus": _rune_colossus,
		"rune_creeping_rot": _rune_creeping, "rune_contagion": _rune_contagion,
		"rune_hollow_choir": _rune_hollow, "rune_requiem": _rune_requiem,
	}
	var known: Array = DmCombatData.abilities()["rune_ids"]
	var bare: Array[String] = []
	for rid: String in known:
		check(DmRunes.is_rune_id(rid) and DmRiteRegistry.has(_rite_of(rid)), "A: %s is a rune of a rite that exists (%s)" % [rid, _rite_of(rid)])
		if not cases.has(rid):
			bare.append(rid)
	for rid: String in cases:
		check(known.has(rid), "A: the table has no rune the data lacks (%s)" % rid)
	if not bare.is_empty():
		print("INFO runes: no gameplay case yet for %s" % ", ".join(bare))
	for rid: String in cases:
		if known.has(rid):
			await (cases[rid] as Callable).call(rid)

	# =================================================================== B: the Grimoire's rune picks
	await _grimoire()

	# =================================================================== C: legendary mods
	await _legends()

	print("%d passed, %d failed" % [passed, failed])
	print("%s runes %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------------------------------------------------------------------- runes

func _rite_of(rid: String) -> String:
	return String(DmCombatData.abilities()["runes"][rid]["rite"])


func _rune_splinter(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base := 0.0
	for with_rune in [false, true]:
		reset("bone_needle", rid if with_rune else "")
		var reach := float(T["splinter"]["reach"])
		var e1 := foe(Vector3(0, 0, -26))
		var e2 := foe(Vector3(reach * 0.65, 0, -26))
		var far := foe(Vector3(reach * 2.0, 0, -26))
		caster.request_cast("bone_needle", pos_of(e1), eid(e1))
		await secs(1.2)
		if not with_rune:
			base = loss(e1)
			check(base > 0.0 and loss(e2) == 0.0, "%s: without it the needle hurts only its target (%.2f / %.2f)" % [rid, base, loss(e2)])
		else:
			check(near(loss(e1), base, 0.01) and near(loss(e2), base * float(T["splinter"]["damageFrac"]), 0.01), "%s: a shard hits the nearest other enemy for %.0f%% (%.1f of %.1f)" % [rid, float(T["splinter"]["damageFrac"]) * 100.0, loss(e2), base])
			check(loss(far) == 0.0, "%s: ...and nothing beyond its %.0f m reach" % [rid, float(T["splinter"]["reach"])])
			check(evs("bone_needle", "splinter").size() == 1, "%s: one shard event is played" % rid)


func _rune_marrow_tap(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var res := {}
	for with_rune in [false, true]:
		reset("bone_needle", rid if with_rune else "")
		var e1 := foe(Vector3(0, 0, -26))
		caster.p["resource"]["value"] = 0.0
		caster.request_cast("bone_needle", pos_of(e1), eid(e1))
		await until(func() -> bool: return loss(e1) > 0.0, 2.0)
		res[with_rune] = [loss(e1), float(caster.p["resource"]["value"])]
		print("marrow tap probe: with=%s loss=%.2f essence=%.2f max=%.1f" % [with_rune, loss(e1), float(caster.p["resource"]["value"]), float(caster.p["resource"]["max"])])
	check(near(res[true][0], res[false][0] * float(T["marrowTap"]["damageMult"]), 0.01), "%s: the needle hits for x%.1f (%.1f vs %.1f)" % [rid, float(T["marrowTap"]["damageMult"]), res[true][0], res[false][0]])
	check(near(res[true][1] - res[false][1], float(T["marrowTap"]["essenceBonus"]), 1.0), "%s: and returns %d more essence (%.1f vs %.1f)" % [rid, int(T["marrowTap"]["essenceBonus"]), res[true][1], res[false][1]])


func _rune_volley(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var every := int(T["volley"]["every"])
	var spread := float(T["volley"]["reach"]) / 3.0   # (neighbours well inside the volley's reach)
	reset("bone_needle", rid)
	var a := foe(Vector3(0, 0, -26))
	var b := foe(Vector3(spread, 0, -26))
	var c2 := foe(Vector3(-spread, 0, -26))
	var single := 0.0
	caster.request_cast("bone_needle", pos_of(a), eid(a))
	await secs(0.9)
	single = loss(a)
	check(single > 0.0 and loss(b) == 0.0 and evs("bone_needle", "hit").size() == 1, "%s: needles 1-%d are single shots (%.1f, %.1f, %d hit events, cd %s)" % [rid, every - 1, single, loss(b), evs("bone_needle", "hit").size(), str(caster.p["cooldowns"])])
	for i in range(2, every):
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("bone_needle", pos_of(a), eid(a))
		await secs(0.9)
	for e in [a, b, c2]:
		core.set_enemy_hp(e, core.enemy_info(e)["max_hp"], core.enemy_info(e)["max_hp"])
	hits.clear()
	caster.p["resource"]["value"] = 0.0
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.request_cast("bone_needle", pos_of(a), eid(a))
	await until(func() -> bool: return evs("bone_needle", "hit").size() >= 3, 2.0)
	var each := loss(a)
	check(near(each, single * float(T["volley"]["damageFrac"]), 0.01) and near(loss(b), each, 0.01) and near(loss(c2), each, 0.01), "%s: needle %d is a volley of %d at x%.1f, each at a different enemy (%.1f / %.1f / %.1f)" % [rid, every, int(T["volley"]["needles"]), float(T["volley"]["damageFrac"]), loss(a), loss(b), loss(c2)])
	check(evs("bone_needle", "hit").size() == int(T["volley"]["needles"]), "%s: %d hits land (%d)" % [rid, int(T["volley"]["needles"]), evs("bone_needle", "hit").size()])
	var got := float(caster.p["resource"]["value"])   # one needle's essence (+ a little regen), not every needle's
	var per_needle := float(DmCombatData.abilities()["constants"]["NEEDLE_ESSENCE"])
	check(got >= per_needle * 0.9 and got <= per_needle * 1.7, "%s: the volley returns the essence of ONE needle (%.1f of %.1f)" % [rid, got, per_needle])
	var leads := evs("bone_needle", "cast").filter(func(h: Dictionary) -> bool: return bool(h["ev"].get("lead", true)))
	check(leads.size() == 1 and evs("bone_needle", "cast").size() == int(T["volley"]["needles"]), "%s: one muzzle burst, %d shots" % [rid, int(T["volley"]["needles"])])
	# alone: all three needles go to the single enemy
	reset("bone_needle", rid)
	var solo := foe(Vector3(0, 0, -26))
	for i in every:
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("bone_needle", pos_of(solo), eid(solo))
		await secs(0.9)
	check(evs("bone_needle", "hit").size() == every - 1 + int(T["volley"]["needles"]), "%s: a volley at a lone enemy sends all %d at it (%d hits in %d casts)" % [rid, int(T["volley"]["needles"]), evs("bone_needle", "hit").size(), every])


func _rune_ring(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base := 0.0
	for with_rune in [false, true]:
		reset("marrow_spear", rid if with_rune else "")
		var ring_r := float(T["ring"]["radius"])
		var cursor_z := -18.0 - (float(DmAbilities.def("marrow_spear")["range"]) - ring_r - 1.1)   # (the hero stands at z -18; past the ring the line still has reach)
		var on_line := foe(Vector3(0, 0, cursor_z))
		var beside := foe(Vector3(ring_r * 0.8, 0, cursor_z))
		var beyond := foe(Vector3(0, 0, cursor_z - ring_r - 0.9))
		caster.request_cast("marrow_spear", Vector3(0, 0, cursor_z), -1)
		await secs(1.2)
		if not with_rune:
			base = blow(on_line)
			check(base > 0.0 and loss(beside) == 0.0 and loss(beyond) > 0.0, "%s: without it the spear is a line (%.1f; beside %.1f; beyond %.1f)" % [rid, base, loss(beside), loss(beyond)])
		else:
			check(blow(on_line) > 0.0 and blow(beside) > 0.0 and near(blow(beside), base * float(T["ring"]["damageMult"]), 0.01), "%s: the ring at the cursor strikes everything inside %.0f m for x%.1f (%.1f)" % [rid, float(T["ring"]["radius"]), float(T["ring"]["damageMult"]), blow(beside)])
			check(loss(beyond) == 0.0 and evs("marrow_spear", "ring").size() == 1, "%s: ...and no longer reaches down the line" % rid)


func _rune_impale(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base := 0.0
	for with_rune in [false, true]:
		reset("marrow_spear", rid if with_rune else "")
		var e1 := foe(Vector3(0, 0, -24))
		var e2 := foe(Vector3(0, 0, -29))
		caster.request_cast("marrow_spear", pos_of(e2), -1)
		await secs(1.2)
		if not with_rune:
			base = blow(e1)
			check(loss(e2) > 0.0 and not has_status(e1, &"root"), "%s: without it the spear pierces the line and roots nobody" % rid)
		else:
			check(loss(e2) == 0.0 and has_status(e1, &"root") and near(blow(e1), base * float(T["impale"]["damageMult"]), 0.01), "%s: only the first enemy, x%.1f, rooted %.1f s (%.1f)" % [rid, float(T["impale"]["damageMult"]), float(T["impale"]["rootS"]), blow(e1)])


func _rune_mass_grave(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base_hp := 0.0
	for with_rune in [false, true]:
		reset("exhume", rid if with_rune else "")
		var raised := int(T["massGrave"]["count"])
		var lay := float(T["massGrave"]["pickRadius"]) / float(raised + 1)   # (one corpse more than it raises, all inside its pick radius)
		for k in raised + 1:
			corpse(Vector3(lay * k, 0, -24))
		caster.request_cast("exhume", Vector3(0, 0, -24), -1)
		await secs(1.0)
		if not with_rune:
			base_hp = float(legion().info(legion().list()[0])["max_hp"]) if legion().count() > 0 else 0.0
			check(legion().count() == 1 and base_hp > 0.0, "%s: without it Exhume raises one thrall" % rid)
		else:
			var hp: float = float(legion().info(legion().list()[0])["max_hp"]) if legion().count() > 0 else 0.0
			check(legion().count() == int(T["massGrave"]["count"]) and near(hp, base_hp * float(T["massGrave"]["statMult"]), 0.01), "%s: it raises %d at x%.2f the stats (%d thralls, hp %.0f vs %.0f)" % [rid, int(T["massGrave"]["count"]), float(T["massGrave"]["statMult"]), legion().count(), hp, base_hp])
			check(g.corpses.corpses_in_radius(Vector3(0, 0, -24), 20.0).size() == 1, "%s: ...each from its own corpse (1 of %d left)" % [rid, raised + 1])


func _rune_colossus(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	reset("exhume", rid)
	var need := int(T["colossus"]["corpses"])
	var lay := float(T["colossus"]["pickRadius"]) / float(need + 1)
	for k in need:
		corpse(Vector3(lay * k, 0, -24))
	caster.request_cast("exhume", Vector3(0, 0, -24), -1)
	await ticks(3)
	var cd_after := caster.cooldown_left("exhume")
	await secs(1.0)
	var ts := legion().list()
	check(ts.size() == 1 and String(legion().info(ts[0])["kind"]) == "colossus", "%s: %d corpses become one Colossus (%d thralls)" % [rid, need, ts.size()])
	check(g.corpses.corpses_in_radius(Vector3(0, 0, -24), 20.0).size() == 0, "%s: all %d are spent" % [rid, need])
	check(near(cd_after, float(DmAbilities.def("exhume")["cooldownMs"]) * float(T["colossus"]["cooldownMult"]), 150.0), "%s: and Exhume rests x%d as long (%.0f ms)" % [rid, int(T["colossus"]["cooldownMult"]), caster.cooldown_left("exhume")])
	# too few corpses: a plain thrall, as without the rune
	reset("exhume", rid)
	for k in int(T["colossus"]["minCorpses"]) - 1:
		corpse(Vector3(float(k), 0, -24))
	caster.request_cast("exhume", Vector3(0, 0, -24), -1)
	await secs(1.0)
	check(legion().count() == 1 and String(legion().info(legion().list()[0])["kind"]) != "colossus", "%s: with fewer than %d corpses it raises an ordinary thrall" % [rid, int(T["colossus"]["minCorpses"])])


func _rune_creeping(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base_r := 0.0
	for with_rune in [false, true]:
		reset("miasma", rid if with_rune else "")
		var e := foe(Vector3(0, 0, -27.0 - float(T["creepingRot"]["seekReach"]) * 0.75))   # (inside the seek reach, further than the circle drifts in 4 s)
		caster.request_cast("miasma", Vector3(0, 0, -27), -1)
		await secs(1.6)
		var zs: Array = caster.mem("miasma")["zones"]
		var z: Dictionary = zs[0] if zs.size() > 0 else {}
		if not with_rune:
			base_r = float(z.get("r", 0.0))
			check(not z.is_empty() and near(float(z["z"]), -27.0, 0.01), "%s: without it the circle stays where it landed" % rid)
		else:
			check(near(float(z["r"]), base_r * float(T["creepingRot"]["radiusMult"]), 0.01), "%s: radius x%.2f (%.2f vs %.2f)" % [rid, float(T["creepingRot"]["radiusMult"]), float(z["r"]), base_r])
			var t0 := float(z["z"])
			await secs(2.0)
			var moved := t0 - float(z["z"])
			var speed := float(T["creepingRot"]["speed"])
			check(moved > speed * 2.0 * 0.6 and moved < speed * 2.0 * 1.3 and near(float(z["x"]), 0.0, 0.01), "%s: it drifts toward the nearest enemy at %.1f m/s (%.2f m in 2 s)" % [rid, speed, moved])
			check(evs("miasma", "move").size() >= 2 and evs("miasma", "land")[0]["ev"]["creep"] > 0.0, "%s: the other peers are told where it walks (%d move events)" % [rid, evs("miasma", "move").size()])
			var every_s := float(DmRiteRegistry.module("miasma").get_script().get_script_constant_map()["MOVE_EV_S"])
			check(evs("miasma", "move").size() <= int(ceil(3.6 / every_s)) + 1, "%s: ...once per %.1f s at most, not every tick (%d)" % [rid, every_s, evs("miasma", "move").size()])


func _rune_contagion(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	for with_rune in [false, true]:
		reset("miasma", rid if with_rune else "")
		var reach := float(T["contagion"]["reach"])
		var a := foe(Vector3(0, 0, -28))
		var b := foe(Vector3(reach * 0.65, 0, -28))
		var far := foe(Vector3(reach * 2.0, 0, -28))
		caster.request_cast("miasma", Vector3(0, 0, -27), -1)
		await secs(2.8)
		check(stacks_of(a, &"withered") >= int(T["contagion"]["minStacks"]), "%s: the circle withered its victim (%d stacks)" % [rid, stacks_of(a, &"withered")])
		var stacks := stacks_of(a, &"withered")
		core.remove_status(b, &"withered")
		core.damage(a, 1e9, hero.core_id)
		await ticks(3)
		if with_rune:
			check(stacks_of(b, &"withered") == stacks - 1 and stacks_of(far, &"withered") == 0, "%s: its death hands %d stacks to a neighbour within %.1f m, not to a far one (%d)" % [rid, stacks - 1, float(T["contagion"]["reach"]), stacks_of(b, &"withered")])
			check(evs("miasma", "contagion").size() >= 1, "%s: a thread is drawn to the neighbour" % rid)
		else:
			check(stacks_of(b, &"withered") <= 1, "%s: without it the stacks die with the enemy (%d)" % [rid, stacks_of(b, &"withered")])


func _rune_hollow(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var spec := {"kind": "warrior", "cap": 4.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0}
	var base := 0.0
	for with_rune in [false, true]:
		reset("black_litany", rid if with_rune else "")
		var e := foe(Vector3(0, 0, -18.0 - float(DmAbilities.def("black_litany")["radius"]) * 0.4))
		corpse(Vector3(1, 0, -19))   # the corpse the litany eats ...
		raise_at(Vector3(-1, 0, -19), spec)   # ... and a thrall (it rises from a corpse of its own)
		await ticks(2)
		caster.request_cast("black_litany", Vector3.ZERO)
		await secs(0.5)
		if not with_rune:
			base = loss(e)
			check(legion().count() == 0 and base > 0.0, "%s: without it the litany sacrifices the legion" % rid)
		else:
			check(legion().count() == 1, "%s: it spares the thralls" % rid)
			var want := DmAbilities.litany_damage(DmAbilities.litany_spell_power(DmAbilities.sp(caster.p, caster.now_ms), rid), 1, 0, 1)
			check(near(loss(e), want, want * 0.02) and not near(loss(e), base, 0.01), "%s: at x%.1f spell power (%.1f vs %.1f without)" % [rid, float(T["hollowChoir"]["powerMult"]), loss(e), base])


func _rune_requiem(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var plain_r := float(DmAbilities.def("black_litany")["radius"])
	var wide_r := plain_r * float(T["requiem"]["radiusMult"])
	var near_e := Vector3(0, 0, -18.0 - plain_r * 0.4)   # inside both radii (the hero stands at z -18)
	var mid_e := Vector3((plain_r + wide_r) * 0.5, 0, -18)  # between the plain radius and the widened one
	for with_rune in [false, true]:
		reset("black_litany", rid if with_rune else "")
		var a := foe(near_e)
		var m := foe(mid_e)
		caster.request_cast("black_litany", Vector3.ZERO)
		await secs(0.6)
		if not with_rune:
			check(loss(a) > 0.0 and loss(m) == 0.0, "%s: without it the burst is immediate and %.0f m wide" % [rid, plain_r])
		else:
			check(loss(a) == 0.0 and evs("black_litany", "requiem").size() == 1, "%s: nothing at once, a warning is drawn" % rid)
			await secs(float(T["requiem"]["delayMs"]) / 1000.0)
			check(loss(a) > 0.0 and loss(m) > 0.0, "%s: after %.0f s it bursts x%.1f wider (%.1f and %.1f)" % [rid, float(T["requiem"]["delayMs"]) / 1000.0, float(T["requiem"]["radiusMult"]), loss(a), loss(m)])


# ---------------------------------------------------------------------------------------------------------------------------- Grimoire

func _grimoire() -> void:
	reset()
	await g.ui_host.refresh_inventory()
	check(caster.p["runes"].is_empty() and g.rune_sockets(1).is_empty(), "B: no rune socketed to begin with")
	g.ui.toggle_panel("grimoire")
	await frames(3)
	check(g.ui.is_open("grimoire"), "B: the Grimoire opens")
	g.ui_host.counsel.last_combat_ms = -1e9   # the fights above leave the hero "in combat" for a few seconds
	var owned: Dictionary = DmRunes.owned_runes(g.ui_host.inventory.slots)
	check(owned.size() == DmCombatData.abilities()["rune_ids"].size() and not owned.is_empty(), "B: the bag holds all %d runes to learn" % owned.size())
	var err: String = await g.ui.inv.socket_rune_id("bone_needle", "rune_volley")   # what the Grimoire's rune button calls
	check(err.contains("learned") and DmAbilities.rune(caster.p, "bone_needle") == "", "B: a rune not learned yet cannot be socketed (%s)" % err)
	await _learn("rune_volley")
	check(g.ui_host.learned_runes.has("rune_volley") and not DmRunes.owned_runes(g.ui_host.inventory.slots).has("rune_volley"), "B: Learn spends the bag's Volley and the character knows it")
	check(DmAbilities.rune(caster.p, "bone_needle") == "rune_volley" and g.rite_build(1)["runes"].get("bone_needle") == "rune_volley", "B: the empty socket takes it and the caster holds it at once (%s)" % str(caster.p["runes"]))
	await _learn("rune_requiem")
	check(DmAbilities.rune(caster.p, "black_litany") == "rune_requiem" and caster.p["runes"].size() == 2, "B: a second rite takes its own rune")
	await _learn("rune_splinter")
	check(DmAbilities.rune(caster.p, "bone_needle") == "rune_volley", "B: learning a rune never replaces a socketed one")
	err = await g.ui.inv.socket_rune_id("bone_needle", "rune_splinter")
	check(err == "" and DmAbilities.rune(caster.p, "bone_needle") == "rune_splinter" and not DmRunes.owned_runes(g.ui_host.inventory.slots).has("rune_volley"), "B: swapping in a learned rune replaces it; the old one stays learned, not an item (%s)" % err)
	check(g.loot._owns_rune({"item_id": "rune_volley"}), "B: a learned rune never drops again")
	g.ui_host.counsel.last_combat_ms = g.ui_host.counsel.now()
	err = await g.ui.inv.socket_rune_id("bone_needle", "rune_volley")
	check(err.contains("fight") and DmAbilities.rune(caster.p, "bone_needle") == "rune_splinter", "B: no swaps in a fight (%s)" % err)
	g.ui_host.counsel.last_combat_ms = -1e9
	err = await g.ui.inv.socket_rune_id("black_litany", "")   # empty the socket
	check(DmAbilities.rune(caster.p, "black_litany") == "" and not caster.p["runes"].has("black_litany"), "B: emptying a socket removes it from the caster")
	err = await g.ui.inv.socket_rune_id("exhume", "rune_volley")
	check(err != "" and DmAbilities.rune(caster.p, "exhume") == "", "B: a rune that does not fit the rite is refused (%s)" % err)
	# the picks survive a level-up / gear refresh (rite_build reads the bag again)
	g.progress.refresh_stats()
	check(DmAbilities.rune(caster.p, "bone_needle") == "rune_splinter", "B: a stats refresh keeps the pick")
	g.ui.close_panels()
	await g.ui.inv.socket_rune_id("bone_needle", "")
	check(caster.p["runes"].is_empty(), "B: everything taken out again")


## Bag -> Learn on the first bag row holding `rid` (what the Reliquary's Learn button calls).
func _learn(rid: String) -> void:
	for r: Dictionary in g.ui_host.inventory.slots:
		if r["item_id"] == rid and int(r["slot_index"]) < DmLoot.bag_size():
			await g.ui.inv.learn_rune(r)
			return
	check(false, "B: %s is in the bag to learn" % rid)


# ---------------------------------------------------------------------------------------------------------------------------- legends

const WARRIOR := {"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0, "r": 0.8}


## A thrall of the legion at `pos` the way an exhume raises one (a corpse is laid there, the legion raises from it): its id.
func raise_at(pos: Vector3, spec: Dictionary = WARRIOR) -> int:
	corpse(pos)
	var r: Dictionary = legion().raise(spec, pos)
	return int((r["thralls"] as Array)[0]) if bool(r["ok"]) and not (r["thralls"] as Array).is_empty() else 0


## What the whole set (all five pieces worn) adds to `key`, summed over its tiers in the set bonuses of the data.
func bonus(set_id: String, key: String) -> float:
	var sum := 0.0
	for b: Dictionary in DmSetBonuses.bonuses_of(set_id):
		sum += float((b["effect"].get("add", {}) as Dictionary).get(key, 0.0))
	return sum


func _legends() -> void:
	var L: Dictionary = DmSimData.LEGEND
	var burst := bonus("legion_unburied", "thrallDeathBurst")
	var every := int(bonus("legion_unburied", "championEvery"))
	var rally := bonus("legion_unburied", "spearRally")
	# --- the feed: wearing / stripping a set reaches the caster and the legion on every change
	reset()
	check(DmLegend.sim_legend_active(caster.legend) == false and legion().legend.get("championEvery", 0.0) == 0.0, "C: no set, no legend")
	await wear("legion_unburied")
	check(burst > 0.0 and every > 0 and rally > 0.0, "C: the data's Legion of the Unburied grants a death burst, a champion and a rally")
	check(float(caster.mods["thrallDeathBurst"]) == burst and float(caster.mods["championEvery"]) == float(every) and float(caster.mods["spearRally"]) == rally, "C: Legion of the Unburied reaches the caster's mods (%s)" % str({"b": caster.mods["thrallDeathBurst"], "c": caster.mods["championEvery"], "s": caster.mods["spearRally"]}))
	check(float(caster.legend["thrallDeathBurst"]) == burst and float(legion().legend["thrallDeathBurst"]) == burst and float(legion().legend["championEvery"]) == float(every) and float(legion().legend["spearRally"]) == rally, "C: ...and the legion's legend follows the gear change (%s)" % str(legion().legend))
	await strip()
	check(not DmLegend.sim_legend_active(legion().legend) and float(caster.mods["championEvery"]) == 0.0, "C: stripping it clears the legend again")
	await wear("legion_unburied")
	check(float(legion().legend["championEvery"]) == float(every), "C: and wearing it again restores it")

	# thrallDeathBurst: a thrall that dies bursts for x its max hp on enemies within deathBurstR; living thralls pick up a legend change
	reset()
	await wear("legion_unburied")
	raise_at(Vector3(0, 0, -24))
	await ticks(2)
	var t0 := legion().list()[0]
	var i0: Dictionary = legion().info(t0)
	check(near(float(i0["death_burst_frac"]), burst, 0.001), "C: thrallDeathBurst reaches the raised thrall (%.2f)" % float(i0["death_burst_frac"]))
	var tp := Vector3(i0["pos"].x, 0.0, i0["pos"].y)
	var max_hp := float(i0["max_hp"])
	var victim := foe(tp + Vector3(float(L["deathBurstR"]) * 0.5, 0, 0))
	var outside := foe(tp + Vector3(float(L["deathBurstR"]) + 3.0, 0, 0))
	core.kill_thrall(t0, "killed")
	await ticks(3)
	check(near(loss(victim), burst * max_hp, 1.0) and loss(outside) == 0.0, "C: thrallDeathBurst - a dying thrall bursts for %.1f x its max hp within %.0f m (%.1f of %.1f)" % [burst, float(L["deathBurstR"]), loss(victim), burst * max_hp])
	await strip()
	raise_at(Vector3(0, 0, -24))
	await ticks(2)
	check(float(legion().info(legion().list()[0])["death_burst_frac"]) == 0.0, "C: without the set a thrall leaves no burst")

	# championEvery: every Nth thrall raised is a champion (x hp, x damage)
	reset()
	await wear("legion_unburied")
	var champs := 0
	for k in every:
		corpse(Vector3(0.5 * k, 0, -24))
	for k in every:
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("exhume", Vector3(0.5 * k, 0, -24), -1)
		await secs(0.7)
	var ts := legion().list()
	var ordinary := 0
	var champion := 0
	for t in ts:
		if bool(legion().info(t)["champion"]):
			champs += 1
			champion = t
		elif ordinary == 0:
			ordinary = t
	check(ts.size() == every and champs == 1 and champion != 0 and ordinary != 0, "C: championEvery %d - the %dth raised is the one champion (%d thralls, %d champions)" % [every, every, ts.size(), champs])
	if champion != 0 and ordinary != 0:
		check(near(float(legion().info(champion)["max_hp"]) / float(legion().info(ordinary)["max_hp"]), float(L["championHp"]), 0.01), "C: ...with x%.0f hp (%.0f vs %.0f)" % [float(L["championHp"]), float(legion().info(champion)["max_hp"]), float(legion().info(ordinary)["max_hp"])])

	# spearRally: a spear hit marks the nearest enemy; the legion turns on it and hits harder
	reset()
	var tgt := foe(Vector3(0, 0, -26))
	var other := foe(Vector3(12, 0, -26))
	var th1 := raise_at(Vector3(0, 0, -20))
	await until(func() -> bool: return int(legion().info(th1)["state"]) != 0, 4.0)
	caster.request_cast("marrow_spear", Vector3(0, 0, -26), -1)
	await secs(1.0)
	var ti: Dictionary = legion().info(th1)
	check(int(ti["target"]) == tgt and near(float(ti["mark_mult"]), 1.0 + float(caster.mods["spearRally"]), 0.001), "C: spearRally - the legion turns on the marked enemy at x%.1f (mark %.2f)" % [1.0 + float(caster.mods["spearRally"]), float(ti["mark_mult"])])
	await strip()
	check(float(caster.mods["spearRally"]) == 0.0, "C: ...and the mod leaves with the set")

	await _plague_choir()
	await _colossus_mantle()
	await _requiem_wraiths()
	await strip()


func _plague_choir() -> void:
	var L: Dictionary = DmSimData.LEGEND
	reset()
	await wear("plague_choir")
	var spreads := bonus("plague_choir", "miasmaSpreadsWithered")
	var burst_at := int(bonus("plague_choir", "witheredBurstAt"))
	check(spreads > 0.0 and burst_at > 1 and float(caster.legend["miasmaSpreadsWithered"]) == spreads and float(caster.legend["witheredBurstAt"]) == float(burst_at), "C: Plague Choir reaches the caster's legend (%s)" % str(caster.legend))
	# miasmaSpreadsWithered: an enemy that dies withered inside the circle spreads its stacks to the 3 nearest within 4 m
	var a := foe(Vector3(0, 0, -28))
	var n1 := foe(Vector3(float(L["spreadR"]) * 0.5, 0, -28))
	var n2 := foe(Vector3(-float(L["spreadR"]) * 0.5, 0, -28))
	var far := foe(Vector3(0, 0, -28.0 - float(L["spreadR"]) * 2.0))
	caster.request_cast("miasma", Vector3(0, 0, -27), -1)
	await secs(3.2)
	var stacks := stacks_of(a, &"withered")
	check(stacks >= 2, "C: the circle withered it (%d stacks)" % stacks)
	core.remove_status(n1, &"withered")
	core.remove_status(n2, &"withered")
	core.damage(a, 1e9, hero.core_id)
	await ticks(3)
	var s1 := stacks_of(n1, &"withered")
	check(s1 >= stacks and stacks_of(n2, &"withered") >= stacks and stacks_of(far, &"withered") == 0, "C: miasmaSpreadsWithered - its %d stacks pass to the neighbours within %.0f m (%d / %d), not to a far one" % [stacks, float(L["spreadR"]), s1, stacks_of(n2, &"withered")])
	check(evs("miasma", "legend").any(func(h: Dictionary) -> bool: return h["ev"]["kind"] == "spread"), "C: the spread is drawn")
	# witheredBurstAt: an enemy reaching the threshold loses its stacks and a fresh circle opens on it
	reset()
	var zones: Array = caster.mem("miasma").get_or_add("zones", [])
	var big := foe(Vector3(0, 0, -28))
	caster.request_cast("miasma", Vector3(0, 0, -27), -1)
	await secs(1.4)
	check(not caster.mem("miasma").get("last", {}).is_empty(), "C: the cast is remembered for Chain Plague")
	caster.apply_status(big, &"withered", burst_at - 1, -1.0, {"dps": 1.0, "cap": float(burst_at)})
	var before := zones.size()
	await secs(1.3)
	var plague := zones.filter(func(z: Dictionary) -> bool: return z["plague"])
	check(plague.size() >= 1 and stacks_of(big, &"withered") < burst_at, "C: witheredBurstAt - %d stacks burst into a fresh circle (%d plague circles, %d stacks left)" % [burst_at, plague.size(), stacks_of(big, &"withered")])
	check(plague.size() <= int(L["burstClouds"]) and evs("miasma", "legend").any(func(h: Dictionary) -> bool: return h["ev"]["kind"] == "plague"), "C: ...at most %d at once, and it is drawn" % int(L["burstClouds"]))
	await strip()
	check(float(caster.legend["witheredBurstAt"]) == 0.0, "C: Plague Choir leaves with the set")


func _colossus_mantle() -> void:
	var L: Dictionary = DmSimData.LEGEND
	reset()
	var plain := hero.take_damage(20.0, null)
	hero.heal(1e6)
	await wear("colossus_mantle")
	var guard := bonus("colossus_mantle", "colossusGuard")
	var reflect := bonus("colossus_mantle", "wardReflect")
	var shatter := bonus("colossus_mantle", "litanyShatter")
	check(guard > 0.0 and reflect > 0.0 and shatter > 0.0 and float(caster.mods["colossusGuard"]) == guard and float(caster.mods["wardReflect"]) == reflect and float(caster.mods["litanyShatter"]) == shatter, "C: Colossus Mantle reaches the mods (%s)" % str({"g": caster.mods["colossusGuard"], "r": caster.mods["wardReflect"], "s": caster.mods["litanyShatter"]}))
	check(hero._legend_hurt, "C: ...and arms the hit hook")
	# colossusGuard: enough thralls = that much less damage taken (a Gravecaller has no ward per thrall, so nothing else moves the number)
	var spec := {"kind": "warrior", "cap": 8.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0, "r": 0.8}
	hero.heal(1e6)
	var one := hero.take_damage(20.0, null)
	hero.heal(1e6)
	for k in int(L["colossusThralls"]):
		raise_at(hero.global_position + Vector3(2 + k, 0, 0), spec)
	await ticks(2)
	var three := hero.take_damage(20.0, null)
	check(legion().count() >= int(L["colossusThralls"]) and near(three, one * (1.0 - float(caster.mods["colossusGuard"])), 0.2) and near(plain, one, 0.2), "C: colossusGuard - %d thralls cut a blow to %.0f%% (%.1f -> %.1f)" % [legion().count(), 100.0 * three / maxf(one, 0.001), one, three])
	# wardReflect: the share Bone Ward turned is dealt back at the attacker. A Gravecaller has no ward per thrall, so grant it for the test
	hero.heal(1e6)
	var striker := foe(hero.position + Vector3(1.2, 0, 0))
	var saved_mods := hero.mods
	hero.mods = hero.mods.duplicate()
	hero.mods["wardPerThrall"] = 0.2
	var ward := minf(float(DmLegend.L()["wardCap"]), 0.2 * float(legion().count()))
	hits.clear()
	hero.take_damage(20.0, striker)
	check(loss(striker) > 0.0 and near(loss(striker), DmLegend.ward_reflect_damage(20.0, ward, reflect), 0.2), "C: wardReflect - the ward's share goes back at the attacker (%.2f, want %.2f)" % [loss(striker), DmLegend.ward_reflect_damage(20.0, ward, reflect)])
	check(evs("black_litany", "reflect").size() == 1, "C: ...and is drawn once")
	hero.mods = saved_mods
	# litanyShatter: a broken Litany barrier bursts around you for a multiple of its size
	hero.heal(1e6)
	var near_foe := foe(hero.position + Vector3(float(L["shatterR"]) * 0.6, 0, 0))
	var far_foe := foe(hero.position + Vector3(float(L["shatterR"]) + 3.0, 0, 0))
	hero.p["barrier"] = 10.0
	hero.p["barrierPeak"] = 10.0
	hits.clear()
	hero.take_damage(30.0, null)
	check(near(loss(near_foe), shatter * 10.0, 0.5) and loss(far_foe) == 0.0 and evs("black_litany", "shatter").size() == 1, "C: litanyShatter - the broken barrier (10) bursts for %.0f within %.0f m, drawn once (%.1f)" % [shatter * 10.0, float(L["shatterR"]), loss(near_foe)])
	await strip()
	check(float(caster.mods["colossusGuard"]) == 0.0 and not hero._legend_hurt, "C: Colossus Mantle leaves with the set (no hit hook left)")
	hero.heal(1e6)
	check(near(hero.take_damage(20.0, null), plain, 0.2), "C: ...and blows cost full again")


func _requiem_wraiths() -> void:
	var L: Dictionary = DmSimData.LEGEND
	reset()
	await wear("requiem_wraiths")
	var wisp := bonus("requiem_wraiths", "corpseWisp")
	var nova_mult := bonus("requiem_wraiths", "wraithNova")
	check(wisp > 0.0 and nova_mult > 0.0 and float(caster.mods["corpseWisp"]) == wisp and float(caster.mods["wraithNova"]) == nova_mult, "C: Requiem Wraiths reaches the mods (%s)" % str({"w": caster.mods["corpseWisp"], "n": caster.mods["wraithNova"]}))
	# corpseWisp: a corpse of yours consumed raises a healing wisp (up to the cap), each heals a share of max hp a second
	var wisp_cap := int(L["wispCap"])
	var corpses := wisp_cap + 2   # (two more than the wisps can be)
	for k in corpses:
		corpse(Vector3(0.6 * k, 0, -24))
	hero.p["hp"] = float(hero.p["stats"]["maxHp"]) * 0.3
	hero._mirror_from_state()
	var hp0 := float(hero.p["hp"])
	for k in corpses:
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("exhume", Vector3(0.6 * k, 0, -24), -1)
		await secs(0.6)
	var legends: DmRiteLegends = caster._legends
	check(legends != null and legends.wisps.size() == int(L["wispCap"]), "C: corpseWisp - consuming corpses raises wisps up to the cap of %d (%d)" % [int(L["wispCap"]), legends.wisps.size() if legends != null else -1])
	check(evs("black_litany", "wisp").size() == int(L["wispCap"]), "C: each wisp is drawn once (%d)" % evs("black_litany", "wisp").size())
	var heal_before := float(hero.p["hp"])
	await secs(2.1)
	var healed := float(hero.p["hp"]) - heal_before
	var mh := float(hero.p["stats"]["maxHp"])
	check(healed >= 0.9 * 2.0 * float(wisp_cap) * mh * float(L["wispHealFrac"]) and healed < 3.0 * 2.0 * float(wisp_cap) * mh * float(L["wispHealFrac"]), "C: ...each healing %.0f%% of max hp a second (%.0f in 2 s with %d wisps)" % [float(L["wispHealFrac"]) * 100.0, healed, wisp_cap])
	# wraithNova: a Soul Harvest cast makes every wisp and wraith release a nova
	var e1 := foe(hero.position + Vector3(float(L["novaR"]) * 0.8, 0, 0.0))    # off the spear's line, inside a wisp's nova
	var e2 := foe(hero.position + Vector3(float(L["novaR"]) + 9.0, 0, 0.0))
	hero.p["souls"] = hero.p["soulsMax"]
	check(DmAbilities.empowered(caster.p, "marrow_spear"), "C: (Soul Harvest is charged)")
	hits.clear()
	caster.request_cast("marrow_spear", Vector3(0, 0, -30), -1)
	await secs(0.5)
	var novas := evs("black_litany", "nova")
	check(novas.size() == 1 and (novas[0]["ev"]["pts"] as Array).size() >= 1, "C: wraithNova - an empowered cast sets the wisps off (%d nova event)" % novas.size())
	var nova_amt := float(novas[0]["ev"]["amount"]) if not novas.is_empty() else 1e9
	if not novas.is_empty():
		var nova_dmg := float(novas[0]["ev"]["amount"])
		check(near(nova_dmg, DmAbilities.sp(caster.p, caster.now_ms) * nova_mult, nova_dmg * 0.02), "C: ...for spell power x %.1f (%.1f)" % [nova_mult, nova_dmg])
	check(loss(e1) >= nova_amt * 0.99 and loss(e2) == 0.0, "C: ...hitting what stands within %.0f m of a wisp (%.1f / %.1f)" % [float(L["novaR"]), loss(e1), loss(e2)])
	await strip()
	check(float(caster.mods["corpseWisp"]) == 0.0, "C: Requiem Wraiths leaves with the set")

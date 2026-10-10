extends SceneTree
## Rune variants and legendary-set mechanics on the rebuild (godot/next/rites, thralls, hero). godot --headless --path godot --script res://tests/next_runes/run.gd
##   A  every rune the data defines has a gameplay test below (table-driven: the table keys must equal DmRunes' ids), each proving its effect against the same cast without it
##   B  Grimoire rune picks: the bag -> the Grimoire panel shows them, socketing through the panel's own path reaches the caster, taking one out removes it
##   C  worn legendary sets feed the legion + caster on every gear change (and strip again), and every legend mod that exists in the data does its job
##   D  Bonded Dead still raises on area entry (tests/next_meta owns the full proof; here it runs with a worn legend)
##   E  cost: per-frame cost with a creeping/contagion circle + volley casts, and a gear change

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var hero: DmHeroBody
var caster: DmRiteCaster
var th: DmThrallHost
var mock: DmMockBackend
var cid := 0
var _ids := 0
var foes: Array = []
var hits: Array = []   ## [{rite, t, ev}] every event the caster played since reset


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


## A brain-off, soaking enemy (no nav, stands still) registered with the director like a spawned one.
func foe(at: Vector3, def_id := "robber") -> DmEnemy:
	var e: DmEnemy = load("res://enemies/%s.tscn" % def_id).instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.def_id = def_id
	e.hp_mult = 1000.0
	e.position = at
	g.add_child(e)
	e.set_physics_process(false)
	DmStatusSet.attach(e)
	_ids += 1
	var key := 9000 + _ids
	e.set_meta(&"dm_id", key)
	g.director.enemies[key] = e
	e.tree_exiting.connect(func() -> void: g.director.enemies.erase(key))
	foes.append(e)
	return e


func eid(e: DmEnemy) -> int:
	return int(e.get_meta(&"dm_id"))


func loss(e: DmEnemy) -> float:
	return e.max_hp - e.hp


func corpse(at: Vector3, kind := "normal") -> DmSimCorpse:
	return g.corpses.add_corpse(at.x, at.z, kind, "robber", false, 0.0, 1.0, g.area_of(1))


func clear_world() -> void:
	for e: DmEnemy in foes:
		if is_instance_valid(e):
			e.queue_free()
	foes.clear()
	for c: DmSimCorpse in g.corpses.corpses_in_radius(Vector3.ZERO, 1000.0, Callable(), "", true):
		g.corpses.consume(c.id, 1, "consumed")
	th.clear()
	var zs: Array = caster.mem("miasma").get("zones", [])
	zs.clear()
	caster.mem("bone_needle").clear()


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
	await g.start((await api.load_or_create_character(0)).data, api, {"dressing": false, "persist": false, "waves": false, "audio": false})
	hero = g.local_body()
	await ticks(3)
	caster = hero.get_node("Rites") as DmRiteCaster
	th = hero.get_node("Thralls") as DmThrallHost
	caster.p["stats"]["level"] = 60.0
	caster.random = func() -> float: return 0.5   # jitter 1.0, no crit: damage is exact
	caster.event_played.connect(func(ev: Dictionary) -> void: hits.append({"rite": String(ev["rite"]), "t": String(ev["t"]), "ev": ev}))
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
	var want: Array = DmCombatData.abilities()["rune_ids"].duplicate()
	var have: Array = cases.keys()
	want.sort()
	have.sort()
	check(want == have, "A: the table covers exactly the runes the data defines (%s)" % str(want))
	for rid: String in cases:
		await (cases[rid] as Callable).call(rid)

	# =================================================================== B: the Grimoire's rune picks
	await _grimoire()

	# =================================================================== C: legendary mods
	await _legends()

	# =================================================================== D: Bonded Dead, E: cost
	await _bonded()
	await _cost()

	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------------------------------------------------------------------- runes

func _rite_of(rid: String) -> String:
	return String(DmCombatData.abilities()["runes"][rid]["rite"])


func _rune_splinter(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base := 0.0
	for with_rune in [false, true]:
		reset("bone_needle", rid if with_rune else "")
		var e1 := foe(Vector3(0, 0, -26))
		var e2 := foe(Vector3(4, 0, -26))
		var far := foe(Vector3(12, 0, -26))
		caster.request_cast("bone_needle", e1.position, eid(e1))
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
		caster.request_cast("bone_needle", e1.position, eid(e1))
		await until(func() -> bool: return loss(e1) > 0.0, 2.0)
		res[with_rune] = [loss(e1), float(caster.p["resource"]["value"])]
		print("marrow tap probe: with=%s loss=%.2f essence=%.2f max=%.1f" % [with_rune, loss(e1), float(caster.p["resource"]["value"]), float(caster.p["resource"]["max"])])
	check(near(res[true][0], res[false][0] * float(T["marrowTap"]["damageMult"]), 0.01), "%s: the needle hits for x%.1f (%.1f vs %.1f)" % [rid, float(T["marrowTap"]["damageMult"]), res[true][0], res[false][0]])
	check(near(res[true][1] - res[false][1], float(T["marrowTap"]["essenceBonus"]), 1.0), "%s: and returns %d more essence (%.1f vs %.1f)" % [rid, int(T["marrowTap"]["essenceBonus"]), res[true][1], res[false][1]])


func _rune_volley(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var every := int(T["volley"]["every"])
	reset("bone_needle", rid)
	var a := foe(Vector3(0, 0, -26))
	var b := foe(Vector3(3, 0, -26))
	var c2 := foe(Vector3(-3, 0, -26))
	var single := 0.0
	caster.request_cast("bone_needle", a.position, eid(a))
	await secs(0.9)
	single = loss(a)
	check(single > 0.0 and loss(b) == 0.0 and evs("bone_needle", "hit").size() == 1, "%s: needles 1-%d are single shots (%.1f, %.1f, %d hit events, cd %s)" % [rid, every - 1, single, loss(b), evs("bone_needle", "hit").size(), str(caster.p["cooldowns"])])
	for i in range(2, every):
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("bone_needle", a.position, eid(a))
		await secs(0.9)
	for e in [a, b, c2]:
		e.hp = e.max_hp
	hits.clear()
	caster.p["resource"]["value"] = 0.0
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.request_cast("bone_needle", a.position, eid(a))
	await until(func() -> bool: return evs("bone_needle", "hit").size() >= 3, 2.0)
	var each := loss(a)
	check(near(each, single * float(T["volley"]["damageFrac"]), 0.01) and near(loss(b), each, 0.01) and near(loss(c2), each, 0.01), "%s: needle %d is a volley of %d at x%.1f, each at a different enemy (%.1f / %.1f / %.1f)" % [rid, every, int(T["volley"]["needles"]), float(T["volley"]["damageFrac"]), loss(a), loss(b), loss(c2)])
	check(evs("bone_needle", "hit").size() == int(T["volley"]["needles"]), "%s: three hits land (%d)" % [rid, evs("bone_needle", "hit").size()])
	var got := float(caster.p["resource"]["value"])   # one needle's 6 (+ ~3 a second of regen), not three needles' 18
	check(got >= 5.5 and got <= 10.0, "%s: the volley returns the essence of ONE needle (%.1f)" % [rid, got])
	var leads := evs("bone_needle", "cast").filter(func(h: Dictionary) -> bool: return bool(h["ev"].get("lead", true)))
	check(leads.size() == 1 and evs("bone_needle", "cast").size() == 3, "%s: one muzzle burst, three shots" % rid)
	# alone: all three needles go to the single enemy
	reset("bone_needle", rid)
	var solo := foe(Vector3(0, 0, -26))
	for i in every:
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("bone_needle", solo.position, eid(solo))
		await secs(0.9)
	check(evs("bone_needle", "hit").size() == every - 1 + int(T["volley"]["needles"]), "%s: a volley at a lone enemy sends all %d at it (%d hits in %d casts)" % [rid, int(T["volley"]["needles"]), evs("bone_needle", "hit").size(), every])


func _rune_ring(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base := 0.0
	for with_rune in [false, true]:
		reset("marrow_spear", rid if with_rune else "")
		var on_line := foe(Vector3(0, 0, -26))
		var beside := foe(Vector3(2.4, 0, -26))
		var beyond := foe(Vector3(0, 0, -29.9))
		caster.request_cast("marrow_spear", Vector3(0, 0, -26), -1)
		await secs(1.2)
		if not with_rune:
			base = loss(on_line)
			check(base > 0.0 and loss(beside) == 0.0 and loss(beyond) > 0.0, "%s: without it the spear is a line (%.1f; beside %.1f; beyond %.1f)" % [rid, base, loss(beside), loss(beyond)])
		else:
			check(loss(on_line) > 0.0 and loss(beside) > 0.0 and near(loss(beside), base * float(T["ring"]["damageMult"]), 0.01), "%s: the ring at the cursor strikes everything inside %.0f m for x%.1f (%.1f)" % [rid, float(T["ring"]["radius"]), float(T["ring"]["damageMult"]), loss(beside)])
			check(loss(beyond) == 0.0 and evs("marrow_spear", "ring").size() == 1, "%s: ...and no longer reaches down the line" % rid)


func _rune_impale(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base := 0.0
	for with_rune in [false, true]:
		reset("marrow_spear", rid if with_rune else "")
		var e1 := foe(Vector3(0, 0, -24))
		var e2 := foe(Vector3(0, 0, -29))
		caster.request_cast("marrow_spear", e2.position, -1)
		await secs(1.2)
		if not with_rune:
			base = loss(e1)
			check(loss(e2) > 0.0 and not DmStatusSet.of(e1).has(&"root"), "%s: without it the spear pierces the line and roots nobody" % rid)
		else:
			check(loss(e2) == 0.0 and DmStatusSet.of(e1).has(&"root") and near(loss(e1), base * float(T["impale"]["damageMult"]), 0.01), "%s: only the first enemy, x%.1f, rooted %.1f s (%.1f)" % [rid, float(T["impale"]["damageMult"]), float(T["impale"]["rootS"]), loss(e1)])


func _rune_mass_grave(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base_hp := 0.0
	for with_rune in [false, true]:
		reset("exhume", rid if with_rune else "")
		for k in 4:
			corpse(Vector3(1.5 * k, 0, -24))
		caster.request_cast("exhume", Vector3(0, 0, -24), -1)
		await secs(1.0)
		if not with_rune:
			base_hp = th.list()[0].max_hp if th.count() > 0 else 0.0
			check(th.count() == 1 and base_hp > 0.0, "%s: without it Exhume raises one thrall" % rid)
		else:
			var hp: float = th.list()[0].max_hp if th.count() > 0 else 0.0
			check(th.count() == int(T["massGrave"]["count"]) and near(hp, base_hp * float(T["massGrave"]["statMult"]), 0.01), "%s: it raises %d at x%.2f the stats (%d thralls, hp %.0f vs %.0f)" % [rid, int(T["massGrave"]["count"]), float(T["massGrave"]["statMult"]), th.count(), hp, base_hp])
			check(g.corpses.corpses_in_radius(Vector3(0, 0, -24), 20.0).size() == 1, "%s: ...each from its own corpse (1 of 4 left)" % rid)


func _rune_colossus(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	reset("exhume", rid)
	for k in 5:
		corpse(Vector3(0.8 * k, 0, -24))
	caster.request_cast("exhume", Vector3(0, 0, -24), -1)
	await ticks(3)
	var cd_after := caster.cooldown_left("exhume")
	await secs(1.0)
	var ts := th.list()
	check(ts.size() == 1 and ts[0].kind == "colossus", "%s: five corpses become one Colossus (%d thralls)" % [rid, ts.size()])
	check(g.corpses.corpses_in_radius(Vector3(0, 0, -24), 20.0).size() == 0, "%s: all five are spent" % rid)
	check(near(cd_after, float(DmAbilities.def("exhume")["cooldownMs"]) * float(T["colossus"]["cooldownMult"]), 150.0), "%s: and Exhume rests x%d as long (%.0f ms)" % [rid, int(T["colossus"]["cooldownMult"]), caster.cooldown_left("exhume")])
	# too few corpses: a plain thrall, as without the rune
	reset("exhume", rid)
	corpse(Vector3(0, 0, -24))
	corpse(Vector3(1, 0, -24))
	caster.request_cast("exhume", Vector3(0, 0, -24), -1)
	await secs(1.0)
	check(th.count() == 1 and th.list()[0].kind != "colossus", "%s: with fewer than %d corpses it raises an ordinary thrall" % [rid, int(T["colossus"]["minCorpses"])])


func _rune_creeping(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var base_r := 0.0
	for with_rune in [false, true]:
		reset("miasma", rid if with_rune else "")
		var e := foe(Vector3(0, 0, -36))
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
			check(moved > 1.5 and moved < 4.0 and near(float(z["x"]), 0.0, 0.01), "%s: it drifts toward the nearest enemy at %.1f m/s (%.2f m in 2 s)" % [rid, float(T["creepingRot"]["speed"]), moved])
			check(evs("miasma", "move").size() >= 2 and evs("miasma", "land")[0]["ev"]["creep"] > 0.0, "%s: the other peers are told where it walks (%d move events)" % [rid, evs("miasma", "move").size()])
			check(evs("miasma", "move").size() <= 8, "%s: ...at a few a second, not every tick (%d)" % [rid, evs("miasma", "move").size()])


func _rune_contagion(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	for with_rune in [false, true]:
		reset("miasma", rid if with_rune else "")
		var a := foe(Vector3(0, 0, -28))
		var b := foe(Vector3(3.0, 0, -28))
		var far := foe(Vector3(9, 0, -28))
		caster.request_cast("miasma", Vector3(0, 0, -27), -1)
		await secs(2.8)
		var sa := DmStatusSet.of(a)
		check(sa.stacks(&"withered") >= int(T["contagion"]["minStacks"]), "%s: the circle withered its victim (%d stacks)" % [rid, sa.stacks(&"withered")])
		var stacks := sa.stacks(&"withered")
		DmStatusSet.of(b).clear()
		a.take_damage(1e9, hero)
		await ticks(3)
		var sb := DmStatusSet.of(b)
		if with_rune:
			check(sb.stacks(&"withered") == stacks - 1 and DmStatusSet.of(far).stacks(&"withered") == 0, "%s: its death hands %d stacks to a neighbour within %.1f m, not to a far one (%d)" % [rid, stacks - 1, float(T["contagion"]["reach"]), sb.stacks(&"withered")])
			check(b.has_meta(&"dm_contagious") and evs("miasma", "contagion").size() >= 1, "%s: the neighbour carries it on and a thread is drawn" % rid)
		else:
			check(sb.stacks(&"withered") <= 1, "%s: without it the stacks die with the enemy (%d)" % [rid, sb.stacks(&"withered")])


func _rune_hollow(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var spec := {"kind": "warrior", "cap": 4.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0}
	var base := 0.0
	for with_rune in [false, true]:
		reset("black_litany", rid if with_rune else "")
		var e := foe(Vector3(0, 0, -21))
		corpse(Vector3(1, 0, -19))
		th.raise_bonded(spec)
		await ticks(2)
		caster.request_cast("black_litany", Vector3.ZERO)
		await secs(0.5)
		if not with_rune:
			base = loss(e)
			check(th.count() == 0 and base > 0.0, "%s: without it the litany sacrifices the legion" % rid)
		else:
			check(th.count() == 1, "%s: it spares the thralls" % rid)
			var want := DmAbilities.litany_damage(DmAbilities.litany_spell_power(DmAbilities.sp(caster.p, caster.now_ms), rid), 1, 0, 1)
			check(near(loss(e), want, want * 0.02) and base > loss(e), "%s: at x%.1f spell power (%.1f vs %.1f without)" % [rid, float(T["hollowChoir"]["powerMult"]), loss(e), base])


func _rune_requiem(rid: String) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING
	var near_e := Vector3(0, 0, -21)   # 3 m: inside both radii
	var mid_e := Vector3(7.8, 0, -18)  # between the plain 7 m and the widened 7 x 1.7 m
	var plain_r := float(DmAbilities.def("black_litany")["radius"])
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
	var owned: Dictionary = DmRunes.owned_runes(g.ui_host.inventory.slots)
	check(owned.size() == 11, "B: the panel is fed the bag's %d runes" % owned.size())
	var err: String = await g.ui.inv.socket_rune_id("bone_needle", "rune_volley")   # what the Grimoire's rune button calls
	check(err == "", "B: socketing Volley through the panel's path works (%s)" % err)
	check(DmAbilities.rune(caster.p, "bone_needle") == "rune_volley" and g.rite_build(1)["runes"].get("bone_needle") == "rune_volley", "B: the caster holds it at once (%s)" % str(caster.p["runes"]))
	err = await g.ui.inv.socket_rune_id("black_litany", "rune_requiem")
	check(DmAbilities.rune(caster.p, "black_litany") == "rune_requiem" and caster.p["runes"].size() == 2, "B: a second rite takes its own rune")
	err = await g.ui.inv.socket_rune_id("bone_needle", "rune_splinter")   # swap: Volley returns to the bag
	check(DmAbilities.rune(caster.p, "bone_needle") == "rune_splinter" and DmRunes.owned_runes(g.ui_host.inventory.slots).get("rune_volley", 0) == 1, "B: swapping replaces it and the old rune goes back to the bag")
	err = await g.ui.inv.socket_rune_id("black_litany", "")   # take it out
	check(DmAbilities.rune(caster.p, "black_litany") == "" and not caster.p["runes"].has("black_litany"), "B: taking a rune out removes it from the caster")
	err = await g.ui.inv.socket_rune_id("exhume", "rune_volley")
	check(err != "" and DmAbilities.rune(caster.p, "exhume") == "", "B: a rune that does not fit the rite is refused (%s)" % err)
	# the picks survive a level-up / gear refresh (rite_build reads the bag again)
	g.progress.refresh_stats()
	check(DmAbilities.rune(caster.p, "bone_needle") == "rune_splinter", "B: a stats refresh keeps the pick")
	g.ui.close_panels()
	# put the bag back
	await g.ui.inv.socket_rune_id("bone_needle", "")
	check(caster.p["runes"].is_empty(), "B: everything taken out again")


# ---------------------------------------------------------------------------------------------------------------------------- legends

func _legends() -> void:
	var L: Dictionary = DmSimData.LEGEND
	# --- the feed: wearing / stripping a set reaches the caster and the legion on every change
	reset()
	check(DmLegend.sim_legend_active(caster.legend) == false and th.legend.get("championEvery", 0.0) == 0.0, "C: no set, no legend")
	await wear("legion_unburied")
	check(float(caster.mods["thrallDeathBurst"]) == 0.8 and float(caster.mods["championEvery"]) == 4.0 and float(caster.mods["spearRally"]) == 1.0, "C: Legion of the Unburied reaches the caster's mods (%s)" % str({"b": caster.mods["thrallDeathBurst"], "c": caster.mods["championEvery"], "r": caster.mods["spearRally"]}))
	check(float(caster.legend["thrallDeathBurst"]) == 0.8 and float(th.legend["thrallDeathBurst"]) == 0.8 and float(th.legend["championEvery"]) == 4.0 and float(th.legend["spearRally"]) == 1.0, "C: ...and DmThrallHost.legend follows the gear change (%s)" % str(th.legend))
	await strip()
	check(not DmLegend.sim_legend_active(th.legend) and float(caster.mods["championEvery"]) == 0.0, "C: stripping it clears the legend again")
	await wear("legion_unburied")
	check(float(th.legend["championEvery"]) == 4.0, "C: and wearing it again restores it")

	# thrallDeathBurst: a thrall that dies bursts for x its max hp on enemies within deathBurstR; living thralls pick up a legend change
	reset()
	await wear("legion_unburied")
	th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0})
	await ticks(2)
	var t0: DmThrall = th.list()[0]
	check(near(t0.death_burst_frac, 0.8, 0.001), "C: thrallDeathBurst reaches the raised thrall (%.2f)" % t0.death_burst_frac)
	var tp := t0.global_position
	var victim := foe(tp + Vector3(1.5, 0, 0))
	var outside := foe(tp + Vector3(float(L["deathBurstR"]) + 3.0, 0, 0))
	t0.kill("killed")
	await ticks(3)
	check(near(loss(victim), 0.8 * t0.max_hp, 1.0) and loss(outside) == 0.0, "C: thrallDeathBurst - a dying thrall bursts for 0.8 x its max hp within %.0f m (%.1f of %.1f)" % [float(L["deathBurstR"]), loss(victim), 0.8 * t0.max_hp])
	await strip()
	th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0})
	await ticks(2)
	check(th.list()[0].death_burst_frac == 0.0, "C: without the set a thrall leaves no burst")

	# championEvery: every 4th thrall raised is a champion (x hp, x damage)
	reset()
	await wear("legion_unburied")
	var champs := 0
	var base_hp := 0.0
	for k in 4:
		corpse(Vector3(0.5 * k, 0, -24))
	for k in 4:
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("exhume", Vector3(0.5 * k, 0, -24), -1)
		await secs(0.7)
	var ts := th.list()
	for t: DmThrall in ts:
		if t.champion:
			champs += 1
			check(near(t.max_hp, 0.0, 1e9), "C: (champion seen)")
	var ordinary: DmThrall = null
	var champion: DmThrall = null
	for t: DmThrall in ts:
		if t.champion:
			champion = t
		elif ordinary == null:
			ordinary = t
	check(ts.size() == 4 and champs == 1 and champion != null and ordinary != null, "C: championEvery 4 - the 4th raised is the one champion (%d thralls, %d champions)" % [ts.size(), champs])
	if champion != null and ordinary != null:
		check(near(champion.max_hp / ordinary.max_hp, float(L["championHp"]), 0.01), "C: ...with x%.0f hp (%.0f vs %.0f)" % [float(L["championHp"]), champion.max_hp, ordinary.max_hp])

	# spearRally: a spear hit marks the nearest enemy; the legion turns on it and hits harder
	reset()
	var tgt := foe(Vector3(0, 0, -26))
	var other := foe(Vector3(12, 0, -26))
	th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0})
	await until(func() -> bool: return th.list()[0].state != DmThrall.S.RISING, 4.0)
	caster.request_cast("marrow_spear", Vector3(0, 0, -26), -1)
	await secs(1.0)
	var tt: DmThrall = th.list()[0]
	check(tt.target == tgt and near(tt.mark_mult, 1.0 + float(caster.mods["spearRally"]), 0.001), "C: spearRally - the legion turns on the marked enemy at x%.1f (mark %.2f)" % [1.0 + float(caster.mods["spearRally"]), tt.mark_mult])
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
	check(float(caster.legend["miasmaSpreadsWithered"]) == 1.0 and float(caster.legend["witheredBurstAt"]) == 8.0, "C: Plague Choir reaches the caster's legend (%s)" % str(caster.legend))
	# miasmaSpreadsWithered: an enemy that dies withered inside the circle spreads its stacks to the 3 nearest within 4 m
	var a := foe(Vector3(0, 0, -28))
	var n1 := foe(Vector3(2, 0, -28))
	var n2 := foe(Vector3(-2, 0, -28))
	var far := foe(Vector3(0, 0, -36))
	caster.request_cast("miasma", Vector3(0, 0, -27), -1)
	await secs(3.2)
	var stacks := DmStatusSet.of(a).stacks(&"withered")
	check(stacks >= 2, "C: the circle withered it (%d stacks)" % stacks)
	DmStatusSet.of(n1).clear()
	DmStatusSet.of(n2).clear()
	a.take_damage(1e9, hero)
	await ticks(3)
	var s1 := DmStatusSet.of(n1).stacks(&"withered")
	check(s1 >= stacks and DmStatusSet.of(n2).stacks(&"withered") >= stacks and DmStatusSet.of(far).stacks(&"withered") == 0, "C: miasmaSpreadsWithered - its %d stacks pass to the neighbours within %.0f m (%d / %d), not to a far one" % [stacks, float(L["spreadR"]), s1, DmStatusSet.of(n2).stacks(&"withered")])
	check(evs("miasma", "legend").any(func(h: Dictionary) -> bool: return h["ev"]["kind"] == "spread"), "C: the spread is drawn")
	# witheredBurstAt: an enemy reaching 8 stacks loses them and a fresh circle opens on it
	reset()
	var zones: Array = caster.mem("miasma").get_or_add("zones", [])
	var big := foe(Vector3(0, 0, -28))
	caster.request_cast("miasma", Vector3(0, 0, -27), -1)
	await secs(1.4)
	check(not caster.mem("miasma").get("last", {}).is_empty(), "C: the cast is remembered for Chain Plague")
	DmStatusSet.of(big).apply(&"withered", hero, 7, -1.0, {"dps": 1.0, "cap": 8.0})
	var before := zones.size()
	await secs(1.3)
	var plague := zones.filter(func(z: Dictionary) -> bool: return z["plague"])
	check(plague.size() >= 1 and DmStatusSet.of(big).stacks(&"withered") < 8, "C: witheredBurstAt - 8 stacks burst into a fresh circle (%d plague circles, %d stacks left)" % [plague.size(), DmStatusSet.of(big).stacks(&"withered")])
	check(plague.size() <= int(L["burstClouds"]) and evs("miasma", "legend").any(func(h: Dictionary) -> bool: return h["ev"]["kind"] == "plague"), "C: ...at most %d at once, and it is drawn" % int(L["burstClouds"]))
	await strip()
	check(float(caster.legend["witheredBurstAt"]) == 0.0, "C: Plague Choir leaves with the set")


func _colossus_mantle() -> void:
	var L: Dictionary = DmSimData.LEGEND
	reset()
	var plain := hero.take_damage(20.0, null)
	hero.heal(1e6)
	await wear("colossus_mantle")
	check(float(caster.mods["colossusGuard"]) == 0.3 and float(caster.mods["wardReflect"]) == 0.6 and float(caster.mods["litanyShatter"]) == 4.0, "C: Colossus Mantle reaches the mods (%s)" % str({"g": caster.mods["colossusGuard"], "r": caster.mods["wardReflect"], "s": caster.mods["litanyShatter"]}))
	check(hero._legend_hurt, "C: ...and arms the hit hook")
	# colossusGuard: 3+ thralls = 30 % less damage taken (a Gravecaller has no ward per thrall, so nothing else moves the number)
	var spec := {"kind": "warrior", "cap": 8.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0}
	hero.heal(1e6)
	var one := hero.take_damage(20.0, null)
	hero.heal(1e6)
	for k in 3:
		th._spawn(DmThralls.raise_stats(spec, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, k + 1, 0.0), hero.global_position + Vector3(2 + k, 0, 0), 0.0)
	await ticks(2)
	var three := hero.take_damage(20.0, null)
	check(th.count() >= 3 and near(three, one * (1.0 - float(caster.mods["colossusGuard"])), 0.2) and near(plain, one, 0.2), "C: colossusGuard - %d thralls cut a blow to %.0f%% (%.1f -> %.1f)" % [th.count(), 100.0 * three / maxf(one, 0.001), one, three])
	# wardReflect: the share Bone Ward turned is dealt back at the attacker. A Gravecaller has no ward per thrall, so grant it for the test
	hero.heal(1e6)
	var striker := foe(hero.position + Vector3(1.2, 0, 0))
	var saved_mods := hero.mods
	hero.mods = hero.mods.duplicate()
	hero.mods["wardPerThrall"] = 0.2
	var ward := minf(float(DmLegend.L()["wardCap"]), 0.2 * float(th.count()))
	hits.clear()
	hero.take_damage(20.0, striker)
	check(loss(striker) > 0.0 and near(loss(striker), DmLegend.ward_reflect_damage(20.0, ward, 0.6), 0.2), "C: wardReflect - the ward's share goes back at the attacker (%.2f, want %.2f)" % [loss(striker), DmLegend.ward_reflect_damage(20.0, ward, 0.6)])
	check(evs("black_litany", "reflect").size() == 1, "C: ...and is drawn once")
	hero.mods = saved_mods
	# litanyShatter: a broken Litany barrier bursts around you for x4 its size
	hero.heal(1e6)
	var near_foe := foe(hero.position + Vector3(2.5, 0, 0))
	var far_foe := foe(hero.position + Vector3(float(L["shatterR"]) + 3.0, 0, 0))
	hero.p["barrier"] = 10.0
	hero.p["barrierPeak"] = 10.0
	hits.clear()
	hero.take_damage(30.0, null)
	check(near(loss(near_foe), 4.0 * 10.0, 0.5) and loss(far_foe) == 0.0 and evs("black_litany", "shatter").size() == 1, "C: litanyShatter - the broken barrier (10) bursts for %.0f within %.0f m, drawn once (%.1f)" % [4.0 * 10.0, float(L["shatterR"]), loss(near_foe)])
	await strip()
	check(float(caster.mods["colossusGuard"]) == 0.0 and not hero._legend_hurt, "C: Colossus Mantle leaves with the set (no hit hook left)")
	hero.heal(1e6)
	check(near(hero.take_damage(20.0, null), plain, 0.2), "C: ...and blows cost full again")


func _requiem_wraiths() -> void:
	var L: Dictionary = DmSimData.LEGEND
	reset()
	await wear("requiem_wraiths")
	check(float(caster.mods["corpseWisp"]) == 10.0 and float(caster.mods["wraithNova"]) == 1.2, "C: Requiem Wraiths reaches the mods (%s)" % str({"w": caster.mods["corpseWisp"], "n": caster.mods["wraithNova"]}))
	# corpseWisp: a corpse of yours consumed raises a healing wisp (cap 3), each heals 2 % max hp a second
	for k in 5:
		corpse(Vector3(0.6 * k, 0, -24))
	hero.p["hp"] = float(hero.p["stats"]["maxHp"]) * 0.3
	hero._mirror_from_state()
	var hp0 := float(hero.p["hp"])
	for k in 5:
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
	check(healed >= 0.9 * 2.0 * 3.0 * mh * float(L["wispHealFrac"]) and healed < 3.0 * 2.0 * 3.0 * mh * float(L["wispHealFrac"]), "C: ...each healing %.0f%% of max hp a second (%.0f in 2 s with 3 wisps)" % [float(L["wispHealFrac"]) * 100.0, healed])
	# wraithNova: a Soul Harvest cast makes every wisp and wraith release a nova
	var e1 := foe(hero.position + Vector3(2.4, 0, 0.0))    # off the spear's line, inside a wisp's nova
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
		check(near(nova_dmg, DmAbilities.sp(caster.p, caster.now_ms) * 1.2, nova_dmg * 0.02), "C: ...for spell power x %.1f (%.1f)" % [1.2, nova_dmg])
	check(loss(e1) >= nova_amt * 0.99 and loss(e2) == 0.0, "C: ...hitting what stands within %.0f m of a wisp (%.1f / %.1f)" % [float(L["novaR"]), loss(e1), loss(e2)])
	await strip()
	check(float(caster.mods["corpseWisp"]) == 0.0, "C: Requiem Wraiths leaves with the set")


# ---------------------------------------------------------------------------------------------------------------------------- bonded + cost

func _bonded() -> void:
	reset()
	var prog: DmProgression = g.progress.prog
	var saved: Dictionary = prog.local["boons"]
	prog.local["boons"] = {"bonded_dead": 1}
	g.progress.apply_progress()
	check(bool(prog.boons()["bondedDead"]), "D: the Bonded Dead boon is on")
	await wear("legion_unburied")
	var home := Vector3(float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["x"]), 0.0, float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["z"]))
	hero.teleport(home)
	await until(func() -> bool: return g.area_id == "chapterhouse", 3.0)
	th.clear()
	hero.teleport(Vector3(0, 0, -18))
	check(await until(func() -> bool: return g.area_id == "graves", 3.0), "D: the hero walks into the Hollow Graves")
	check(await until(func() -> bool: return th.count() == 1, 4.0), "D: Bonded Dead - a thrall rises on entering a hunting ground with none")
	check(th.list()[0].death_burst_frac == 0.8, "D: ...and it carries the worn legend (death burst %.1f)" % th.list()[0].death_burst_frac)
	await strip()
	prog.local["boons"] = saved
	g.progress.apply_progress()


func _cost() -> void:
	reset()
	await wear("plague_choir")
	var fc := DmFrameCost.attach(g)
	for k in 12:
		foe(Vector3(-6 + k, 0, -30 - (k % 3)))
	await frames(30)
	fc.reset()
	for i in 90:
		await process_frame
	var idle := fc.median_ms()
	caster.set_runes({"miasma": "rune_contagion", "bone_needle": "rune_volley"})
	await frames(10)
	fc.reset()
	for i in 120:
		if i % 40 == 0:
			caster.p["cooldowns"].clear()
			caster.p["castUntil"] = 0.0
			caster.request_cast("miasma", Vector3(0, 0, -29), -1)
		if i % 3 == 0:
			caster.p["cooldowns"].erase("bone_needle")
			caster.p["castUntil"] = 0.0
			caster.request_cast("bone_needle", foes[i % foes.size()].position, eid(foes[i % foes.size()]))
		await process_frame
	var med := fc.median_ms()
	print("COST 12 soaking enemies idle: median frame %.2f ms; with a Contagion circle + Plague Choir + volley needles: median %.2f ms (p95 %.2f, worst %.2f)" % [idle, med, fc.p95_ms(), fc.worst_ms()])
	perf_info(med < idle + 6.0 and med < 25.0, "E: a Contagion circle + Plague Choir + volleys over 12 enemies adds %.2f ms a frame (%.2f vs %.2f idle; budget +6 ms, shared VPS)" % [med - idle, med, idle])
	# the gear-change path itself (no UI): re-reading the build + legend + hit hook
	var t := Time.get_ticks_usec()
	for i in 50:
		g.progress.refresh_stats()
	var per := (Time.get_ticks_usec() - t) / 50000.0
	print("COST progress.refresh_stats (build + caster + legend + legion + HUD) with a legendary set: %.2f ms each" % per)
	perf_info(per < 15.0, "E: a gear change re-reads the build in %.2f ms (budget 15)" % per)
	var a0 := Time.get_ticks_usec()
	for i in 2000:
		caster._set_mods(caster.mods)
	var legend_us := (Time.get_ticks_usec() - a0) / 2000.0
	print("COST legend resolve (_set_mods) alone: %.1f us" % legend_us)
	perf_info(legend_us < 200.0, "E: resolving the legend is %.1f us, once per gear change, never per tick" % legend_us)
	await strip()
	fc.queue_free()


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])

extends RefCounted
## DmAbilitySystem (godot/game/dm_ability_system.gd): the headless caster plus every visual/audio/gesture hook.
## Parity: for every ability id the same scripted seeded run is played on a plain DmSimCaster and on a DmAbilitySystem (real Vfx + AudioDirector
## autoloads, stub host); the cast result codes, the intents sent, the player's state and the world must be identical, with no script errors.
## Coverage: every ok cast must have drawn/played something; the per-callsite checks assert the specific hooks (gestures, shakes, popups, ...).

var passed := 0
var failed := 0
var messages: Array = []
var totals: Dictionary = {}
var by_id: Dictionary = {}


class StubCam:
	extends RefCounted
	var shakes: Array = []

	func shake(a: float) -> void:
		shakes.append(a)


class StubAvatar:
	extends RefCounted
	var gestures: Array = []

	func cast(kind: String, seconds: float, facing: float, gesture_seconds: float, ability_id: String = "") -> void:
		gestures.append([kind, seconds, gesture_seconds, ability_id])

	func tip() -> Vector3:
		return Vector3(0.0, 1.4, -16.0)


class StubHost:
	extends RefCounted
	var camera := StubCam.new()
	var avatar := StubAvatar.new()
	var floats: Array = []

	func float_text(x: float, y: float, z: float, text: String, kind: String) -> void:
		floats.append([x, y, z, text, kind])


func _check(cond: bool, what: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		if messages.size() < 40:
			messages.append("FAIL " + what)


func _const(v: float) -> float:
	return v


const MODS := {"thrallCap": 3, "thrallKind": "warrior", "thrallHpMult": 2, "thrallDamageMult": 1, "thrallAttackSpeedMult": 1, "maxHpMult": 1.2, "essenceRegenMult": 1,
	"miasmaRadiusMult": 1, "witheredMaxStacks": 5, "corpseHeal": 0, "wardPerThrall": 0.1, "litanyBarrier": 0.04, "sacrificeLeavesCorpse": false,
	"miasmaBurstsCorpses": false, "thrallDeathBurst": 0, "championEvery": 0, "spearRally": 0, "wardReflect": 0, "colossusGuard": 0, "litanyShatter": 0,
	"corpseWisp": 0, "soulHarvestRateMult": 1, "wraithNova": 0, "miasmaSpreadsWithered": 0, "witheredBurstAt": 0}
const STATS := {"level": 60, "maxHp": 800, "spellPower": 70, "maxEssence": 1000, "essenceRegen": 6, "moveSpeed": 5.4, "thrallHp": 160, "thrallDamage": 22, "damageBonusPct": 0}
const LOADOUT := {"main": "staff", "mainTier": "gold", "off": "skull_focus", "offTier": "gold", "spellMult": 1.1, "needleRangeMult": 1.25, "needlePierce": 1,
	"needleCadenceMult": 1, "needleDamageMult": 1, "needleWithered": 0, "reap": false, "exhumeRefund": 0, "thrallBonus": 1, "riteCooldownMult": 1, "bellAllyHeal": 0}


## One world: hero at (0, -16) in the graves, a ring of enemies, corpses and (after the setup raise) a couple of thralls.
func make(visual: bool, family: String, mods: Dictionary, loadout: Dictionary, runes: Dictionary, rnd: float, host: Object = null) -> Dictionary:
	var world: Dictionary = DmSimExact.load_json("res://data/sim/world.json")
	var nav := DmNav.new()
	for o in world["obstacles"]:
		nav.add_obstacle(DmNavObstacle.from_dict(o))
	for sb in world["sightBlockers"]:
		nav.add_sight_blocker(DmNavObstacle.from_dict(sb))
	var all: Array = []
	for a in DmContent.area_order():
		if a != "depths":
			all.append(a)
	nav.set_unlocked(all)
	var sim := DmWorldSim.new(nav, DmRng.new(77))
	sim.waveTier = 1.0
	sim.set_crypts(world["crypts"])
	var p := DmPlayerRules.new_state(STATS, family)
	p["loadout"] = loadout
	p["runes"] = runes
	p["area"] = "graves"
	p["x"] = 0.0
	p["z"] = -16.0
	p["hp"] = 400.0
	var c: DmSimCaster
	if visual:
		var ab := DmAbilitySystem.new(sim, p, "p1", "ossuary", family, mods)
		ab.game = host
		c = ab
	else:
		c = DmSimCaster.new(sim, p, "p1", "ossuary", family, mods)
	c.dev = true
	c.route_vigil = true
	c.random = Callable(self, "_const").bind(rnd)
	c.record_sent = true
	sim.set_player(DmSimPlayer.make("p1", 0.0, -16.0, "graves", true, 60.0, family))
	for i in 7:
		var a := float(i) / 7.0 * TAU
		var e := sim.spawn_enemy("robber", "graves", cos(a) * 3.5, -16.0 + sin(a) * 3.5, false, false)
		e.hp = 1e7
		e.maxHp = 1e7
		e.state = "move"
	for i in 10:
		var a2 := float(i) / 10.0 * TAU + 0.3
		sim.add_corpse(cos(a2) * 2.2, -16.0 + sin(a2) * 2.2, "resonant" if i == 3 else "normal", "robber", i == 4, 0.0, 1.0, "graves")
	return {"sim": sim, "p": p, "c": c}


func step(w: Dictionary, now_ref: Array, frames: int) -> void:
	var sim: DmWorldSim = w["sim"]
	var c: DmSimCaster = w["c"]
	var p: Dictionary = w["p"]
	for i in frames:
		now_ref[0] += 50.0
		sim.set_player(DmSimPlayer.make("p1", p["x"], p["z"], p["area"], p["alive"], 60.0, c.family))
		c.update(now_ref[0], 0.05)
		for ev in sim.step(0.05):
			c.handle_event(ev)


## Raise two thralls (a plain caster would do the same), so rally / litany / vigil have something to work with.
func setup_thralls(w: Dictionary, now_ref: Array) -> void:
	var c: DmSimCaster = w["c"]
	var sim: DmWorldSim = w["sim"]
	for k in 2:
		now_ref[0] += 100.0
		var cr: DmSimCorpse = null
		for cc: DmSimCorpse in sim.corpses.values():
			cr = cc
			break
		if cr != null:
			c.cast("exhume", {"x": cr.x, "z": cr.z}, now_ref[0])
		w["p"]["castUntil"] = 0.0
		w["p"]["cooldowns"].clear()
		step(w, now_ref, 6)
	step(w, now_ref, 30)
	# the rising enemies were pinned to full hp; keep them alive and in place
	for e: DmSimEnemy in sim.enemies.values():
		e.hp = 1e7


func target_for(w: Dictionary, id: String) -> Dictionary:
	var sim: DmWorldSim = w["sim"]
	var tg := String(DmSimData.ABILITIES[id].get("targeting", "ground"))
	if tg == "enemy":
		var best: DmSimEnemy = null
		var bd := INF
		for e: DmSimEnemy in sim.enemies.values():
			var d := DmSimMath.hypot(e.x - float(w["p"]["x"]), e.z - float(w["p"]["z"]))
			if e.state != "dead" and d < bd:
				bd = d
				best = e
		return {"x": best.x, "z": best.z, "enemyId": best.id}
	var cr: DmSimCorpse = null
	var cd := INF
	for c: DmSimCorpse in sim.corpses.values():
		var d2 := DmSimMath.hypot(c.x - float(w["p"]["x"]), c.z - float(w["p"]["z"]))
		if c.echoOwner == "" and d2 < cd:
			cd = d2
			cr = c
	if cr == null:
		return {"x": 3.0, "z": -16.0}
	return {"x": cr.x, "z": cr.z}


func fingerprint(w: Dictionary) -> String:
	var sim: DmWorldSim = w["sim"]
	var c: DmSimCaster = w["c"]
	var p: Dictionary = w["p"]
	var hp := 0.0
	for e: DmSimEnemy in sim.enemies.values():
		hp += e.hp
	var cds: Array = []
	var keys: Array = p["cooldowns"].keys()
	keys.sort()
	for k in keys:
		cds.append([k, p["cooldowns"][k]])
	return JSON.stringify({"sent": c.sent, "x": p["x"], "z": p["z"], "hp": p["hp"], "res": p["resource"]["value"], "barrier": p["barrier"], "souls": p["souls"],
		"cds": cds, "enemies": sim.enemies.size(), "ehp": hp, "corpses": sim.corpses.size(), "thralls": sim.thralls.size(), "zones": sim.zones.size(), "wisps": c.wisp_count()})


func fx_total(ab: DmAbilitySystem) -> int:
	var n := 0
	for k in ab.stats:
		if k != "float":
			n += int(ab.stats[k])
	return n


## Cast `id` on both worlds, fly 4 seconds, compare. `prep` may tweak a world (souls, essence ...).
func parity(id: String, label: String, family: String, mods: Dictionary, runes: Dictionary, rnd: float, loadout: Dictionary = LOADOUT, souls: bool = false) -> Dictionary:
	var host := StubHost.new()
	var wa := make(false, family, mods, loadout, runes, rnd)
	var wb := make(true, family, mods, loadout, runes, rnd, host)
	var na := [1000.0]
	var nb := [1000.0]
	setup_thralls(wa, na)
	setup_thralls(wb, nb)
	for w in [wa, wb]:
		w["p"]["castUntil"] = 0.0
		w["p"]["cooldowns"].clear()
		w["p"]["resource"]["value"] = 900.0
		if souls:
			w["p"]["souls"] = float(w["p"]["soulsMax"])
	var ca: DmSimCaster = wa["c"]
	var cb: DmAbilitySystem = wb["c"]
	ca.clear_log()
	cb.clear_log()
	cb.popups = []
	var s0 := fx_total(cb)
	var g0 := host.avatar.gestures.size()
	var ra := ca.cast(id, target_for(wa, id), na[0])
	var rb := cb.cast(id, target_for(wb, id), nb[0])
	_check(ra == rb, "%s result parity (%s vs %s)" % [label, ra, rb])
	step(wa, na, 80)
	step(wb, nb, 80)
	_check(fingerprint(wa) == fingerprint(wb), "%s gameplay parity" % label)
	var drew := fx_total(cb) - s0
	var vfx: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Vfx")
	if vfx != null:
		vfx.clear()
	if rb == "ok":
		_check(drew > 0, "%s drew/played something (%d)" % [label, drew])
	return {"result": rb, "drew": drew, "gestures": host.avatar.gestures.size() - g0, "host": host, "ab": cb}


func run() -> void:
	DmSimData.ensure()
	var runes := {}
	var abilities: Array = DmSimData.ABILITIES.keys()
	var all_stats: Dictionary = {}
	for id: String in abilities:
		var fam := "necromancer"
		# the New Blood ids are cast by their own family's caster (same code path, family only picks the ring colour)
		if ["flail_swing", "lantern_cone", "chain_pull", "burn_the_dead", "watchmans_ward", "cremate", "last_light"].has(id):
			fam = "warden"
		elif ["palm_strike", "toll", "resonant_step", "knell", "choir_of_one", "sound_the_corpse", "great_toll"].has(id):
			fam = "monk"
		elif ["hook_throw", "harvest", "crow_swarm", "hook_pull", "hex_charm", "butcher", "murder_of_crows"].has(id):
			fam = "witch"
		elif ["spirit_bolt", "veil_form", "echo", "veil_tear", "crossing", "lay_to_rest", "between_worlds"].has(id):
			fam = "veilwalker"
		elif ["hollow_cut", "shield_bash", "grave_slam", "bulwark", "corpse_vigil", "grave_brand", "oath_unbroken"].has(id):
			fam = "knight"
		var r := parity(id, id, fam, MODS, runes, 0.5)
		by_id[id] = r["result"]
		all_stats[id] = {"result": r["result"], "drew": r["drew"], "gestures": r["gestures"]}
		if r["result"] == "ok" and not (id in ["veil_form", "between_worlds", "spirit_bolt", "burn_the_dead", "watchmans_ward", "crow_swarm", "veil_tear", "murder_of_crows"]):
			pass
	var ok_n := 0
	for id in by_id:
		if by_id[id] == "ok":
			ok_n += 1
	_check(ok_n >= 40, "most ids cast ok (%d of %d)" % [ok_n, by_id.size()])
	messages.append("ok casts: %d of %d ids; not ok: %s" % [ok_n, by_id.size(), _not_ok()])
	run_rune_and_legend()
	run_hooks()


func _not_ok() -> String:
	var out: Array = []
	for id in by_id:
		if by_id[id] != "ok":
			out.append("%s=%s" % [id, by_id[id]])
	return ", ".join(out)


## Rune variants and legendary-set mechanics (wisps, wraith nova, Litany shatter, ward reflect) against the plain caster.
func run_rune_and_legend() -> void:
	var rune_cases := [
		["bone_needle", "rune_volley"], ["bone_needle", "rune_splinter"], ["bone_needle", "rune_marrow_tap"],
		["marrow_spear", "rune_ossuary_ring"], ["marrow_spear", "rune_impale"],
		["exhume", "rune_mass_grave"], ["exhume", "rune_bone_colossus"],
		["miasma", "rune_creeping_rot"], ["miasma", "rune_contagion"],
		["black_litany", "rune_hollow_choir"], ["black_litany", "rune_requiem"],
	]
	for rc in rune_cases:
		var rn := {String(rc[0]): String(rc[1])}
		var lo: Dictionary = LOADOUT.duplicate()
		for rnd in [0.5, 0.01]:
			var r := parity(rc[0], "%s/%s/r%s" % [rc[0], rc[1], rnd], "necromancer", MODS, rn, rnd, lo)
			_check(r["result"] == "ok", "%s %s casts" % [rc[0], rc[1]])
	# scythe and sickle loadouts
	var lo_reap: Dictionary = LOADOUT.duplicate()
	lo_reap["reap"] = true
	lo_reap["needlePierce"] = 0
	var rr := parity("bone_needle", "scythe", "necromancer", MODS, {}, 0.5, lo_reap)
	_check(rr["result"] == "ok" and rr["ab"].stats["flash"] > 0, "scythe draws flashes")
	var rs := parity("bone_needle", "scythe+splinter", "necromancer", MODS, {"bone_needle": "rune_splinter"}, 0.5, lo_reap)
	_check(rs["result"] == "ok", "scythe+splinter ok")
	# legend: wisps, nova, shatter, reflect (empowered casts via full souls)
	var lm: Dictionary = MODS.duplicate()
	lm["corpseWisp"] = 8
	lm["wraithNova"] = 1.0
	lm["litanyShatter"] = 1.0
	lm["wardReflect"] = 0.5
	lm["spearRally"] = 1.0
	lm["thrallKind"] = "wraith"
	for id in ["exhume", "black_litany", "corpse_explosion", "grave_offering", "bone_mantle", "marrow_spear", "miasma"]:
		var r2 := parity(id, "legend/" + id, "necromancer", lm, {}, 0.5, LOADOUT, id == "marrow_spear" or id == "miasma" or id == "exhume")
		if id in ["exhume", "black_litany", "corpse_explosion"]:
			_check(r2["result"] == "ok", "legend %s casts" % id)


func run_hooks() -> void:
	var host := StubHost.new()
	var lm: Dictionary = MODS.duplicate()
	lm["corpseWisp"] = 8
	lm["wraithNova"] = 1.0
	lm["litanyShatter"] = 1.0
	lm["wardReflect"] = 0.5
	lm["thrallKind"] = "wraith"
	var w := make(true, "necromancer", lm, LOADOUT, {}, 0.01, host)
	var now := [1000.0]
	setup_thralls(w, now)
	var ab: DmAbilitySystem = w["c"]
	w["p"]["castUntil"] = 0.0
	w["p"]["cooldowns"].clear()
	w["p"]["resource"]["value"] = 900.0
	# Bone Needle crit: floating number, crit Binbun, gesture, sound
	var e: DmSimEnemy = null
	for ee: DmSimEnemy in w["sim"].enemies.values():
		e = ee
		break
	var s0: Dictionary = ab.stats.duplicate()
	_check(ab.cast("bone_needle", {"x": e.x, "z": e.z, "enemyId": e.id}, now[0]) == "ok", "hook: needle casts")
	step(w, now, 30)
	var needle_g := false
	for g in host.avatar.gestures:
		if g[0] == "cast" and g[3] == "bone_needle" and is_equal_approx(float(g[1]), 3.2):
			needle_g = true
	_check(needle_g, "hook: needle gesture (cast, 3.2 s, bone_needle)")
	_check(ab.stats["projectile"] > s0["projectile"], "hook: needle visual projectile")
	_check(ab.stats["bb"] > s0["bb"], "hook: crit_hit Binbun on a crit")
	var crit_seen := false
	for f in host.floats:
		if f[4] == "crit" and f[1] == 1.6:
			crit_seen = true
	_check(crit_seen, "hook: crit number floated at y 1.6")
	_check(ab.popups.is_empty(), "hook: popups drained by update")
	# Soul Harvest: empowered cast releases the souls
	w["p"]["castUntil"] = 0.0
	w["p"]["cooldowns"].clear()
	w["p"]["souls"] = float(w["p"]["soulsMax"])
	var s1: int = ab.stats["bb"]
	_check(ab.cast("black_litany", {"x": 0.0, "z": -16.0}, now[0]) == "ok", "hook: empowered litany casts")
	_check(ab.stats["bb"] > s1, "hook: soul_harvest_pillar on an empowered cast")
	step(w, now, 20)
	_check(host.camera.shakes.size() >= 1, "hook: camera shakes (litany result)")
	# Requiem wisp from a consumed corpse
	_check(ab.wisp_count() >= 1 and ab.stats["orbit"] >= 1, "hook: Requiem wisp has an orbit visual")
	var orb0: int = ab.stats["orbit"]
	for i in 6:
		ab.on_corpse_consumed()
	_check(ab.wisp_count() <= int(DmSimData.LEGEND["wispCap"]), "hook: wisp cap holds")
	_check(ab.stats["orbit"] > orb0, "hook: renewed wisps redraw")
	# notes (wisp heal) drain to float_text
	step(w, now, 60)
	var heal_float := false
	for f in host.floats:
		if f[4] == "heal":
			heal_float = true
	_check(heal_float, "hook: wisp heal note floats")
	# Brand / vigil / seed / rally / burst visuals
	var d0 := fx_total(ab)
	ab.on_brand({"x": 1.0, "z": -15.0})
	ab.on_brand({"x": 1.0, "z": -15.0, "sprung": true})
	ab.on_vigil({"x": 1.0, "z": -15.0, "ok": true}, true)
	ab.on_seeded({"corpseId": 99, "x": 2.0, "z": -14.0, "armMs": 600.0})
	ab.on_seed_burst({"x": 2.0, "z": -14.0, "r": 3.0})
	ab.on_seed_gone(99)
	ab.on_rally({"x": 0.0, "z": -16.0, "ids": w["sim"].thralls.keys()}, Callable(ab, "_fol_p"))
	_check(fx_total(ab) - d0 >= 20, "hook: on_brand/on_vigil/on_seeded/on_seed_burst/on_rally draw (%d)" % (fx_total(ab) - d0))
	_check(ab._seeds.is_empty() and ab._seed_cores.is_empty(), "hook: seed marks cleared by on_seed_gone")
	# mantle shards follow their caster
	var m0: int = ab.stats["bone_orbit"]
	ab.on_mantle({"x": 0.0, "z": -16.0, "r": 3.0, "corpses": 3, "tethers": [[1.0, -15.0], [2.0, -14.0]], "by": "p1"}, true)
	_check(ab.stats["bone_orbit"] > m0 and ab._mantle_fx != null, "hook: mantle orbit shards + ring")
	ab.on_mantle_follow({"x": 5.0, "z": -16.0, "r": 3.0, "corpses": 1, "tethers": [], "by": "p9"}, false, Callable())
	# reflect ward + litany shatter
	var d1 := fx_total(ab)
	ab.litany_shatter(400.0)
	_check(fx_total(ab) > d1, "hook: litany shatter bursts")
	var d2 := fx_total(ab)
	ab.reflect_ward(500.0, 300.0, e.x, e.z)
	_check(fx_total(ab) > d2, "hook: ward reflect draws on the attacker")
	# New Blood family events
	var d3 := fx_total(ab)
	ab.on_new_blood({"t": "newBlood", "by": "p1", "kind": "harvest", "ok": true, "x": 1.0, "z": -16.0, "amount": 30.0}, true)
	ab.on_new_blood({"t": "newBlood", "by": "p2", "kind": "toll", "ok": true, "x": 1.0, "z": -16.0}, false)
	_check(fx_total(ab) - d3 >= 4, "hook: new blood event rings + crow orbit")
	# a dead hero stops the tick-driven shards
	w["p"]["alive"] = false
	step(w, now, 5)
	_check(ab._mantle_fx == null, "hook: dead hero kills the mantle visuals")

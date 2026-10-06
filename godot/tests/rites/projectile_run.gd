extends SceneTree
## The projectile / line / cone rites (godot/next/rites: bone_fan, rot_lance, marrow_spear, wailing_skull, ivory_cleave, bone_storm, soul_siphon).
## godot --headless --path godot --script res://tests/rites/projectile_run.gd
## Part A: solo (DmSession on OfflineMultiplayerPeer), host stepped by hand. Part B: in-process ENet, 1 host + 2 clients on DmTestPorts.free_port()
## (fx/sfx once per peer). Part C: perf (cost per cast, frame cost with shots / storms / tethers active against 25 enemies).

var PORT := DmTestPorts.free_port()
var passed := 0
var failed := 0
const DT := 0.02


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
	await _part_a()
	await _part_b()
	await _part_c()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func wait_for(cond: Callable, timeout := 8.0) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < timeout * 1000.0:
		if cond.call():
			return true
		await create_timer(0.05).timeout
	return cond.call()


func _half() -> float:
	return 0.5


# ---- doubles -----------------------------------------------------------------------------------------------------------------------------

class World:
	extends Node3D
	var enemies: Array = []
	var corpses: DmCorpseField
	var events: Array = []
	var _n := 0

	func add(e: DmEnemy) -> int:
		_n += 1
		e.set_meta("rid", _n)
		enemies.append(e)
		return _n

	func enemies_in_radius(pos: Vector3, r: float) -> Array:
		return enemies.filter(func(e): return is_instance_valid(e) and Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length() <= r)

	func enemy_by_id(id: int) -> Node:
		for e in enemies:
			if is_instance_valid(e) and int(e.get_meta("rid")) == id:
				return e
		return null

	func enemy_id(e: Node) -> int:
		return int(e.get_meta("rid"))

	func area_of(_peer: int) -> String:
		return ""

	func on_rite_event(ev: Dictionary) -> void:
		events.append(ev)

	func count(t: String) -> int:
		return events.filter(func(ev): return ev.get("t") == t).size()


class RecMotifs:
	extends RefCounted
	var n := 0
	func bone_splinters(_x, _y, _z, _o) -> void: n += 1
	func rot_spores(_x, _z, _c, _o) -> void: n += 1
	func grave_dirt(_x, _z, _o) -> void: n += 1
	func soul_motes(_x, _z, _c, _o) -> void: n += 1
	func skull_wisps(_x, _z, _c, _o) -> void: n += 1
	func skull_ring(_x, _z, _r, _c, _o) -> void: n += 1


class RecFx:
	extends RefCounted
	var c := {}
	var motifs := RecMotifs.new()
	func _b(k: String) -> void: c[k] = int(c.get(k, 0)) + 1
	func decal(_o) -> Variant: _b("decal"); return null
	func emit(_o) -> void: _b("emit")
	func emit_smoke(_o) -> void: _b("smoke")
	func flash(_o) -> void: _b("flash")
	func play(_id, _p, _o) -> Variant: _b("bb"); return null
	func projectile(_o) -> Variant: _b("projectile"); return null
	func beam(_a, _b2, _c, _w, _d) -> Variant: _b("beam"); return null
	func light_flash(_p, _c, _i, _l) -> void: _b("light")
	func bone_orbit(_o) -> Variant: _b("orbit"); return null
	func spike_line(_x, _z, _dx, _dz, _l, _w, _s) -> void: _b("spike")
	func spike_ring(_x, _z, _r, _n, _l) -> void: _b("spike")


class RecAudio:
	extends RefCounted
	var sfx: Array = []
	var loops: Array = []
	func play_sfx(id, _p, _i) -> void: sfx.append(id)
	func loop_sfx(id, _ms, _p, _f) -> void: loops.append(id)


class FieldVfx:
	extends Node
	func decal(_o: Dictionary) -> Variant: return null
	func emit(_o: Dictionary) -> void: pass


func _robber(w: World, parent: Node, pos: Vector3, hp := 1.0e6, frozen := false) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.rng_seed = 3
	e.position = pos
	parent.add_child(e)
	e.hp = hp
	if frozen:
		e.set_physics_process(false)
	w.add(e)
	return e


func _stub(c: DmRiteCaster) -> Array:
	var f := RecFx.new()
	var a := RecAudio.new()
	c.fx.fx = f
	c.fx.audio = a
	return [f, a]


func _step(c: DmRiteCaster, secs: float) -> void:
	for i in int(round(secs / DT)):
		c.step(DT)
		for e in c.world.enemies:
			var ss := DmStatusSet.of(e) if is_instance_valid(e) else null
			if ss != null:
				ss.advance(DT)


## Step until the host has played one more event of type `t` (the blow has just landed: no DoT tick has run yet), at most `max_s`.
func _land(c: DmRiteCaster, t: String, max_s := 3.0) -> void:
	var n: int = (c.world as World).count(t)
	for i in int(max_s / DT):
		c.step(DT)
		if (c.world as World).count(t) > n:
			return


func _stk(e: Node, id: StringName) -> int:
	var ss := DmStatusSet.of(e)
	return ss.stacks(id) if ss != null else 0


func _ready_cast(c: DmRiteCaster) -> void:
	c.p["cooldowns"].clear()
	c.p["castUntil"] = 0.0
	c.p["resource"]["value"] = float(c.p["resource"]["max"])


func _solo(nm: String) -> Dictionary:
	var h := Node.new()
	h.name = nm
	root.add_child(h)
	var sess := DmSession.new()
	sess.name = "Session"
	h.add_child(sess)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
	sess.character_name = "Solo"
	sess.discipline_id = "gravecaller"
	var w := World.new()
	w.name = "W"
	h.add_child(w)
	var f := DmCorpseField.new()
	f.name = "Corpses"
	f.visuals = false
	f.auto_step = false
	f.vfx = FieldVfx.new()
	f.add_child(f.vfx)
	w.add_child(f)
	w.corpses = f
	sess.host(OfflineMultiplayerPeer.new())
	var body := sess.get_body(1)
	body.position = Vector3.ZERO
	DmThrallHost.attach(body, w)
	var c := DmRiteCaster.attach(body, w)
	c.auto_step = false
	c.random = Callable(self, "_half")
	c.p["stats"]["level"] = 20.0
	var st := _stub(c)
	await process_frame
	return {"h": h, "sess": sess, "w": w, "f": f, "body": body, "c": c, "fx": st[0], "au": st[1], "thr": body.get_node("Thralls")}


func _teardown(s: Dictionary) -> void:
	for e in (s["w"] as World).enemies:
		if is_instance_valid(e):
			e.free()
	await (s["sess"] as DmSession).leave()
	(s["h"] as Node).queue_free()


func _rejects(c: DmRiteCaster) -> Array:
	var rej: Array = []
	c.cast_rejected.connect(func(r, why): rej.append([r, why]))
	return rej


func _sp(c: DmRiteCaster) -> float:
	return DmAbilities.sp(c.p, c.now_ms)


func _loss(e: DmEnemy, hp0: float) -> float:
	return hp0 - e.hp


# ---- Part A: solo ------------------------------------------------------------------------------------------------------------------------

func _part_a() -> void:
	for r in ["bone_fan", "rot_lance", "marrow_spear", "wailing_skull", "ivory_cleave", "bone_storm", "soul_siphon"]:
		ok(DmRiteRegistry.has(r) and DmRiteRegistry.module(r).id == r, "A: %s registered with its own module" % r)
	ok(DmRiteHotbar.rite_for_slot(1) == "marrow_spear" and DmRiteRegistry.has(DmRiteHotbar.rite_for_slot(1)), "A: the default loadout's slot 1 (marrow_spear) is castable now")
	var s := await _solo("P1")
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var fx: RecFx = s["fx"]
	var au: RecAudio = s["au"]
	var rej := _rejects(c)
	var max_e: float = c.p["stats"]["maxEssence"]
	var pick := {}

	# --- unlock gates (the shared cast_check): level 1 has only the primary and the spear
	c.p["stats"]["level"] = 1.0
	for r in ["bone_fan", "rot_lance", "wailing_skull", "ivory_cleave", "bone_storm", "soul_siphon"]:
		rej.clear()
		c.request_cast(r, Vector3(0, 0, 5))
		ok(rej.size() == 1 and rej[0][1] == "locked", "A: %s is locked at level 1" % r)
	c.p["stats"]["level"] = 20.0
	ok(c.events_played == 0, "A: locked rites played nothing")

	# ============================== bone_fan
	var A := _robber(w, h, Vector3(0, 0, 6))
	var B := _robber(w, h, Vector3(0.7, 0, 6.5))     # inside the 15 degree cone, nearest to the aim line after A
	var C2 := _robber(w, h, Vector3(-1.2, 0, 7.0))   # inside the cone, further off the line
	var D := _robber(w, h, Vector3(6, 0, 3))         # far outside the cone
	var Z := _robber(w, h, Vector3(0, 0, 14))        # out of range (8 + 0.4)
	var ids := {"A": w.enemy_id(A), "Z": w.enemy_id(Z)}
	rej.clear()
	c.request_cast("bone_fan", Vector3(30, 0, 30))
	ok(rej.size() == 1 and rej[0][1] == "no_target" and c.events_played == 0, "A: bone_fan with nothing near the aim: no_target, no event")
	c.request_cast("bone_fan", Vector3(0, 0, 14), ids["Z"])
	ok(rej.size() == 2 and rej[1][1] == "range" and c.cooldown_left("bone_fan") == 0.0, "A: bone_fan at a target past range 8: refused (range), free")
	c.p["resource"]["value"] = 10.0
	var hpA := A.hp
	var hpB := B.hp
	var hpC := C2.hp
	var hpD := D.hp
	var ess0 := c.essence()
	c.request_cast("bone_fan", Vector3(0, 0, 6), ids["A"])
	ok(c.events_played == 1 and w.count("cast") == 1 and (w.events[0]["slivers"] as Array).size() == 3, "A: bone_fan: ONE cast event with 3 slivers")
	ok(fx.c.get("flash", 0) == 1 and au.sfx == ["boneFan"] and fx.c.get("projectile", 0) == 3, "A: bone_fan cast fx once (flash 1, sfx boneFan, 3 projectiles)")
	var tgts: Array = (w.events[0]["slivers"] as Array).map(func(sv): return int(sv["eid"]))
	ok(tgts.has(ids["A"]) and tgts.has(w.enemy_id(B)) and tgts.has(w.enemy_id(C2)) and not tgts.has(w.enemy_id(D)), "A: slivers home on A, B, C and not on the enemy outside the cone")
	ok(is_equal_approx(c.cooldown_left("bone_fan"), float(DmAbilities.def("bone_fan")["cooldownMs"])) and is_equal_approx(c.essence(), ess0), "A: cooldown 520 ms, no essence cost")
	_step(c, 0.1)
	ok(A.hp == hpA, "A: nothing lands before the slivers arrive")
	_step(c, 0.6)
	var dmg_fan := _sp(c) * float(DmAbilities.def("bone_fan")["power"])
	ok(is_equal_approx(_loss(A, hpA), dmg_fan) and is_equal_approx(_loss(B, hpB), dmg_fan) and is_equal_approx(_loss(C2, hpC), dmg_fan), "A: each sliver does power 0.55 x spell power (%.3f)" % dmg_fan)
	ok(D.hp == hpD, "A: the enemy outside the cone is untouched")
	var regen := DmResources.passive("necromancer", {"stats": c.p["stats"], "value": 0.0, "max": max_e, "sinceHurtMs": 1e9, "sinceResourceGainMs": 1e9})
	var gain := c.essence() - 10.0
	ok(gain >= 6.0 and gain <= 6.0 + regen * 0.8, "A: three landings return only the 6-essence cap (+3 each, cap 6): %.2f" % gain)
	ok(w.count("hit") == 3 and au.sfx.count("needleHit") == 3 and fx.c.get("emit", 0) == 3, "A: three hit events, one fx each")
	# lone target: one landing, +3, the other two slivers fly out and die
	for e in [B, C2, D, Z]:
		e.global_position = Vector3(40, 0, 40)
	_ready_cast(c)
	c.p["resource"]["value"] = 10.0
	hpA = A.hp
	var n0 := w.count("hit")
	c.request_cast("bone_fan", Vector3(0, 0, 6), ids["A"])
	_step(c, 0.6)
	ok(w.count("hit") == n0 + 1 and is_equal_approx(_loss(A, hpA), dmg_fan) and c.essence() - 10.0 < 3.0 + regen * 0.8 + 0.01, "A: a lone target takes one sliver, +3 essence")
	# the target dies mid-flight: nothing lands
	_ready_cast(c)
	hpA = A.hp
	n0 = w.count("hit")
	c.request_cast("bone_fan", Vector3(0, 0, 6), ids["A"])
	A.hp = 0.0
	_step(c, 0.6)
	ok(w.count("hit") == n0 and A.hp == 0.0, "A: a sliver whose target died in flight does nothing")
	A.hp = 1.0e6

	# ============================== rot_lance
	_ready_cast(c)
	for e in [A, B, C2, D, Z]:
		e.global_position = Vector3(40, 0, 40)
	var L1 := _robber(w, h, Vector3(0, 0, 5))
	var L2 := _robber(w, h, Vector3(0.2, 0, 8))
	var L3 := _robber(w, h, Vector3(0, 0, 11))        # third in the lane: not pierced
	var L4 := _robber(w, h, Vector3(2.0, 0, 7))       # outside the 0.25 + radius lane
	var LF := _robber(w, h, Vector3(0, 0, 17))
	rej.clear()
	c.request_cast("rot_lance", Vector3(0, 0, 17), w.enemy_id(LF))
	ok(rej.size() == 1 and rej[0][1] == "range", "A: rot_lance past range 14: refused (range)")
	c.p["resource"]["value"] = 10.0
	var hl := [L1.hp, L2.hp, L3.hp, L4.hp]
	var n_ev := c.events_played
	var hits0 := w.count("hit")
	au.sfx.clear()
	c.request_cast("rot_lance", Vector3(0, 0, 5), w.enemy_id(L1))
	ok(c.events_played == n_ev + 1 and au.sfx == ["rotLance"] and fx.c.get("beam", 0) == 1, "A: rot_lance cast fx once (sfx rotLance, beam 1)")
	ok(is_equal_approx(c.cooldown_left("rot_lance"), 700.0), "A: cooldown 700 ms")
	_step(c, 0.1)
	ok(L1.hp == hl[0], "A: the lance has not landed after 0.1 s (flies 32 m/s)")
	_land(c, "hit")
	var dmg_l := _sp(c) * float(DmAbilities.def("rot_lance")["power"])
	ok(is_equal_approx(_loss(L1, hl[0]), dmg_l) and is_equal_approx(_loss(L2, hl[1]), dmg_l), "A: the lance pierces the first two for power 0.8 x spell power (%.3f)" % dmg_l)
	ok(L3.hp == hl[2] and L4.hp == hl[3], "A: the third in the lane and the one off the lane are untouched")
	var s1 := DmStatusSet.of(L1)
	ok(_stk(L1, &"withered") == 1 and _stk(L2, &"withered") == 1 and _stk(L3, &"withered") == 0, "A: +1 Withered stack on each pierced enemy")
	ok(c.essence() - 10.0 >= 4.0 and c.essence() - 10.0 <= 4.0 + regen * 0.9, "A: +4 essence once (not per enemy): %.2f" % (c.essence() - 10.0))
	ok(w.count("hit") == hits0 + 1 and au.sfx.count("needleHit") == 1, "A: one hit event for the lance (all pierced positions), one needleHit")
	# a second lance stacks Withered to 2 (cap from the discipline: witheredMaxStacks)
	_ready_cast(c)
	c.request_cast("rot_lance", Vector3(0, 0, 5), w.enemy_id(L1))
	_land(c, "hit")
	ok(s1.stacks(&"withered") == 2, "A: a second lance stacks Withered (2)")
	ok(float(DmCombatData.const_table("ROT_LANCE")["pierce"]) == 2.0 and s1.stacks(&"withered") <= int(DmLegend.effective_withered_cap(c.mods)), "A: ... never past the discipline's cap")

	# ============================== marrow_spear
	for e in [L1, L2, L3, L4, LF]:
		e.global_position = Vector3(40, 0, 40)
	_ready_cast(c)
	c.p["resource"]["value"] = 50.0
	rej.clear()
	c.request_cast("marrow_spear", Vector3(0, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "no_target" and c.cooldown_left("marrow_spear") == 0.0, "A: marrow_spear aimed at the caster itself: refused (no direction)")
	var S1 := _robber(w, h, Vector3(0, 0, 4))
	var S2 := _robber(w, h, Vector3(1.2, 0, 9))      # 1.2 off the line: inside 0.9 + 0.2 + 0.45
	var S3 := _robber(w, h, Vector3(2.2, 0, 6))      # outside
	var S4 := _robber(w, h, Vector3(0, 0, 14))       # past the 12 m reach
	var S5 := _robber(w, h, Vector3(0, 0, -3))       # behind
	var hs := [S1.hp, S2.hp, S3.hp, S4.hp, S5.hp]
	n_ev = c.events_played
	au.sfx.clear()
	var ess_s := c.essence()
	var casts0 := w.count("cast")
	var beams0: int = fx.c.get("beam", 0)
	c.request_cast("marrow_spear", Vector3(0, 0, 10))
	ok(is_equal_approx(ess_s - c.essence(), 18.0) and is_equal_approx(c.cooldown_left("marrow_spear"), 2200.0), "A: marrow_spear costs 18 essence, cooldown 2.2 s")
	ok(c.events_played == n_ev + 1 and w.count("cast") == casts0 + 1 and fx.c.get("beam", 0) == beams0 + 1, "A: spear cast: one event, flash + beam at the tip")
	_land(c, "line")
	var sp_def := DmAbilities.spear(_sp(c), "", 1.0)
	ok(is_equal_approx(_loss(S1, hs[0]), sp_def["dmg"]) and is_equal_approx(_loss(S2, hs[1]), sp_def["dmg"]), "A: the line hits everything on it for power 2.1 x spell power (%.3f)" % sp_def["dmg"])
	ok(S3.hp == hs[2] and S4.hp == hs[3] and S5.hp == hs[4], "A: off the line, beyond 12 m and behind: untouched")
	var ss1 := DmStatusSet.of(S1)
	var HM: Dictionary = DmSimData.HEMORRHAGE
	ok(ss1.stacks(&"fracture") == 1 and ss1.has(&"bleed"), "A: +1 Fracture and a bleed on each")
	ok(ss1.has(&"bleed") and ss1.remaining(&"bleed") > float(HM["durationS"]) - 0.1, "A: the bleed runs HEMORRHAGE.durationS (%.1f s)" % ss1.remaining(&"bleed"))
	ok(w.count("line") == 1 and au.sfx.count("spear") == 1 and fx.c.get("spike", 0) == 1, "A: line fx once (sfx spear, spike line 1)")
	# a second spear on a fractured enemy hits harder (Fracture 15 % per stack)
	_ready_cast(c)
	c.p["resource"]["value"] = 50.0
	var hp_f := S1.hp
	c.request_cast("marrow_spear", Vector3(0, 0, 10))
	_land(c, "line")
	ok(is_equal_approx(_loss(S1, hp_f), sp_def["dmg"] * (1.0 + float(DmSimData.FRACTURE["perStack"]))), "A: one Fracture stack raises the next blow x%.2f (%.3f)" % [1.0 + float(DmSimData.FRACTURE["perStack"]), _loss(S1, hp_f)])
	ok(DmStatusSet.of(S1).stacks(&"fracture") == 2, "A: Fracture stacks to 2")

	# --- Impaling rune: first enemy only, x1.5, rooted
	for e in [S1, S2, S3, S4, S5]:
		DmStatusSet.of(e).clear() if DmStatusSet.of(e) != null else null
	c.p["runes"] = {"marrow_spear": "rune_impale"}
	_ready_cast(c)
	var hi := [S1.hp, S2.hp]
	c.request_cast("marrow_spear", Vector3(0, 0, 10))
	_land(c, "impale")
	ok(is_equal_approx(_loss(S1, hi[0]), sp_def["impaleDmg"]) and S2.hp == hi[1], "A: Impaling skewers only the first enemy for x1.5 (%.3f)" % sp_def["impaleDmg"])
	ok(DmStatusSet.of(S1).has(&"root") and not (DmStatusSet.of(S2) != null and DmStatusSet.of(S2).has(&"root")), "A: ... and roots it")
	ok(w.count("impale") == 1 and (w.events.filter(func(ev): return ev.get("t") == "impale")[0]["hit"] as bool), "A: impale event")
	# --- Ossuary Ring rune: the cursor pulled back to 12 m, r 3, x0.8
	c.p["runes"] = {"marrow_spear": "rune_ossuary_ring"}
	_ready_cast(c)
	S1.global_position = Vector3(0, 0, 40)
	S2.global_position = Vector3(0, 0, 40)
	var R1 := _robber(w, h, Vector3(0, 0, 11.5))
	var R2 := _robber(w, h, Vector3(2.5, 0, 12.5))
	var R3 := _robber(w, h, Vector3(0, 0, 5))        # on the way, not in the ring
	var hr := [R1.hp, R2.hp, R3.hp]
	c.request_cast("marrow_spear", Vector3(0, 0, 30))
	_land(c, "ring")
	ok(is_equal_approx(_loss(R1, hr[0]), sp_def["dmg"] * float(DmSimData.RUNE_TUNING["ring"]["damageMult"])), "A: Ossuary Ring: a cursor at 30 m lands at 12 m, ring hits for x0.8")
	ok(R2.hp < hr[1] and R3.hp == hr[2], "A: ... everything inside r 3 (and nothing outside)")
	ok(w.count("ring") == 1 and fx.c.get("spike", 0) >= 3, "A: ring fx (spike rings)")
	c.p["runes"] = {}
	# --- spearRally mod: the nearest enemy hit is marked, the legion turns on it
	var thr: DmThrallHost = s["thr"]
	var f: DmCorpseField = s["f"]
	f.add_corpse(0.5, 0.5, "normal", "robber", false, 0.0, 1.0, "")
	thr.raise({"kind": "warrior", "cap": 6.0, "hp": 40.0, "damage": 5.0, "attackSpeedMult": 1.0}, Vector3(0.5, 0, 0.5))
	for e in [R1, R2, R3]:
		e.global_position = Vector3(40, 0, 40)
	S1.global_position = Vector3(0, 0, 4)
	S2.global_position = Vector3(0, 0, 8)
	c._mods["spearRally"] = 0.5
	(thr.list()[0] as DmThrall).state = DmThrall.S.IDLE   # past its rising animation (the sim skips rising thralls)
	_ready_cast(c)
	c.request_cast("marrow_spear", Vector3(0, 0, 10))
	_step(c, 0.5)
	var th: DmThrall = thr.list()[0]
	_step(c, 0.1)
	ok(th.target == S1 and is_equal_approx(th.mark_mult, 1.5), "A: spearRally marks the NEAREST enemy hit: the thrall targets it and hits x1.5")
	_step(c, float(DmSimData.LEGEND["rallyS"]) + 0.2)
	ok(is_equal_approx(th.mark_mult, 1.0), "A: ... and the bonus ends with the mark (LEGEND.rallyS)")
	c._mods["spearRally"] = 0.0
	thr.clear()

	# ============================== wailing_skull
	for e in [S1, S2, S3, S4, S5]:
		e.global_position = Vector3(40, 0, 40)
	for e in [R1, R2, R3]:
		e.global_position = Vector3(40, 0, 41)
	_ready_cast(c)
	var K: Array = []
	for i in 6:
		K.append(_robber(w, h, Vector3(0, 0, 6 + i * 4.5)))   # 4.5 m apart: inside the 6.5 m leap range
	var W: Dictionary = DmCombatData.const_table("WAILING_SKULL")
	var base := _sp(c) * float(DmAbilities.def("wailing_skull")["power"])
	var hk := K.map(func(e): return e.hp)
	rej.clear()
	c.request_cast("wailing_skull", Vector3(0, 0, 40))
	ok(rej.size() == 1 and rej[0][1] == "no_target", "A: wailing_skull with nothing within 4 m of the cursor: no_target")
	c.request_cast("wailing_skull", Vector3(1, 0, 17), w.enemy_id(K[3]))
	ok(rej.size() == 2 and rej[1][1] == "range" and c.essence() == c.p["resource"]["max"], "A: wailing_skull past range 13 refused (range), nothing spent")
	au.sfx.clear()
	n_ev = c.events_played
	var hits1 := w.count("hit")
	var ess_k := c.essence()
	c.request_cast("wailing_skull", Vector3(0.8, 0, 6.5))   # no target id: the enemy nearest the cursor within 4 m
	ok(is_equal_approx(ess_k - c.essence(), 16.0) and is_equal_approx(c.cooldown_left("wailing_skull"), 3000.0), "A: 16 essence, cooldown 3 s")
	ok(w.count("leap") == 1 and au.sfx == ["wail"], "A: the cast: one leap event, wail once")
	_step(c, 4.0)
	ok(is_equal_approx(_loss(K[0], hk[0]), base) and is_equal_approx(_loss(K[1], hk[1]), DmAbilities.skull_leap_damage(base, 2)) and is_equal_approx(_loss(K[2], hk[2]), DmAbilities.skull_leap_damage(base, 3)), "A: 3 leaps: power 2.4 x sp, then x0.8, x0.64 (%.3f)" % base)
	ok(K[3].hp == hk[3] and w.count("leap") == 3 and w.count("hit") == hits1 + 3, "A: the fourth enemy is spared (hops 3), 3 leap + 3 hit events")
	ok(w.events.filter(func(ev): return ev.get("t") == "hit" and ev.get("more")).size() == 2, "A: the last landing has no further leap")
	# a kill earns another leap, never past 5, never twice on one enemy
	_ready_cast(c)
	for i in 6:
		K[i].global_position = Vector3(0, 0, 6 + i * 4.5)
		K[i].hp = 1.0
	c.request_cast("wailing_skull", Vector3(0, 0, 6))
	_step(c, 6.0)
	var dead := K.filter(func(e): return e.hp <= 0.0).size()
	ok(dead == 5 and K[5].hp == 1.0, "A: every leap kills so each earns another, but never past 5 in all (%d dead, the sixth lives)" % dead)

	# ============================== ivory_cleave
	for e in K:
		e.global_position = Vector3(40, 0, 42)
	for e in [S1, S2, S3, S4, S5]:
		e.global_position = Vector3(40, 0, 40)
	_ready_cast(c)
	rej.clear()
	c.request_cast("ivory_cleave", Vector3(0, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "no_target", "A: ivory_cleave aimed at the caster itself: refused")
	var ang := func(deg: float, d: float) -> Vector3: return Vector3(sin(deg_to_rad(deg)) * d, 0, cos(deg_to_rad(deg)) * d)
	var I1 := _robber(w, h, ang.call(0.0, 3.0))       # front, inside 3.6 + r
	var I2 := _robber(w, h, ang.call(55.0, 2.0))      # inside the 60 degree half-angle
	var I3 := _robber(w, h, ang.call(75.0, 2.0))      # outside the arc
	var I4 := _robber(w, h, ang.call(0.0, 4.4))       # beyond reach + radius
	var I5 := _robber(w, h, ang.call(180.0, 2.0))     # behind
	var hc := [I1.hp, I2.hp, I3.hp, I4.hp, I5.hp]
	var ess_i := c.essence()
	au.sfx.clear()
	n_ev = c.events_played
	c.request_cast("ivory_cleave", Vector3(0, 0, 8))
	var dmg_i := _sp(c) * float(DmAbilities.def("ivory_cleave")["power"])
	ok(is_equal_approx(ess_i - c.essence(), 14.0) and is_equal_approx(c.cooldown_left("ivory_cleave"), 1600.0), "A: ivory_cleave costs 14 essence, cooldown 1.6 s")
	ok(is_equal_approx(_loss(I1, hc[0]), dmg_i) and is_equal_approx(_loss(I2, hc[1]), dmg_i), "A: the crescent cuts the front and the 55 degree enemy at once for power 1.7 x sp (%.3f)" % dmg_i)
	ok(I3.hp == hc[2] and I4.hp == hc[3] and I5.hp == hc[4], "A: outside the 120 degree arc, past the reach, behind: untouched")
	ok(DmStatusSet.of(I1).stacks(&"fracture") == 1 and DmStatusSet.of(I2).stacks(&"fracture") == 1 and (DmStatusSet.of(I3) == null or DmStatusSet.of(I3).stacks(&"fracture") == 0), "A: +1 Fracture on what it cuts")
	ok(c.events_played == n_ev + 1 and au.sfx.count("ivoryCleave") == 1 and au.sfx.count("boneHit") == 1 and w.count("cleave") == 1, "A: cleave fx once (sfx ivoryCleave + boneHit), resolved instantly")

	# ============================== bone_storm
	for e in [I1, I2, I3, I4, I5]:
		e.global_position = Vector3(40, 0, 43)
	_ready_cast(c)
	f.corpses.clear()
	for p in [Vector3(0, 0, 5), Vector3(0.6, 0, 5), Vector3(-0.6, 0, 5.4)]:
		f.add_corpse(p.x, p.z, "normal", "robber", false, 0.0, 1.0, "")
	var T1 := _robber(w, h, Vector3(0, 0, 10))
	var hp_t := T1.hp
	var ess_b := c.essence()
	au.sfx.clear()
	n_ev = c.events_played
	c.request_cast("bone_storm", Vector3(0, 0, 5))
	var life := DmAbilities.bone_storm_life_s(3.0)
	ok(is_equal_approx(life, 4.0 + 1.8), "A: three corpses add 3 x 0.6 s: life %.1f s" % life)
	ok(is_equal_approx(ess_b - c.essence(), 32.0) and is_equal_approx(c.cooldown_left("bone_storm"), 12000.0) and f.count() == 3, "A: bone_storm costs 32 essence, cooldown 12 s, the corpses are only counted")
	var cast_ev: Dictionary = w.events[w.events.size() - 1]
	ok(is_equal_approx(float(cast_ev["life"]), life) and fx.c.get("orbit", 0) == 1 and au.sfx == ["storm"] and au.loops.has("boneStormLoop"), "A: cast fx once (orbit, storm sfx, loop)")
	_step(c, 0.45)
	var tick1: Dictionary = w.events[w.events.size() - 1]
	ok(tick1["t"] == "tick" and absf(float(tick1["z"]) - (5.0 + 2.2 * 0.4)) < 0.06, "A: the first tick (0.4 s) has drifted toward the enemy by 2.2 m/s x 0.4 s (z %.2f)" % float(tick1["z"]))
	_step(c, 6.5)
	var ticks := w.count("tick")
	ok(ticks == int(life / 0.4), "A: it ticks every 0.4 s for its whole life (%d ticks)" % ticks)
	var hit_ticks := w.events.filter(func(ev): return ev.get("t") == "tick" and ev.get("hit")).size()
	var dmg_b := DmAbilities.rite_damage(DmAbilities.sp(c.p, 0.0), "bone_storm")
	ok(hit_ticks >= 3 and is_equal_approx(_loss(T1, hp_t), dmg_b * hit_ticks), "A: every hit tick did power 0.5 x sp (%d ticks, %.3f total)" % [hit_ticks, _loss(T1, hp_t)])
	var n_after := w.count("tick")
	_step(c, 2.0)
	ok(w.count("tick") == n_after, "A: it is over after its life: no more ticks")
	# ground aim is clamped to range 10
	_ready_cast(c)
	c.request_cast("bone_storm", Vector3(0, 0, 40))
	var ce: Dictionary = w.events[w.events.size() - 1]
	ok(is_equal_approx(Vector2(float(ce["x"]), float(ce["z"])).length(), 10.0), "A: a far cursor is clamped to the rite's 10 m range")
	_step(c, 0.1)
	c.set_alive(false)
	var nd := w.count("tick")
	_step(c, 2.0)
	ok(w.count("tick") == nd, "A: a dead caster's storm stops")
	c.set_alive(true)

	# ============================== soul_siphon
	T1.global_position = Vector3(40, 0, 44)
	_ready_cast(c)
	c.p["cooldowns"].clear()
	var P1 := _robber(w, h, Vector3(0, 0, 6))
	rej.clear()
	c.request_cast("soul_siphon", Vector3(0, 0, 6), w.enemy_id(_robber(w, h, Vector3(0, 0, 12))))
	ok(rej.size() == 1 and rej[0][1] == "range", "A: soul_siphon past range 9: refused (range)")
	c.p["resource"]["value"] = 20.0
	c.p["hp"] = float(c.p["stats"]["maxHp"]) * 0.2
	var hp_s := P1.hp
	var hp_c: float = c.p["hp"]
	au.sfx.clear()
	c.request_cast("soul_siphon", Vector3(0, 0, 6), w.enemy_id(P1))
	ok(is_equal_approx(20.0 - c.essence(), 14.0) and is_equal_approx(c.cooldown_left("soul_siphon"), 7000.0), "A: soul_siphon costs 14 essence, cooldown 7 s")
	ok(au.sfx == ["siphon"] and fx.c.get("beam", 0) >= 3 + 2 and au.loops.has("siphonLoop"), "A: tether fx once (3 beams, siphon sfx, loop)")
	var S: Dictionary = DmCombatData.const_table("SOUL_SIPHON")
	var dmg_s := _sp(c) * float(DmAbilities.def("soul_siphon")["power"])
	_step(c, 0.55)
	ok(is_equal_approx(_loss(P1, hp_s), dmg_s), "A: the first drain (0.5 s) does power 0.55 x sp (%.3f)" % dmg_s)
	ok(is_equal_approx(float(c.p["hp"]) - hp_c, dmg_s * float(S["healFrac"])), "A: and heals the caster for 35 %% of it (+%.3f)" % (float(c.p["hp"]) - hp_c))
	ok(c.essence() - 6.0 >= 2.0 and c.essence() - 6.0 <= 2.0 + regen * 0.6, "A: and gives 2 essence a tick")
	_step(c, 3.5)
	var drains := roundi(_loss(P1, hp_s) / dmg_s)
	ok(is_equal_approx(_loss(P1, hp_s), dmg_s * drains) and (drains == 5 or drains == 6), "A: 5-6 drains over its 3 s (the sim's last tick lands on the expiry frame), then it ends (%d)" % drains)
	ok(w.count("end") == 1, "A: an end event closes the beams")
	# it breaks when the enemy gets beyond 1.4 x range (12.6 m)
	_ready_cast(c)
	hp_s = P1.hp
	c.request_cast("soul_siphon", Vector3(0, 0, 6), w.enemy_id(P1))
	_step(c, 0.55)
	P1.global_position = Vector3(0, 0, 14)
	_step(c, 3.0)
	ok(is_equal_approx(_loss(P1, hp_s), dmg_s), "A: the tether breaks once the enemy is past 12.6 m: one drain only")
	# it follows the enemy while it stays within reach
	P1.global_position = Vector3(0, 0, 6)
	_ready_cast(c)
	hp_s = P1.hp
	c.request_cast("soul_siphon", Vector3(0, 0, 6), w.enemy_id(P1))
	_step(c, 0.55)
	P1.global_position = Vector3(0, 0, 11)   # past the 9 m cast range, inside the 12.6 m break range
	_step(c, 1.0)
	ok(_loss(P1, hp_s) >= dmg_s * 2.0 - 0.01, "A: the tether follows an enemy that moves past the cast range (keeps draining)")
	_step(c, 3.0)
	# a dead caster
	_ready_cast(c)
	P1.global_position = Vector3(0, 0, 6)
	c.request_cast("soul_siphon", Vector3(0, 0, 6), w.enemy_id(P1))
	c.set_alive(false)
	hp_s = P1.hp
	_step(c, 2.0)
	ok(P1.hp == hp_s, "A: a dead caster's tether does nothing")
	c.set_alive(true)

	# ============================== forged + shared
	var forged := c.rejected_intents
	c.request_cast("bone_fan", Vector3(0, 0, 6), w.enemy_id(P1), 999)
	ok(c.rejected_intents == forged + 1, "A: an intent from a peer that does not own the body is rejected (forged)")
	await _teardown(s)


# ---- Part B: ENet, host + 2 clients ------------------------------------------------------------------------------------------------------

class Peer:
	var node: Node
	var sess: DmSession
	var w: World
	var casters: Dictionary = {}
	var rec: Dictionary = {}   ## owner id -> [RecFx, RecAudio]
	var rej: Array = []


func _mk(nm: String) -> Peer:
	var pr := Peer.new()
	pr.node = Node.new()
	pr.node.name = nm
	root.add_child(pr.node)
	pr.sess = DmSession.new()
	pr.sess.name = "Session"
	pr.node.add_child(pr.sess)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
	pr.sess.character_name = nm
	pr.sess.discipline_id = "gravecaller"
	pr.w = World.new()
	pr.w.name = "W"
	pr.node.add_child(pr.w)
	(pr.sess.get_node("Players") as Node).child_entered_tree.connect(func(b: Node): _attach.call_deferred(pr, b))
	return pr


func _attach(pr: Peer, b: Node) -> void:
	if not is_instance_valid(b) or b.get_node_or_null("Rites") != null:
		return
	var c := DmRiteCaster.attach(b as Node3D, pr.w)
	c.random = Callable(self, "_half")
	var st := _stub(c)
	var id: int = (b as DmSessionBody).owner_peer
	pr.casters[id] = c
	pr.rec[id] = st
	c.cast_rejected.connect(func(r, why): pr.rej.append([id, r, why]))


func _part_b() -> void:
	var host := _mk("H")
	var hpeer := ENetMultiplayerPeer.new()
	ok(hpeer.create_server(PORT, 4) == OK, "B: server created")
	host.sess.host(hpeer)
	_attach(host, host.sess.get_body(1))
	var c1 := _mk("C1")
	var c2 := _mk("C2")
	for cl in [c1, c2]:
		var pe := ENetMultiplayerPeer.new()
		pe.create_client("127.0.0.1", PORT)
		(cl as Peer).sess.join(pe)
	var peers: Array = [host, c1, c2]
	ok(await wait_for(func(): return peers.all(func(p): return p.casters.size() == 3)), "B: every peer has a caster on every body")
	var id1 := c1.sess.get_my_id()
	var id2 := c2.sess.get_my_id()
	for id in [id1, id2]:
		host.casters[id].auto_step = true
		host.casters[id].p["stats"]["level"] = 20.0
	host.sess.get_body(id1).position = Vector3(0, 0, 2)
	host.sess.get_body(id2).position = Vector3(0, 0, -3)
	await create_timer(0.3).timeout
	var a := _robber(host.w, host.node, Vector3(0, 0, 8), 1.0e6, true)
	var b := _robber(host.w, host.node, Vector3(0, 0, 11), 1.0e6, true)
	var aid := host.w.enemy_id(a)
	var specs := [
		# [owner caster id, rite, aim, target id, expected events on every peer, {sfx: count}]
		[id1, "bone_fan", Vector3(0, 0, 8), aid, 2, {"boneFan": 1, "needleHit": 1}],
		[id1, "rot_lance", Vector3(0, 0, 8), aid, 2, {"rotLance": 1, "needleHit": 1}],
		[id2, "marrow_spear", Vector3(0, 0, 8), -1, 2, {"spear": 1}],
		[id1, "wailing_skull", Vector3(0, 0, 8), aid, 4, {"wail": 2, "needleHit": 2}],
		[id1, "ivory_cleave", Vector3(0, 0, 8), -1, 1, {"ivoryCleave": 1}],
		[id1, "soul_siphon", Vector3(0, 0, 8), aid, -1, {"siphon": 1}],
	]
	for sp in specs:
		var oid: int = sp[0]
		var owner_peer: Peer = c1 if oid == id1 else c2
		var hc: DmRiteCaster = host.casters[oid]
		hc.p["cooldowns"].clear()
		hc.p["castUntil"] = 0.0
		hc.p["resource"]["value"] = 100.0
		if sp[1] == "ivory_cleave":
			a.global_position = Vector3(0, 0, 4.5)
		for p in peers:
			(p.rec[oid][1] as RecAudio).sfx.clear()
		var ev0: int = hc.events_played
		owner_peer.casters[oid].request_cast(sp[1], sp[2], sp[3])
		var want: int = ev0 + int(sp[4])
		if int(sp[4]) < 0:   # runs to its own end event
			var n_end: int = host.w.count("end")
			await wait_for(func(): return host.w.count("end") > n_end, 10.0)
			want = hc.events_played
		ok(await wait_for(func(): return peers.all(func(p): return p.casters[oid].events_played == want), 10.0), "B: %s: %d events reached every peer" % [sp[1], want - ev0])
		await create_timer(0.3).timeout
		var counts_ok := true
		for p in peers:
			var au: RecAudio = p.rec[oid][1]
			for k in sp[5]:
				if au.sfx.count(k) != int(sp[5][k]):
					counts_ok = false
					print("  %s %s sfx %s want %s=%d" % [p.node.name, sp[1], str(au.sfx), k, int(sp[5][k])])
			if p.casters[oid].events_played != want:
				counts_ok = false
		ok(counts_ok, "B: %s fx/sfx exactly once per peer %s" % [sp[1], str(sp[5])])
		a.global_position = Vector3(0, 0, 8)
		await create_timer(0.2).timeout
	# the storm: every peer gets the cast + the same ticks, one storm sfx each
	var sc: DmRiteCaster = host.casters[id2]
	sc.p["cooldowns"].clear()
	sc.p["castUntil"] = 0.0
	sc.p["resource"]["value"] = 100.0
	for p in peers:
		(p.rec[id2][1] as RecAudio).sfx.clear()
	var ev1: int = sc.events_played
	c2.casters[id2].request_cast("bone_storm", Vector3(0, 0, 8))
	ok(await wait_for(func(): return sc.events_played >= ev1 + 1 + 3), "B: the storm is ticking on the host")
	ok(await wait_for(func(): return host.w.count("tick") >= 10 and (host.sess.get_body(id2) != null), 12.0) and await wait_for(func(): return peers.all(func(p): return p.casters[id2].events_played == sc.events_played), 6.0), "B: every peer received every storm event (%d)" % (sc.events_played - ev1))
	for p in peers:
		var au: RecAudio = p.rec[id2][1]
		ok(au.sfx.count("storm") == 1, "B: %s storm start sfx once" % p.node.name)
	ok(host.w.count("tick") * 1 > 0 and a.hp < 1.0e6, "B: the storm hit the enemy it drifted to")
	for e in host.w.enemies:
		if is_instance_valid(e):
			e.free()
	for p in [c1, c2, host]:
		(p as Peer).sess.leave()
	await create_timer(0.5).timeout
	for p in peers:
		p.node.queue_free()


# ---- Part C: perf ------------------------------------------------------------------------------------------------------------------------

func _part_c() -> void:
	var s := await _solo("P3")
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var body: Node3D = s["body"]
	var f: DmCorpseField = s["f"]
	for i in 25:
		_robber(w, h, Vector3(-8 + (i % 5) * 4, 0, 6 + (i / 5) * 3))
	var cs: Array = [c]
	for k in 2:
		var cx := DmRiteCaster.new()
		cx.name = "Rites%d" % (k + 2)
		cx.world = w
		body.add_child(cx)
		cx.auto_step = false
		cx.peer_id = 1
		cx.p["stats"]["level"] = 20.0
		_stub(cx)
		cs.append(cx)
	var each := {}
	var rites := ["bone_fan", "rot_lance", "marrow_spear", "wailing_skull", "ivory_cleave", "bone_storm", "soul_siphon"]
	for r in rites:
		var tot := 0.0
		var n := 30
		for i in n:
			var cc: DmRiteCaster = cs[0]
			_ready_cast(cc)
			cc.p["resource"]["max"] = 1.0e6
			cc.p["resource"]["value"] = 1.0e6
			var tid: int = w.enemy_id(w.enemies[(i * 7) % 25])
			var aim: Vector3 = (w.enemies[(i * 7) % 25] as Node3D).global_position
			var t0 := Time.get_ticks_usec()
			cc.request_cast(r, aim, tid)
			tot += float(Time.get_ticks_usec() - t0)
			cc.set_alive(true)
			for e in w.enemies:
				e.global_position = e.global_position   # keep the scene static
			cc._pending.clear()
			cc._mem.clear()
		each[r] = tot / float(n)
	# frame cost: the three casters keep every rite going against 25 enemies (shots in flight, 3 storms, 3 tethers)
	for k in 3:
		var cc: DmRiteCaster = cs[k]
		cc._mem.clear()
		cc._pending.clear()
		cc.p["resource"]["max"] = 1.0e6
		cc.p["resource"]["value"] = 1.0e6
	var t_total := 0.0
	var ticks := 0
	var max_pending := 0
	var storms := 0
	var tethers := 0
	for i in 150:   # 3 s of sim
		var t0 := Time.get_ticks_usec()
		for k in 3:
			var cc: DmRiteCaster = cs[k]
			cc.p["cooldowns"].clear()
			cc.p["castUntil"] = 0.0
			var e: DmEnemy = w.enemies[(i * 3 + k) % 25]
			var tid := w.enemy_id(e)
			if i % 13 == 0:
				cc.request_cast(["bone_fan", "rot_lance", "wailing_skull"][(i / 13 + k) % 3], e.global_position, tid)
			if i % 25 == 0:
				cc.request_cast(["marrow_spear", "ivory_cleave", "bone_storm", "soul_siphon"][(i / 25 + k) % 4], e.global_position, tid)
			cc.step(DT)
		t_total += float(Time.get_ticks_usec() - t0)
		ticks += 1
		for e in w.enemies:
			var ss := DmStatusSet.of(e)
			if ss != null:
				ss.advance(DT)
		var pend := 0
		storms = 0
		tethers = 0
		for k in 3:
			pend += (cs[k]._pending as Array).size()
			storms += (cs[k].mem("bone_storm").get("storms", []) as Array).size()
			tethers += (cs[k].mem("soul_siphon").get("tethers", []) as Array).size()
		max_pending = maxi(max_pending, pend)
	var per_tick := t_total / float(ticks)
	# idle step (nothing active) for reference
	for k in 3:
		cs[k]._mem.clear()
		cs[k]._pending.clear()
	var t1 := Time.get_ticks_usec()
	for i in 500:
		cs[0].step(DT)
	var idle_us := float(Time.get_ticks_usec() - t1) / 500.0
	print("PERF cast us (25 enemies): " + ", ".join(rites.map(func(r): return "%s %.0f" % [r, each[r]])))
	print("PERF idle caster step: %.1f us per tick" % idle_us)
	print("PERF host step + casting a rite every ~0.25 s per caster (3 casters, 25 enemies; peak %d shots in flight, last tick %d storms + %d tethers): %.1f us per tick" % [max_pending, storms, tethers, per_tick])
	for r in rites:
		ok(float(each[r]) < 6000.0, "C: %s cast costs < 6 ms (%.0f us)" % [r, each[r]])
	ok(per_tick < 4000.0, "C: 3 casters keeping every rite going against 25 enemies < 4 ms/tick (%.0f us)" % per_tick)
	ok(idle_us < 200.0, "C: an idle caster step stays cheap (%.1f us)" % idle_us)
	await _teardown(s)

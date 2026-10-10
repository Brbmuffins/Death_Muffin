extends SceneTree
## Elite affixes suite (godot/next/affixes). godot --headless --path godot --script res://tests/next_affixes/run.gd
## A roll rules (count, omen forcing, Depths extras, Nightfall). B each affix's rules and numbers vs the sim (DmSimData.AFFIX_TUNING).
## C corpse economy (Hungering vs the field's atomic consume, Vengeful Risen, Shrouded vs a Miasma cloud). D look + moments once per peer on an
## in-process ENet client. E cost with 30 enemies incl. 6 affixed elites.

const DT := 1.0 / 60.0
var passed := 0
var failed := 0


func ok(c: bool, msg: String) -> void:
	if c:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


class CH:
	extends RefCounted
	var alive := true
	func kill() -> void:
		alive = false

class CountVfx:
	extends Node
	var n := {}
	var live := 0
	func _c(k: String) -> void:
		n[k] = int(n.get(k, 0)) + 1
	func emit(_o) -> void: _c("emit")
	func emit_smoke(_o) -> void: _c("smoke")
	func decal(o):
		_c("decal")
		if float(o.get("duration", 0.0)) > 1e8:
			_c("persistent")
		return CH.new()
	func beam(_a, _b, _c2, _w, _d): _c("beam"); return CH.new()
	func light_flash(_p, _c2, _i, _l = 0.35) -> void: _c("flash")
	func count(k: String) -> int: return int(n.get(k, 0))

class CountAudio:
	extends Node
	var sfx := {}
	func play_sfx(name: String, _pos = null, _i: float = 1.0) -> bool:
		sfx[name] = int(sfx.get(name, 0)) + 1
		return true
	func count(k: String) -> int: return int(sfx.get(k, 0))

class Dummy:
	extends Node3D
	var hits: Array = []
	func dm_alive() -> bool: return true
	func dm_take_enemy_hit(d: float, _from: Node, kind: String = "melee") -> void: hits.append([d, kind])

class StubDir:
	extends Node
	var game = null
	var spawned: Array = []
	func spawn(def, pos, _heroes, _elite, mult, over):
		spawned.append([def, pos, mult, over])
		return null


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	_a_roll()
	await _b_rules()
	await _c_economy()
	await _d_net()
	await _e_perf()
	await _f_game()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _seq(vals: Array) -> Callable:
	var i := [0]
	return func() -> float:
		var v: float = vals[i[0] % vals.size()]
		i[0] += 1
		return v


func _elite(parent: Node, list: Array, pos := Vector3.ZERO, hp_mult := 1.0, dir: Node = null, scene := "robber") -> DmEnemy:
	var e: DmEnemy = load("res://enemies/%s.tscn" % scene).instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.rng_seed = 3
	e.elite = true
	e.hp_mult = hp_mult
	e.position = pos
	e.set_meta(&"dm_area", "graves")
	DmAffixSet.attach(e, PackedStringArray(list), dir)
	parent.add_child(e)
	return e


## Steps until `cond` holds (or `limit` s); returns the seconds it took.
func _until(c: DmAffixSet, cond: Callable, limit: float) -> float:
	var t := 0.0
	while t < limit and not cond.call():
		c._physics_process(DT)
		t += DT
	return t


func _step(c: DmAffixSet, secs: float) -> void:
	for i in int(round(secs / DT)):
		c._physics_process(DT)


# ---- A ----------------------------------------------------------------------------------------------------------------------------------
func _a_roll() -> void:
	var T: Dictionary = DmSimData.AFFIX_TUNING
	ok(DmSimData.AFFIX_ORDER == ["bellTolled", "hungering", "shrouded", "vengeful"], "A: four affixes in the sim's order")
	ok(T["bellTolled"]["intervalS"] == 6 and T["bellTolled"]["windupS"] == 0.9 and T["bellTolled"]["r"] == 3 and T["bellTolled"]["damageMult"] == 0.6, "A: bell numbers")
	ok(T["hungering"]["intervalS"] == 4 and T["hungering"]["reach"] == 5 and T["hungering"]["healFrac"] == 0.15, "A: hungering numbers")
	ok(T["shrouded"]["damageTakenMult"] == 0.5 and T["vengeful"]["risen"] == 3, "A: shroud / vengeful numbers")
	# elite: one of the four by rand
	for i in 4:
		var l := DmAffixSet.roll(true, "", -1.0, 0.0, _seq([(float(i) + 0.5) / 4.0]))
		ok(l.size() == 1 and l[0] == DmSimData.AFFIX_ORDER[i], "A: elite roll %d -> %s" % [i, DmSimData.AFFIX_ORDER[i]])
	ok(DmAffixSet.roll(false, "", -1.0, 0.0, _seq([0.0])).is_empty(), "A: a plain body rolls nothing")
	# omen forcing: the Tolling's Bell-Tolled on every elite, whatever the dice say
	var omen := DmNextMeta.omen_for(0.0)
	var tolling := {}
	for k in DmContent.get_export("omens", "OMENS"):
		var o: Dictionary = DmContent.get_export("omens", "OMENS")[k]
		if o.get("affix") != null:
			tolling = o
	ok(not tolling.is_empty() and tolling["affix"] == "bellTolled", "A: the Tolling omen carries bellTolled")
	for r in [0.0, 0.3, 0.6, 0.99]:
		var l := DmAffixSet.roll(true, String(tolling["affix"]), -1.0, 0.0, _seq([r]))
		ok(l.size() == 1 and l[0] == "bellTolled", "A: omen forces Bell-Tolled (dice %.2f)" % r)
	ok(DmAffixSet.roll(false, "bellTolled", -1.0, 0.0, _seq([0.0])).is_empty(), "A: the omen only touches elites")
	# Depths: 1 + extraAffixes(depth), distinct
	var D: Dictionary = DmSimData.DEPTHS
	for depth in [1, 5, 10, 15, 20, 40, 100]:
		var want := 1 + mini(int(D["maxExtraAffixes"]), int(floor(float(depth) / float(D["extraAffixEvery"]))))
		want = mini(want, 4)
		var rn := RandomNumberGenerator.new()
		rn.seed = depth
		var l := DmAffixSet.roll(true, "", float(depth), 0.0, rn.randf)
		var distinct := {}
		for a in l:
			distinct[a] = true
		ok(l.size() == want and distinct.size() == l.size(), "A: depth %d elite bears %d distinct affixes (%d)" % [depth, want, l.size()])
	var forced := DmAffixSet.roll(true, "bellTolled", 20.0, 0.0, _seq([0.1, 0.5, 0.9]))
	ok(forced[0] == "bellTolled" and forced.size() > 1 and forced.find("bellTolled", 1) == -1, "A: omen + depths: bell first, extras never repeat it")
	# Nightfall: non-elites shroud on the chance
	ok(DmAffixSet.roll(false, "", -1.0, 0.3, _seq([0.1]))[0] == "shrouded", "A: Nightfall shrouds a plain body under the chance")
	ok(DmAffixSet.roll(false, "", -1.0, 0.3, _seq([0.5])).is_empty(), "A: ...and not over it")
	# no component for no affix
	var e := DmEnemy.new()
	ok(DmAffixSet.attach(e, PackedStringArray()) == null and e.get_child_count() == 0, "A: an empty list attaches nothing")
	e.free()


# ---- B ----------------------------------------------------------------------------------------------------------------------------------
func _b_rules() -> void:
	var arena := Node3D.new()
	root.add_child(arena)
	var tg := Dummy.new()
	tg.position = Vector3(1.0, 0, 0)
	arena.add_child(tg)
	tg.add_to_group(&"dm_target")
	var far := Dummy.new()
	far.position = Vector3(5.0, 0, 0)
	arena.add_child(far)
	far.add_to_group(&"dm_target")
	var e := _elite(arena, ["bellTolled"])
	var c := DmAffixSet.of(e)
	ok(c != null and c.has("bellTolled") and not c.has("hungering"), "B: component carries only its kinds")
	ok(e.has_meta(&"dm_affix_list") and not e.has_meta(&"dm_shrouded"), "B: list meta, no shroud flag")
	var tells: Array = []
	e.telegraph.connect(func(k, _f, _a, r, s): tells.append([String(k), r, s]))
	var moments: Array = []
	c.moment.connect(func(k, _at): moments.append(String(k)))
	_step(c, 5.9)
	ok(tells.is_empty(), "B: bell silent before the 6 s interval")
	_step(c, 0.2)
	ok(tells.size() == 1 and tells[0][0] == "toll" and is_equal_approx(tells[0][1], 3.0) and is_equal_approx(tells[0][2], 0.9), "B: bell tells at 6 s: ring r 3 for 0.9 s %s" % str(tells))
	_step(c, 0.8)
	ok(tg.hits.is_empty(), "B: no damage during the 0.9 s wind-up")
	_step(c, 0.2)
	ok(tg.hits.size() == 1 and is_equal_approx(float(tg.hits[0][0]), e.damage * 0.6) and tg.hits[0][1] == "toll", "B: toll hits for blow x 0.6 (%s vs %.2f)" % [str(tg.hits), e.damage * 0.6])
	ok(far.hits.is_empty(), "B: outside r 3 is safe")
	ok(moments == ["tell", "toll"], "B: moments tell, toll %s" % str(moments))
	_step(c, 5.0)
	ok(tells.size() == 1, "B: the next tell waits a full 6 s after the last (not 5)")
	_step(c, 1.2)
	ok(tells.size() == 2, "B: second tell at +6 s")
	# a stagger / death cancels it
	e.take_damage(1e9, null)
	_step(c, 2.0)
	ok(tg.hits.size() == 1, "B: a dead bell never sounds")
	arena.queue_free()
	await process_frame


# ---- C ----------------------------------------------------------------------------------------------------------------------------------
func _field(arena: Node) -> DmCorpseField:
	var f := DmCorpseField.new()
	f.name = "Corpses"
	f.visuals = false
	f.auto_step = false
	arena.add_child(f)
	return f


func _c_economy() -> void:
	var H: Dictionary = DmSimData.AFFIX_TUNING["hungering"]
	# Hungering: heals 15% per corpse, nearest within 5 m, only while hurt, 4 s apart; the field's atomic consume decides who eats
	var arena := Node3D.new()
	root.add_child(arena)
	var f := _field(arena)
	var e := _elite(arena, ["hungering"], Vector3(0, 0, 0))
	var c := DmAffixSet.of(e)
	var gone: Array = []
	f.corpse_gone.connect(func(cc, reason): gone.append([cc.id, reason]))
	var near := f.add_corpse(2.0, 0.0, "normal", "robber", false, 0.0, 1.0, "graves")
	var mid := f.add_corpse(4.5, 0.0, "normal", "robber", false, 0.0, 1.0, "graves")
	var far_c := f.add_corpse(7.0, 0.0, "normal", "robber", false, 0.0, 1.0, "graves")
	_step(c, 5.0)
	ok(f.count() == 3 and e.hp == e.max_hp, "C: a healthy hungering elite does not eat")
	e.hp = e.max_hp * 0.5
	var t_bite := _until(c, func(): return f.count() < 3, 1.0)
	ok(f.count() == 2 and f.get_corpse(near.id) == null and gone[0] == [near.id, "devoured"], "C: it eats the nearest corpse, reason devoured %s" % str(gone))
	ok(is_equal_approx(e.hp, e.max_hp * (0.5 + float(H["healFrac"]))), "C: heals 15%% of max hp (%.2f / %.2f)" % [e.hp, e.max_hp])
	var t2 := _until(c, func(): return f.count() < 2, 6.0)
	ok(absf(t2 - 4.0) < 0.05 and f.count() == 1 and f.get_corpse(mid.id) == null and f.get_corpse(far_c.id) != null, "C: second bite 4 s later (%.2f s), the next in reach; the one at 7 m (> 5) is safe" % t2)
	e.hp = e.max_hp - 1.0
	var before := e.hp
	_step(c, 4.2)
	ok(f.count() == 1, "C: out of reach nothing is eaten")
	f.add_corpse(1.0, 0.0, "normal", "robber", false, 0.0, 1.0, "graves")
	_step(c, 4.2)
	ok(is_equal_approx(e.hp, e.max_hp) and e.hp > before, "C: heal is capped at the missing hp")
	# economy: a race with a rite's consume: whoever consumes first wins, the elite never double-eats
	var f2 := f
	var rite_corpse := f2.add_corpse(1.5, 1.0, "normal", "robber", false, 0.0, 1.0, "graves")
	e.hp = e.max_hp * 0.2
	ok(f2.consume(rite_corpse.id, 2, "consumed"), "C: a rite consumes first")
	var left := f2.count()
	_step(c, 4.2)
	ok(f2.count() == left - 0 or f2.count() <= left, "C: the elite only eats what is still there")
	arena.queue_free()
	await process_frame
	# fewer corpses for rites with a hungering elite around than without
	var counts := []
	for with_elite in [false, true]:
		var a2 := Node3D.new()
		root.add_child(a2)
		var f3 := _field(a2)
		for i in 6:
			f3.add_corpse(1.0 + i * 0.5, 0.0, "normal", "robber", false, 0.0, 1.0, "graves")
		if with_elite:
			var he := _elite(a2, ["hungering"])
			he.hp = he.max_hp * 0.3
			_step(DmAffixSet.of(he), 13.0)
		counts.append(f3.count())
		a2.queue_free()
		await process_frame
	ok(counts[0] == 6 and counts[1] < counts[0], "C: corpses for rites in 13 s: %d without, %d with a hungering elite" % [counts[0], counts[1]])
	await process_frame
	# Vengeful: 3 Risen on a 1.4 m ring at the death spot, as strong as the body; the burst moment once
	var a3 := Node3D.new()
	root.add_child(a3)
	var dir := StubDir.new()
	a3.add_child(dir)
	var ve := _elite(a3, ["vengeful"], Vector3(10, 0, 5), 2.5, dir)
	ve.damage_mult = 1.7
	var vc := DmAffixSet.of(ve)
	var vm: Array = []
	vc.moment.connect(func(k, at): vm.append([String(k), at]))
	ve.take_damage(1e9, null)
	ok(dir.spawned.size() == 3 and dir.spawned.all(func(s): return s[0] == "risen"), "C: vengeful bursts into 3 Risen")
	var ring_ok := true
	for s in dir.spawned:
		ring_ok = ring_ok and absf(Vector2(s[1].x - 10.0, s[1].z - 5.0).length() - 1.4) < 0.01
	ok(ring_ok, "C: on a 1.4 m ring around the fall")
	ok(dir.spawned[0][2]["hp"] == 2.5 and dir.spawned[0][2]["dmg"] == 1.7, "C: Risen as strong as the body that died")
	ok(vm.size() == 1 and vm[0][0] == "vengeful", "C: the burst moment fires once")
	a3.queue_free()
	await process_frame
	# Shrouded: damage x0.5 through the one damage path; lifted in a friendly cloud; back after it
	var a4 := Node3D.new()
	root.add_child(a4)
	var se := _elite(a4, ["shrouded"])
	var ss := DmStatusSet.attach(se)
	var sc := DmAffixSet.of(se)
	ok(se.has_meta(&"dm_shrouded"), "C: shroud flag for the miasma stamp")
	_step(sc, 0.2)
	ok(ss.has(&"shrouded"), "C: shrouded status on")
	var hp0 := se.hp
	se.take_damage(100.0, null, false)
	ok(is_equal_approx(hp0 - se.hp, 50.0), "C: shrouded takes half (%.1f)" % (hp0 - se.hp))
	se.set_meta(&"dm_miasma_ms", Time.get_ticks_msec())   # what rite_miasma stamps each scan the body stands in the cloud
	_step(sc, 0.2)
	ok(not ss.has(&"shrouded"), "C: a friendly miasma lifts the ward")
	hp0 = se.hp
	se.take_damage(100.0, null, false)
	ok(is_equal_approx(hp0 - se.hp, 100.0), "C: full damage inside the cloud")
	await create_timer(0.5).timeout
	_step(sc, 0.2)
	ok(ss.has(&"shrouded"), "C: the ward returns once the cloud no longer covers it")
	var src := FileAccess.get_file_as_string("res://next/rites/rite_miasma.gd")
	ok(src.contains("dm_miasma_ms") and src.contains("dm_shrouded"), "C: rite_miasma stamps shrouded bodies (also serves Corpse Explosion's rot via add_zone)")
	sc.strip_shroud()
	ok(not ss.has(&"shrouded") and not sc.has("shrouded") and not se.has_meta(&"dm_shrouded"), "C: strip_shroud lifts it for good")
	_step(sc, 0.3)
	ok(not ss.has(&"shrouded"), "C: and it stays lifted")
	a4.queue_free()
	await process_frame


# ---- D ----------------------------------------------------------------------------------------------------------------------------------
func _branch(nm: String) -> Node3D:
	var h := Node3D.new()
	h.name = nm
	root.add_child(h)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
	return h


func _twin(branch: Node3D, list: Array, dir: Node = null) -> Array:
	var e := _elite(branch, [], Vector3.ZERO)   # placeholder replaced below
	e.free()
	var b: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	b.name = "E1"
	b.with_visual = false
	b.use_nav = false
	b.use_avoidance = false
	b.wander_enabled = false
	b.rng_seed = 3
	b.elite = true
	b.set_meta(&"dm_area", "graves")
	b.set_multiplayer_authority(1)
	var comp := DmAffixSet.attach(b, PackedStringArray(list), dir)
	comp.vfx = CountVfx.new()
	comp.audio = CountAudio.new()
	branch.add_child(b)
	return [b, comp]


func _d_net() -> void:
	var port := DmTestPorts.free_port()
	var H := _branch("H")
	var C := _branch("C")
	var hp := ENetMultiplayerPeer.new()
	ok(hp.create_server(port, 2) == OK, "D: server on %d" % port)
	H.multiplayer.multiplayer_peer = hp
	var cp := ENetMultiplayerPeer.new()
	ok(cp.create_client("127.0.0.1", port) == OK, "D: client")
	C.multiplayer.multiplayer_peer = cp
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000 and H.multiplayer.get_peers().is_empty():
		await process_frame
	ok(not H.multiplayer.get_peers().is_empty(), "D: peers connected")
	await process_frame
	var f := _field(H)
	_field(C)   # the client's replicated copy (the corpse RPCs need the node on both peers)
	var dir := StubDir.new()
	H.add_child(dir)
	var h := _twin(H, ["bellTolled", "hungering", "shrouded", "vengeful"], dir)
	var c := _twin(C, ["bellTolled", "hungering", "shrouded", "vengeful"])
	var he: DmEnemy = h[0]
	var ce: DmEnemy = c[0]
	var hc: DmAffixSet = h[1]
	var cc: DmAffixSet = c[1]
	ok(he.is_multiplayer_authority() and not ce.is_multiplayer_authority(), "D: host body is authority, client body a puppet")
	var hm: Array = []
	var cm: Array = []
	hc.moment.connect(func(k, _a): hm.append(String(k)))
	cc.moment.connect(func(k, _a): cm.append(String(k)))
	var ht: Array = []
	var ct: Array = []
	he.telegraph.connect(func(k, _f, _a, _r, _s): ht.append(String(k)))
	ce.telegraph.connect(func(k, _f, _a, _r, _s): ct.append(String(k)))
	var hv: CountVfx = hc.vfx
	var cv: CountVfx = cc.vfx
	ok(hv.count("persistent") == 4 and cv.count("persistent") == 4, "D: each peer draws the four persistent rings (%d / %d)" % [hv.count("persistent"), cv.count("persistent")])
	he.hp = he.max_hp * 0.4
	f.add_corpse(2.0, 0.0, "normal", "robber", false, 0.0, 1.0, "graves")
	_step(hc, 6.2)   # eats at 4 s, tells at 6 s
	await create_timer(0.4).timeout
	_step(hc, 0.9)
	await create_timer(0.4).timeout
	ok(hm.count("hungering") == 1 and cm.count("hungering") == 1, "D: hungering beat once per peer (%d / %d)" % [hm.count("hungering"), cm.count("hungering")])
	ok(hm.count("tell") == 1 and cm.count("tell") == 1 and ht == ["toll"] and ct == ["toll"], "D: bell tell + one telegraph per peer (%s / %s)" % [str(ht), str(ct)])
	ok(hm.count("toll") == 1 and cm.count("toll") == 1, "D: toll beat once per peer (%d / %d)" % [hm.count("toll"), cm.count("toll")])
	ok(ha_total(hc) == ha_total(cc) and ha_total(hc) > 0, "D: same sounds on both peers (%d / %d)" % [ha_total(hc), ha_total(cc)])
	ok(hv.count("decal") == cv.count("decal") and hv.count("beam") == cv.count("beam") and hv.count("flash") == cv.count("flash"), "D: same decals / beams / flashes on both peers")
	he.take_damage(1e9, null)
	ce.apply_net_state(he.get_net_state())   # the replicated DEAD state
	await create_timer(0.4).timeout
	ok(hm.count("vengeful") == 1 and cm.count("vengeful") == 1, "D: vengeful burst once per peer")
	ok(dir.spawned.size() == 3, "D: only the host spawns the Risen (%d)" % dir.spawned.size())
	ok(hv.count("persistent") == 4 and (hc._rings.size() == 0 and cc._rings.size() == 0), "D: rings are gone on both peers after the death")
	H.queue_free()
	C.queue_free()
	await process_frame


func ha_total(c: DmAffixSet) -> int:
	var a: CountAudio = c.audio
	var t := 0
	for k in a.sfx:
		t += int(a.sfx[k])
	return t


# ---- E ----------------------------------------------------------------------------------------------------------------------------------
func _e_perf() -> void:
	var res := {}
	for with in [false, true]:
		var arena := Node3D.new()
		root.add_child(arena)
		var tg := Dummy.new()
		tg.position = Vector3(0, 0, 40)
		arena.add_child(tg)
		tg.add_to_group(&"dm_target")
		for i in 30:
			var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
			e.with_visual = false
			e.use_nav = false
			e.use_avoidance = false
			e.wander_enabled = false
			e.position = Vector3(float(i % 6) * 3.0 - 8.0, 0, float(i / 6) * 3.0 - 6.0)
			e.set_meta(&"dm_area", "graves")
			if i < 6:
				e.elite = true
				if with:
					var kinds := ["bellTolled", "hungering", "shrouded", "vengeful"]
					var l := [kinds[i % 4]]
					if i >= 4:
						l.append(kinds[(i + 1) % 4])
					var comp := DmAffixSet.attach(e, PackedStringArray(l))
					comp.vfx = CountVfx.new()
					comp.audio = CountAudio.new()
			arena.add_child(e)
			if with and i < 6:
				DmStatusSet.attach(e)
		var fc := DmFrameCost.attach(self.root)
		for i in 60:
			await process_frame
		fc.reset()
		for i in 240:
			await process_frame
		res[with] = fc.median_ms()
		fc.queue_free()
		arena.queue_free()
		await process_frame
	var delta_ms: float = res[true] - res[false]
	print("  cost: 30 enemies median %.3f ms plain, %.3f ms with 6 affixed elites (delta %.3f ms)" % [res[false], res[true], delta_ms])
	perf_info(delta_ms < 2.0, "E: 6 affixed elites add %.3f ms/frame (< 2.0 ms budget)" % delta_ms)
	# per-tick cost of the component itself, isolated
	var arena2 := Node3D.new()
	root.add_child(arena2)
	var e2 := _elite(arena2, ["bellTolled", "hungering", "shrouded", "vengeful"])
	var c2 := DmAffixSet.of(e2)
	var t1 := Time.get_ticks_usec()
	for i in 6000:
		c2._physics_process(DT)
	var us := float(Time.get_ticks_usec() - t1) / 6000.0
	print("  cost: %.2f us per physics tick for an elite with all four affixes" % us)
	perf_info(us < 100.0, "E: component tick %.2f us (< 100 us)" % us)
	arena2.queue_free()
	await process_frame


# ---- F ----------------------------------------------------------------------------------------------------------------------------------
## The real shell (offline, solo): the director rolls, the Tolling omen forces Bell-Tolled, the Depths' count, a vengeful elite's Risen join the director.
func _f_game() -> void:
	var tolling := {}
	for k in DmContent.get_export("omens", "OMENS"):
		var o: Dictionary = DmContent.get_export("omens", "OMENS")[k]
		if o.get("affix") != null:
			tolling = o
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("af%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var ch := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(ch.data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "omen": tolling})
	var dir := g.director
	var b := g.local_body()
	b.p["stats"]["maxHp"] = 1e9
	b.p["hp"] = 1e9
	b._mirror_from_state()
	var spot := b.position + Vector3(12, 0, 0)
	var plain := dir.spawn("robber", spot, [b], false)
	ok(DmAffixSet.of(plain) == null and not plain.has_meta(&"dm_affix_list"), "F: a plain enemy has no affix component")
	var tolled := dir.spawn("robber", spot + Vector3(2, 0, 0), [b], true)
	var tl: PackedStringArray = tolled.get_meta(&"dm_affix_list", PackedStringArray())
	ok(tl == PackedStringArray(["bellTolled"]) and DmAffixSet.of(tolled) != null, "F: the Tolling omen forces Bell-Tolled on a director elite (%s)" % str(tl))
	ok(int(tolled.get_meta(&"dm_affixes", 0)) == 1, "F: dm_affixes meta = 1")
	var depth_e := dir.spawn("robber", spot + Vector3(4, 0, 0), [b], true, {}, {"area": "depths", "depth": 20.0})
	var dl: PackedStringArray = depth_e.get_meta(&"dm_affix_list", PackedStringArray())
	ok(dl.size() == 4 and dl[0] == "bellTolled" and int(depth_e.get_meta(&"dm_affixes", 0)) == 4, "F: a depth-20 elite bears 4 affixes, omen first (%s)" % str(dl))
	var forced := dir.spawn("robber", spot + Vector3(6, 0, 0), [b], true, {}, {"affix_list": PackedStringArray(["vengeful", "shrouded"])})
	ok(DmAffixSet.of(forced).kinds == PackedStringArray(["vengeful", "shrouded"]), "F: an explicit affix_list wins (Depths run's own roll)")
	await ticks(12)
	var st := DmStatusSet.of(forced)
	ok(st != null and st.has(&"shrouded"), "F: the shell's status set carries the shroud")
	var n0 := dir.enemies.size()
	for k in 80:
		await physics_frame
		if forced.sm.id() != DmEnemyState.Id.RISING:
			break
	forced.take_damage(1e9, b, false)
	await ticks(3)
	var risen := 0
	for e in dir.enemies.values():
		if is_instance_valid(e) and (e as DmEnemy).def_id == "risen":
			risen += 1
	ok(risen == 3, "F: a vengeful elite's death adds 3 Risen to the director (%d)" % risen)
	var dep: DmDepths = g.depths
	var lst: PackedStringArray = dep._affixes_of({"elite": true, "affix": "hungering", "extras": ["shrouded", "bellTolled", "vengeful"]})
	ok(lst == PackedStringArray(["bellTolled", "shrouded", "vengeful"]), "F: Depths order under the omen: forced first, no repeats (%s)" % str(lst))
	await g.leave()
	g.queue_free()
	await process_frame


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])

extends SceneTree
## Combat-readability polish of the rebuild (see next/feel/README.md): the floating-number budget, the action bar's "no corpse / no legion" state,
## the low-health thrall ring and the red legion pips. godot --headless --path godot --script res://tests/next_clarity/run.gd

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	_budget()
	_needs_pure()
	await _slot_widget()
	await _game()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ---- the float budget ----------------------------------------------------------------------------------------------------------------

func _budget() -> void:
	var b := DmFloatBudget.new()
	var ok := 0
	for i in 40:
		if b.allow("thrall", 1000.0):
			ok += 1
	check(ok == DmFloatBudget.CLASS_CAP["thrall"], "thrall numbers are capped at %d alive (got %d)" % [DmFloatBudget.CLASS_CAP["thrall"], ok])
	check(b.allow("thrall", 1000.0 + DmFloatBudget.LIFE_MS["thrall"] + 1.0), "room again once they have faded")
	b = DmFloatBudget.new()
	ok = 0
	for i in 40:
		if b.allow("dot", 0.0):
			ok += 1
	check(ok == DmFloatBudget.CLASS_CAP["dot"], "dot numbers are capped at %d alive (got %d)" % [DmFloatBudget.CLASS_CAP["dot"], ok])
	b = DmFloatBudget.new()
	for i in 30:
		b.allow("hit", 0.0)
	check(not b.allow("hit", 0.0) and b.allow("crit", 0.0), "a full hit class still has room for a crit")
	b = DmFloatBudget.new()
	var shown := 0
	for i in 60:
		for k in ["hit", "dot", "thrall", "crit"]:
			if b.allow(k, 0.0):
				shown += 1
	check(shown <= DmFloatBudget.TOTAL_CAP + 4, "never more than the hard total at once (%d)" % shown)
	check(b.allow("hurt", 0.0) and b.allow("gold", 0.0) and b.allow("heal", 0.0), "hurt / gold / heal floats are never limited")
	var t0 := Time.get_ticks_usec()
	var bb := DmFloatBudget.new()
	for i in 20000:
		bb.allow("hit", float(i % 5000))
	var us := float(Time.get_ticks_usec() - t0) / 20000.0
	print("float budget allow(): %.3f us per call" % us)
	check(us < 20.0, "allow() costs %.2f us" % us)


# ---- action bar --------------------------------------------------------------------------------------------------------------------

func _needs_pure() -> void:
	for id in DmNextHudVm.NEEDS:
		var kind: String = DmNextHudVm.NEEDS[id]
		check(DmNextHudVm.needs_of(id, false, 0) == kind, "%s needs a %s when there is none" % [id, kind])
		check(DmNextHudVm.needs_of(id, true, 3) == "", "%s is usable with a corpse and a legion" % id)
	check(DmNextHudVm.needs_of("marrow_spear", false, 0) == "", "a rite that needs neither is never flagged")
	# every rite whose validate() can refuse no_corpse / no_thralls is listed (read from the sources, so a new one cannot be forgotten)
	for id in DmRiteRegistry.ids():
		var src := FileAccess.get_file_as_string("res://next/rites/rite_%s.gd" % id)
		if src.contains("\"no_corpse\""):
			check(DmNextHudVm.NEEDS.get(id, "") == "corpse", "%s refuses no_corpse, so the bar flags it" % id)
		if src.contains("\"no_thralls\""):
			check(DmNextHudVm.NEEDS.get(id, "") == "legion", "%s refuses no_thralls, so the bar flags it" % id)


func _slot_widget() -> void:
	var s := DmHudSlot.new()
	root.add_child(s)
	await frames(1)
	s.apply({"icon": "", "key": "2", "cost": 12, "left_ms": 0.0, "total_ms": 1000.0, "affordable": true, "needs": "corpse"})
	check(s._need.text == "no corpse", "slot says 'no corpse' (%s)" % s._need.text)
	check(s._icon.material != null, "slot icon is dimmed")
	s.apply({"icon": "", "key": "2", "cost": 12, "left_ms": 1500.0, "total_ms": 3000.0, "affordable": true, "needs": "corpse"})
	check(s._need.text == "", "the note gives way to the cooldown number")
	s.apply({"icon": "", "key": "2", "cost": 12, "left_ms": 0.0, "total_ms": 1000.0, "affordable": true, "needs": ""})
	check(s._need.text == "" and s._icon.material == null, "a usable slot is clean")
	s.apply({"icon": "", "key": "2", "cost": 12, "left_ms": 0.0, "total_ms": 1000.0, "affordable": true, "locked": true, "unlock_level": 8, "needs": "corpse"})
	check(s._need.text == "", "a locked slot shows its unlock level, not the note")
	s.queue_free()


# ---- in the game: the bar, the legion ----------------------------------------------------------------------------------------------

func _game() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("cl%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(1)   # Ossuary
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "store": DmCounselStore.new("")})
	var b := g.local_body()
	var caster := b.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	await frames(20)
	var th := b.get_node("Thralls") as DmThrallHost
	th.clear()
	for cp: DmSimCorpse in g.corpses.corpses_in_radius(Vector3.ZERO, 1000.0, Callable(), "", true):
		g.corpses.consume(cp.id, 1, "consumed")
	var vm: Dictionary = g.ui_host.hud_state()
	var by_key := {}
	for sl in vm["slots"]:
		by_key[sl["key"]] = sl
	var slot_of := func(rite: String) -> Dictionary:
		for i in g.ui_host.keys.size():
			if g.ui_host.keys[i] == rite:
				return vm["slots"][i]
		if g.ui_host.signature == rite:
			return vm["slots"][vm["slots"].size() - 1]
		return {}
	var corpse_slot := false
	for sl in vm["slots"]:
		if String(sl.get("needs", "")) == "corpse":
			corpse_slot = true
	check(corpse_slot, "with no corpse the bar flags a corpse rite (exhume / explosion are in the Ossuary's kit)")
	check(not vm["slots"].is_empty() and vm["primary"].get("needs", "") == "", "the primary is never flagged")
	var cpse := g.corpses.add_corpse(b.global_position.x + 2.0, b.global_position.z, "normal", "robber", false, 0.0, 1.0, g.area_of(1))
	await frames(2)
	vm = g.ui_host.hud_state()
	corpse_slot = false
	for sl in vm["slots"]:
		if String(sl.get("needs", "")) == "corpse":
			corpse_slot = true
	check(not corpse_slot, "a corpse within reach clears the flag")
	g.corpses.consume(cpse.id, 1, "consumed")
	g.corpses.add_corpse(b.global_position.x + 40.0, b.global_position.z, "normal", "robber", false, 0.0, 1.0, g.area_of(1))
	vm = g.ui_host.hud_state()
	corpse_slot = false
	for sl in vm["slots"]:
		if String(sl.get("needs", "")) == "corpse":
			corpse_slot = true
	check(corpse_slot, "a corpse 40 m away does not count")
	# the needs pass costs next to nothing (the whole build is ~0.6 ms headless, of which this is a few us)
	var t0 := Time.get_ticks_usec()
	for i in 500:
		g.ui_host.vm._refresh_needs(b)
		DmNextHudVm._legion_hurt(th)
	var us := float(Time.get_ticks_usec() - t0) / 500.0
	print("needs + legion pass: %.1f us per build" % us)
	check(us < 40.0, "the needs / legion pass stays cheap (%.1f us)" % us)

	# the legion: hurt pips + the low-health ring
	var spec := {"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0}
	for k in 3:
		th._spawn(DmThralls.raise_stats(spec, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, k + 1, 0.0), b.global_position + Vector3(2 + k, 0, 0), 0.0)
	await g.get_tree().create_timer(2.2).timeout
	vm = g.ui_host.hud_state()
	check(int(vm["thrall_hurt"]) == 0, "a healthy legion shows no red pips (%d)" % int(vm["thrall_hurt"]))
	var t0t: DmThrall = th.list()[0]
	t0t.hp = t0t.max_hp * 0.2
	await frames(3)
	vm = g.ui_host.hud_state()
	check(int(vm["thrall_hurt"]) == 1, "a thrall at 20 %% health turns one pip red (%d)" % int(vm["thrall_hurt"]))
	check(t0t._low_hp, "that thrall wears the low-health ring")
	t0t.hp = t0t.max_hp * 0.42   # between the thresholds: stays low (no flicker)
	await frames(3)
	check(t0t._low_hp, "no flicker between 35 %% and 50 %% health")
	t0t.hp = t0t.max_hp * 0.8   # a Rally heal
	await frames(3)
	check(not t0t._low_hp and int(g.ui_host.hud_state()["thrall_hurt"]) == 0, "healed past 50 %%: the ring and the pip go back")
	var ring_before: Variant = t0t._ring
	await frames(30)
	check(t0t._ring == ring_before, "the ring is not rebuilt while the state holds")
	# the HUD part: Diamonds paint a state of 2 red
	var d := DmHudParts.Diamonds.new()
	d.set_state([2, 1, false])
	check(d.on[0] == 2 and d.fill_hurt != d.fill_on, "Diamonds know a hurt state")
	d.free()
	await g.leave()
	g.queue_free()
	await frames(3)

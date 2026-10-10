extends SceneTree
## Slice HUD suite (godot/next/hud): the real DmGameUi / DmHud on DmNextGame through the DmNextUiHost adapter.
## godot --headless --path godot --script res://tests/next_hud/run.gd

const DT := 1.0 / 60.0
const FIRST_FRAME_BUDGET_MS := 35.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var character: Dictionary
var events: Array = []


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


func floats(kind: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == "float" and e["ctx"]["kind"] == kind)


func _run() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("nh%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	# ---- boot with the real HUD (the default)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"dressing": false, "persist": false})
	check(g.ui != null and g.ui_host != null and g.hud == null, "boots with the real HUD (DmGameUi + DmNextUiHost), no minimal HUD")
	var hud: DmHud = g.ui.hud
	check(hud != null and hud.hp_orb != null and hud.minimap != null and hud.visible, "DmHud built: orbs, minimap")
	check(not g.ui._vm.is_empty(), "first HUD apply happened during start (loading)")
	g.ui_host.feedback.connect(func(t: String) -> void: events.append({"id": "rejected", "ctx": {"text": t}}))
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))
	# ---- hotbar shows the loadout (DmLoadout over the kit's default loadout)
	var kit := DmContent.kit("necromancer")
	var want: Array = (kit["defaultLoadout"] as Array).duplicate()
	want.append(kit["rmb"])
	var h := g.ui_host
	check(h.keys == want and h.primary == kit["defaultPrimary"], "loadout = the kit's default loadout + rmb, primary %s" % h.primary)
	var vm := h.hud_state()
	check(vm["slots"].size() == 6 and vm["primary"]["key"] == "LMB" and vm["slots"][4]["key"] == "RMB" and vm["slots"][0]["key"] == "1", "vm: LMB + 5 slots with keys 1-4 / RMB + the signature on R")
	check(vm["slots"][5]["key"] == "R" and vm["slots"][5]["locked"] and h.rite_at(6) == kit["signatures"][h.shell.body_of(1).discipline_id], "vm: R is the discipline's signature (locked below level 10)")
	check(hud.primary_slot != null and hud.primary_slot.key_text == "LMB" and hud._slots.size() == 6, "HUD built the primary slot and 6 rite slots (5 + the signature)")
	for i in 5:
		check(String(hud._slots[i].icon_path).ends_with(String(DmAbilities.def(want[i])["icon"]).replace("art/", "")), "slot %d icon is %s" % [i + 1, want[i]])
	var miasma_slot := want.find("miasma") + 1
	check(miasma_slot > 0, "miasma is on the hotbar (slot %d)" % miasma_slot)
	# ---- the rest of the vm
	check(hud.area_lbl.text.to_upper().find("CHAPTERHOUSE") >= 0 and vm["level"] == int(character["level"]), "area name + level")
	check(is_equal_approx(hud.hp_orb.fill, 1.0), "health orb full")
	var b := g.local_body()
	check(h.hud_state()["minimap"]["destination"] == null, "minimap: no destination while standing")
	b.set_move_target(b.position + Vector3(6, 0, 0))
	var dest: Variant = h.hud_state()["minimap"]["destination"]
	check(dest != null and is_equal_approx(float(dest["x"]), b.position.x + 6.0), "minimap: a click-to-move goal shows as the destination mark")
	b.has_target = false
	check(h.hud_state()["minimap"]["destination"] == null, "minimap: the mark clears on arrival")
	var caster := b.get_node("Rites") as DmRiteCaster
	# ---- keys cast through DmRiteCaster
	caster.p["resource"]["value"] = 100.0
	var aim := Vector3(0, 0, 10)
	var key_ev := InputEventKey.new()
	key_ev.pressed = true
	key_ev.physical_keycode = KEY_1 + (miasma_slot - 1)
	g.input._unhandled_input(key_ev)
	await ticks(3)
	check(caster.cooldown_left("miasma") > 0.0, "key %d casts miasma (cooldown %.0f ms)" % [miasma_slot, caster.cooldown_left("miasma")])
	check(float(caster.p["resource"]["value"]) < 100.0 - 1.0, "essence spent")
	check(g.input.hotbar.get_connections().size() == 1, "one hotbar listener (the HUD): %d (two = every key cast twice)" % g.input.hotbar.get_connections().size())
	check(events.any(func(e: Dictionary) -> bool: return e["id"] == "slot_flash" and e["ctx"]["slot"] == miasma_slot), "slot flash for the cast")
	var left := await until(func() -> bool: return hud._slots[miasma_slot - 1].left_ms > 0.0, 2.0)
	check(left and hud._slots[miasma_slot - 1].total_ms > 1.0, "cooldown sweep: slot shows %.0f / %.0f ms" % [hud._slots[miasma_slot - 1].left_ms, hud._slots[miasma_slot - 1].total_ms])
	check(await until(func() -> bool: return float(hud.vm.get("essence", 100.0)) < 99.0, 2.0), "essence shown on the HUD (%s)" % hud.vm.get("essence"))
	# ---- rejection: the same rite again is on cooldown
	await ticks(120)   # past the cast lock (busy is silent, as in the current game)
	g.input._unhandled_input(key_ev)
	await ticks(2)
	check(floats("info").any(func(e: Dictionary) -> bool: return String(e["ctx"]["text"]).find("not ready") >= 0), "cooldown rejection shows a float: %s" % [floats("info").map(func(e: Dictionary) -> String: return e["ctx"]["text"])])
	# a hotbar rite that has no module in the slice yet: said once, not silently dropped as a forged intent (found from the loadout,
	# so this keeps working as rites are ported; skipped once every slot is ported)
	var unported := -1
	for sl in range(0, 6):
		var rid := String(g.ui_host.rite_at(sl))
		if rid != "" and not DmRiteRegistry.has(rid):
			unported = sl
			break
	if unported >= 0:
		var forged := caster.rejected_intents
		events.clear()
		await ticks(40)
		events.clear()
		g.input.hotbar.emit(unported, aim, 0)
		check(caster.rejected_intents == forged and events.any(func(e: Dictionary) -> bool: return e["id"] == "rejected" or e["id"] == "float"), "an unported rite (slot %d) gives feedback, not a forged intent" % unported)
	# ---- LMB on an enemy: bone needle, damage numbers
	b.teleport(Vector3(0, 0, -16))
	check(await until(func() -> bool: return g.director.alive_count() >= 2, 15.0), "robbers spawn")
	var foe: DmEnemy
	for e in g.director.enemies.values():
		if is_instance_valid(e) and e.is_hittable() and (foe == null or e.position.distance_to(b.position) < foe.position.distance_to(b.position)):
			foe = e
	await until(func() -> bool: return foe.sm.id() != DmEnemyState.Id.RISING, 5.0)   # a rising enemy is immune
	b.teleport(foe.position + Vector3(0, 0, 4))
	b.heal(1e6)
	events.clear()
	var needle_before := caster.cooldown_left("bone_needle")
	g.input.hotbar.emit(0, foe.global_position, DmWaveDirector.id_of(foe))
	await ticks(2)
	check(caster.cooldown_left("bone_needle") > needle_before, "LMB casts bone_needle")
	# right after the cast: the aimed target is remembered for a short REAL-time window, which a loaded machine could outlast below
	check(g.ui_host.target_enemy() == foe, "target frame follows the aimed enemy")
	check(await until(func() -> bool: return not floats("hit").is_empty() or not floats("crit").is_empty(), 4.0), "a rite hit floats a damage number")
	check(hud.float_layer.get_child_count() > 0, "the number is drawn on the HUD float layer")
	check(hud.vm.get("target") != null or await until(func() -> bool: return hud.vm.get("target") != null, 1.0), "target frame in the HUD vm")
	# ---- player damage
	events.clear()
	var hp0 := b.hp
	b.take_damage(12.0, foe)
	await ticks(2)
	check(not floats("hurt").is_empty() and b.hp < hp0, "damage taken floats a hurt number")
	check(events.any(func(e: Dictionary) -> bool: return e["id"] == "hit_flash"), "hit flash on damage")
	# ---- bag: a drop picked up shows in the bag and the Reliquary
	var m: DmRewardsMember = g.rewards.members[int(character["id"])]
	var bag_before := g.ui_host.inventory.count("reagent_grave_dust")
	m.loot_view.item(b.position, {"item_id": "reagent_grave_dust", "quantity": 3}, true)
	check(await until(func() -> bool: return g.ui_host.inventory.count("reagent_grave_dust") == bag_before + 3, 3.0), "a walked-over drop lands in the bag")
	check(g.ui_host.slots.any(func(s: Dictionary) -> bool: return s["item_id"] == "reagent_grave_dust"), "bag slots (game.slots) include it")
	check(events.any(func(e: Dictionary) -> bool: return e["id"] == "loot"), "loot toast event")
	g.ui.toggle_panel("inventory")
	await process_frame
	check(g.ui.inv.panel.visible, "Reliquary opens (I)")
	check(g.ui.inv.count("reagent_grave_dust") == bag_before + 3, "the Reliquary counts the drop")
	g.ui.toggle_panel("inventory")
	# ---- panels
	for p in ["grimoire", "settings"]:
		g.ui.close_panels()
		g.ui.toggle_panel(p)
		await process_frame
		check(g.ui.is_open(p), "panel %s opens" % p)
	g.ui.close_panels()
	# ---- cadence: the HUD applies at 20 Hz, not per frame
	var n0 := Time.get_ticks_msec()
	var applies := 0
	var frames := 0
	var last_vm = g.ui._vm
	while Time.get_ticks_msec() - n0 < 1000:
		await process_frame
		frames += 1
		if not is_same(g.ui._vm, last_vm):
			applies += 1
			last_vm = g.ui._vm
	# The throttle is wall-clock (50 ms), so on a loaded machine frames can be slower than 50 ms and every frame applies: the floor is
	# min(8, frames / 2), the cap stays 22, and with plenty of frames the throttle must be visible (fewer applies than frames).
	check(applies >= mini(8, frames / 2) and applies <= 22 and (frames < 60 or applies < frames / 2), "HUD applies at ~20 Hz (%d applies in %d frames in 1 s)" % [applies, frames])
	await g.leave()
	g.queue_free()
	await process_frame
	await _first_frame()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Budget like tests/perf/first_frame_run.gd: the first frame after start() (which warms the HUD + panels) must not stall.
func _first_frame() -> void:
	var n: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(n)
	await n.start(character, api, {"dressing": false, "persist": false})
	var t := Time.get_ticks_usec()
	var cpu0 := DmFrameCost.cpu_ms()
	await process_frame
	var wall := (Time.get_ticks_usec() - t) / 1000.0
	# Budget on CPU time when the process was descheduled (shared VPS: wall >> CPU is another process, not a stall of ours); /proc ticks are 10 ms.
	var cpu := DmFrameCost.cpu_ms() - cpu0
	var first := wall if cpu >= wall * DmFrameCost.BUSY_SHARE else cpu
	print("FIRSTFRAME first=%.1fms budget=%.0fms warm panels %d ms" % [first, FIRST_FRAME_BUDGET_MS, n.ui.warm_ms])
	perf_info(first < FIRST_FRAME_BUDGET_MS, "first frame after start under %.0f ms (got %.1f)" % [FIRST_FRAME_BUDGET_MS, first])
	await n.leave()
	n.queue_free()
	await process_frame


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])

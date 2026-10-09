extends SceneTree
## HUD view-model -> widget state (headless):  godot --headless --path godot --script res://tests/hud/run.gd

var _fail := 0
var _pass := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# --- pure helpers (HUD.ts formulas) ---
	_check(DmHudSlot.cd_text(0.0) == "", "cd text: ready is empty")
	_check(DmHudSlot.cd_text(4200.0) == "5", "cd text: ceil seconds")
	_check(DmHudSlot.cd_text(1000.0) == "1", "cd text: exactly 1 s")
	_check(DmHudSlot.cd_text(900.0) == "0.9", "cd text: tenths under a second")
	_check(DmHudSlot.cd_text(50.0) == "0.1" or DmHudSlot.cd_text(50.0) == "0.0" or DmHudSlot.cd_text(50.0) == "0.1", "cd text: tiny")
	_check(DmHudSlot.cd_pct(3000.0, 6000.0) == 50, "cd pct half")
	_check(DmHudSlot.cd_pct(0.0, 6000.0) == 0, "cd pct ready")
	_check(DmHudSlot.cd_pct(5999.0, 6000.0) == 100, "cd pct rounds")
	_check(DmHudBrewChip.sub_text("heal", true, false, 0, 0) == "none", "belt: empty heal says none")
	_check(DmHudBrewChip.sub_text("elixir", true, false, 0, 0) == "+ add", "belt: empty elixir says + add")
	_check(DmHudBrewChip.sub_text("elixir", false, true, 41.7, 2) == "41s", "belt: active shows seconds")
	_check(DmHudBrewChip.sub_text("elixir", false, false, 0, 3) == "×3", "belt: count")
	_check(DmHudBrewChip.sub_text("elixir", false, false, 0, 0) == "ready", "belt: ready")
	_check(DmHudKit.commas(1234567) == "1,234,567" and DmHudKit.commas(999) == "999" and DmHudKit.commas(0) == "0", "number commas")
	_check(DmHud.wave_milestone_text(0) == ["Elite Vanguard at tier 3", false], "milestone: next one to reach")
	_check(DmHud.wave_milestone_text(3) == ["Elite Vanguard", true], "milestone: first active")
	_check(DmHud.wave_milestone_text(6) == ["Restless Crypts +1", true], "milestone: top + count")
	_check(DmHud.wave_milestone_text(8) == ["Nightfall +2", true], "milestone: all three")

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(root)
	var hud := DmHud.new()
	root.add_child(hud)
	await _frames(2)

	# --- combat frame ---
	hud.apply(DmHudMock.combat())
	await _frames(2)
	_check(hud.hp_txt.text == "1,264 / 1,900", "hp label")
	_check(absf(hud.hp_orb.fill - 1264.0 / 1900.0) < 1e-6, "hp orb fill")
	_check(absf(hud.hp_orb.barrier - minf(0.9, 180.0 / 1900.0 * 3.0)) < 1e-6, "barrier ring alpha = min(.9, barrier/max*3)")
	_check(hud.ess_txt.text == "62 / 100" and hud.ess_sub.text == "GRAVE ESSENCE", "essence label + resource name")
	_check(absf(hud.ess_orb.fill - 0.62) < 1e-6, "essence fill")
	_check(not hud.vignette.low, "no low-hp vignette at 66%")
	_check(hud.level_badge.text.text == "31", "level badge")
	_check(absf(hud.xp_bar.value - 18420.0 / 29500.0) < 1e-6 and hud.xp_txt.text == "18,420 / 29,500", "xp bar + text")
	_check(hud.gold_lbl.text == "48,210" and hud.shard_lbl.text == "12", "currency")
	_check(hud.souls_n.text == "7 / 10" and absf(hud.souls_bar.value - 0.7) < 1e-6, "soul meter")
	_check(hud.thrall_num.text == "5/8" and hud.thrall_pips.on.size() == 8 and hud.thrall_pips.on.count(true) == 5, "thrall pips and chip")
	_check(hud.area_lbl.text == "THE HOLLOW GRAVES", "area name uppercased")
	_check(hud.save_lbl.text == "Saved 2 min ago", "save text")

	# --- slots ---
	_check(hud._slots.size() == 6, "six hotbar slots")
	_check(hud._slots.size() == 6 and hud._slots[1]._cdtext.text == "5" and hud._slots[3]._cdtext.text == "0.9" and hud._slots[0]._cdtext.text == "", "slot cooldown texts")
	_check(hud._slots[0]._cost.text == "18" and hud._slots[4].alt, "slot cost + alt (right-click) accent")
	_check(hud._slots[5].locked and hud._slots[5]._lock.text == "10", "6th slot (R) is locked until level 10")
	_check(hud._slots[4]._key.text == "RMB" and hud.primary_slot._key.text == "LMB", "key caps")
	var st := DmHudMock.combat()
	st["slots"][2]["empowered"] = true
	st["slots"][3]["affordable"] = false
	st["slots"][1]["locked"] = true
	st["slots"][1]["unlock_level"] = 12
	hud.apply(st)
	_check(hud._slots[2].empowered and not hud._slots[0].empowered, "empowered flag")
	_check(hud._slots[3]._icon.material != null and hud._slots[0]._icon.material == null, "unaffordable slot is dimmed")
	_check(hud._slots[1]._lock.text == "12" and hud._slots[1]._icon.material != null, "locked slot shows its unlock level")
	_check(hud._slots[2]._cost.get_theme_color("font_color") == Color("9ff5e0"), "empowered cost turns jade")
	var sw := DmHudMock.combat()
	sw["slots"][0]["swap"] = true
	hud.apply(sw)
	_check(hud._slots[0]._swap_ico.visible and not hud._slots[1]._swap_ico.visible, "swap affordance only when ready")
	# slot count change rebuilds
	var four := DmHudMock.combat()
	four["slots"] = (four["slots"] as Array).slice(0, 4)
	hud.apply(four)
	await _frames(1)
	_check(hud._slots.size() == 4, "slot row rebuilds to 4")
	hud.apply(DmHudMock.combat())
	await _frames(1)
	_check(hud._slots.size() == 6, "slot row rebuilds to 6")

	# --- upgrades ---
	_check(hud.dmg_pct.text == "+72%" and hud.dmg_cost.text == "540g", "damage readout")
	_check(absf(hud.dmg_bar.value - 9.0 / 25.0) < 1e-6, "damage bar = tier/max")
	_check(hud.dmg_gems.on == [true, true, true] or hud.dmg_gems.on == DmUpgrades.milestones(9.0, 25.0), "damage gems from milestones()")
	_check(not hud.dmg_buy.disabled, "can afford damage")
	_check(hud.wave_cost.text == "1,126g" and not hud.wave_buy.disabled, "wave cost")
	_check(hud.dial_tier.text == "Tier 4 / 4" and hud.dial_plus.disabled and not hud.dial_minus.disabled, "dial at its ceiling")
	_check(hud.dial_ms.text == "Elite Vanguard", "dial milestone line")
	var poor := DmHudMock.combat()
	poor["gold"] = 100
	hud.apply(poor)
	_check(hud.dmg_buy.disabled and hud.wave_buy.disabled, "buy buttons disable when gold is short")
	var maxed := DmHudMock.combat()
	maxed["damage"]["cost"] = null
	hud.apply(maxed)
	_check(hud.dmg_cost.text == "Max" and hud.dmg_buy.disabled, "max tier shows Max")
	var sig := {"dmg": 0, "wave": 0, "dial": 0}
	hud.buy_damage.connect(func() -> void: sig["dmg"] += 1)
	hud.buy_wave.connect(func() -> void: sig["wave"] += 1)
	hud.dial_wave.connect(func(d: int) -> void: sig["dial"] += d)
	hud.apply(DmHudMock.combat())
	hud.dmg_buy.pressed.emit()
	hud.wave_buy.pressed.emit()
	hud.dial_minus.pressed.emit()
	_check(sig["dmg"] == 1 and sig["wave"] == 1 and sig["dial"] == -1, "buttons emit signals")

	# --- left-edge readouts ---
	_check(hud.ward.visible and hud.ward_n.text == "−30%", "bone ward")
	_check(hud.chain.visible and hud.chain_n.text == "×23" and absf(hud.chain_bar.value - 0.6) < 1e-6, "kill chain")
	_check(hud.chain_lbl.text == "RAMPAGE · +15% XP & GOLD", "chain label")
	_check(hud.brews_box.visible and hud.brew_row.get_child_count() == 3, "belt has three chips")
	_check(hud._brew_chips["tonic"].empty and hud._brew_chips["tonic"]._sub.text == "+ add", "empty tonic chip")
	_check(hud._brew_chips["elixir"]._sub.text == "41s", "active elixir timer")
	_check(hud.omen_host.visible and hud.party_box.get_child_count() == 2, "omen + 2 party members")
	var none := DmHudMock.combat()
	none["ward"] = null
	none["chain"] = null
	none["brews"] = []
	none["omen"] = null
	none["party"] = []
	hud.apply(none)
	await _frames(1)
	_check(not hud.ward.visible and not hud.chain.visible and not hud.brews_box.visible and not hud.omen_host.visible, "readouts hide when null")
	_check(hud.party_box.get_child_count() == 0, "party clears")
	var zero_ward := DmHudMock.combat()
	zero_ward["ward"] = {"pct": 0, "thralls": 0, "per_thrall": 0.06}
	hud.apply(zero_ward)
	_check(not hud.ward.visible, "0% ward hides")

	# --- target / boss ---
	hud.apply(DmHudMock.combat())
	_check(hud.target_box.visible and not hud.boss.visible, "target shown, boss hidden")
	_check(absf(hud.target_bar.value - 5200.0 / 9000.0) < 1e-6, "target hp")
	_check(hud.target_name_row.get_child_count() == 4, "target name + elite + 2 affixes")
	_check(hud.target_stat.get_child_count() == 2, "target statuses")
	hud.apply(DmHudMock.boss())
	_check(hud.boss.visible and not hud.target_box.visible, "boss replaces target")
	_check(hud.boss_phase.text == "THE PROCESSION BEGINS", "boss phase line")
	_check(hud.boss_num.text == "41,200 / 80,000" and absf(hud.boss_bar.value - 0.515) < 1e-6, "boss hp")
	_check(hud.boss_bar.marks == [0.6, 0.3], "boss phase ticks at 60% and 30%")
	_check(hud.souls_n.text == "HARVEST", "full soul meter says HARVEST")
	_check(hud.hp_orb.fill < 0.3 and hud.vignette.low, "low-hp vignette under 30%")
	var dead := DmHudMock.boss()
	dead["hp"] = 0
	hud.apply(dead)
	_check(not hud.vignette.low, "no low-hp vignette at 0 hp")
	var big := DmHudMock.boss()
	big["boss"]["hp"] = -5
	hud.apply(big)
	_check(hud.boss_num.text == "0 / 80,000" and hud.boss_bar.value == 0.0, "boss hp clamps at 0")

	# --- map column ---
	hud.apply(DmHudMock.calm())
	_check(hud.depth_box.visible and hud.depth_k.text == "STAIR OPEN" and hud.depth_cue.text.begins_with("The stair is open"), "depth readout, stair open + chest")
	_check(hud.next_box.visible and hud.next_txt.text.begins_with("Take the east door"), "next suggestion")
	_check(hud.prompt.visible, "interaction prompt")
	_check(hud.dev_chip.visible, "dev chip")
	var m := DmHudMock.minimap()
	_check(DmHudMinimap.walkable(0.0, 20.0, m), "minimap: chapterhouse floor is walkable")
	_check(not DmHudMinimap.walkable(40.0, -15.0, m), "minimap: sealed area is not walkable")
	_check(DmHudMinimap.world_point(Vector2(95, 95), 10.0, 20.0) == Vector2(10.0, 20.0), "minimap centre = player")
	_check(DmHudMinimap.world_point(Vector2(0, 0), 0, 0) == null, "minimap: outside the disc")
	var wp: Vector2 = DmHudMinimap.world_point(Vector2(95 + 21, 95), 0.0, 0.0)
	_check(absf(wp.x - 10.0) < 1e-6, "minimap scale 2.1 px / unit")
	var ac := DmHudMock.combat()
	ac["auto_combat"] = {"on": true, "available": true, "visible": true}
	hud.apply(ac)
	_check(hud.auto_btn.visible and hud.auto_btn.text == "Auto: On · G" and not hud.auto_btn.disabled, "auto combat on")
	ac["auto_combat"] = {"on": false, "available": false, "visible": true}
	hud.apply(ac)
	_check(hud.auto_btn.text == "Auto: Easy only" and hud.auto_btn.disabled, "auto combat easy-only")
	ac["auto_combat"] = {"on": false, "available": false, "visible": false}
	hud.apply(ac)
	_check(not hud.auto_btn.visible, "auto combat hidden")

	# --- progressive reveal + NEW cues ---
	var rv := DmHudMock.combat()
	rv["reveal"] = {"hud.upgrades": false, "hud.shards": false, "hud.spells": false, "menu.spells": false, "menu.atlas": false}
	hud.apply(rv)
	_check(not hud.up_plate.visible and not hud.shard_chip.visible, "unrevealed plate and shards are held back")
	_check(not hud.menu_btns["grimoire"].visible and not hud.menu_btns["atlas"].visible and hud.menu_btns["codex"].visible, "unrevealed menu buttons hidden")
	_check(not hud.grim_btn.get_meta("host").visible, "grimoire button held back")
	rv["reveal"] = {}
	rv["new"] = {"hud.upgrades": true}
	hud.apply(rv)
	_check(hud.up_plate.visible, "revealed (absent = shown)")
	var pip_vis := 0
	for p in hud._pips["hud.upgrades"]:
		if (p as Control).visible:
			pip_vis += 1
	_check(pip_vis == 1 and (hud._glows["hud.upgrades"][0] as DmHudParts.NewGlow).active, "NEW pip + glow on the upgrades plate")
	var cue := []
	hud.cue_used.connect(func(id: String) -> void: cue.append(id))
	rv["new"] = {"menu.spells": true}
	hud.apply(rv)
	hud.menu_btns["grimoire"].pressed.emit()
	_check(cue == ["menu.spells"], "clicking a NEW menu button reports the cue as used")

	# --- toasts ---
	for c in hud.toasts.get_children():
		c.free()
	hud.apply(DmHudMock.calm())
	hud.toast("Hello there", "good")
	hud.toast("Hello there", "good")
	_check(hud.toasts.get_child_count() == 1, "same toast twice is one")
	hud.toast("Second", "")
	hud.toast("Third", "err")
	hud.toast("Fourth", "")
	await _frames(1)
	_check(hud.toasts.get_child_count() == 3, "three toasts at most")
	_check(hud.toasts.get_child(0).get_meta("text") == "Second", "oldest toast made room")
	for c in hud.toasts.get_children():
		c.free()
	hud.loot_toast("Bone Dust", 1, "common")
	hud.loot_toast("Bone Dust", 2, "common")
	await _frames(1)
	_check(hud.toasts.get_child_count() == 1 and hud.toasts.get_child(0).get_meta("total") == 3, "repeat pickup merges into a x3 toast")
	_check(hud.toasts.get_child(0).hold_s == 3.5, "minor loot lives 3.5 s")
	hud.loot_toast("Gravewrought Mantle", 1, "epic")
	_check(hud.toasts.get_child(1).hold_s == 8.0 and hud.toasts.get_child(1).kind == "loot_major", "rare loot keeps 8 s and the gold edge")
	for n in ["A", "B", "C"]:
		hud.loot_toast(n, 1, "common")
	await _frames(1)
	_check(hud.toasts.get_child_count() == 4, "four toasts at most with loot")
	var has_mantle := false
	for c in hud.toasts.get_children():
		if c.get_meta("text", "") == "" and c.get_meta("total", 0) == 1 and c.kind == "loot_major":
			has_mantle = true
	_check(has_mantle, "minor loot makes room before major loot")
	# toasts sit lower under a boss / target plate
	hud.apply(DmHudMock.boss())
	_check(hud.toasts.offset_top == 112.0, "toasts step down under the boss bar")
	hud.apply(DmHudMock.calm())
	_check(hud.toasts.offset_top == 64.0, "toasts return to the top")

	# --- banner / chat / death / floating text ---
	hud.banner("The Hollow Graves", "Level 3", 400)
	await _frames(2)
	_check(hud.banner_active(), "banner shows")
	for i in 10:
		hud.chat_line("line %d" % i)
	_check(hud.chat_log.get_child_count() == 8, "chat keeps 8 lines")
	var dv := DmHudMock.combat()
	dv["death"] = {"show": true, "sub": "The Covenant will carry you back."}
	hud.apply(dv)
	_check(hud.death_sub.text == "The Covenant will carry you back.", "death subtitle")
	var before := hud.float_layer.get_child_count()
	hud.float_text(Vector2(300, 300), "1,204", "crit")
	_check(hud.float_layer.get_child_count() == before + 1, "floating number spawns")
	var sent := []
	hud.chat_sent.connect(func(t: String) -> void: sent.append(t))
	hud.chat_in.text_submitted.emit("  hi  ")
	hud.chat_in.text_submitted.emit("   ")
	_check(sent == ["hi"], "chat trims and ignores empty")

	# --- counsel-tip anchors ---
	hud.apply(DmHudMock.combat())
	await _frames(2)
	_check(hud.tip_anchor_rect("minimap").size.x > 100, "tip anchor: minimap")
	_check(hud.tip_anchor_rect("wave").size.x >= 300, "tip anchor: upgrades plate")
	_check(hud.tip_anchor_rect("belt").size.x > 100, "tip anchor: belt")
	_check(hud.tip_anchor_rect("nope") == Rect2(), "unknown tip has no anchor")
	_check(hud.tip_default_position().x == 18.0 and hud.tip_default_position().y >= 70.0, "tip default position")

	# --- HUD size: scales the frame only, corners stay put, hit areas follow ---
	await _hud_scale_tests(Vector2i(1600, 900))
	await _hud_scale_tests(Vector2i(2560, 1080))

	print("hud tests: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _hud_scale_tests(sz: Vector2i) -> void:
	# a SubViewport: headless windows drop mouse events, a SubViewport routes them like the real one
	var sv := SubViewport.new()
	sv.size = sz
	get_root().add_child(sv)
	var hud := DmHud.new()
	sv.add_child(hud)
	await _frames(3)
	var tag := " [%dx%d]" % [sz.x, sz.y]
	_check(is_equal_approx(DmSettings.clamp_hud_scale(0.1), 0.75) and is_equal_approx(DmSettings.clamp_hud_scale(9), 1.3) and DmSettings.clamp_hud_scale("x") == 1.0, "clamp_hud_scale bounds")
	# fit rule: never forced below 100 %, never above what the frame width allows
	_check(DmHud.fit_scale(1.3, 1600.0) < 1.3 and DmHud.fit_scale(1.3, 1600.0) >= 1.0, "130%% is held back on the narrowest frame (%.3f)" % DmHud.fit_scale(1.3, 1600.0))
	_check(DmHud.fit_scale(1.3, 2400.0) == 1.3 and DmHud.fit_scale(0.75, 800.0) == 0.75 and DmHud.fit_scale(1.3, 900.0) == 1.0, "fit_scale: roomy frame keeps it, shrink is never limited, tiny frame floors at 100%")
	var m := DmHudMock.combat()
	m["minimap"] = DmHudMock.minimap()
	hud.apply(m)
	var vp: Viewport = sv
	var hits := {"menu": 0, "nav": 0}
	var menu_btn: Button = hud.menu_btns["inventory"]
	menu_btn.pressed.connect(func() -> void: hits["menu"] += 1)
	hud.navigate.connect(func(_x: float, _z: float) -> void: hits["nav"] += 1)
	for want in [1.0, 0.75, 1.3, 1.0]:
		hud.set_hud_scale(want)
		await _frames(3)
		var s := hud.effective_scale
		_check(is_equal_approx(hud.safe.scale.x, s) and (want <= 1.0 and is_equal_approx(s, want) or want > 1.0 and s >= 1.0 and s <= want), "scale %s applied as %.3f%s" % [str(want), s, tag])
		var frame := Rect2(hud.safe.global_position, hud.safe.size * s)
		_check(absf(frame.end.x - (hud.size.x - maxf(0.0, (hud.size.x - hud.size.y * DmHud.MAX_ASPECT) * 0.5))) < 1.0 and absf(frame.end.y - hud.size.y) < 1.0, "scaled frame still fills the room (corners stay in their corners) at %s" % str(want))
		# no overlap: the side columns clear the orbs (with the gutter) at every scale
		var hp_w: Rect2 = (hud.hp_orb.get_parent() as Control).get_global_rect()
		var es_w: Rect2 = (hud.ess_orb.get_parent() as Control).get_global_rect()
		var gap := 8.0
		var xr := hud.xp_box.get_global_rect()
		var cr := hud.chat_col.get_global_rect()
		var ur := hud.up_panel.get_global_rect()
		_check(xr.end.x + gap <= hp_w.position.x or xr.end.y <= hp_w.position.y, "xp column clears the health orb at %s" % str(want) + tag)
		_check(cr.end.x + gap <= hp_w.position.x or cr.end.y <= hp_w.position.y, "chat column clears the health orb at %s" % str(want) + tag)
		_check(ur.position.x >= es_w.end.x + gap or ur.end.y <= es_w.position.y, "upgrade panel clears the essence orb at %s" % str(want) + tag)
		_check(Rect2(Vector2.ZERO, hud.size).grow(1.0).encloses(menu_btn.get_global_rect()), "menu button stays on screen at %s" % str(want))
		# a real click at the button's centre and on the minimap
		var before: int = hits["menu"]
		_click(vp, menu_btn.get_global_rect().get_center())
		await _frames(3)
		_check(hits["menu"] == before + 1, "click on a HUD button lands at %s" % str(want))
		var mr := hud.minimap.get_global_rect()
		var nb: int = hits["nav"]
		_click(vp, mr.position + mr.size * 0.5)
		await _frames(2)
		_check(hits["nav"] == nb + 1, "minimap click navigates at %s" % str(want))
		# the click offset must scale: a point 20 screen px right of centre maps to 20/s local px
		var got := []
		var cb := func(x: float, z: float) -> void: got.append(Vector2(x, z))
		hud.navigate.connect(cb)
		_click(vp, mr.position + mr.size * 0.5)
		_click(vp, mr.position + mr.size * 0.5 + Vector2(20.0, 0.0))
		await _frames(2)
		hud.navigate.disconnect(cb)
		_check(got.size() == 2, "two minimap clicks navigate" + tag)
		if got.size() == 2:
			var dx: float = got[1].x - got[0].x
			_check(absf(dx - 20.0 / s / DmHudMinimap.SCALE) < 0.01, "minimap click offset follows the scale at %s (dx %.3f)%s" % [str(want), dx, tag])
	# node tip stays on the screen when the frame is scaled
	for want in [0.75, 1.3]:
		hud.set_hud_scale(want)
		await _frames(2)
		hud.node_tip("<b>Oak</b><div>12 XP</div>", hud.size.x - 4.0, hud.size.y - 4.0)
		await _frames(2)
		var tr := Rect2(hud.node_tip_box.global_position, hud.node_tip_box.size * hud.effective_scale)
		_check(Rect2(Vector2.ZERO, hud.size).grow(0.5).encloses(tr), "node tip stays inside the screen at %s" % str(want))
		hud.node_tip(null)
	hud.set_hud_scale(1.0)
	_check(is_equal_approx(hud.effective_scale, 1.0) and hud.safe.scale == Vector2.ONE, "back to 100%" + tag)
	sv.queue_free()


func _click(vp: Viewport, at: Vector2) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = at
	mv.global_position = at
	vp.push_input(mv)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = at
		e.global_position = at
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		vp.push_input(e)

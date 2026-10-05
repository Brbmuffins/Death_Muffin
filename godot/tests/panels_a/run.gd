extends SceneTree
## Panels-A tests (headless):  godot --headless --path godot --script res://tests/panels_a/run.gd
## data in -> displayed rows / buttons / enabled state, for Ascension, Class, Sheet, Cosmetics, Legion, Grimoire, Codex, Atlas, Dialogue, Waystones,
## plus the string formatters against fixtures generated from the TypeScript (tools/godot/export-panels-a.ts).

var _fail := 0
var _pass := 0
var _root: Control


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _eq(a: Variant, b: Variant, what: String) -> void:
	if str(a) == str(b):
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what, " | got ", a, " expected ", b)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists("res://tests/panels_a/fixtures/fmt.json") or not FileAccess.file_exists("res://data/panels_a/atlas.json"):
		printerr("fixtures missing: run npx vite-node tools/godot/export-panels-a.ts")
		quit(1)
		return
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(_root)
	await _frames(2)
	_test_formatters()
	_test_ascension()
	_test_class()
	_test_sheet()
	_test_cosmetics()
	_test_legion()
	_test_grimoire()
	await _test_codex()
	await _test_atlas()
	_test_dialogue()
	_test_waystones()
	await _test_windows()
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _mount(c: Node) -> Node:
	_root.add_child(c)
	return c


func _btn(root: Node, act: String, arg: Variant = null) -> Button:
	return DmPa.find_act(root, act, arg) as Button


# ---------------------------------------------------------------------------------------------------------------------
func _test_formatters() -> void:
	var f := FileAccess.open("res://tests/panels_a/fixtures/fmt.json", FileAccess.READ)
	var fix: Dictionary = JSON.parse_string(f.get_as_text())
	var bad := 0
	for c in fix["chance"]:
		var p := minf(1.0, float(c["p"]))
		if DmPa.fmt_chance(p) != String(c["text"]) or DmPa.one_in(p) != String(c["oneIn"]):
			bad += 1
			printerr("  chance ", p, ": got ", DmPa.fmt_chance(p), " / ", DmPa.one_in(p), " want ", c["text"], " / ", c["oneIn"])
	_eq(bad, 0, "fmtChance/oneIn match the TypeScript (%d cases)" % fix["chance"].size())
	bad = 0
	for c in fix["pct"]:
		if DmPa.pct(float(c["x"])) != String(c["text"]):
			bad += 1
			printerr("  pct ", c["x"], ": ", DmPa.pct(float(c["x"])), " want ", c["text"])
	_eq(bad, 0, "pct matches the TypeScript")
	bad = 0
	for c in fix["secs"]:
		if DmGrimoireView.secs(float(c["ms"])) != String(c["text"]):
			bad += 1
	_eq(bad, 0, "cooldown seconds match the TypeScript")
	bad = 0
	for c in fix["qty"]:
		if DmPa.fmt_qty(int(c["q"][0]), int(c["q"][1])) != String(c["text"]):
			bad += 1
	_eq(bad, 0, "fmtQty matches the TypeScript")
	_eq(DmPa.commas(1234567), "1,234,567", "commas")
	_eq(DmPa.gate_auto("a {auto}b{/auto}c", false), "a c", "gateAuto drops")
	_eq(DmPa.gate_auto("a {auto}b{/auto}c", true), "a bc", "gateAuto keeps")


# --- Ascension -------------------------------------------------------------------------------------------------------
func _test_ascension() -> void:
	var w := DmAscensionPanel.new()
	_mount(w)
	var st := DmPaMock.ascension_state()
	w.set_state(st)
	# 11 vow cards, 15 boon cards
	var vow_cards := DmPa.find_all(w, "vow").filter(func(n: Node) -> bool: return n is PanelContainer)
	var boon_cards := DmPa.find_all(w, "boon").filter(func(n: Node) -> bool: return n is PanelContainer)
	_eq(vow_cards.size(), 11, "ascension: one card per vow")
	_eq(boon_cards.size(), 15, "ascension: one card per boon")
	# header numbers
	var stats: Dictionary = {}
	for n in DmPa.find_all(w, "stat"):
		stats[n.get_meta("stat")] = (n as Label).text
	_eq(stats["best"], "Ascension II", "best rank = roman(ascension)")
	_eq(stats["heat"], "4", "sworn heat = 3 (elder) + 1 (iron)")
	_eq(stats["ashes"], "90", "ashes")
	_eq(stats["shards"], "350", "shards")
	# vow gating: swollen_waves is open (unlocks has it), deacon_host (400 shards) locked + unaffordable? 350 < 400
	var by_id: Dictionary = {}
	for c in vow_cards:
		by_id[c.get_meta("vow")] = c
	_check(not by_id["swollen_waves"].get_meta("locked"), "opened vow is not locked")
	_check(by_id["deacon_host"].get_meta("locked"), "unopened vow is locked")
	var unlock_deacon := _btn(w, "unlock", "vow:deacon_host")
	_check(unlock_deacon != null and unlock_deacon.disabled, "400-shard vow cannot be unlocked with 350 shards")
	_check(unlock_deacon.text.contains("400"), "unlock button states the shard price")
	var unlock_thin := _btn(w, "unlock", "vow:thin_graves")
	_check(unlock_thin != null and not unlock_thin.disabled, "120-shard vow is affordable")
	var got_unlock: Array = []
	w.unlock_requested.connect(func(k: String) -> void: got_unlock.append(k))
	unlock_thin.pressed.emit()
	_eq(got_unlock, ["vow:thin_graves"], "unlock emits the key")
	# sworn vows highlight
	_check(by_id["elder_dead"].get_meta("sworn"), "elder_dead sworn card")
	_check(not by_id["swollen_waves"].get_meta("sworn"), "unsworn card")
	# swear: nothing changed -> disabled, label "Vows sworn"
	var swear := _btn(w, "swear")
	_check(swear.disabled and swear.text.contains("VOWS SWORN"), "swear disabled when draft == sworn")
	# step a vow up: swollen_waves + (max 3)
	var plus: Button = null
	for b in DmPa.acts(w, "vow"):
		if b.get_meta("arg") == "swollen_waves" and b.text == "+":
			plus = b
	plus.pressed.emit()
	swear = _btn(w, "swear")
	_check(not swear.disabled and swear.text.contains("SWEAR THESE VOWS"), "draft change enables swearing")
	_eq(w.view["draft_heat"], 5, "draft heat = 4 + 1")
	_check(w.view["restart"], "changing vows with kills on the tally warns of a restart")
	var warn := DmPa.find_all(w, "role").filter(func(n: Node) -> bool: return n.get_meta("role") == "restart_warning")
	_eq(warn.size(), 1, "restart warning shown")
	# ascend button blocked while vows changed
	var asc := _btn(w, "ascend")
	_check(asc.disabled and asc.text.contains("SWEAR OR UNDO"), "ascend blocked until vows are sworn or undone")
	# the Ashes preview multiplier: 1 + ashesPerHeat * heat
	var mult := 1.0 + float(DmProgContent.ascension()["ashesPerHeat"]) * 5.0
	_eq("×%.1f" % mult, _stat_text(w, "mult"), "ashes multiplier preview")
	# swear emits the draft
	var sworn: Array = []
	w.vows_swear_requested.connect(func(v: Dictionary) -> void: sworn.append(v))
	swear.pressed.emit()
	_eq(sworn.size(), 1, "swear emits once")
	_eq(sworn[0].get("swollen_waves"), 1, "sworn vows include the new step")
	# clear all
	_btn(w, "clear").pressed.emit()
	_eq(w.view["draft_heat"], 0, "clear all empties the draft")
	# max-rank: elder_dead is 3/20 -> minus enabled; iron_dead minus then at 0 disabled
	w.set_state(DmPaMock.ascension_state())
	w.drafted = false
	w.set_state(DmPaMock.ascension_state())
	var elder_plus: Button = null
	var iron_minus: Button = null
	for b in DmPa.acts(w, "vow"):
		if b.get_meta("arg") == "iron_dead" and b.text == "−":
			iron_minus = b
	_check(iron_minus != null and not iron_minus.disabled, "minus enabled at 1 step")
	iron_minus.pressed.emit()
	for b in DmPa.acts(w, "vow"):
		if b.get_meta("arg") == "iron_dead" and b.text == "−":
			iron_minus = b
	_check(iron_minus.disabled, "minus disabled at 0 steps")
	# ascend: ashes for the run with sworn heat; confirm step
	w.drafted = false
	w.set_state(DmPaMock.ascension_state())
	var ashes := DmAscension.ashes_for_run(st["run"], 4)
	asc = _btn(w, "ascend")
	_check(not asc.disabled and asc.text.contains(str(ashes)), "ascend enabled and shows the Ashes it pays (%d)" % ashes)
	asc.pressed.emit()
	_check(_btn(w, "confirm") != null and _btn(w, "cancel") != null, "ascend asks twice")
	var asc_msg := DmPa.all_text(w)
	_check(asc_msg.contains("Ascension IV"), "confirm text names the new best rank when heat > best (4 > 2)")
	var did: Array = []
	w.ascend_confirmed.connect(func() -> void: did.append(true))
	_btn(w, "cancel").pressed.emit()
	_check(_btn(w, "ascend") != null, "Not yet goes back")
	_btn(w, "ascend").pressed.emit()
	_btn(w, "confirm").pressed.emit()
	_eq(did.size(), 1, "confirm emits ascend")
	# no prelate kill -> cannot ascend
	var st2 := DmPaMock.ascension_state()
	st2["run"] = {"prelateKills": 0, "peakWaveTier": 2, "kills": 100}
	w.confirming = false
	w.drafted = false
	w.set_state(st2)
	asc = _btn(w, "ascend")
	_check(asc.disabled and asc.text.contains("SLAY THE PRELATE"), "no Prelate kill: ascend disabled")
	# boons: vigil owned 2, cost for rank 3; ashes 90
	var boon_btn := _btn(w, "boon", "vigil")
	var cost := DmAscension.boon_cost("vigil", {"vigil": 2, "marrow_font": 1})
	_check(boon_btn != null and boon_btn.text.contains(str(cost)), "boon button shows the next cost")
	_check(boon_btn.disabled == (90 < cost), "boon disabled iff Ashes < cost")
	# a boon that needs a rank we lack
	for id in DmProgContent.boon_order():
		var def: Dictionary = DmProgContent.boons()[id]
		if def.has("requires") and int(def["unlockShards"]) == 0:
			var b := _btn(w, "boon", id)
			if b != null and float(def["requires"]) > 2.0:
				_check(b.disabled and b.text.begins_with("ASCENSION"), "boon needing a higher rank shows the requirement (%s)" % id)
			break
	# mastered
	var st3 := DmPaMock.ascension_state()
	var vig: Dictionary = DmProgContent.boons()["vigil"]
	st3["boons"] = {"vigil": int(vig["maxRank"])}
	w.set_state(st3)
	var mb := _btn(w, "boon", "vigil")
	_check(mb.disabled and mb.text.contains("MASTERED"), "maxed boon reads Mastered")
	w.queue_free()


func _stat_text(root: Node, key: String) -> String:
	for n in DmPa.find_all(root, "stat"):
		if n.get_meta("stat") == key:
			return (n as Label).text
	return ""


# --- Class -------------------------------------------------------------------------------------------------------------
func _test_class() -> void:
	var w := DmClassPanel.new()
	_mount(w)
	w.set_data(2)
	var cards := DmPa.acts(w, "class")
	_eq(cards.size(), 9, "class: nine playable disciplines")
	for c in cards:
		_eq(c.get_meta("disabled"), int(c.get_meta("arg")) == 2, "only the current class is disabled (class %s)" % c.get_meta("arg"))
	var chosen: Array = []
	w.class_chosen.connect(func(i: int) -> void: chosen.append(i))
	w.choose(2)
	w.choose(3)
	_eq(chosen, [3], "choosing the current class does nothing; another emits its index")
	w.begin_saving()
	_check(DmPa.all_text(w).contains("Saving your character"), "saving status shows")
	for c in DmPa.acts(w, "class"):
		_check(c.get_meta("disabled"), "all cards disabled while saving")
	w.choose(4)
	_eq(chosen, [3], "no second request while busy")
	w.fail("Nope.")
	_check(DmPa.all_text(w).contains("Nope."), "error shown verbatim")
	_check(not DmPa.find_act(w, "class", 4).get_meta("disabled"), "cards re-enabled after a failure")
	w.queue_free()


# --- Sheet --------------------------------------------------------------------------------------------------------------
func _test_sheet() -> void:
	var v := DmSheetView.new()
	_mount(v)
	var d := DmPaMock.sheet()
	v.set_data(d)
	var lines := DmPa.find_all(v, "line").filter(func(n: Node) -> bool: return n is VBoxContainer)
	var expect := 0
	for s in d["sections"]:
		expect += (s["lines"] as Array).size()
	_eq(lines.size(), expect, "sheet: one line per stat across sections")
	_check(DmPa.all_text(v).contains("INT > VIT > STR > AGI"), "looking-for priority order shown")
	_check(DmPa.all_text(v).contains(String(d["primer"])), "primer shown")
	# JSON-null weapons (and other looking fields) must not crash the panel (parity fix: the game_ui adapter workaround is gone)
	var dn: Dictionary = d.duplicate(true)
	dn["looking"]["weapons"] = null
	dn["looking"]["why"] = null
	var vn := DmSheetView.new()
	_mount(vn)
	vn.set_data(dn)
	_check(DmPa.all_text(vn).to_lower().contains("what you"), "sheet: null weapons renders without crashing")
	vn.queue_free()
	# maxHp open by default, others closed
	_check(v.is_line_open("maxHp"), "health line open by default")
	var other := ""
	for s in d["sections"]:
		for l in s["lines"]:
			if String(l["id"]) != "maxHp" and not String(l["id"]).begins_with("set:") and not String(l["id"]).begins_with("affix:"):
				other = String(l["id"])
				break
		if other != "":
			break
	_check(not v.is_line_open(other), "other lines start closed")
	var rows_before := DmPa.find_all(v, "row").size()
	v.toggle_line(other)
	_check(v.is_line_open(other), "clicking opens a line")
	_check(DmPa.find_all(v, "row").size() > rows_before, "opening shows its breakdown rows")
	var open_changes: Array = []
	v.line_toggled.connect(func(id: String, o: bool) -> void: open_changes.append([id, o]))
	v.toggle_line(other)
	_eq(open_changes, [[other, false]], "toggle emits")
	# set lines are always open and ignore clicks
	for s in d["sections"]:
		for l in s["lines"]:
			if String(l["id"]).begins_with("set:") or String(l["id"]).begins_with("affix:"):
				_check(v.is_line_open(String(l["id"])), "set/affix line always open")
				v.toggle_line(String(l["id"]))
				_check(v.is_line_open(String(l["id"])), "set/affix line ignores toggle")
	v.set_data({"ready": false})
	_check(DmPa.all_text(v).contains("not ready"), "no character yet message")
	v.queue_free()


# --- Cosmetics ------------------------------------------------------------------------------------------------------------
func _test_cosmetics() -> void:
	var v := DmCosmeticsView.new()
	_mount(v)
	_check(DmPa.all_text(v).contains("opening the chest"), "loading text before data")
	var data := DmPaMock.cosmetics_view()
	v.set_view(data)
	v.set_charm_counts({"charm_grave_rat": 2})
	_eq(v.total_level_text(), "Total level 143", "total level")
	var capes := DmPa.acts(v, "cape")
	_eq(capes.size(), data["capes"].size(), "one button per cape")
	var worn := DmPa.find_act(v, "cape", "cape_apprentice") as Button
	_eq(worn.text, "TAKE OFF", "worn cape offers Take off")
	var wear := DmPa.find_act(v, "cape", "cape_journeyman") as Button
	_check(wear != null and not wear.disabled and wear.text == "WEAR", "unlocked cape can be worn")
	var locked: Button = null
	for c in data["capes"]:
		if not bool(c["unlocked"]):
			locked = DmPa.find_act(v, "cape", String(c["id"])) as Button
			break
	_check(locked.disabled and locked.text == "LOCKED", "locked cape is disabled")
	var got: Array = []
	v.cape_toggled.connect(func(id: String) -> void: got.append(["cape", id]))
	v.pet_toggled.connect(func(id: String) -> void: got.append(["pet", id]))
	v.adopt_requested.connect(func(id: String) -> void: got.append(["adopt", id]))
	worn.pressed.emit()
	wear.pressed.emit()
	_eq(got, [["cape", ""], ["cape", "cape_journeyman"]], "taking off emits an empty id; wearing emits the id")
	# pets: first adopted (Call), grave rat has a charm (Adopt ×2), others Not found
	var pets: Array = data["pets"]
	var p0 := DmPa.find_act(v, "pet", String(pets[0]["id"])) as Button
	_check(p0 != null and p0.text == "CALL", "adopted pet can be called")
	var rat := DmPa.find_act(v, "adopt", "pet_grave_rat") as Button
	_check(rat != null and rat.text.contains("×2") and not rat.disabled, "charm in the bag enables Adopt with the count")
	var nf := DmPa.acts(v, "notfound")
	_eq(nf.size(), pets.size() - 2, "remaining pets are Not found")
	for b in nf:
		_check(b.disabled, "Not found is disabled")
	got.clear()
	p0.pressed.emit()
	rat.pressed.emit()
	_eq(got, [["pet", String(pets[0]["id"])], ["adopt", "pet_grave_rat"]], "pet buttons emit")
	v.set_busy(true)
	for b in DmPa.acts(v, "cape"):
		_check(b.disabled, "busy disables cape buttons")
	v.set_busy(false)
	v.set_error("The Sexton refuses.")
	_check(DmPa.all_text(v).contains("The Sexton refuses."), "error verbatim")
	v.queue_free()


# --- Legion ---------------------------------------------------------------------------------------------------------------
func _test_legion() -> void:
	var v := DmLegionView.new()
	_mount(v)
	var d := DmPaMock.legion()
	v.set_data(d)
	_check(DmPa.find_act(v, "take", "weapon") != null, "weapon slot has Take off")
	_check(DmPa.find_act(v, "take", "armor") == null, "empty armour slot has no Take off")
	_check(DmPa.all_text(v).contains("Empty. Give it a helm"), "empty armour slot hint")
	_check(DmPa.all_text(v).contains("Not used by thralls: +8% spell damage"), "unused affixes listed")
	_check(DmPa.all_text(v).contains("Thralls hit +12% harder"), "legion total lines")
	_check(DmPa.all_text(v).contains("188"), "thrall raised now: health")
	_check(DmPa.all_text(v).contains("tier 4 / 12"), "reinforce tier line (max 12)")
	var re := DmPa.find_act(v, "reinforce") as Button
	_check(re.disabled and re.text.contains("1,250G"), "reinforce disabled when gold 980 < 1250; shows price")
	_check(re.tooltip_text.contains("270"), "tooltip says how much more gold")
	var nxt := DmLegion.reinforce_bonus(5)
	_check(DmPa.all_text(v).contains("Next: +%s health and damage, +%s attack speed" % [DmPa.pct(nxt["hp"]), DmPa.pct(nxt["speed"])]), "next tier numbers come from DmLegion.reinforce_bonus")
	d["gold"] = 5000
	v.set_data(d)
	re = DmPa.find_act(v, "reinforce") as Button
	_check(not re.disabled, "reinforce enabled with enough gold")
	var got: Array = []
	v.reinforce_requested.connect(func() -> void: got.append("reinforce"))
	v.take_off_requested.connect(func(k: String) -> void: got.append(["take", k]))
	v.give_requested.connect(func(s: int) -> void: got.append(["give", s]))
	re.pressed.emit()
	(DmPa.find_act(v, "take", "weapon") as Button).pressed.emit()
	(DmPa.find_act(v, "give", 7) as Button).pressed.emit()
	_eq(got, ["reinforce", ["take", "weapon"], ["give", 7]], "legion actions emit")
	# spares: only 4 shown, "1 more" line
	_eq(DmPa.acts(v, "give").size(), DmLegionView.SPARES_SHOWN, "four spares shown")
	_check(DmPa.all_text(v).contains("1 more in your bag, ranked lower."), "overflow line")
	var verdicts: Array = DmPa.find_all(v, "verdict").map(func(n: Node) -> String: return n.get_meta("verdict"))
	_eq(verdicts, ["up", "up", "down", "same"], "verdict arrows in rank order")
	d["tier"] = 12
	d["cost"] = -1
	v.set_data(d)
	_check(DmPa.find_act(v, "reinforce") == null and DmPa.all_text(v).contains("Fully reinforced"), "top tier: no button")
	d["kit"]["armor"] = d["kit"]["weapon"].duplicate()
	d["spares"] = []
	v.set_data(d)
	_check(DmPa.all_text(v).contains("No spare weapons or armour"), "no spares message")
	v.set_error("The legion would not take that.")
	_check(DmPa.all_text(v).contains("would not take"), "error shown")
	v.queue_free()


# --- Grimoire --------------------------------------------------------------------------------------------------------------
func _test_grimoire() -> void:
	var v := DmGrimoireView.new()
	_mount(v)
	var st := DmPaMock.grimoire_state()
	var seen: Array = []
	v.mark_seen.connect(func(ids: Array) -> void: seen.append(ids))
	v.set_state(st)
	v.open_session()
	_eq(seen, [["bone_fan", "grave_frost"]], "opening marks the unseen rites seen")
	# a new primary was unseen -> jumps to the primary list
	_eq(str(v.selected), "primary", "unseen primary selects LMB")
	_eq(v.listed(), st["kit"]["primaries"], "primary mode lists the kit primaries")
	_check(DmPa.all_text(v).contains("Primaries cost nothing"), "primary note")
	var cards := DmPa.find_all(v, "rite").filter(func(n: Node) -> bool: return n is PanelContainer)
	_eq(cards.size(), st["kit"]["primaries"].size(), "one card per primary")
	var eq_count := 0
	for c in cards:
		if c.get_meta("equipped"):
			eq_count += 1
	_eq(eq_count, 1, "exactly the equipped primary is marked")
	# socket 1: lists assignable rites, with key buttons
	v.select_socket(0)
	var listed := v.listed()
	_eq(listed.size(), v.assignable().size(), "role=all lists every assignable rite")
	_check(v.assignable().has("corpse_explosion"), "the right-click rite is assignable")
	# locked at level 12? find a rite above level 12
	var locked_id := ""
	for id in listed:
		if DmPaData.unlock_level(String(id)) > 12:
			locked_id = String(id)
			break
	if locked_id != "":
		for b in DmPa.acts(v, "put"):
			if b.get_meta("rite") == locked_id:
				_check(b.disabled, "locked rite's key buttons are disabled")
		var lc: Node = null
		for c in DmPa.find_all(v, "rite"):
			if c is PanelContainer and c.get_meta("rite") == locked_id:
				lc = c
		_check(lc != null and lc.get_meta("locked") and not lc.has_meta("act"), "locked rite is sealed and not pickable")
		_check(DmPa.all_text(v).contains("Level %d" % DmPaData.unlock_level(locked_id)), "locked rite shows its level")
	# the rite already on socket 1 has its '1' button disabled
	for b in DmPa.acts(v, "put"):
		if b.get_meta("rite") == "marrow_spear":
			_eq(b.disabled, b.get_meta("arg") == 0, "current slot button disabled, others enabled")
	var got: Array = []
	v.assign_requested.connect(func(slot: int, id: String) -> void: got.append([slot, id]))
	v.assign_primary_requested.connect(func(id: String) -> void: got.append(["primary", id]))
	for b in DmPa.acts(v, "put"):
		if b.get_meta("rite") == "grave_frost" and b.get_meta("arg") == 2:
			if not b.disabled:
				b.pressed.emit()
	_eq(got, [[2, "grave_frost"]], "key button assigns the rite to that slot")
	v.selected = 1
	v.pick("miasma")
	v.select_socket("primary")
	v.pick("bone_fan")
	_eq(got, [[2, "grave_frost"], [1, "miasma"], ["primary", "bone_fan"]], "picking a card assigns into the selected socket")
	# role filter
	v.select_socket(0)
	v.role = "control"
	var controls := v.listed()
	for id in controls:
		_check(DmPaData.roles_of(String(id)).has("control"), "role filter keeps only control rites (%s)" % id)
	_check(controls.size() < v.assignable().size(), "role filter narrows the list")
	v.role = "all"
	# runes
	v.set_runes(DmPaMock.runes())
	v.select_socket("primary")   # bone_needle has a rune socket (splinter)
	_check(DmPa.find_all(v, "rune_pip").size() >= 1, "rune pip badge on the socket holding one")
	_check(DmPa.act_text(v, "rune_out").contains("TAKE THE RUNE OUT"), "socketed rune can be taken out")
	var rune_got: Array = []
	v.rune_socket_requested.connect(func(r: String, id: String) -> void: rune_got.append([r, id]))
	(DmPa.find_act(v, "rune_out") as Button).pressed.emit()
	_eq(rune_got, [["bone_needle", ""]], "take out emits an empty rune id")
	_check(v.rune_busy, "busy while the server answers")
	v.rune_done("The Sexton refuses.")
	_check(not v.rune_busy and DmPa.all_text(v).contains("The Sexton refuses."), "rune error shown and busy cleared")
	# owned rune -> clickable row; sealed -> not
	v.set_runes({"sockets": {}, "owned": {"rune_splinter": 1}})
	var owned_rows := DmPa.find_all(v, "rune_row").filter(func(n: Node) -> bool: return n.get_meta("mode") == "owned")
	var sealed_rows := DmPa.find_all(v, "rune_row").filter(func(n: Node) -> bool: return n.get_meta("mode") == "sealed")
	_eq(owned_rows.size(), 1, "one owned rune row")
	_check(sealed_rows.size() >= 1 and not sealed_rows[0].has_meta("act"), "sealed rune rows are not clickable")
	_check(DmPa.all_text(v).contains("Drops from"), "sealed rows say where the rune drops")
	# a rite without runes
	v.select_socket(4)   # corpse_explosion
	_check(DmPa.all_text(v).contains("has no runes yet"), "rite without a rune family says so")
	v.queue_free()


# --- Codex -------------------------------------------------------------------------------------------------------------------
func _test_codex() -> void:
	var w := DmCodexPanel.new()
	_mount(w)
	w.set_discipline("gravecaller")
	w.set_journal(["robber", "hound"], ["chapterhouse", "graves"])
	w.set_runes_found(["rune_splinter"])
	w.set_met_npcs(["prior"])
	var c: Dictionary = DmContent.file("codex")
	# every tab builds and has content
	for t in DmCodexPanel.TABS:
		w.select_tab(String(t[0]))
		_check(w.tab_view(String(t[0])).get_child_count() > 0 or String(t[0]) == "chronicle", "codex tab '%s' has content" % t[0])
	_eq(DmCodexPanel.TABS.size(), 15, "codex: 15 tabs")
	# rites: one entry per RITE_ORDER
	w.select_tab("rites")
	_eq(_entries(w.tab_view("rites")).size(), c["RITE_ORDER"].size(), "rites tab lists every rite")
	# {auto} gating
	var tips_text := DmPa.all_text(w.tab_view("rites"))
	_check(not tips_text.contains("{auto}") and not tips_text.contains("Auto (G)"), "auto-combat help hidden by default")
	w.auto_combat_allowed = true
	w.render_tab("rites")
	_check(DmPa.all_text(w.tab_view("rites")).contains("Auto (G)"), "auto-combat help shown when allowed")
	# disciplines: 9, mine marked
	w.select_tab("disciplines")
	var discs := _entries(w.tab_view("disciplines"))
	_eq(discs.size(), 9, "disciplines tab: nine")
	var mine := discs.filter(func(n: Node) -> bool: return n.has_meta("mine") and n.get_meta("mine"))
	_eq(mine.size(), 1, "exactly one marked 'Your discipline'")
	_check(DmPa.all_text(w.tab_view("disciplines")).contains("Your discipline"), "mine label")
	# the dead: 35 entries, 2 known
	w.select_tab("dead")
	var dead_v := w.tab_view("dead")
	var sealed := DmPa.find_all(dead_v, "sealed")
	_eq(sealed.size(), 33, "dead tab: 33 sealed of 35 when 2 recorded")
	_check(DmPa.all_text(dead_v).contains("RECORDED 2 OF 35"), "recorded count")
	_check(DmPa.all_text(dead_v).contains(String(c["CODEX_SEALED"]["dead"])), "sealed text")
	_check(DmPa.all_text(dead_v).contains(String(c["CODEX_DEAD"]["robber"]["counter"])), "known entry shows its counter text")
	# diocese
	w.select_tab("diocese")
	var area_n := DmContent.area_order().size()
	_check(DmPa.all_text(w.tab_view("diocese")).contains("WALKED 2 OF %d" % area_n), "walked count")
	_eq(DmPa.find_all(w.tab_view("diocese"), "sealed").size(), area_n - 2, "unvisited areas are sealed")
	# runes: found / not found
	w.select_tab("runes")
	var rows := DmPa.find_all(w.tab_view("runes"), "rune")
	var found := rows.filter(func(n: Node) -> bool: return n.get_meta("found"))
	_eq(found.size(), 1, "one rune found")
	_eq(rows.size(), 11, "eleven runes listed")
	_check(DmPa.all_text(w.tab_view("runes")).contains("1 of 3 found") or DmPa.all_text(w.tab_view("runes")).contains("1 of 2 found"), "per-rite found count")
	# people: met marker
	w.select_tab("people")
	_check(DmPa.all_text(w.tab_view("people")).contains("Met ·") and DmPa.all_text(w.tab_view("people")).contains("Not yet met"), "met / not yet met")
	# sets: computed rows present (legendary header)
	w.select_tab("sets")
	_check(DmPa.all_text(w.tab_view("sets")).contains("LEGENDARY SETS"), "legendary sets heading")
	var rows_d := DmPaData.codex_rows()
	_eq(_entries(w.tab_view("sets")).size(), (rows_d["sets"] as Array).size(), "one entry per set row")
	# atlas tab button + signal
	w.select_tab("atlas")
	var got: Array = []
	w.atlas_requested.connect(func() -> void: got.append(1))
	(DmPa.find_act(w, "open_atlas") as Button).pressed.emit()
	_eq(got.size(), 1, "Gear Atlas button emits")
	# chronicle: requested when the tab opens, rendered from data
	var req: Array = []
	w.chronicle_requested.connect(func() -> void: req.append(1))
	w.select_tab("rites")
	w.select_tab("chronicle")
	_eq(req.size(), 1, "opening Chronicle asks for fresh data")
	_check(DmPa.all_text(w.tab_view("chronicle")).contains("not being kept"), "no data: not being kept")
	w.set_chronicle(DmPaMock.chronicle())
	var ct := DmPa.all_text(w.tab_view("chronicle"))
	_check(ct.contains("18,432") and ct.contains("25h 30m") and ct.contains("Depth 14"), "chronicle numbers (kills, hours, depth)")
	_check(ct.contains("#3 (now)") and ct.contains("9/30/2026") and ct.contains("9/12/2026"), "runs table with current + ended dates")
	_check(ct.contains("The Hollow Graves") and ct.contains("The Bell-Sworn Prelate"), "per-area and boss kills listed")
	_check(not ct.contains("The Drowned Nave"), "areas with zero kills are omitted")
	w.queue_free()
	await _frames(1)


func _entries(v: Node) -> Array:
	return DmPa.find_all(v, "entry")


# --- Atlas ---------------------------------------------------------------------------------------------------------------------
func _test_atlas() -> void:
	DmAtlasPanel.memory["view"] = "best"
	DmAtlasPanel.memory["set"] = ""
	DmAtlasPanel.memory["where"] = ""
	var w := DmAtlasPanel.new()
	_mount(w)
	var ctx := DmPaMock.atlas_context()
	w.set_context(ctx)
	w.open_atlas()
	await _frames(2)
	var a := DmPaData.atlas()
	# model sanity
	_eq(a["item_order"].size(), a["items"].size(), "atlas: item order covers items")
	# By slot: every gear item of the slot, worn first
	w.set_view("slot")
	DmAtlasPanel.memory["slot"] = "chest"
	w.render_list()
	var rows := w.rows()
	var chest_gear := w.gear_for_slot("chest")
	_eq(rows.size(), chest_gear.size(), "slot view lists every chest piece")
	_eq(rows[0]["id"], "set_gravecaller_chest", "worn piece sorts first")
	# By slot sort: scores descend (verdict-based) after the worn piece
	var prev := 1e9
	for r in rows.slice(1):
		var s := w._score(a["items"][r["id"]])
		_check(s <= prev + 1e-9, "slot view is sorted by score (%s)" % r["id"])
		prev = s
	# By set: five pieces of the remembered set; header shows worn count
	w.set_view("set")
	var own := DmLegendarySets.set_for("gravecaller")
	_eq(DmAtlasPanel.memory["set"], own, "set view defaults to your legendary set")
	_eq(w.rows().size(), 5, "set view: five pieces")
	DmAtlasPanel.memory["set"] = "gravecaller"
	w.render_list()
	var hdr := DmPa.find_all(w, "role").filter(func(n: Node) -> bool: return n.get_meta("role") == "set_header")
	_check(hdr.size() == 1 and DmPa.all_text(hdr[0]).contains("1/5 worn"), "set header counts worn pieces (chest worn)")
	var bonuses := DmPa.find_all(hdr[0], "on")
	_check(bonuses.size() == 3 and not bonuses[0].get_meta("on"), "bonus rows off until enough pieces are worn")
	# Where: defaults to the current area; groups with counts
	w.set_view("where")
	_eq(DmAtlasPanel.memory["where"], "graves", "where view starts at your current area")
	var wrows := w.rows()
	_check(wrows[0].has("head") and String(wrows[0]["head"]).begins_with("Gear ("), "where view groups gear first")
	var place: Dictionary = {}
	for p in a["by_disc"]["gravecaller"]["places"]:
		if p["id"] == "graves":
			place = p
	var counted := 0
	for r in wrows:
		if r.has("id"):
			counted += 1
	_eq(counted, (place["items"] as Array).size(), "where view lists every item of the place exactly once")
	_check(DmPa.find_all(w, "role").any(func(n: Node) -> bool: return n.get_meta("role") == "quality"), "drop quality line for a hunting ground")
	var qd: Dictionary = a["by_disc"]["gravecaller"]["quality"]["graves"]
	_check(w.quality_text(qd).contains("Drop quality 1 of 9"), "quality text rung")
	# Mats: kinds partition the non-gear items
	w.set_view("mats")
	var counts := {}
	for k in ["materials", "brews", "reagents", "cosmetics"]:
		DmAtlasPanel.memory["mats"] = k
		counts[k] = w.rows().size()
		_check(counts[k] > 0 or k == "cosmetics", "mats kind '%s' has rows" % k)
	_check(w.mats_kind_of("charm_grave_rat") == "cosmetics" and w.mats_kind_of("flask_hp_minor") == "brews" and w.mats_kind_of("reagent_grave_dust") == "reagents" and w.mats_kind_of("material_copper_bar") == "materials", "mats classification")
	# Best for me: only upgrades in reach, non-owned, 3 per slot at most
	w.set_view("best")
	var best := w.rows()
	_check(best.size() > 0, "best view has rows with verdicts present")
	var per_head := 0
	var cur := ""
	for r in best:
		if r.has("head"):
			cur = String(r["head"])
			per_head = 0
		else:
			per_head += 1
			if cur != "The legendary chase (rare boss drops)":
				_check(per_head <= 3, "at most three picks per slot")
				var it: Dictionary = a["items"][r["id"]]
				_check(int(it["level"]) <= 12 + 10, "reach filter: level %d <= 22" % int(it["level"]))
				_check(not ctx["owned"].has(r["id"]), "owned pieces are not suggested")
	DmAtlasPanel.memory["reach"] = false
	_check(w.rows().size() >= best.size(), "dropping the reach filter shows at least as much")
	DmAtlasPanel.memory["reach"] = true
	# no verdicts -> best view empty message
	var w2 := DmAtlasPanel.new()
	_mount(w2)
	var c2 := DmPaMock.atlas_context()
	c2["verdicts"] = {}
	c2["outlooks"] = {}
	w2.set_context(c2)
	w2.open_atlas()
	w2.set_view("best")
	_check(DmPa.all_text(w2).contains("No upgrade in reach"), "best view empty message")
	w2.queue_free()
	# search
	w._on_search("crown")
	var hits := w.rows()
	_check(hits.size() > 0 and hits.size() <= DmAtlasPanel.LIST_MAX, "search finds items, capped at 80")
	for h in hits:
		_check(String(a["items"][h["id"]]["name"]).to_lower().contains("crown") or String(h["id"]).contains("crown"), "search hit matches (%s)" % h["id"])
	var gear_done := false
	for h in hits:
		if not bool(a["items"][h["id"]]["gear"]):
			gear_done = true
		elif gear_done:
			_check(false, "search lists gear before other items")
	w._on_search("")
	# source line + chance formatting against the model
	var sl := w.src_line("set_gravecaller_head", "graves")
	_check(String(sl["text"]).begins_with("Hollow Graves"), "source line prefers the place being viewed")
	_check(String(sl["title"]).contains("1 in"), "hover text includes 1-in-N odds for rare sources")
	_check(String(w.src_line("reagent_grave_dust")["text"]) != "No source", "reagent has a source")
	# smart loot: sources differ by discipline for legendary pieces / own armour
	var own_head := "set_gravecaller_head"
	var for_gc := DmPaData.sources_for(own_head, "gravecaller")
	var for_kn := DmPaData.sources_for(own_head, "hollow_knight")
	_check(for_gc.size() > 0 and for_kn.size() > 0 and float(for_gc[0]["chance"]) != float(for_kn[0]["chance"]) or JSON.stringify(for_gc) != JSON.stringify(for_kn), "smart loot: your own set drops more often (per-discipline sources)")
	# detail: select, trail/back
	w.set_view("slot")
	w.select_item("set_gravecaller_head")
	_check(DmPa.all_text(w._detail).contains("GRAVECALL CROWN"), "detail shows the item name")
	_check(DmPa.all_text(w._detail).contains("WHERE IT DROPS") and DmPa.all_text(w._detail).contains("IF YOU SALVAGE IT") and DmPa.all_text(w._detail).contains("UPGRADING IT"), "detail sections")
	var go := DmPa.find_act(w._detail, "go", "set_gravecaller_chest")
	_check(go != null, "set pieces link to each other")
	(go as Button).pressed.emit()
	_eq(w.sel, "set_gravecaller_chest", "following a link selects it")
	_eq(w.trail, ["set_gravecaller_head"], "trail remembers where you came from")
	w.back()
	_eq(w.sel, "set_gravecaller_head", "Back returns to the previous item")
	w.back()
	_eq(w.sel, "", "Back at the root returns to the list")
	_check(DmPa.all_text(w._detail).contains("HOW TO READ THIS"), "empty detail shows the legend")
	# crafted item shows recipe + links
	var craft_id := ""
	for id in a["made_by"]:
		if a["items"].has(id):
			craft_id = String(id)
			break
	w.select_item(craft_id)
	_check(DmPa.all_text(w._detail).contains("HOW TO MAKE IT"), "craftable item shows how to make it")
	# show-all-sources toggle
	var many := ""
	for id in a["item_order"]:
		if w._src(String(id)).filter(func(s: Dictionary) -> bool: return s["kind"] != "salvage").size() > DmAtlasPanel.SOURCES_SHORT:
			many = String(id)
			break
	if many != "":
		w.select_item(many)
		var more := DmPa.find_act(w._detail, "more") as Button
		_check(more != null and more.text.begins_with("SHOW ALL") or (more != null and more.text.begins_with("Show all")), "long source lists offer Show all")
		more.pressed.emit()
		_check((DmPa.find_all(w._detail, "role").filter(func(n: Node) -> bool: return n.get_meta("role") == "drops")[0] as Node).get_child_count() > (DmAtlasPanel.SOURCES_SHORT + 1) * 4 - 1, "Show all expands the table")
	# arrows
	var up := w.arrow_badges({"kind": "upgrade", "pct": 12.4, "text": "t", "empty": false}, null)
	_eq(up[0]["text"], "▲ +12%", "upgrade arrow")
	_eq(w.arrow_badges({"kind": "upgrade", "pct": 0.4, "text": "t", "empty": true}, null)[0]["text"], "▲ new", "empty slot upgrade reads 'new'")
	_eq(w.arrow_badges({"kind": "downgrade", "pct": 5.2, "text": "t"}, null)[0]["text"], "▼ 5%", "downgrade arrow")
	_eq(w.arrow_badges({"kind": "same", "pct": 0, "text": "t"}, null)[0]["text"], "≈", "same arrow")
	var o := {"setName": "Gravecall", "total": 5, "withSetPct": 30.0, "bonusPct": 9.0, "hint": "h"}
	var both := w.arrow_badges({"kind": "downgrade", "pct": 2.0, "text": "t"}, o)
	_eq([both[0]["text"], both[1]["text"]], ["▼ alone", "▲ +30% with set"], "downgrade alone + upgrade with set")
	# short formatters
	_eq(DmAtlasPanel.short_event("Ordinary kill"), "kill", "short event: ordinary")
	_eq(DmAtlasPanel.short_event("Boss kill (repeat)"), "boss repeat", "short event: repeat")
	_eq(DmAtlasPanel.short_event("Salvage Rare"), "salvage Rare", "short event: salvage")
	_eq(DmAtlasPanel.short_event("Chest (floor 3)"), "chest (floor 3)", "short event: chest (prefix replaced like the TS)")
	_eq(DmAtlasPanel.short_event("Chop (Woodcutting 1)"), "chop", "short event: parenthesis dropped")
	_eq(DmAtlasPanel.short_place({"place": "The Catacomb Depths, floors 1-3"}), "Depths floors 1-3", "short place")
	_eq(DmAtlasPanel.owned_from_slots([{"item_id": "a", "quantity": 2, "equipped": 0}, {"item_id": "a", "quantity": 1, "equipped": 1}])["a"], {"n": 3, "worn": true}, "owned_from_slots sums and ORs worn")
	w.close()
	w.queue_free()
	await _frames(1)


# --- Dialogue -------------------------------------------------------------------------------------------------------------------
func _test_dialogue() -> void:
	var d := DmDialoguePanel.new()
	_mount(d)
	d.source = DmMockSource.new()
	var changes: Array = []
	d.npc_changed.connect(func(id: String) -> void: changes.append(id))
	d.open_npc("prior")
	_check(d.is_open() and changes == ["prior"], "opens and announces the speaker")
	var labels: Dictionary = DmContent.get_export("dialogue", "LABEL")
	_eq(_choice_texts(d), [labels["advice"]["prior"], labels["about"], labels["bye"]], "greeting offers advice / about / goodbye")
	d.choose(0)
	_eq(d.node_kind, "advice", "advice node")
	_eq(_choice_texts(d), [labels["about"], labels["bye"]], "advice offers about / goodbye")
	d.choose(0)
	_eq(d.node_kind, "about", "about node")
	var topics: Array = DmContent.get_export("dialogue", "TOPICS")["prior"]
	var texts := _choice_texts(d)
	_eq(texts.size(), topics.size() + 1, "about lists the topics plus Back")
	_eq(texts[texts.size() - 1], labels["back"], "Back last")
	for b in DmPa.acts(d, "choice"):
		if b.get_meta("arg") < topics.size():
			_check(b.get_meta("fresh"), "unheard topic is fresh")
	d.choose(0)
	_eq(d.node_kind, "topic", "topic node")
	_eq(d.topic_id, topics[0]["id"], "topic id")
	_eq(_choice_texts(d)[1], "Tell me of something else", "topic offers something else")
	d.go("about")
	var fresh := 0
	for b in DmPa.acts(d, "choice"):
		if b.get_meta("fresh"):
			fresh += 1
	_eq(fresh, topics.size() - 1, "a heard topic loses its fresh mark")
	d.go("menu")
	_check(DmPa.all_text(d).contains("Ask, and I will answer as plainly as I can."), "menu line for the Prior")
	# goodbye closes
	var bye := _choice_texts(d).find(labels["bye"])
	d.choose(bye)
	_check(not d.is_open() and changes[changes.size() - 1] == "", "Goodbye closes and announces nobody")
	# reopen: greeted before -> second-time greeting; same npc while open is a no-op
	d.open_npc("sexton")
	d.open_npc("sexton")
	_eq(changes.filter(func(x: String) -> bool: return x == "sexton").size(), 1, "opening the same NPC again does nothing")
	_check(DmPa.all_text(d).contains("THE SEXTON"), "NPC name shown")
	d.close()
	d.queue_free()


func _choice_texts(d: DmDialoguePanel) -> Array:
	return DmPa.acts(d, "choice").map(func(b: Button) -> String: return b.text)


# --- Waystones --------------------------------------------------------------------------------------------------------------------
func _test_waystones() -> void:
	var w := DmWaystonePanel.new()
	_mount(w)
	w.set_unlocked(["chapterhouse", "graves", "ossuary"])
	var btns := DmPa.acts(w, "travel")
	_eq(btns.size(), 3, "one button per unlocked waystone")
	_check((btns[1] as Button).get_child(0).get_child(0).text == "THE HOLLOW GRAVES", "area name")
	var levels := DmPa.all_text(w)
	_check(levels.contains("Lv 1") and levels.contains("Lv %d" % int(DmContent.area("ossuary")["level"])), "levels shown")
	var got: Array = []
	w.travel_requested.connect(func(id: String) -> void: got.append(id))
	w.visible = true
	(btns[2] as Button).pressed.emit()
	_eq(got, ["ossuary"], "travel emits the area id")
	_check(not w.visible, "the panel closes before travelling")
	w.queue_free()


# --- Windows (fixed header, tabs) -------------------------------------------------------------------------------------------------
func _test_windows() -> void:
	var cw := DmCharacterWindow.new()
	_mount(cw)
	cw.sheet.set_data(DmPaMock.sheet())
	cw.cosmetics.set_view(DmPaMock.cosmetics_view())
	cw.open_tab("pets")
	await _frames(3)
	_eq(cw.active, "pets", "J/N: open_tab selects the tab")
	_check(cw.cosmetics.visible and not cw.sheet.visible, "only the active tab's content shows")
	var pressed := 0
	for k in cw._tabs:
		if (cw._tabs[k]["btn"] as Button).button_pressed:
			pressed += 1
	_eq(pressed, 1, "exactly one tab button looks pressed after a programmatic select")
	_check(cw.head.get_parent().get_parent() != cw.scroll.get_parent(), "title/close header is outside the scrolling body")
	cw.queue_free()
	var gw := DmGrimoireWindow.new()
	_mount(gw)
	gw.grimoire.set_state(DmPaMock.grimoire_state())
	gw.legion.set_data(DmPaMock.legion())
	gw.set_family("knight")
	_check(not (gw._tabs["legion"]["btn"] as Button).visible, "Legion tab hidden for non-necromancers")
	gw.set_family("necromancer")
	_check((gw._tabs["legion"]["btn"] as Button).visible, "Legion tab shown for necromancers")
	gw.queue_free()
	var ap := DmAscensionPanel.new()
	_mount(ap)
	ap.set_state(DmPaMock.ascension_state())
	ap.open_altar()
	await _frames(4)
	_check(ap.visible and ap.panel_width == 900, "altar window is 900 wide")
	ap.close()
	_check(not ap.visible, "closes")
	ap.queue_free()

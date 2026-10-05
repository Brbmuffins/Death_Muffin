class_name DmLoadoutPresets
extends VBoxContainer
## Port of src/ui/LoadoutPresets.ts + the loadout half of gameplay/loadoutRules.ts (captureGear, sameLoadout, cleanName, reportLines) +
## WorldScene.loadoutHost / loadoutHotkey: up to six named presets of rites + runes + worn weapon and off-hand, in the Grimoire's loadout slot.
## DmApi: list_loadouts / save_loadout / delete_loadout / apply_loadout_preset (the server puts the gear on in one transaction; the rites half is applied here).

const MAX_PRESETS := 6
const NAME_MAX := 24
const MAIN_HAND_SLOT := 105
const OFF_HAND_SLOT := 106

var ui: Node
var rows: Variant = null              ## null = not read yet; else [{slot, preset}]
var load_error := ""
var msg := ""
var busy := false
var naming: Dictionary = {}           ## {slot, rename} while a name form is open
var confirm_delete := -1
var name_edit: LineEdit
var _last_slot := -1


func setup(ui_: Node) -> void:
	ui = ui_
	add_theme_constant_override("separation", 6)


# --- pure rules -----------------------------------------------------------------------------------------------------------------

static func clean_name(raw: String) -> String:
	var s := ""
	for i in raw.length():
		var c := raw.unicode_at(i)
		if c >= 32 and c != 127 and raw[i] != "<" and raw[i] != ">":
			s += raw[i]
	var parts := s.split(" ", false)
	s = " ".join(parts).strip_edges()
	return s.substr(0, NAME_MAX).strip_edges()


static func capture_gear(slots: Array) -> Dictionary:
	var ref := func(slot: int) -> Variant:
		for r in slots:
			if int(r["slot_index"]) == slot:
				return {"itemId": r["item_id"], "instanceId": r.get("instance_id")}
		return null
	var runes := {}
	for r in slots:
		var rite: Variant = DmRunes.rune_slot_rite(r["slot_index"])
		if rite != null and DmRunes.rune_fits(String(r["item_id"]), String(rite)):
			runes[rite] = r["item_id"]
	return {"weapon": ref.call(MAIN_HAND_SLOT), "offhand": ref.call(OFF_HAND_SLOT), "runes": runes}


static func same_loadout(a: Dictionary, b: Dictionary) -> bool:
	var g := func(x: Variant) -> String:
		return "" if x == null else "%s#%s" % [x["itemId"], "" if x.get("instanceId") == null else str(int(x["instanceId"]))]
	if a["rites"]["primary"] != b["rites"]["primary"] or ",".join(a["rites"]["keys"]) != ",".join(b["rites"]["keys"]):
		return false
	for r in DmRunes.rites():
		if a.get("runes", {}).get(r) != b.get("runes", {}).get(r):
			return false
	return (a.get("weapon") == null or g.call(a["weapon"]) == g.call(b.get("weapon"))) and (a.get("offhand") == null or g.call(a["offhand"]) == g.call(b.get("offhand")))


static func report_lines(report: Variant, item_name: Callable) -> Array:
	var lines: Array = []
	if not (report is Dictionary):
		return lines
	for s in report.get("skipped", []):
		var item_id: Variant = s.get("itemId")
		var what := ""
		if item_id != null and String(item_id) != "":
			what = String(DmContent.rune(String(item_id)).get("name", item_name.call(item_id))) if s.get("part") == "rune" else String(item_name.call(item_id))
		var rite: Variant = s.get("rite")
		var where := (" for %s" % String(DmAbilities.def(String(rite))["name"])) if s.get("part") == "rune" and rite != null else ""
		if s.get("part") == "rune" and (item_id == null or String(item_id) == ""):
			lines.append("%s still holds its rune: your bag is full, so it has nowhere to go." % String(DmAbilities.def(String(rite))["name"]))
		elif s.get("reason") == "missing":
			lines.append("%s%s is not in your bag (sold, ground, or resting in the Vault), so it was left out." % [what, where])
		elif s.get("reason") == "no_room":
			lines.append(("%s%s was not set: the rune it replaces needs a free bag slot." % [what, where]) if s.get("part") == "rune" else "%s was not worn: swapping it needs more free bag slots." % what)
		else:
			lines.append("%s does not fit that slot and was left out." % what)
	return lines


# --- host (what the section needs from the game) -----------------------------------------------------------------------------------------

func current() -> Dictionary:
	var gear := capture_gear(ui.game.slots)
	return {"rites": {"primary": ui.rites.primary, "keys": ui.rites.keys.duplicate()}, "runes": gear["runes"], "weapon": gear["weapon"], "offhand": gear["offhand"]}


func item_name(id: String) -> String:
	return String(DmContent.item(id).get("name", id))


func key_for(slot: int) -> String:
	var a := "loadout_%d" % (slot + 1)
	return DmUiBinds.label(ui.binds[a]) if ui.binds.has(a) else ""


func next_key() -> String:
	return DmUiBinds.label(ui.binds["loadout_next"]) if ui.binds.has("loadout_next") else ""


func _list() -> Array:
	var r: DmResult = await ui.game.api.list_loadouts(int(ui.game.character["id"]))
	if not r.ok:
		load_error = r.error if r.error != "" else "Your loadouts could not be read."
		return []
	var out: Array = []
	for row in r.data:
		out.append({"slot": int(row["slot"]), "preset": row["preset"]})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["slot"] < b["slot"])
	return out


func load_rows() -> void:
	load_error = ""
	rows = await _list()
	draw()


func reset() -> void:
	rows = null


func save_preset(slot: int, preset: Dictionary) -> void:
	var r: DmResult = await ui.game.api.save_loadout(int(ui.game.character["id"]), slot, preset)
	if not r.ok:
		msg = r.error
		return
	rows = await _list()


## Put a preset on: the server wears the gear (one transaction), then the rites half is applied here. Returns the lines about anything skipped.
func apply_preset(slot: int, preset: Dictionary) -> Array:
	var r: DmResult = await ui.game.api.apply_loadout_preset(int(ui.game.character["id"]), slot)
	if not r.ok:
		msg = r.error
		return [r.error]
	await ui.game.refresh_inventory()
	var lines := report_lines(r.data.get("report"), Callable(self, "item_name"))
	lines.append_array(ui.apply_rites_preset(preset["rites"]))
	ui.toast(("%s is on, with %d thing%s left out" % [preset["name"], lines.size(), "s" if lines.size() > 1 else ""]) if not lines.is_empty() else "%s is on" % preset["name"], "" if not lines.is_empty() else "good")
	ui.play("shard")
	return lines


func hotkey(action: String) -> void:
	if busy:
		return
	busy = true
	var rws := await _list()
	var slot := -1
	if action == "loadout_next":
		var now := current()
		var active := -1
		for r in rws:
			if same_loadout(r["preset"], now):
				active = int(r["slot"])
				break
		slot = DmUiBinds.next_slot(rws.map(func(r: Dictionary) -> int: return r["slot"]), active, _last_slot)
		if slot < 0:
			ui.toast("No saved loadouts yet: save one in the Grimoire (L)")
			busy = false
			return
		if active == slot:
			for r in rws:
				if r["slot"] == slot:
					ui.toast("%s is your only loadout" % r["preset"]["name"])
			busy = false
			return
	else:
		slot = int(action.substr(action.length() - 1)) - 1
	var row: Dictionary = {}
	for r in rws:
		if r["slot"] == slot:
			row = r
	if row.is_empty():
		ui.toast("Loadout %d is empty: save one in the Grimoire (L)" % (slot + 1))
		busy = false
		return
	await apply_preset(slot, row["preset"])
	_last_slot = slot
	busy = false


# --- view --------------------------------------------------------------------------------------------------------------------------------

func _btn(text: String, name: String, handler: Callable, disabled: bool = false, primary: bool = false) -> Button:
	var b := Button.new()
	b.theme_type_variation = "DmButtonSmallPrimary" if primary else "DmButtonSmall"
	b.text = DmUi.upper(text)
	b.name = name
	b.disabled = disabled or busy
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(handler)
	return b


func draw() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var head := HBoxContainer.new()
	head.add_child(DmUi.label(DmUi.upper("Loadouts"), "DmSub"))
	if rows == null:
		add_child(head)
		add_child(DmUi.label("Reading your loadouts…", "DmHint"))
		return
	var small := "rites, runes and weapons together · %d/%d" % [rows.size(), MAX_PRESETS]
	if next_key() != "":
		small += " · next: %s" % next_key()
	var sl := DmUi.label(small, "DmFaint")
	sl.add_theme_font_size_override("font_size", 11)
	head.add_child(sl)
	add_child(head)
	if rows.is_empty():
		add_child(DmUi.label("Set up your five rites, your runes and your weapon, then save it here. One click brings it all back.", "DmHint", true))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	add_child(grid)
	var now := current()
	for r in rows:
		grid.add_child(_card(r, now))
	var free := -1
	for i in MAX_PRESETS:
		var taken := false
		for r in rows:
			if r["slot"] == i:
				taken = true
		if not taken:
			free = i
			break
	if free >= 0:
		if not naming.is_empty() and naming["slot"] == free and not naming["rename"]:
			grid.add_child(_name_form(free, "Loadout %d" % (free + 1)))
		else:
			var p := PanelContainer.new()
			p.theme_type_variation = "DmInset"
			p.add_child(_btn("＋ Save what I have now", "New_%d" % free, func() -> void:
				naming = {"slot": free, "rename": false}
				confirm_delete = -1
				draw()))
			grid.add_child(p)
	var m := DmUi.label(load_error if load_error != "" else msg, "DmNote", true)
	m.name = "Msg"
	add_child(m)


func _card(r: Dictionary, now: Dictionary) -> Control:
	var p: Dictionary = r["preset"]
	var slot: int = r["slot"]
	if not naming.is_empty() and naming["slot"] == slot and naming["rename"]:
		return _name_form(slot, String(p["name"]))
	var active := same_loadout(p, now)
	var c := PanelContainer.new()
	c.theme_type_variation = "DmInset"
	c.name = "Card_%d" % slot
	var v := VBoxContainer.new()
	c.add_child(v)
	var nm := String(p["name"]) + ("  [on now]" if active else "")
	var k := key_for(slot)
	if k != "":
		nm += "  [%s]" % k
	v.add_child(DmUi.label(nm, "DmItemName"))
	var rite_names: Array = []
	for id in [p["rites"]["primary"]] + p["rites"]["keys"]:
		rite_names.append(String(DmAbilities.defs().get(id, {}).get("name", id)))
	var il := DmUi.label(", ".join(rite_names), "DmMuted", true)
	il.add_theme_font_size_override("font_size", 12)
	v.add_child(il)
	var runes: Array = []
	for rite in DmRunes.rites():
		if p.get("runes", {}).get(rite) != null:
			runes.append("%s: %s" % [DmAbilities.def(rite)["name"], DmContent.rune(String(p["runes"][rite])).get("name", "")])
	v.add_child(DmUi.label(", ".join(runes) if not runes.is_empty() else "no runes", "DmFaint", true))
	var hand := func(label: String, g: Variant) -> String:
		return "%s: %s" % [label, item_name(String(g["itemId"])) if g != null else "keep current"]
	v.add_child(DmUi.label("%s · %s" % [hand.call("Main hand", p.get("weapon")), hand.call("Off-hand", p.get("offhand"))], "DmFaint", true))
	var act := HBoxContainer.new()
	act.add_theme_constant_override("separation", 4)
	act.add_child(_btn("Applied" if active else "Apply", "Apply_%d" % slot, func() -> void: _do_apply(slot, p), active, true))
	act.add_child(_btn("Update", "Update_%d" % slot, func() -> void: _do_update(slot, p)))
	act.add_child(_btn("Rename", "Rename_%d" % slot, func() -> void:
		naming = {"slot": slot, "rename": true}
		confirm_delete = -1
		draw()))
	var del := confirm_delete == slot
	act.add_child(_btn("Really delete?" if del else "Delete", ("DeleteYes_%d" if del else "Delete_%d") % slot, func() -> void: _do_delete(slot, del)))
	v.add_child(act)
	return c


func _name_form(slot: int, value: String) -> Control:
	var c := PanelContainer.new()
	c.theme_type_variation = "DmInset"
	var v := VBoxContainer.new()
	c.add_child(v)
	v.add_child(DmUi.label("Name", "DmMuted"))
	name_edit = LineEdit.new()
	name_edit.max_length = NAME_MAX
	name_edit.text = value
	name_edit.name = "NameEdit"
	name_edit.text_submitted.connect(func(_t: String) -> void: submit_name())
	v.add_child(name_edit)
	var h := HBoxContainer.new()
	h.add_child(_btn("Save", "NameSave", submit_name))
	h.add_child(_btn("Cancel", "NameCancel", func() -> void:
		naming = {}
		draw()))
	v.add_child(h)
	return c


func submit_name() -> void:
	if naming.is_empty() or name_edit == null:
		return
	var nm := clean_name(name_edit.text)
	if nm == "":
		msg = "Give the loadout a name."
		draw()
		return
	var n := naming
	var row: Dictionary = {}
	for r in rows:
		if r["slot"] == n["slot"]:
			row = r
	naming = {}
	var preset: Dictionary
	if n["rename"] and not row.is_empty():
		preset = (row["preset"] as Dictionary).duplicate(true)
		preset["name"] = nm
	else:
		preset = current()
		preset["name"] = nm
	await _run(func() -> void:
		await save_preset(int(n["slot"]), preset)
		msg = "Renamed." if n["rename"] else "%s saved." % nm)


func _do_apply(slot: int, p: Dictionary) -> void:
	await _run(func() -> void:
		var lines := await apply_preset(slot, p)
		msg = ("%s is on, except: %s" % [p["name"], " ".join(lines)]) if not lines.is_empty() else "%s is on." % p["name"])


func _do_update(slot: int, p: Dictionary) -> void:
	await _run(func() -> void:
		var preset := current()
		preset["name"] = p["name"]
		await save_preset(slot, preset)
		msg = "%s now holds what you have on." % p["name"])


func _do_delete(slot: int, confirmed: bool) -> void:
	msg = ""
	if not confirmed:
		confirm_delete = slot
		draw()
		return
	confirm_delete = -1
	await _run(func() -> void:
		var r: DmResult = await ui.game.api.delete_loadout(int(ui.game.character["id"]), slot)
		if not r.ok:
			msg = r.error
			return
		rows = await _list()
		msg = "Loadout deleted.")


func _run(fn: Callable) -> void:
	busy = true
	draw()
	await fn.call()
	busy = false
	draw()

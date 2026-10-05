class_name DmGrimoireView
extends VBoxContainer
## The Grimoire (L, hotbar button, or right-click a slot; src/ui/GrimoirePanel.ts): the left-click primary plus five rite sockets (keys 1-5, RMB on 5).
## Click a socket, then a rite (or a rite's slot buttons) to equip it. A rite already on another key swaps places; cooldowns stay with the rite.
## Locked rites stay visible with their level. Relic runes: the selected rite's rune box (socket / swap / take out).
##
## Data in:  set_state({rites:{primary, keys:[5 ids]}, level:int, unseen:[ids], kit:{primaries:[], grimoire:[], rmb}})
##           set_runes({sockets:{rite: rune_id}, owned:{rune_id: count}}) or leave unset for "no rune box"
##           open_session(select = null)  (marks this opening's NEW tags, jumps to the primary when a new primary is unseen, emits mark_seen)
##           `loadout_host` is an empty slot for the Loadout presets strip (LoadoutPresets.ts, necromancers; not in this track).
## Signals:
##   assign_requested(slot, id)      -> client loadout (Rites) save; the loadout presets themselves use DmApi.save_loadout / apply_loadout_preset
##   assign_primary_requested(id)    -> same
##   mark_seen(ids)                  -> client "rites seen" memory
##   rune_socket_requested(rite, rune_id)  -> DmApi.rune_socket(character_id, rite, rune_id)  (rune_id "" = take the rune out); the host calls rune_done(error)

signal assign_requested(slot: int, id: String)
signal assign_primary_requested(id: String)
signal mark_seen(ids: Array)
signal rune_socket_requested(rite: String, rune_id: String)

const SLOTS := 5
const ROLES: Array[String] = ["damage", "corpse", "control", "survival", "legion"]

var state: Dictionary = {}
var runes: Variant = null
var selected: Variant = 0         # "primary" or 0..4
var role := "all"
var fresh: Dictionary = {}
var rune_error := ""
var rune_busy := false
var loadout_host: Control


func _init() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loadout_host = Control.new()
	loadout_host.name = "LoadoutHost"


func set_state(s: Dictionary) -> void:
	state = s
	render()


func set_runes(r: Variant, redraw := true) -> void:
	runes = r
	if redraw:
		render()


func open_session(select: Variant = null) -> void:
	if select != null:
		selected = select
	var unseen: Array = state.get("unseen", [])
	fresh = {}
	for id in unseen:
		fresh[id] = true
	var prim: Array = state.get("kit", {}).get("primaries", [])
	if select == null and String(str(selected)) != "primary":
		for id in unseen:
			if prim.has(id):
				selected = "primary"
				break
	render()
	mark_seen.emit(unseen)


func rune_done(err: Variant) -> void:
	rune_error = String(err) if err != null else ""
	rune_busy = false
	render()


static func secs(ms: float) -> String:
	return DmPa.strip_zeros(ms / 1000.0, 2) + "s"


func assignable() -> Array:
	var kit: Dictionary = state.get("kit", {})
	var out: Array = []
	for id in kit.get("grimoire", []):
		if not out.has(id):
			out.append(id)
	var rmb := String(kit.get("rmb", ""))
	if rmb != "" and not out.has(rmb):
		out.append(rmb)
	return out


## The rites listed under the bar for the current socket + role filter (what the entries show).
func listed() -> Array:
	var kit: Dictionary = state.get("kit", {})
	if str(selected) == "primary":
		return kit.get("primaries", []).duplicate()
	return assignable().filter(func(id: String) -> bool: return role == "all" or DmPaData.roles_of(id).has(role))


func selected_rite() -> String:
	var rites: Dictionary = state.get("rites", {})
	if str(selected) == "primary":
		return String(rites.get("primary", ""))
	return String((rites.get("keys", []) as Array)[int(selected)])


var _built_sig := 0
var _built := false
var _list: VBoxContainer                 # the rite cards: persistent, its rows come from _entries
var _entries := DmRowCache.new()         # rite id -> its card; only a card whose own inputs changed is rebuilt


func render() -> void:
	# One open used to draw this three times (open, refresh, mark_seen's refresh). Nothing in the inputs changed = nothing to redraw.
	var sig := [state, runes, selected, role, fresh, rune_error, rune_busy].hash()
	if _built and sig == _built_sig and get_child_count() > 0:
		return
	_built_sig = sig
	_built = true
	if loadout_host.get_parent() == self:
		remove_child(loadout_host)   # keep the slot alive across redraws (the presets strip is mounted into it)
	if _list != null and _list.get_parent() == self:
		remove_child(_list)
	DmPa.clear(self)
	if state.is_empty():
		return
	var rites: Dictionary = state["rites"]
	var level: int = int(state.get("level", 1))
	var kit: Dictionary = state["kit"]
	var primary_mode := str(selected) == "primary"
	var choices := assignable().size() > SLOTS or (kit.get("primaries", []) as Array).size() > 1
	var note := "Click a socket, then an unlocked rite to equip it." if choices else "Your class has one primary and five rites; you can rearrange all five slots."
	add_child(DmPa.rich("%s <b>LMB</b> is your left-click attack. Slot <b>5</b> also casts on right-click. A rite already on another slot swaps places, and cooldowns stay with the rite. Right-click a hotbar slot to jump here. Your signature rite stays on <b>R</b>." % note, 14, DmUi.TEXT_MUTED))
	# socket bar
	var bar := DmPa.grid(6, 8, 8)
	bar.add_child(_socket(String(rites["primary"]), "primary", "LMB"))
	for i in SLOTS:
		bar.add_child(_socket(String(rites["keys"][i]), i, "RMB · 5" if i == 4 else str(i + 1)))
	add_child(bar)
	add_child(loadout_host)
	if runes != null:
		add_child(_rune_section(selected_rite()))
	if primary_mode:
		add_child(DmPa.text("Primaries cost nothing and fire on left-click.", 14, DmUi.TEXT_MUTED))
	else:
		var f := DmPa.flow(6, 6)
		for r in ["all"] + ROLES:
			var lab: String = "All" if r == "all" else String(DmContent.get_export("abilities", "ROLE_LABEL")[r])
			var c := DmPa.chip(lab, role == r, "role", r)
			c.pressed.connect(func() -> void:
				role = r
				render())
			f.add_child(c)
		add_child(f)
	if _list == null:
		_list = DmPa.vbox(8)
		_list.set_meta("role", "list")
	add_child(_list)
	var ids: Array = listed()
	var sigs: Array = []
	for id in ids:
		sigs.append(_entry_sig(String(id), rites, level, primary_mode))
	_entries.sync(_list, ids, sigs, func(i: int) -> Dictionary: return {"node": _entry(String(ids[i]), rites, level, primary_mode)})


## What one rite card is drawn from.
func _entry_sig(id: String, rites: Dictionary, level: int, primary_mode: bool) -> int:
	var on: int
	if primary_mode:
		on = 0 if String(rites["primary"]) == id else -1
	else:
		on = (rites["keys"] as Array).find(id)
	return [id, level < DmPaData.unlock_level(id), on, fresh.has(id), primary_mode].hash()


func _socket(id: String, key: Variant, label: String) -> Control:
	var a: Dictionary = DmContent.ability(id)
	var on := str(selected) == str(key)
	var b := PanelContainer.new()
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := DmUi.box(DmUi.INSET, DmUi.GOLD if on else DmUi.BORDER_STRONG, 1, 0, Vector2(4, 8))
	b.add_theme_stylebox_override("panel", sb)
	b.set_meta("act", "socket")
	b.set_meta("arg", key)
	b.set_meta("on", on)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	b.add_child(v)
	var ic := DmPa.icon(String(a.get("icon", "")), 52, id)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(ic)
	var nm := DmPa.text(DmUi.upper(String(a.get("name", id))), 12, DmUi.BONE_100, "display", true)
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(nm)
	var k := DmPa.text(label, 13, DmUi.SPELL_300, "numeric", false)
	k.position = Vector2(7, 4)
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(k)
	# rune pip: the badge of the rune socketed in this rite
	if runes != null and DmPaData.is_rune_rite(id):
		var rid: String = String((runes as Dictionary).get("sockets", {}).get(id, ""))
		if rid != "":
			var pip := DmPa.icon("art/items/%s.webp" % rid, 18, rid, "◇")
			pip.position = Vector2(62, 6)
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pip.set_meta("rune_pip", rid)
			b.add_child(pip)
	b.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			select_socket(key))
	return b


func select_socket(key: Variant) -> void:
	selected = key
	render()


func _entry(id: String, rites: Dictionary, level: int, primary_mode: bool) -> Control:
	var a: Dictionary = DmContent.ability(id)
	var need := DmPaData.unlock_level(id)
	var locked := level < need
	var keys: Array = rites["keys"]
	var on: int
	if primary_mode:
		on = 0 if String(rites["primary"]) == id else -1
	else:
		on = keys.find(id)
	var cost := "%d essence" % int(a["essenceCost"]) if float(a.get("essenceCost", 0)) > 0.0 else "No cost"
	var roles := " · ".join(PackedStringArray(DmPaData.roles_of(id).map(func(r: String) -> String: return String(DmContent.get_export("abilities", "ROLE_LABEL")[r]))))
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", DmUi.box(DmUi.INSET, DmUi.BORDER_ACTIVE if on >= 0 else DmUi.BORDER, 1, 0, Vector2(12, 10)))
	card.set_meta("rite", id)
	card.set_meta("locked", locked)
	card.set_meta("equipped", on >= 0)
	card.set_meta("fresh", fresh.has(id) and not locked)
	if locked:
		card.modulate = Color(1, 1, 1, 0.62)
		card.set_meta("sealed", true)
	else:
		card.set_meta("act", "pick")
		card.set_meta("arg", id)
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		card.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				pick(id))
	var h := DmPa.hbox(12)
	card.add_child(h)
	h.add_child(DmPa.icon(String(a.get("icon", "")), 52, id))
	var t := DmPa.vbox(4)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	var hd := DmPa.hbox(10)
	var nm := DmPa.text(DmUi.upper(String(a["name"])), 18, DmUi.BONE_100, "display_bold", false)
	hd.add_child(nm)
	if fresh.has(id) and not locked:
		hd.add_child(DmUi.new_pip())
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hd.add_child(sp)
	var meta_t := "Level %d" % need if locked else "%s · %s" % [cost, secs(float(a["cooldownMs"]))]
	hd.add_child(DmPa.text(meta_t, 12, DmUi.SPELL_300, "numeric", false))
	t.add_child(hd)
	if roles != "":
		t.add_child(DmPa.text(DmUi.upper(roles), 11, DmUi.BONE_300, "body", false))
	t.add_child(DmPa.text(String(a.get("description", "")), 14, DmUi.TEXT_MUTED))
	var row := DmPa.hbox(10)
	var sw: Array = DmPaData.codex_rows().get("rite_swatch", {}).get(id, [])
	row.add_child(DmPa.swatches(sw))
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sp2)
	if primary_mode:
		if on == 0:
			row.add_child(DmPa.text("Equipped", 14, DmUi.BONE_100, "body_bold", false))
		elif not locked:
			row.add_child(DmPa.text("Click to equip", 14, DmUi.TEXT_MUTED, "body", false))
	else:
		var kb := DmPa.hbox(4)
		for i in SLOTS:
			var b := Button.new()
			b.text = str(i + 1)
			b.custom_minimum_size = Vector2(30, 28)
			b.focus_mode = Control.FOCUS_NONE
			b.theme_type_variation = "DmButtonSmall"
			b.disabled = locked or on == i
			b.set_meta("act", "put")
			b.set_meta("arg", i)
			b.set_meta("rite", id)
			b.set_meta("on", on == i)
			b.tooltip_text = "Put %s on %s" % [a["name"], "right-click or key 5" if i == 4 else "key %d" % (i + 1)]
			b.pressed.connect(func() -> void:
				selected = i
				assign_requested.emit(i, id))
			kb.add_child(b)
		row.add_child(kb)
	t.add_child(row)
	return card


## Click on a rite card: equip it into the selected socket.
func pick(id: String) -> void:
	if str(selected) == "primary":
		assign_primary_requested.emit(id)
	else:
		assign_requested.emit(int(selected), id)


# --- rune box ----------------------------------------------------------------------------------------------------
func _rune_section(rite: String) -> Control:
	var name := String(DmContent.ability(rite).get("name", rite))
	var c := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(12, 10))
	c.set_meta("role", "rune_box")
	var b := DmPa.card_body(c)
	var hh := DmPa.hbox(8)
	hh.add_child(DmPa.text(DmUi.upper("Rune socket"), 15, DmUi.BONE_300, "display_bold", false))
	hh.add_child(DmPa.text(name, 12, DmUi.TEXT_MUTED, "body", false))
	b.add_child(hh)
	if not DmPaData.is_rune_rite(rite):
		b.add_child(DmPa.text("%s has no runes yet. Bone Needle, Marrow Spear, Exhume, Miasma Circle and Black Litany each take one." % name, 14, DmUi.TEXT_FAINT))
		return c
	var rs: Dictionary = runes
	var sockets: Dictionary = rs.get("sockets", {})
	var owned: Dictionary = rs.get("owned", {})
	var cur := String(sockets.get(rite, ""))
	var now := DmPa.hbox(12)
	if cur != "":
		var def := DmContent.rune(cur)
		now.add_child(DmPa.icon("art/items/%s.webp" % cur, 56, cur, "◆"))
		var tx := DmPa.vbox(4)
		tx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tx.add_child(DmPa.text(String(def["name"]), 15, DmUi.BONE_100, "body_bold", false))
		for l in def.get("lines", []):
			tx.add_child(DmPa.text(String(l), 14, DmUi.TEXT_MUTED))
		if def.get("cost") != null and String(def["cost"]) != "":
			tx.add_child(DmPa.text(String(def["cost"]), 14, Color("e7b07a")))
		var out := DmPa.button("Take the rune out", "small", rune_busy, "rune_out")
		out.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		out.pressed.connect(func() -> void: request_rune(rite, ""))
		tx.add_child(out)
		now.add_child(tx)
	else:
		var e := DmPa.text("◇", 28, DmUi.TEXT_FAINT, "display_bold", false)
		e.custom_minimum_size = Vector2(56, 56)
		e.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		e.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		now.add_child(e)
		var tx := DmPa.vbox(2)
		tx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tx.add_child(DmPa.text("Empty socket", 15, DmUi.BONE_100, "body_bold", false))
		tx.add_child(DmPa.text("A rune changes how %s behaves, not how hard it hits. Choose one below." % name, 14, DmUi.TEXT_MUTED))
		now.add_child(tx)
	b.add_child(now)
	var sources := DmPaData.rune_sources()
	for rid in DmPaData.runes_for(rite):
		var def := DmContent.rune(rid)
		var n: int = int(owned.get(rid, 0))
		var rarity := String(def["rarity"])
		var row := PanelContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var hl := DmPa.hbox(10)
		row.add_child(hl)
		var tx := DmPa.vbox(0)
		tx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var go := ""
		var mode := ""
		if cur == rid:
			mode = "on"
			go = "Socketed"
			tx.add_child(DmPa.text("%s  %s" % [def["name"], rarity], 14, DmUi.BONE_100, "body_bold", false))
			tx.add_child(DmPa.text(String(def["short"]), 13, DmUi.TEXT_MUTED))
			row.add_theme_stylebox_override("panel", DmUi.box(Color(DmUi.SPELL_400, 0.12), DmUi.BORDER_ACTIVE, 1, 0, Vector2(8, 6)))
		elif n > 0:
			mode = "owned"
			go = "Swap in" if cur != "" else "Socket"
			tx.add_child(DmPa.text("%s  %s · you have %d" % [def["name"], rarity, n], 14, DmUi.BONE_100, "body_bold", false))
			tx.add_child(DmPa.text(String(def["short"]), 13, DmUi.TEXT_MUTED))
			row.add_theme_stylebox_override("panel", DmUi.box(Color(0, 0, 0, 0.2), DmUi.BORDER, 1, 0, Vector2(8, 6)))
			row.set_meta("act", "rune")
			row.set_meta("arg", rid)
			row.set_meta("disabled", rune_busy)
			row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			row.gui_input.connect(func(ev: InputEvent) -> void:
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					request_rune(rite, rid))
		else:
			mode = "sealed"
			go = "Not found yet"
			tx.add_child(DmPa.text("%s  %s" % [def["name"], rarity], 14, DmUi.TEXT_MUTED, "body_bold", false))
			tx.add_child(DmPa.text(String(def["short"]), 13, DmUi.TEXT_FAINT))
			tx.add_child(DmPa.text("Drops from %s" % sources.get(rid, ""), 12, DmUi.TEXT_FAINT))
			row.add_theme_stylebox_override("panel", DmUi.box(Color(0, 0, 0, 0.2), DmUi.SLOT_BORDER, 1, 0, Vector2(8, 6)))
			row.tooltip_text = String(sources.get(rid, ""))
		row.set_meta("rune_row", rid)
		row.set_meta("mode", mode)
		var ic := DmPa.icon("art/items/%s.webp" % rid, 34, rid, "◆")
		if mode == "sealed":
			ic.modulate = Color(0.5, 0.5, 0.5, 1)
		hl.add_child(ic)
		hl.add_child(tx)
		hl.add_child(DmPa.text(go, 12, DmUi.SPELL_300, "numeric", false))
		b.add_child(row)
	b.add_child(DmPa.rich("This socket is already yours. <b>Runes</b> drop from elites (more often the deeper the ground), Grave Surge offerings, bosses (the first kill of each always leaves one) and Catacomb Depths chests. The Gear Atlas (<kbd>.</kbd>) lists the chances.", 13, DmUi.TEXT_FAINT))
	if rune_error != "":
		var er := DmPa.text(rune_error, 13, DmUi.DANGER)
		er.set_meta("role", "rune_error")
		b.add_child(er)
	return c


func request_rune(rite: String, rune_id: String) -> void:
	if rune_busy:
		return
	rune_busy = true
	rune_error = ""
	render()
	rune_socket_requested.emit(rite, rune_id)

class_name DmCodexPanel
extends DmPaTabbedWindow
## The Codex (K; src/ui/CodexPanel.ts): rites, disciplines, weapons, armor sets, Gear Atlas, affixes, runes, Altar & Vows, stats, the dead, the diocese,
## people, professions, lore, Chronicle. Text comes from the exported content/codex.ts (godot/data/content/codex.json) and from the computed rows
## (godot/data/panels_a/codex_rows.json, produced by tools/godot/export-panels-a.ts evaluating codexSetRows(), codexAffixRows(), ...).
## Enemy and area entries stay sealed until the journal records them. Each tab is built when you open it.
##
## Data in:  set_discipline(id), set_journal(dead: Array, areas: Array), set_runes_found(ids), set_met_npcs(ids), set_chronicle(view),
##           auto_combat_allowed (gateAuto: shows/drops the {auto}...{/auto} help text)
## Signals:  atlas_requested        -> opens the Gear Atlas (DmAtlasPanel)
##           chronicle_requested    -> DmApi.get_chronicle(character_id); answer with set_chronicle(view)  (the web refreshes it when the tab opens)

signal atlas_requested
signal chronicle_requested

const TABS := [
	["rites", "Rites"], ["disciplines", "Disciplines"], ["weapons", "Weapons"], ["sets", "Armor sets"], ["atlas", "Gear Atlas"],
	["affixes", "Item affixes"], ["runes", "Relic Runes"], ["altar", "Altar & Vows"], ["stats", "Stats"], ["dead", "The Dead"],
	["diocese", "The Diocese"], ["people", "People"], ["professions", "Professions"], ["lore", "Covenant Lore"], ["chronicle", "Chronicle"],
]

var discipline := "gravecaller"
var journal_dead: Dictionary = {}
var journal_area: Dictionary = {}
var runes_found: Dictionary = {}
var met_npcs: Dictionary = {}
var chronicle_view: Dictionary = {}
var auto_combat_allowed := false

var _views: Dictionary = {}
var _c: Dictionary = {}    # codex.json exports
var _r: Dictionary = {}    # codex_rows.json


func _init() -> void:
	super._init()
	title = "Codex"
	panel_width = 680
	_c = DmContent.file("codex")
	_r = DmPaData.codex_rows()
	for t in TABS:
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 8)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_views[t[0]] = v
		add_tab(t[0], t[1], v)
	tab_changed.connect(_on_tab)
	_on_tab(active)


func _on_tab(id: String) -> void:
	if id == "chronicle":
		chronicle_requested.emit()
	render_tab(id)


func set_discipline(id: String) -> void:
	discipline = id
	render_tab("disciplines")


func set_journal(dead: Array, areas: Array) -> void:
	journal_dead = {}
	for d in dead:
		journal_dead[String(d)] = true
	journal_area = {}
	for a in areas:
		journal_area[String(a)] = true
	render_tab("dead")
	render_tab("diocese")


func set_runes_found(ids: Array) -> void:
	runes_found = {}
	for i in ids:
		runes_found[String(i)] = true
	render_tab("runes")


func set_met_npcs(ids: Array) -> void:
	met_npcs = {}
	for i in ids:
		met_npcs[String(i)] = true
	render_tab("people")


func set_chronicle(view: Dictionary) -> void:
	chronicle_view = view
	render_tab("chronicle")


func tab_view(id: String) -> VBoxContainer:
	return _views[id]


## Rebuild one tab (only the open tab pays for it; others rebuild when opened).
func render_tab(id: String) -> void:
	if id != active:
		_views[id].set_meta("stale", true)
		return
	var v: VBoxContainer = _views[id]
	DmPa.clear(v)
	v.remove_meta("stale")
	match id:
		"rites": _rites(v)
		"disciplines": _disciplines(v)
		"weapons": _weapons(v)
		"sets": _sets(v)
		"atlas": _atlas(v)
		"affixes": _affixes(v)
		"runes": _runes(v)
		"altar": _altar(v)
		"stats": _stats(v)
		"dead": _dead(v)
		"diocese": _diocese(v)
		"people": _people(v)
		"professions": _professions(v)
		"lore": _lore(v)
		"chronicle": _chronicle(v)


# --- helpers ----------------------------------------------------------------------------------------------------
func _gate(t: String) -> String:
	return DmPa.gate_auto(t, auto_combat_allowed)


func _tip(v: Control, t: String) -> void:
	v.add_child(DmPa.text(t, 14, DmUi.BONE_300))


func _note(v: Control, t: String) -> void:
	v.add_child(DmPa.text(t, 14, DmUi.TEXT_MUTED))


## A .cw-codex-entry. Returns {card, txt}: add paragraphs to txt. `media` is the icon/portrait on the left.
func _entry(v: Control, name: String, meta: String = "", media: Control = null, border: Color = DmUi.BORDER, bg: Color = DmUi.INSET) -> VBoxContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", DmUi.box(bg, border, 1, 0, Vector2(12, 10)))
	var h := DmPa.hbox(12)
	card.add_child(h)
	if media != null:
		h.add_child(media)
	var txt := DmPa.vbox(4)
	txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(txt)
	if name != "" or meta != "":
		var hd := DmPa.hbox(10)
		var n := DmPa.text(DmUi.upper(name), 18, DmUi.BONE_100, "display_bold", false)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		n.clip_text = true
		n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		hd.add_child(n)
		if meta != "":
			var m := DmPa.text(meta, 12, DmUi.SPELL_300, "numeric", false)
			m.size_flags_vertical = Control.SIZE_SHRINK_END
			hd.add_child(m)
		txt.add_child(hd)
	card.set_meta("entry", name)
	v.add_child(card)
	return txt


func _p(txt: Control, t: String) -> void:
	txt.add_child(DmPa.text(t, 14, DmUi.TEXT_MUTED))


func _use_well(txt: Control, tip: String) -> void:
	txt.add_child(DmPa.rich("<b>Use it well.</b> %s" % tip, 14, DmUi.BONE_300))


func _ability_icon(id: String) -> Control:
	return DmPa.icon(String(DmContent.ability(id).get("icon", "")), 52, id)


func _secs(ms: float) -> String:
	return DmGrimoireView.secs(ms)


func _sealed(v: Control, text: String) -> void:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 0, Vector2(12, 10)))
	card.modulate = Color(1, 1, 1, 0.62)
	card.set_meta("sealed", true)
	var h := DmPa.hbox(12)
	card.add_child(h)
	var seal := DmPa.text("⊘", 26, DmUi.STONE_500, "display_bold", false)
	seal.custom_minimum_size = Vector2(34, 34)
	seal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	h.add_child(seal)
	var t := DmPa.vbox(2)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_child(DmPa.text(DmUi.upper("Sealed"), 15, DmUi.TEXT_FAINT, "display_bold", false))
	t.add_child(DmPa.text(text, 14, DmUi.TEXT_MUTED))
	h.add_child(t)
	v.add_child(card)


func _count(v: Control, label: String, n: int, total: int) -> void:
	var l := DmPa.rich("%s <b>%d</b> OF %d" % [DmUi.upper(label), n, total], 12, DmUi.TEXT_FAINT)
	v.add_child(l)


func _table_card(txt: Control, headers: Array, rows: Array, ratios: Array = [], right: Array = []) -> void:
	txt.add_child(DmPa.table(headers, rows, ratios, right))


func _area_name(id: String) -> String:
	return String(DmContent.area(id).get("name", id))


# --- tabs ---------------------------------------------------------------------------------------------------------
func _rites(v: VBoxContainer) -> void:
	for id in _c["RITE_ORDER"]:
		var a: Dictionary = DmContent.ability(String(id))
		var r: Dictionary = _c["CODEX_RITES"][id]
		var slot := int(a.get("slot", 1))
		var key := "Left click" if slot == 0 else ("Key R" if slot == 6 else "Grimoire · slots 1–5")
		var cost := "%d essence" % int(a["essenceCost"]) if float(a.get("essenceCost", 0)) > 0.0 else "No cost"
		var txt := _entry(v, String(a["name"]), "%s · %s · %s" % [key, cost, _secs(float(a["cooldownMs"]))], _ability_icon(String(id)))
		_p(txt, String(a["description"]))
		_use_well(txt, _gate(String(r["tip"])))
		var sw := DmPa.hbox(8)
		sw.add_child(DmPa.swatches(_r["rite_swatch"].get(id, [])))
		sw.add_child(DmPa.text(String(r["colour"]), 12, DmUi.TEXT_FAINT, "body", false))
		txt.add_child(sw)


func _stats(v: VBoxContainer) -> void:
	_tip(v, String(_c["CODEX_STATS_COUNSEL"]))
	for s in _c["CODEX_STATS"]:
		var txt := _entry(v, String(s["name"]), String(s["stat"]))
		_p(txt, String(s["effects"]))


func _weapons(v: VBoxContainer) -> void:
	_tip(v, String(_c["CODEX_WEAPONS_COUNSEL"]))
	for w in _c["CODEX_WEAPONS"]:
		var txt := _entry(v, String(w["name"]), "%s · %s" % [w["hands"], w["suits"]], DmPa.icon("art/items/%s_gold.svg" % w["kind"], 52, String(w["kind"]), "⚔"))
		_p(txt, String(w["change"]))
		_use_well(txt, _gate(String(w["tip"])))
	var rows: Array = []
	for t in _r["weapon_tiers"]:
		rows.append([t["label"], "%d+" % int(t["level"]), ", ".join(PackedStringArray((t["areas"] as Array).map(func(a: String) -> String: return _area_name(a))))])
	v.add_child(DmPa.table(["Tier", "Recommended level", "Drops in"], rows))


func _sets(v: VBoxContainer) -> void:
	_tip(v, String(_c["CODEX_SETS_COUNSEL"]))
	var rows: Array = _r["sets"]
	for r in rows:
		if int(r["collection"]) != 3:
			_set_entry(v, r)
	var h := DmPa.text(DmUi.upper("Legendary sets"), 15, DmUi.rarity_color("legendary"), "display_bold", false)
	v.add_child(DmPa.margin(h, 0, 14, 0, 0))
	_tip(v, String(_c["CODEX_LEGENDARY_COUNSEL"]))
	for r in rows:
		if int(r["collection"]) == 3:
			_set_entry(v, r)


func _set_entry(v: Control, r: Dictionary) -> void:
	var coll := int(r["collection"])
	var label := "Legendary" if coll == 3 else ("First collection" if coll == 1 else "Ascended collection")
	var leg := coll == 3
	var txt := _entry(v, String(r["name"]), "%s · %s" % [r["wearer"], label], null, Color(DmUi.rarity_color("legendary"), 0.55) if leg else DmUi.BORDER)
	var pairs: Array = []
	for b in r["bonuses"]:
		var body := String(b["text"])
		if b.has("name") and String(b["name"]) != "":
			body = "<b>%s.</b> %s" % [b["name"], body]
		pairs.append(["%d pieces" % int(b["pieces"]), body])
	txt.add_child(DmPa.dl(pairs))
	txt.add_child(DmPa.text(String(r["drops"]), 14, DmUi.BONE_300))


func _atlas(v: VBoxContainer) -> void:
	_tip(v, String(_c["CODEX_ATLAS_COUNSEL"]))
	var b := DmPa.button("Open the Gear Atlas", "", false, "open_atlas")
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.pressed.connect(func() -> void: atlas_requested.emit())
	v.add_child(b)


func _affixes(v: VBoxContainer) -> void:
	_tip(v, String(_c["CODEX_AFFIX_COUNSEL"]))
	var rows: Array = []
	for r in _r["affixes"]:
		rows.append([("† " if bool(r["necro"]) else "") + String(r["word"]), r["low"], r["high"]])
	v.add_child(DmPa.table(["Name", "Item level 10", "Item level 40"], rows, [1.2, 1, 1]))
	var txt := _entry(v, "The Legion kit", "Y · thrall gear")
	_p(txt, String(_c["CODEX_LEGION_COUNSEL"]))
	var ex: Array = []
	for r in _r["legion_examples"]:
		ex.append([r["item"], r["slot"], str(r["points"]), r["gives"]])
	txt.add_child(DmPa.table(["Spare piece", "Slot", "Stat points", "Gives your thralls"], ex, [1.2, 0.8, 0.8, 2]))
	var tr: Array = []
	for r in _r["legion_tiers"]:
		tr.append([str(int(r["tier"])), DmPa.commas(r["cost"]), DmPa.commas(r["total"]), r["bonus"]])
	txt.add_child(DmPa.table(["Reinforce tier", "Gold", "Total", "Legion bonus"], tr, [1, 0.8, 0.8, 2.4]))


func _runes(v: VBoxContainer) -> void:
	_tip(v, String(_c["CODEX_RUNES_COUNSEL"]))
	var lo := _entry(v, "Loadouts", "Grimoire (L)")
	_p(lo, String(_c["CODEX_LOADOUTS_COUNSEL"]))
	for g in _r["runes"]:
		var found := 0
		for r in g["runes"]:
			if runes_found.has(String(r["id"])):
				found += 1
		var txt := _entry(v, String(g["rite"]), "%d of %d found" % [found, (g["runes"] as Array).size()])
		for r in g["runes"]:
			var known := runes_found.has(String(r["id"]))
			var row := PanelContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.set_meta("rune", String(r["id"]))
			row.set_meta("found", known)
			row.add_theme_stylebox_override("panel", DmUi.box(Color(DmUi.SPELL_400, 0.12) if known else Color(0, 0, 0, 0.2), DmUi.BORDER_ACTIVE if known else DmUi.SLOT_BORDER, 1, 0, Vector2(8, 6)))
			var h := DmPa.hbox(10)
			row.add_child(h)
			var ic := DmPa.icon("art/items/%s.webp" % r["id"], 44, String(r["id"]), "◆")
			if not known:
				ic.modulate = Color(0.55, 0.55, 0.55)
			h.add_child(ic)
			var t := DmPa.vbox(2)
			t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			t.add_child(DmPa.text("%s  %s" % [r["name"], r["rarity"]], 14, DmUi.BONE_100 if known else DmUi.TEXT_MUTED, "body_bold", false))
			if known:
				var body := "<b>%s.</b> %s" % [r["short"], " ".join(PackedStringArray(r["lines"]))]
				var rt := DmPa.rich(body, 13, DmUi.TEXT_MUTED)
				if r.get("cost") != null and String(r["cost"]) != "":
					rt.text += " [color=#e7b07a]%s[/color]" % String(r["cost"]).replace("[", "[lb]")
				t.add_child(rt)
				t.add_child(DmPa.text("%s Drops from %s." % [r["lore"], r["sources"]], 12, DmUi.TEXT_FAINT, "body_italic"))
			else:
				t.add_child(DmPa.text("Not found yet. Drops from %s." % r["sources"], 13, DmUi.TEXT_FAINT))
			h.add_child(t)
			txt.add_child(row)


func _altar(v: VBoxContainer) -> void:
	_tip(v, String(_c["CODEX_ALTAR_COUNSEL"]))
	var rows: Array = []
	for r in _r["altar"]:
		rows.append([r["name"], r["kind"], r["effect"], r["cost"], r["unlock"]])
	v.add_child(DmPa.table(["Name", "Kind", "Effect", "Heat / cost", "Unlock"], rows, [1, 0.6, 2.2, 1.2, 0.9]))


func _dead(v: VBoxContainer) -> void:
	var order: Array = _c["DEAD_ORDER"]
	var known := 0
	for id in order:
		if journal_dead.has(String(id)):
			known += 1
	_count(v, "Recorded", known, order.size())
	var sealed_text := String(_c["CODEX_SEALED"]["dead"])
	var bosses := DmContent.bosses()
	for id in order:
		if not journal_dead.has(String(id)):
			_sealed(v, sealed_text)
			continue
		var e: Dictionary = _c["CODEX_DEAD"][id]
		var txt := _entry(v, String(e["name"]), String(_c["BEHAVIOUR_LABEL"].get(String(e["role"]), "")))
		if bosses.has(id):
			var boss: Dictionary = bosses[id]
			if String(boss.get("portrait", "")) != "" and String(id) != "prelate":
				txt.add_child(DmPa.icon(String(boss["portrait"]), 96, String(id), "♛"))
		else:
			txt.add_child(DmPa.text(String(DmContent.enemy(String(id)).get("blurb", "")), 15, DmUi.TEXT_FAINT, "display_italic"))
		txt.add_child(DmPa.dl([["Behaviour", String(e["behaviour"])], ["Corpse", String(e["corpse"])], ["Counter", String(e["counter"])]]))


func _diocese(v: VBoxContainer) -> void:
	var order: Array = DmContent.area_order()
	var known := 0
	for id in order:
		if journal_area.has(String(id)):
			known += 1
	_tip(v, String(_c["CODEX_TRAVEL_COUNSEL"]))
	_count(v, "Walked", known, order.size())
	for id in order:
		if not journal_area.has(String(id)):
			_sealed(v, String(_c["CODEX_SEALED"]["area"]))
			continue
		var a: Dictionary = DmContent.area(String(id))
		var inst := bool(a.get("instance", false))
		var txt := _entry(v, String(a["name"]), "Your level + depth" if inst else "Level %d" % int(a["level"]))
		txt.add_child(DmPa.text(String(a.get("subtitle", "")), 15, DmUi.TEXT_FAINT, "display_italic"))
		var pairs: Array = [["Reached" if inst else "Unsealed", String(_r["area_unlock"].get(id, ""))], ["Dangers", String(_c["CODEX_AREAS"][id]["dangers"])]]
		if inst:
			var depth := float(chronicle_view.get("life", {}).get("peak.depth", 0))
			pairs.append(["Your deepest", "Depth %d" % int(floor(depth)) if depth > 0.0 else "You have not been down yet"])
		var enemies: Array = a.get("enemies", [])
		if not enemies.is_empty():
			var seen: Array = []
			for e in enemies:
				if journal_dead.has(String(e["id"])):
					seen.append(String(DmContent.enemy(String(e["id"])).get("name", e["id"])))
			var unseen := enemies.size() - seen.size()
			var names := seen.duplicate()
			if unseen > 0:
				names.append("%d unrecorded" % unseen)
			pairs.append(["The dead", ", ".join(PackedStringArray(names))])
		txt.add_child(DmPa.dl(pairs))


func _people(v: VBoxContainer) -> void:
	_note(v, String(_c["CODEX_PEOPLE_COUNSEL"]))
	for p in _r["people"]:
		var txt := _entry(v, String(p["name"]), "%s · %s" % ["Met" if met_npcs.has(String(p["id"])) else "Not yet met", p["where"]])
		_p(txt, String(p["blurb"]))
		txt.add_child(DmPa.rich("<b>Ask about:</b> %s" % p["ask"], 14, DmUi.TEXT_MUTED))


func _lore(v: VBoxContainer) -> void:
	var lore: Dictionary = _c["COVENANT_LORE"]
	var t := DmPa.text(DmUi.upper(String(lore["title"])), 20, DmUi.BONE_100, "display_bold", false)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(DmPa.margin(t, 0, 4, 0, 6))
	for p in lore["paragraphs"]:
		v.add_child(DmPa.text(String(p), 15, DmUi.BONE_300))


func _disciplines(v: VBoxContainer) -> void:
	_tip(v, String(_c["CLASS_CHANGE_COUNSEL"]))
	for d in DmContent.file("disciplines")["PLAYABLE_DISCIPLINES"]:
		var mine := String(d["id"]) == discipline
		var col := Color(String(d["color"]))
		var por := DmPaPortrait.new()
		por.setup(String(d.get("portrait", "")), String(d["id"]), col)
		por.custom_minimum_size = Vector2(72, 96)
		por.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		por.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		por.fixed_size = Vector2(72, 96)
		var txt := _entry(v, String(d["name"]), "Your discipline" if mine else "", por, Color(col, 0.55) if mine else DmUi.BORDER)
		txt.add_child(DmPa.text(String(d["epithet"]), 15, col, "display_italic"))
		_p(txt, String(d["description"]))
		var ps: Dictionary = d["passive"]
		txt.add_child(DmPa.rich_bb("[color=#%s][b]%s.[/b][/color] %s" % [col.to_html(false), ps["name"], ps["text"]], 14, DmUi.BONE_300))
		txt.add_child(DmPa.text(String(_c["CODEX_DISCIPLINES"][d["id"]]["tip"]), 14, DmUi.BONE_300))
		v.get_child(v.get_child_count() - 1).set_meta("mine", mine)


# --- professions ------------------------------------------------------------------------------------------------------
const STATIONS := [
	["Bone Kiln", "Smelting, gathering tools (Mining recipes) and Bonework: bones ground into bone meal (Gravedigging)."],
	["Sawpit", "A plank for every log, plus staves and bows (Woodcutting recipes)."],
	["Cooking Fire", "A meal for every fish (heals over time), fillets, tinctures and flasks (Fishing recipes)."],
	["Great Cauldron & Alembic", "The Alchemist's Wing, through the Chapterhouse's east door: every Alchemy brew, plus a daily bonus brew. The Reagent Shelf there lists every reagent you have found."],
	["Bone Grinder", "Grinds spare gear into ingots, planks and reagents (Salvaging). See below."],
	["Tools", "A hatchet, pickaxe, rod or spade in your bag adds +5% success per metal tier to its skill (copper to moon; the best you carry counts)."],
]


func _professions(v: VBoxContainer) -> void:
	_tip(v, String(_c["CODEX_PROFESSIONS_COUNSEL"]))
	for s in _r["professions"]:
		var rows: Array = []
		for n in s["rows"]:
			rows.append([str(int(n["level"])), n["name"], str(int(n["xp"])), "%ss" % DmPa.strip_zeros(float(n["cycle"]), 1), n["yields"], "~%sk" % DmPa.strip_zeros(float(n["xph"]), 1), n["where"]])
		var txt := _entry(v, String(s["name"]), String(s["rite"]), null, DmUi.BORDER)
		txt.add_child(DmPa.table(["Lvl", "Node", "XP", "Cycle", "Yields", "XP/h", "Where"], rows, [0.4, 1.2, 0.5, 0.6, 1, 0.6, 1.6]))
	var st := _entry(v, "Stations", "Sexton's Acre, by the door")
	st.add_child(DmPa.dl(STATIONS))
	st.add_child(DmPa.text("XP/h assumes steady work at the node's own level with the node always ready; your odds improve with every level above it.", 14, DmUi.TEXT_MUTED))
	var vt := _entry(v, "The Ossuary Vault", "V · Chapterhouse")
	_p(vt, String(_c["CODEX_VAULT_COUNSEL"]))
	var sal: Dictionary = _r["skills_salvaging"]
	var sv := _entry(v, "Salvaging", "%s · Bone Grinder" % sal["rite"], null, DmUi.BORDER)
	_p(sv, String(_c["CODEX_SALVAGE_COUNSEL"]))
	var srows: Array = []
	for r in _r["salvage"]:
		srows.append([r["rarity"], r["qty"], r["ingots"], r["planks"], r["reagents"], str(int(r["xp"]))])
	sv.add_child(DmPa.table(["Gear", "Qty", "Ingot (most gear)", "Plank (staff, wand, grimoire)", "Reagents", "XP"], srows, [0.8, 0.4, 1, 1.2, 1.6, 0.4]))
	var sk := _entry(v, "Reforge and Empowered bosses", "Gold sinks · Workbench (C) · boss altars")
	_p(sk, String(_c["CODEX_REFORGE_COUNSEL"]))
	_p(sk, String(_c["CODEX_EMPOWER_COUNSEL"]))
	var erows: Array = []
	for r in _r["empower"]:
		erows.append([r["boss"], "1 Seal + %s" % DmPa.commas(r["gold"]), "%d%%" % int(r["legendary"])])
	sk.add_child(DmPa.table(["Boss", "Seal and gold", "Legendary in the prize"], erows))
	var bw := _entry(v, "Elixirs & Tonics", "Z elixir · X tonic")
	_p(bw, String(_c["CODEX_BREWS_COUNSEL"]))
	var bp: Array = []
	for r in _r["brews"]:
		bp.append([r["name"], "%s · %s · %ss" % [r["slot"], r["effects"], int(r["seconds"])]])
	bw.add_child(DmPa.dl(bp))
	var rg := _entry(v, "Reagents", "Alchemist's Wing · Alchemy")
	_p(rg, String(_c["CODEX_REAGENTS_COUNSEL"]))
	var rp: Array = []
	for r in _r["reagents"]:
		var from := String(r["from"])
		if String(r.get("usedIn", "")) != "":
			from += ". Brews: %s." % r["usedIn"]
		rp.append([r["name"], from])
	rg.add_child(DmPa.dl(rp))
	var rr: Array = []
	for r in _r["reagent_recipes"]:
		rr.append([str(int(r["level"])), r["name"], str(int(r["qty"])), r["ings"], "%s · %s · %ss" % [r["slot"], r["effects"], int(r["seconds"])]])
	rg.add_child(DmPa.table(["Alch", "Brew", "Makes", "Needs", "Effect"], rr, [0.4, 1.2, 0.5, 1.2, 1.8]))


# --- chronicle -----------------------------------------------------------------------------------------------------------
static func _n(v: Variant) -> String:
	return DmPa.commas(floorf(float(v if v != null else 0)))


static func _dur(s: Variant) -> String:
	var secs := float(s if s != null else 0)
	var h := int(floorf(secs / 3600.0))
	var m := int(floorf(fmod(secs, 3600.0) / 60.0))
	return "%dh %dm" % [h, m] if h > 0 else "%dm" % m


func _chronicle(v: VBoxContainer) -> void:
	if chronicle_view.is_empty():
		_note(v, "The Chronicle is not being kept.")
		return
	var c := chronicle_view
	var life: Dictionary = c.get("life", {})
	_note(v, "Everything you do is written here. Lifetime totals never reset; each Ascension closes a run and opens the next. Counting began on the day the Chronicle was opened.")
	var areas: Array = []
	for a in DmContent.area_order():
		if float(life.get("kills." + String(a), 0)) != 0.0:
			areas.append([_area_name(String(a)), _n(life["kills." + String(a)])])
	var bosses: Array = []
	for b in DmContent.bosses():
		if float(life.get("boss." + String(b), 0)) != 0.0:
			bosses.append([String(DmContent.boss(String(b)).get("name", b)), _n(life["boss." + String(b)])])
	var combat: Array = [["Foes slain", _n(life.get("kills"))]] + areas + bosses + [["Deaths", _n(life.get("deaths"))]]
	if float(life.get("peak.depth", 0)) != 0.0:
		combat += [["Deepest descent", "Depth " + _n(life["peak.depth"])], ["Depths floors cleared", _n(life.get("depths.floors"))], ["Depths chests opened", _n(life.get("depths.chests"))]]
	combat += [["Highest level", _n(life.get("peak.level"))], ["Highest wave tier", _n(life.get("peak.wave"))]]
	var economy: Array = [["Gold earned", _n(life.get("gold.earned"))], ["Gold spent", _n(life.get("gold.spent"))], ["Items sold", _n(life.get("sold"))], ["Items crafted", _n(life.get("crafted"))]]
	var gathering: Array = []
	for s in _r["professions"]:
		gathering.append([String(s["name"]), _n(life.get("gathered." + String(s["skill"])))])
	gathering.append(["AFK time", _dur(life.get("afkSeconds"))])
	var runno := int(c.get("runNo", 1))
	var time: Array = [["Time played", _dur(life.get("playSeconds"))], ["Runs completed", str(runno - 1)], ["This run", "#%d" % runno]]
	var g := DmPa.grid(2, 12, 12)
	for grp in [["Combat", combat], ["Economy", economy], ["Gathering", gathering], ["Time", time]]:
		var card := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(12, 10))
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cb := DmPa.card_body(card)
		cb.add_theme_constant_override("separation", 3)
		cb.add_child(DmPa.text(DmUi.upper(String(grp[0])), 13, DmUi.BONE_300, "display_bold", false))
		for r in grp[1]:
			var row := DmPa.hbox(8)
			row.add_child(DmPa.text(String(r[0]), 13, DmUi.TEXT_MUTED))
			var val := DmPa.text(String(r[1]), 13, DmUi.BONE_100, "numeric", false)
			val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(val)
			cb.add_child(row)
		g.add_child(card)
	v.add_child(g)
	v.add_child(DmPa.margin(DmPa.text(DmUi.upper("Runs"), 15, DmUi.BONE_300, "display_bold", false), 0, 8, 0, 0))
	var run: Dictionary = c.get("run", {})
	var rows: Array = [_run_row("#%d (now)" % runno, run, "—")]
	for r in c.get("runs", []):
		rows.append(_run_row("#%d" % int(r["runNo"]), r["stats"], _date(String(r.get("endedAt", "")))))
	v.add_child(DmPa.table(["Run", "Kills", "Prelate", "Deaths", "Gold", "Time", "Ended"], rows))
	_note(v, "The public leaderboard shows every player's time played and completed runs.")


func _run_row(label: String, s: Dictionary, ended: String) -> Array:
	return [label, _n(s.get("kills")), _n(s.get("boss.prelate")), _n(s.get("deaths")), _n(s.get("gold.earned")), _dur(s.get("playSeconds")), ended]


## ISO timestamp -> "M/D/YYYY" (toLocaleDateString, en-US).
static func _date(iso: String) -> String:
	if iso.length() < 10:
		return iso
	return "%d/%d/%s" % [int(iso.substr(5, 2)), int(iso.substr(8, 2)), iso.substr(0, 4)]

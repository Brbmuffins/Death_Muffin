class_name DmAtlasPanel
extends DmWindow
## The Gear Atlas (the . key; archive/legacy-web:src/ui/AtlasPanel.ts): what drops where and how often, what makes it, and what suits you. Five views (Best for me, By slot,
## By area & boss, By set, Materials & brews) plus search; a list on the left, the selected item's detail on the right (where it drops, how to make it,
## salvage, upgrading, set). All numbers come from the exported Atlas model (godot/data/panels_a/atlas.json, evaluated from gameplay/atlas.ts); the
## per-player parts (the upgrade/downgrade arrow and set outlook for every item) are INPUT because they need the live stat context.
##
## Data in:  set_context({disc: "gravecaller", level: 12, area: "graves",
##                        owned: {item_id: {n, worn}}          (see owned_from_slots(slots))
##                        verdicts: {item_id: {kind: "upgrade"|"downgrade"|"same", pct, text, empty}}   gearStats.itemVerdict as a bag item, per item
##                        outlooks: {item_id: {setName, total, withSetPct, bonusPct, hint}}})           gameplay/atlas.ts setOutlook, per set piece
##           (verdicts/outlooks may be {}: the arrows and "with set" figures simply do not show, like the web without a character)
## Signals:  none (read-only; no DmApi call). `closed` as usual. View/slot/place/set/filters are remembered between opens (static `memory`), like the web.

const VIEWS := [["best", "Best for me"], ["slot", "By slot"], ["where", "By area & boss"], ["set", "By set"], ["mats", "Materials & brews"]]
const MATS := [["materials", "Materials"], ["brews", "Brews & food"], ["reagents", "Reagents, runes & seeds"], ["cosmetics", "Capes & pets"]]
const SLOT_SHORT := {"head": "Head", "chest": "Chest", "legs": "Legs", "feet": "Feet", "hands": "Hands", "main_hand": "Main hand", "off_hand": "Off hand", "ring": "Ring", "trinket": "Trinket"}
const SLOT_ORDER := ["head", "chest", "legs", "feet", "hands", "main_hand", "off_hand", "ring", "trinket"]
const TYPE_GLYPH := {"weapon": "⚔", "offhand": "◐", "armor_head": "⛨", "armor_chest": "⛊", "armor_legs": "⛊", "armor_feet": "◭", "armor_hands": "✋", "ring": "◎", "trinket": "✦", "rune": "✧", "material": "◆"}
const FIT_COLOR := {"ideal": Color("a9c28a"), "good": Color("8fc7b0"), "okay": Color("d8b25a"), "poor": Color("d97a6b")}
const FIT_LABEL := {"ideal": "Ideal", "good": "Good", "okay": "Okay", "poor": "Poor"}
const GOLD_RUNG := Color("d4a24a")
const SOURCES_SHORT := 8
const LIST_MAX := 80

## Remembered while the game runs, so reopening lands where you left off (the web's module-level `memory`).
static var memory := {"view": "best", "slot": "head", "where": "", "set": "", "mats": "materials", "reach": true, "build": false, "sel": ""}

var disc := "gravecaller"
var level := 1
var area := "graves"
var owned: Dictionary = {}
var verdicts: Dictionary = {}
var outlooks: Dictionary = {}
var q := ""
var sel := ""
var trail: Array = []
var all_sources := false

var _a: Dictionary = {}
var _dd: Dictionary = {}       # by_disc[disc]
var _items: Dictionary = {}
var _src_cache: Dictionary = {}
var _who: RichTextLabel
var _search: LineEdit
var _tabs_row: HFlowContainer
var _sub: VBoxContainer
var _list: VBoxContainer
var _detail: VBoxContainer
var _list_scroll: ScrollContainer
var _detail_scroll: ScrollContainer
var _built := false


func _init() -> void:
	super._init()
	title = "Gear Atlas"
	panel_width = 1120
	top_gap = 20
	pad_y = 16
	max_height_margin = 190
	_a = DmPaData.atlas()
	_items = _a.get("items", {})


## owned map {item_id: {n, worn}} from bag slots [{item_id, quantity, equipped}].
static func owned_from_slots(slots: Array) -> Dictionary:
	var out: Dictionary = {}
	for s in slots:
		var o: Dictionary = out.get(String(s["item_id"]), {"n": 0, "worn": false})
		o["n"] = int(o["n"]) + int(s.get("quantity", 1))
		o["worn"] = bool(o["worn"]) or bool(s.get("equipped", false))
		out[String(s["item_id"])] = o
	return out


func set_context(ctx: Dictionary) -> void:
	disc = String(ctx.get("disc", "gravecaller"))
	level = int(ctx.get("level", 1))
	area = String(ctx.get("area", "graves"))
	owned = ctx.get("owned", {})
	verdicts = ctx.get("verdicts", {})
	outlooks = ctx.get("outlooks", {})
	_dd = _a.get("by_disc", {}).get(disc, {})
	_src_cache.clear()
	if String(memory["set"]) == "":
		var own := DmLegendarySets.set_for(disc)
		if own == "":
			for s in _a["sets"]:
				if String(s["disciplineId"]) == disc and int(s["collection"]) == 1:
					own = String(s["id"])
					break
		if own == "":
			own = String(_a["sets"][0]["id"])
		memory["set"] = own
	var pids: Array = _places().map(func(p: Dictionary) -> String: return String(p["id"]))
	if String(memory["where"]) == "" or not pids.has(String(memory["where"])):
		var ar: Dictionary = DmContent.area(area)
		memory["where"] = area if (ar.get("loot", []) as Array).size() > 0 else "graves"
	if _built:
		_refresh_who()
		render()


func open_atlas() -> void:
	if not _built:
		_build_atlas()
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 800)
	panel_width = int(minf(1120.0, vp.x - 48.0))
	sel = ""
	trail = []
	_refresh_who()
	render()
	open()
	if String(memory["sel"]) != "":
		select_item(String(memory["sel"]), false)


func close() -> void:
	if visible:
		memory["sel"] = sel
	super.close()


func _places() -> Array:
	return _dd.get("places", [])


func _src(id: String) -> Array:
	if not _src_cache.has(id):
		_src_cache[id] = DmPaData.sources_for(id, disc)
	return _src_cache[id]


func _made_by(id: String) -> Array:
	return _a.get("made_by", {}).get(id, [])


func _used_in(id: String) -> Array:
	return _a.get("used_in", {}).get(id, [])


# --- scaffold -------------------------------------------------------------------------------------------------------
func _build_atlas() -> void:
	_built = true
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 800)
	var col_h := maxf(260.0, minf(760.0, vp.y - 190.0) - 230.0)
	var top := DmPa.hbox(14)
	_who = DmPa.rich("", 14, DmUi.TEXT_MUTED)
	_who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_who)
	_search = LineEdit.new()
	_search.placeholder_text = "Search items"
	_search.custom_minimum_size = Vector2(240, 36)
	_search.clear_button_enabled = true
	_search.text_changed.connect(_on_search)
	top.add_child(_search)
	body.add_child(top)
	_tabs_row = DmPa.flow(6, 6)
	body.add_child(_tabs_row)
	_sub = DmPa.vbox(4)
	body.add_child(_sub)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(cols)
	_list_scroll = ScrollContainer.new()
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.size_flags_stretch_ratio = 1.05
	_list_scroll.custom_minimum_size = Vector2(300, col_h)
	cols.add_child(_list_scroll)
	_list = DmPa.vbox(5)
	_list_scroll.add_child(_list)
	var det_card := PanelContainer.new()
	det_card.add_theme_stylebox_override("panel", DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 0, Vector2(14, 12)))
	det_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(det_card)
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.custom_minimum_size = Vector2(280, col_h - 24)
	det_card.add_child(_detail_scroll)
	_detail = DmPa.vbox(6)
	_detail_scroll.add_child(_detail)


func _refresh_who() -> void:
	var order: Array = _dd.get("priority", [])
	var txt := " > ".join(PackedStringArray(order.map(func(k: String) -> String: return k.replace("stat_", "").to_upper())))
	_who.text = DmUi.markup("For your <b>%s</b> · prefers <b>%s</b>" % [_dd.get("name", disc), txt])


func _on_search(t: String) -> void:
	q = t.strip_edges().to_lower()
	render_list()


func set_view(v: String) -> void:
	memory["view"] = v
	sel = ""
	trail = []
	q = ""
	if _search != null:
		_search.set_text("")
	render()


var _render_sig := 0
var _rendered := false


func render() -> void:
	# open_atlas() and set_context() both ask for a redraw of the same state: the second (and a reopen with nothing changed) is free.
	var sig := [disc, level, area, owned, verdicts, outlooks, memory, q, sel, trail, all_sources].hash()
	if _rendered and sig == _render_sig:
		return
	_render_sig = sig
	_rendered = true
	_render_tabs()
	render_list()
	if sel == "":
		render_detail()


func _render_tabs() -> void:
	DmPa.clear(_tabs_row)
	for v in VIEWS:
		var b := DmTabButton.new()
		b.setup(String(v[1]))
		b.set_pressed_no_signal(String(memory["view"]) == v[0] and q == "")
		b.set_meta("act", "view")
		b.set_meta("arg", v[0])
		b.pressed.connect(set_view.bind(String(v[0])))
		_tabs_row.add_child(b)


# --- row model --------------------------------------------------------------------------------------------------------
func _is_brew_like(id: String) -> bool:
	return DmContent.brews().has(id) or id.begins_with("flask_") or id.begins_with("elixir_") or id.begins_with("tonic_") or id.begins_with("meal_")


func _is_reagent_like(id: String) -> bool:
	for p in ["reagent_", "herb_", "seed_", "sapling_", "ichor_"]:
		if id.begins_with(p):
			return true
	return String(_items.get(id, {}).get("type", "")) == "rune"


func mats_kind_of(id: String) -> String:
	if id.begins_with("charm_"):
		return "cosmetics"
	if _is_brew_like(id):
		return "brews"
	if _is_reagent_like(id):
		return "reagents"
	return "materials"


static func _slot_of(it: Dictionary) -> String:
	var s: Variant = it.get("slot")
	return str(s) if s != null else ""


func gear_for_slot(slot: String) -> Array:
	var out: Array = []
	for id in _a["item_order"]:
		var it: Dictionary = _items[id]
		if bool(it["gear"]) and _slot_of(it) == slot:
			out.append(it)
	return out


func _verdict(id: String) -> Variant:
	if bool(owned.get(id, {}).get("worn", false)):
		return null
	return verdicts.get(id)


func _outlook(id: String) -> Variant:
	if bool(owned.get(id, {}).get("worn", false)):
		return null
	return outlooks.get(id)


## What a piece is ranked by (AtlasPanel.rank): what it adds now; with "Build towards sets" (and in the legendary chase) its whole set if that is more. null = no verdict.
func rank(id: String, always: bool = false) -> Variant:
	var v: Variant = _verdict(id)
	var o: Variant = _outlook(id)
	var now: Variant = null
	if v != null:
		now = maxf(float(v["pct"]), 0.0) if bool(v.get("empty", false)) else float(v["pct"])
	if o != null and (bool(memory["build"]) or always):
		return maxf(float(now) if now != null else -999.0, float(o["withSetPct"]))
	return now


func _score(it: Dictionary) -> float:
	var id := String(it["id"])
	if bool(owned.get(id, {}).get("worn", false)):
		return 1000.0
	var v: Variant = _verdict(id)
	if v == null:
		return -999.0
	var r: Variant = rank(id)
	return float(r) if r != null else float(v["pct"])


static func _name_less(a: String, b: String) -> bool:
	return a.to_lower() < b.to_lower()


func _sort_gear(items: Array) -> Array:
	return DmStableSort.sorted(items, func(a: Dictionary, b: Dictionary) -> bool:
		var sa := _score(a)
		var sb := _score(b)
		if sa != sb:
			return sa > sb
		if int(a["level"]) != int(b["level"]):
			return int(a["level"]) < int(b["level"])
		return _name_less(String(a["name"]), String(b["name"])))


## The rows of the current view: [{head}] or [{id, place?}].
func rows() -> Array:
	if q != "":
		var hits: Array = []
		var qid := q.replace(" ", "_")
		for id in _a["item_order"]:
			var it: Dictionary = _items[id]
			if String(it["name"]).to_lower().contains(q) or String(id).contains(qid):
				hits.append(it)
		hits = DmStableSort.sorted(hits, func(a: Dictionary, b: Dictionary) -> bool:
			if bool(a["gear"]) != bool(b["gear"]):
				return bool(a["gear"])
			return _name_less(String(a["name"]), String(b["name"])))
		return hits.slice(0, LIST_MAX).map(func(i: Dictionary) -> Dictionary: return {"id": i["id"]})
	var view := String(memory["view"])
	if view == "slot":
		return _sort_gear(gear_for_slot(String(memory["slot"]))).map(func(i: Dictionary) -> Dictionary: return {"id": i["id"]})
	if view == "where":
		var place: Dictionary = {}
		for p in _places():
			if String(p["id"]) == String(memory["where"]):
				place = p
		if place.is_empty():
			return []
		var out: Array = []
		var groups := [
			["Gear", func(i: Dictionary) -> bool: return bool(i["gear"])],
			["Runes", func(i: Dictionary) -> bool: return String(i["type"]) == "rune"],
			["Reagents and ichor", func(i: Dictionary) -> bool: return String(i["type"]) != "rune" and not bool(i["gear"]) and _is_reagent_like(String(i["id"]))],
			["Materials and supplies", func(i: Dictionary) -> bool: return not bool(i["gear"]) and String(i["type"]) != "rune" and not _is_reagent_like(String(i["id"]))],
		]
		for g in groups:
			var ids: Array = (place["items"] as Array).filter(func(id: String) -> bool: return _items.has(id) and (g[1] as Callable).call(_items[id]))
			if ids.is_empty():
				continue
			out.append({"head": "%s (%d)%s" % [g[0], ids.size(), " · every necromancer rite already has a socket in the Grimoire (L)" if g[0] == "Runes" else ""]})
			for id in ids:
				out.append({"id": id, "place": place["id"]})
		return out
	if view == "set":
		for s in _a["sets"]:
			if String(s["id"]) == String(memory["set"]):
				return (s["pieces"] as Array).map(func(id: String) -> Dictionary: return {"id": id})
		return []
	if view == "mats":
		var list: Array = []
		for id in _a["item_order"]:
			var it: Dictionary = _items[id]
			if not bool(it["gear"]) and mats_kind_of(String(id)) == String(memory["mats"]) and (not (_src(String(id)) as Array).is_empty() or not _made_by(String(id)).is_empty()):
				list.append(it)
		list = DmStableSort.sorted(list, func(a: Dictionary, b: Dictionary) -> bool:
			var ra := DmUi.RARITY_ORDER.find(String(a["rarity"]))
			var rb := DmUi.RARITY_ORDER.find(String(b["rarity"]))
			if ra != rb:
				return ra < rb
			return _name_less(String(a["name"]), String(b["name"])))
		return list.map(func(i: Dictionary) -> Dictionary: return {"id": i["id"]})
	return _best_rows()


func _best_rows() -> Array:
	var out: Array = []
	var own_set := DmLegendarySets.set_for(disc)
	var chase: Array = []
	for slot in SLOT_ORDER:
		for i in gear_for_slot(slot):
			if String(i["rarity"]) != "legendary" or owned.has(String(i["id"])) or (own_set != "" and String(i.get("set_id", "")) != own_set):
				continue
			var pct: Variant = rank(String(i["id"]), true)
			if pct != null and float(pct) >= 1.0:
				chase.append({"id": i["id"], "pct": float(pct)})
		var cand: Array = []
		for i in gear_for_slot(slot):
			var id := String(i["id"])
			if String(i["rarity"]) == "legendary" or owned.has(id):
				continue
			if bool(memory["reach"]) and int(i["level"]) > level + 10:
				continue
			var v: Variant = _verdict(id)
			var r: Variant = rank(id)
			var pct := float(r) if r != null else -999.0
			if v == null:
				continue
			var good: bool = (String(v["kind"]) == "upgrade" and (float(v["pct"]) > 0.0 or bool(v.get("empty", false)))) or (bool(memory["build"]) and pct >= 1.0)
			if good:
				cand.append({"i": i, "pct": pct})
		cand = DmStableSort.sorted(cand, func(a: Dictionary, b: Dictionary) -> bool:
			if a["pct"] != b["pct"]:
				return a["pct"] > b["pct"]
			return int(a["i"]["level"]) < int(b["i"]["level"]))
		if cand.is_empty():
			continue
		out.append({"head": SLOT_SHORT[slot]})
		for p in cand.slice(0, 3):
			out.append({"id": p["i"]["id"]})
	if not chase.is_empty():
		out.append({"head": "The legendary chase (rare boss drops)"})
		chase = DmStableSort.sorted(chase, func(a: Dictionary, b: Dictionary) -> bool: return a["pct"] > b["pct"])
		for c in chase.slice(0, 5):
			out.append({"id": c["id"]})
	return out


# --- sub bar + list ---------------------------------------------------------------------------------------------------
var _list_cache := DmRowCache.new()   # list rows by "id|place": a row is rebuilt only when what it shows changed (owned, selected, verdict...)
var _nonce := 0


func render_list() -> void:
	_render_sub()
	var rs := rows()
	if rs.is_empty():
		var msg := "Nothing here."
		if q != "":
			msg = "Nothing by that name."
		elif String(memory["view"]) == "best":
			msg = "No upgrade in reach for any slot. Untick the level filter to see further ahead."
		_list_cache.clear(_list)
		var e := DmPa.text(msg, 14, DmUi.TEXT_MUTED)
		e.set_meta("role", "empty")
		_list.add_child(e)
		return
	# One entry per list child: [key, signature, kind, id/text, place]. Headers that read live state get a fresh signature each time.
	var keys: Array = []
	var sigs: Array = []
	var specs: Array = []
	if q == "" and String(memory["view"]) == "set":
		_nonce += 1
		keys.append("#set")
		sigs.append(_nonce)
		specs.append(["set"])
	elif q == "" and String(memory["view"]) == "mats" and String(memory["mats"]) == "cosmetics":
		_nonce += 1
		keys.append("#cos")
		sigs.append(_nonce)
		specs.append(["cos"])
	var first := true
	for r in rs:
		if r.has("head"):
			keys.append("#head:" + String(r["head"]))
			sigs.append(hash([String(r["head"]), first]))
			specs.append(["head", String(r["head"]), first])
		else:
			var id := String(r["id"])
			var place := String(r.get("place", ""))
			keys.append("%s|%s" % [id, place])
			sigs.append(_row_sig(id, place))
			specs.append(["row", id, place])
		first = false
	_list_cache.sync(_list, keys, sigs, func(i: int) -> Dictionary:
		var sp: Array = specs[i]
		match String(sp[0]):
			"set":
				return {"node": _set_header()}
			"cos":
				return {"node": _cosmetics_header()}
			"head":
				var h := DmPa.text(DmUi.upper(String(sp[1])), 14, DmUi.SPELL_300, "display", false)
				h.set_meta("head", true)
				return {"node": DmPa.margin(h, 0, 0 if bool(sp[2]) else 8, 0, 2)}
		return {"node": _row(String(sp[1]), String(sp[2]))})


## Everything _row() draws from.
func _row_sig(id: String, place: String) -> int:
	return [id, place, disc, owned.get(id), sel == id, verdicts.get(id), outlooks.get(id)].hash()


func _render_sub() -> void:
	DmPa.clear(_sub)
	if q != "":
		_sub.add_child(DmPa.text("Searching every item. Clear the box to go back.", 13, DmUi.TEXT_FAINT))
		return
	var view := String(memory["view"])
	var f := DmPa.flow(8, 6)
	_sub.add_child(f)
	if view == "slot":
		for s in SLOT_ORDER:
			var c := DmPa.chip(SLOT_SHORT[s], String(memory["slot"]) == s, "slot", s)
			c.pressed.connect(func() -> void:
				memory["slot"] = s
				render_list())
			f.add_child(c)
		f.add_child(_build_check())
	elif view == "where":
		f.add_child(DmPa.text(DmUi.upper("Where"), 13, DmUi.TEXT_MUTED, "body", false))
		f.add_child(_where_select())
		var qh: Variant = _quality(String(memory["where"]))
		if qh != null:
			_sub.add_child(qh as Control)
	elif view == "set":
		f.add_child(DmPa.text(DmUi.upper("Set"), 13, DmUi.TEXT_MUTED, "body", false))
		f.add_child(_set_select())
	elif view == "mats":
		for k in MATS:
			var c := DmPa.chip(String(k[1]), String(memory["mats"]) == k[0], "mats", k[0])
			c.pressed.connect(func() -> void:
				memory["mats"] = k[0]
				render_list())
			f.add_child(c)
	else:
		var reach := CheckBox.new()
		reach.text = "Only what is in reach of level %d" % level
		reach.button_pressed = bool(memory["reach"])
		reach.focus_mode = Control.FOCUS_NONE
		reach.set_meta("act", "reach")
		reach.toggled.connect(func(on: bool) -> void:
			memory["reach"] = on
			render_list())
		f.add_child(reach)
		f.add_child(_build_check())
		f.add_child(DmPa.text("Top upgrades per slot for your %s that you do not own yet, then the legendary chase." % _dd.get("name", disc), 13, DmUi.TEXT_FAINT, "body", false))


func _build_check() -> CheckBox:
	var b := CheckBox.new()
	b.text = "Build towards sets"
	b.button_pressed = bool(memory["build"])
	b.focus_mode = Control.FOCUS_NONE
	b.set_meta("act", "build")
	b.tooltip_text = "Off: pieces are ranked by what they add now, counting the set bonuses they switch on with what you wear. On: a set piece is ranked by what the whole set would add."
	b.toggled.connect(func(on: bool) -> void:
		memory["build"] = on
		render_list())
	return b


func _where_select() -> OptionButton:
	var ob := OptionButton.new()
	ob.fit_to_longest_item = false
	ob.set_meta("act", "where")
	var groups := [["Hunting grounds", "area"], ["Bosses", "boss"], ["Catacomb Depths", "depths"], ["Gathering", "gather"]]
	var sel_idx := 0
	for g in groups:
		var any := false
		for p in _places():
			if String(p["kind"]) == g[1]:
				if not any:
					ob.add_item("— %s —" % g[0])
					ob.set_item_disabled(ob.item_count - 1, true)
					any = true
				var nm := String(p["name"]).trim_prefix("The ")
				if g[1] == "area" or g[1] == "boss":
					nm += " (Lv %d)" % int(p["level"])
				ob.add_item(nm)
				ob.set_item_metadata(ob.item_count - 1, String(p["id"]))
				if String(p["id"]) == String(memory["where"]):
					sel_idx = ob.item_count - 1
	ob.select(sel_idx)
	ob.item_selected.connect(func(i: int) -> void:
		memory["where"] = String(ob.get_item_metadata(i))
		render_list())
	return ob


func _set_select() -> OptionButton:
	var ob := OptionButton.new()
	ob.set_meta("act", "set")
	var sel_idx := 0
	for g in [[3, "Legendary"], [2, "Ascended"], [1, "First collection"]]:
		var any := false
		for s in _a["sets"]:
			if int(s["collection"]) == g[0]:
				if not any:
					ob.add_item("— %s —" % g[1])
					ob.set_item_disabled(ob.item_count - 1, true)
					any = true
				var dn := String(DmContent.discipline(String(s["disciplineId"])).get("name", s["disciplineId"]))
				ob.add_item("%s (%s)" % [s["name"], dn])
				ob.set_item_metadata(ob.item_count - 1, String(s["id"]))
				if String(s["id"]) == String(memory["set"]):
					sel_idx = ob.item_count - 1
	ob.select(sel_idx)
	ob.item_selected.connect(func(i: int) -> void:
		memory["set"] = String(ob.get_item_metadata(i))
		render_list())
	return ob


## How good this ground's drops are (areaQuality): the rung of the descent, per-100-kill numbers, item levels, rune and legendary odds.
func _quality(place_id: String) -> Variant:
	var qd: Variant = _dd.get("quality", {}).get(place_id)
	if qd == null:
		return null
	var h := DmPa.hbox(10)
	h.set_meta("role", "quality")
	var rungs := HBoxContainer.new()
	rungs.add_theme_constant_override("separation", 2)
	for i in int(qd["rungs"]):
		var r := ColorRect.new()
		r.custom_minimum_size = Vector2(7, 14)
		r.color = GOLD_RUNG if i < int(qd["rung"]) else Color(DmUi.TEXT_FAINT, 0.3)
		rungs.add_child(r)
	rungs.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(rungs)
	h.add_child(DmPa.rich(quality_text(qd), 13, DmUi.TEXT_FAINT))
	return h


func quality_text(qd: Dictionary) -> String:
	var per := func(n: float) -> String: return ("%.0f" % n) if n >= 10.0 else (("%.1f" % n) if n >= 1.0 else ("%.2f" % n))
	var bits: Array = []
	var s := "of every 100 kills about <b>%s</b> leave an item, <b>%s</b> of them gear" % [per.call(float(qd["dropsPer100"])), per.call(float(qd["gearPer100"]))]
	if float(qd["rarePer100"]) >= 0.05:
		s += ", <b>%s</b> rare or better" % per.call(float(qd["rarePer100"]))
	bits.append(s)
	if float(qd["killsPerOwn"]) > 0.0:
		bits.append("a piece of your own armour set about every <b>%d</b> kills" % int(roundf(float(qd["killsPerOwn"]))))
	bits.append("gear drops at item level about <b>%d</b> (bosses <b>%d</b>)" % [int(qd["ilvlKill"]), int(qd["ilvlBoss"])])
	if float(qd["runePerElite"]) > 0.0:
		bits.append("an elite sheds a rune <b>%s</b> of the time" % DmPa.fmt_chance(float(qd["runePerElite"])))
	if float(qd["bossLegendary"]) > 0.0:
		bits.append("its boss leaves a legendary <b>%s</b> of the time" % DmPa.fmt_chance(float(qd["bossLegendary"])))
	if float(qd["eliteLegendary"]) > 0.0:
		bits.append("an elite, <b>%s</b>" % DmPa.fmt_chance(float(qd["eliteLegendary"])))
	return "<b>Drop quality %d of %d</b> (Lv %d): %s." % [int(qd["rung"]), int(qd["rungs"]), int(qd["level"]), "; ".join(PackedStringArray(bits))]


func _set_header() -> Control:
	var set: Dictionary = {}
	for s in _a["sets"]:
		if String(s["id"]) == String(memory["set"]):
			set = s
	var c := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(10, 8))
	if set.is_empty():
		return c
	var worn := 0
	for p in set["pieces"]:
		if bool(owned.get(String(p), {}).get("worn", false)):
			worn += 1
	var b := DmPa.card_body(c)
	b.add_child(DmPa.rich("<b>%s</b> · %d/5 worn" % [set["name"], worn], 14, DmUi.TEXT))
	for bo in set["bonuses"]:
		b.add_child(_bonus_row(bo, worn))
	c.set_meta("role", "set_header")
	return c


func _bonus_row(bo: Dictionary, worn: int) -> Control:
	var on := worn >= int(bo["pieces"])
	var h := DmPa.hbox(8)
	var n := DmPa.text(str(int(bo["pieces"])), 12, DmUi.OK if on else DmUi.TEXT_FAINT, "numeric", false)
	n.custom_minimum_size.x = 14
	n.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(n)
	var body := "; ".join(PackedStringArray(bo["lines"]))
	if bo.has("name") and String(bo["name"]) != "":
		body = "<b>%s</b>: %s" % [bo["name"], body]
	var t := DmPa.rich(body, 13, DmUi.OK if on else DmUi.TEXT_FAINT)
	h.add_child(t)
	h.set_meta("on", on)
	return h


func _cosmetics_header() -> Control:
	var c := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(10, 8))
	var b := DmPa.card_body(c)
	var cos: Dictionary = _a["cosmetics"]
	b.add_child(DmPa.rich("<b>Capes & pets</b>", 14, DmUi.TEXT))
	for n in cos["notes"]:
		b.add_child(DmPa.text(String(n), 12, DmUi.TEXT_FAINT))
	b.add_child(DmPa.text(DmUi.upper("Capes"), 14, DmUi.SPELL_300, "display", false))
	for x in cos["capes"]:
		var h := DmPa.hbox(8)
		h.add_child(DmPa.text("❀", 12, DmUi.OK, "numeric", false))
		h.add_child(DmPa.rich("<b>%s</b>: %s" % [x["name"], x["requirement"]], 13, DmUi.TEXT_MUTED))
		b.add_child(h)
	b.add_child(DmPa.text(DmUi.upper("Pet charms (click one for where it turns up)"), 14, DmUi.SPELL_300, "display", false))
	return c


# --- a list row -----------------------------------------------------------------------------------------------------------
static func _strip_the(s: String) -> String:
	return s.trim_prefix("The ")


static func short_place(s: Dictionary) -> String:
	return _strip_the(String(s["place"])).replace("Catacomb Depths, ", "Depths ").replace(" (Sexton’s Acre)", "")


static func short_event(e: String) -> String:
	var rules := [["^Ordinary kill$", "kill"], ["^Elite kill$", "elite"], ["^Boss kill \\(repeat\\)$", "boss repeat"], ["^Boss kill$", "boss"], ["^First kill", "first kill"], ["^Grave Surge", "surge"], ["^Chest", "chest"], ["^Floor cleared", "stair"]]
	for r in rules:
		var re := RegEx.new()
		re.compile(r[0])
		if re.search(e) != null:
			return re.sub(e, r[1])
	var sal := RegEx.new()
	sal.compile("^Salvage (.*)$")
	var m := sal.search(e)
	if m != null:
		return "salvage " + m.get_string(1)
	var tail := RegEx.new()
	tail.compile(" \\(.*\\)$")
	return tail.sub(e, "").to_lower()


func skill_name(profession: String) -> String:
	var sk: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")
	return String(sk.get(profession, {}).get("name", profession))


func stat_text(stats: Dictionary) -> String:
	var parts: Array = []
	for k in stats:
		var v := float(stats[k])
		if v != 0.0:
			parts.append("%s%s %s" % ["+" if v > 0 else "", DmPa.strip_zeros(v, 2), String(k).replace("stat_", "").to_upper()])
	return " ".join(PackedStringArray(parts))


func type_name(it: Dictionary) -> String:
	if String(it["type"]) == "rune":
		return "Relic rune"
	if _is_brew_like(String(it["id"])):
		return "Brew"
	if _is_reagent_like(String(it["id"])):
		return "Reagent"
	return "Material"


## The short "where" text of a row and the hover text listing the best sources (AtlasPanel.srcLine).
func src_line(id: String, place: String = "") -> Dictionary:
	var all: Array = _src(id)
	var here: Array = all.filter(func(s: Dictionary) -> bool: return place != "" and String(s["placeId"]) == place)
	var drops: Array = all.filter(func(s: Dictionary) -> bool: return String(s["kind"]) != "salvage" and String(s["kind"]) != "garden")
	var non_depths: Array = drops.filter(func(s: Dictionary) -> bool: return String(s["kind"]) != "depths")
	var pool: Array = here if not here.is_empty() else (non_depths if not non_depths.is_empty() else drops)
	var tl: Array = []
	for s in all.filter(func(s: Dictionary) -> bool: return String(s["kind"]) != "salvage").slice(0, 6):
		var oi := DmPa.one_in(float(s["chance"]))
		tl.append("%s: %s %s%s" % [short_place(s), String(s["event"]).to_lower(), DmPa.fmt_chance(float(s["chance"])), (" (%s)" % oi) if oi != "" else ""])
	for r in _made_by(id).slice(0, 2):
		tl.append("Craft: %s %d at the %s" % [skill_name(String(r["profession"])), int(r["level"]), r["station"]])
	var title_t := "\n".join(PackedStringArray(tl)) if not tl.is_empty() else "No drop: see the detail."
	if pool.is_empty():
		var r: Variant = _made_by(id)[0] if not _made_by(id).is_empty() else null
		var sal: Variant = null
		for s in all:
			if String(s["kind"]) == "salvage":
				sal = s
				break
		var t := "No source"
		if r != null:
			t = "Craft: %s %d" % [skill_name(String(r["profession"])), int(r["level"])]
		elif sal != null:
			t = String(sal["place"]).replace(" (", "\u0001").split("\u0001")[0]
		return {"text": t, "title": title_t}
	var top: Dictionary = pool[0]
	var more := (here.size() if not here.is_empty() else drops.size()) - 1
	return {"text": "%s · %s %s%s" % [short_place(top), short_event(String(top["event"])), DmPa.fmt_chance(float(top["chance"])), (" · +%d more" % more) if more > 0 else ""], "title": title_t}


func _icon(id: String, px: int) -> Control:
	var it: Dictionary = _items.get(id, {})
	var ic := DmPa.icon(String(it.get("icon", "art/items/%s.webp" % id)), px, id, String(TYPE_GLYPH.get(String(it.get("type", "material")), "◆")))
	var col := DmUi.rarity_color(String(it.get("rarity", "common")))
	ic.border = Color(col, 0.5)
	return ic


func _fit_label(band: String, tip: String = "") -> Label:
	var l := DmPa.text(DmUi.upper(FIT_LABEL[band]), 12, FIT_COLOR[band], "display_bold", false)
	l.tooltip_text = tip
	l.set_meta("fit", band)
	return l


func fit_title(id: String, band: String) -> String:
	var mine := float(_items[id]["fit"].get(disc, 0))
	return "%s fit for your %s: it would add about %s%s%% power to an empty slot, compared with the other pieces of its slot and rarity." % [FIT_LABEL[band], _dd.get("name", disc), "+" if mine >= 0 else "", DmPa.strip_zeros(mine, 1)]


## The arrow badge(s) of a verdict (AtlasPanel.arrow): [{text, kind, tip}].
func arrow_badges(v: Dictionary, o: Variant) -> Array:
	var set_up: bool = o != null and float(o["withSetPct"]) >= 1.0
	var kind := String(v["kind"])
	var empty := bool(v.get("empty", false))
	if o != null and set_up and kind != "upgrade":
		var t := "%s. As part of %s (%d pieces): +%d%% power. %s." % [v["text"], o["setName"], int(o["total"]), int(DmMath.js_round(float(o["withSetPct"]))), o["hint"]]
		return [{"text": ("▼ alone" if kind == "downgrade" else "≈ alone"), "kind": "down" if kind == "downgrade" else "same", "tip": t}, {"text": "▲ +%d%% with set" % int(DmMath.js_round(float(o["withSetPct"]))), "kind": "up", "tip": t}]
	if o != null and set_up and kind == "upgrade" and float(o["withSetPct"]) > float(v["pct"]) + 1.0:
		var t := "%s. As part of %s (%d pieces): +%d%% power. %s." % [v["text"], o["setName"], int(o["total"]), int(DmMath.js_round(float(o["withSetPct"]))), o["hint"]]
		var first := "new" if (empty and float(v["pct"]) < 1.0) else "+%d%%" % int(DmMath.js_round(float(v["pct"])))
		return [{"text": "▲ " + first, "kind": "up", "tip": t}, {"text": "+%d%% with set" % int(DmMath.js_round(float(o["withSetPct"]))), "kind": "up", "tip": t}]
	if kind == "upgrade":
		return [{"text": "▲ " + ("new" if (empty and float(v["pct"]) < 1.0) else "+%d%%" % int(DmMath.js_round(float(v["pct"])))), "kind": "up", "tip": String(v["text"])}]
	if kind == "downgrade":
		return [{"text": "▼ %d%%" % int(DmMath.js_round(float(v["pct"]))), "kind": "down", "tip": String(v["text"])}]
	return [{"text": "≈", "kind": "same", "tip": String(v["text"])}]


func _arrow_label(b: Dictionary) -> Label:
	var col: Color = {"up": DmUi.OK, "down": DmUi.DOWN_SOFT, "same": DmUi.TEXT_MUTED}[String(b["kind"])]
	var l := DmPa.text(String(b["text"]), 13, col, "numeric", false)
	l.tooltip_text = String(b["tip"])
	l.set_meta("arrow", String(b["kind"]))
	return l


func _row(id: String, place: String) -> Control:
	var it: Dictionary = _items[id]
	var rarity := String(it["rarity"])
	var col := DmUi.rarity_color(rarity)
	var own: Variant = owned.get(id)
	var worn: bool = own != null and bool(own["worn"])
	var src := src_line(id, place)
	var gear := bool(it["gear"])
	var band: String = String(_dd.get("band", {}).get(id, "")) if gear else ""
	var v: Variant = _verdict(id) if gear else null
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bg := DmUi.INSET.lerp(DmUi.OK, 0.05) if own != null else DmUi.INSET
	var sb := DmUi.box(bg, Color(col, 0.35), 1, 0, Vector2(8, 6))
	sb.border_width_left = 3
	sb.border_color = col
	card.add_theme_stylebox_override("panel", sb)
	if sel == id:
		sb.border_width_top = 2
		sb.border_width_bottom = 2
		sb.border_width_right = 2
		sb.border_color = DmUi.SPELL_300
	card.tooltip_text = String(src["title"])
	card.set_meta("act", "row")
	card.set_meta("arg", id)
	card.set_meta("selected", sel == id)
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			select_item(id))
	var h := DmPa.hbox(10)
	card.add_child(h)
	h.add_child(_icon(id, 40))
	var main := DmPa.vbox(1)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rec: bool = gear and (_dd.get("recommended", []) as Array).has(id)
	var nm := DmPa.text(String(it["name"]) + ("  ★" if rec else ""), 15, col, "body_bold", false)
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	main.add_child(nm)
	var meta_parts: Array = [SLOT_SHORT[_slot_of(it)] if _slot_of(it) != "" else type_name(it), "%s %s" % [rarity.capitalize(), DmUi.rarity_mark(rarity)]]
	if gear:
		meta_parts.append("Lv ~%d" % int(it["level"]))
	var meta := " · ".join(PackedStringArray(meta_parts))
	var st := stat_text(it["stats"]) if gear else ""
	var ml := DmPa.rich_bb("%s%s" % [meta.replace("[", "[lb]"), (" · [b]%s[/b]" % st) if st != "" else ""], 12, DmUi.TEXT_MUTED)
	ml.fit_content = true
	ml.autowrap_mode = TextServer.AUTOWRAP_OFF
	main.add_child(ml)
	var craft := " · craftable" if not _made_by(id).is_empty() else ""
	var sl := DmPa.text(String(src["text"]) + craft, 12, DmUi.BONE_300, "numeric_medium", false)
	sl.clip_text = true
	sl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	main.add_child(sl)
	h.add_child(main)
	var badges := VBoxContainer.new()
	badges.add_theme_constant_override("separation", 3)
	badges.custom_minimum_size.x = 64
	if worn:
		var t := DmPa.text("WORN", 11, DmUi.SPELL_300, "display_bold", false)
		t.set_meta("tag", "worn")
		badges.add_child(t)
	elif own != null and gear:
		var t := DmPa.text("OWNED", 11, DmUi.TEXT_MUTED, "display_bold", false)
		t.set_meta("tag", "owned")
		badges.add_child(t)
	if band != "":
		badges.add_child(_fit_label(band, fit_title(id, band)))
	if v != null:
		for b in arrow_badges(v, _outlook(id)):
			badges.add_child(_arrow_label(b))
	for c in badges.get_children():
		(c as Control).size_flags_horizontal = Control.SIZE_SHRINK_END
	h.add_child(badges)
	return card


# --- detail ------------------------------------------------------------------------------------------------------------------
func select_item(id: String, push: bool = true) -> void:
	if not _items.has(id):
		return
	if push and sel != "" and sel != id:
		trail.append(sel)
	sel = id
	render_list()
	render_detail()
	if _detail_scroll != null:
		_detail_scroll.scroll_vertical = 0


func back() -> void:
	if not trail.is_empty():
		select_item(String(trail.pop_back()), false)
	else:
		sel = ""
		render_list()
		render_detail()


func _h4(t: String) -> Control:
	return DmPa.text(DmUi.upper(t), 13, DmUi.SPELL_300, "display", false)


func _section(title_t: String) -> VBoxContainer:
	var v := DmPa.vbox(4)
	v.add_child(DmUi.hrule())
	v.add_child(DmPa.margin(_h4(title_t), 0, 6, 0, 0))
	_detail.add_child(DmPa.margin(v, 0, 8, 0, 0))
	return v


func _go_button(id: String, label: String, kind: String = "") -> Button:
	var b := DmPa.button(label, "small", false, "go", id)
	b.text = label
	b.pressed.connect(func() -> void:
		all_sources = false
		select_item(id))
	return b


func render_detail() -> void:
	if _detail == null:
		return
	DmPa.clear(_detail)
	if sel == "":
		_detail.add_child(DmPa.text(DmUi.upper("How to read this"), 18, DmUi.BONE_100, "display_bold", false))
		_detail.add_child(DmPa.rich_bb("[color=#a9c28a]Ideal[/color] [color=#8fc7b0]Good[/color] [color=#d8b25a]Okay[/color] [color=#d97a6b]Poor[/color] says how well a piece suits your discipline against the other pieces of its slot and rarity, by the same gear score the Character sheet uses. The number under it is the base piece; an [b]ideal affix roll[/b] adds a good deal more (see \"For you\" on any piece).", 13, DmUi.TEXT_MUTED))
		_detail.add_child(DmPa.rich("Under <b>By area &amp; boss</b>, each hunting ground shows a <b>drop quality</b> rung: the deeper you go, the likelier the pieces worth wearing, runes and legendaries, and the higher their item level. Chances shown are for your own discipline (your set drops more often than the others).", 13, DmUi.TEXT_MUTED))
		_detail.add_child(DmPa.rich_bb("[color=#a9c28a]▲ +12%[/color] [color=#d97a6b]▼ 5%[/color] compares it with what you wear in that slot (percent of your power), counting any set bonus the piece switches on with what you wear. A piece of an armour or legendary set shows a second figure, [color=#a9c28a]▲ +40% with set[/color]: what its whole set would add, bonuses included. [color=#d97a6b]▼ alone[/color] [color=#a9c28a]▲ with set[/color] means one piece by itself is worse than what you wear but the set is better. Lists rank by what a piece adds now; tick [b]Build towards sets[/b] to rank set pieces by their whole set (the legendary chase always does). The Ideal / Good / Okay / Poor label includes each piece's share of its set bonuses.", 13, DmUi.TEXT_MUTED))
		_detail.add_child(DmPa.text("Percentages are per kill, at default settings (Medium, Wave Speed 0, no fortune tonic). Hover a row, or click it, for every source. Click a name in a recipe to follow it.", 13, DmUi.TEXT_MUTED))
		return
	var id := sel
	var it: Dictionary = _items[id]
	var rarity := String(it["rarity"])
	var col := DmUi.rarity_color(rarity)
	var own: Variant = owned.get(id)
	var all: Array = _src(id)
	var back_b := DmPa.button("‹ " + ("Back" if not trail.is_empty() else "List"), "small", false, "back")
	back_b.text = "‹ " + ("Back" if not trail.is_empty() else "List")
	back_b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back_b.pressed.connect(back)
	_detail.add_child(back_b)
	# head
	var head := DmPa.hbox(12)
	head.add_child(_icon(id, 56))
	var hv := DmPa.vbox(2)
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hv.add_child(DmPa.text(DmUi.upper(String(it["name"])), 21, col, "display_bold", true))
	var parts: Array = [SLOT_SHORT[_slot_of(it)] if _slot_of(it) != "" else type_name(it), "%s %s" % [rarity, DmUi.rarity_mark(rarity)]]
	if bool(it["gear"]):
		parts.append("Lv ~%d" % int(it["level"]))
	parts.append("sells %dg" % int(it["sell"]))
	var mt := " · ".join(PackedStringArray(parts))
	if own != null:
		mt += " · [b]%s[/b]" % ("worn" if bool(own["worn"]) else "you have %d" % int(own["n"]))
	hv.add_child(DmPa.rich_bb(mt.replace("<", "").replace("[lb]", "[lb]"), 12, DmUi.TEXT_MUTED))
	if bool(it["gear"]):
		hv.add_child(DmPa.text(stat_text(it["stats"]), 14, DmUi.BONE_100, "numeric", false))
	head.add_child(hv)
	_detail.add_child(head)
	if String(it.get("lore", "")) != "":
		_detail.add_child(DmPa.text(String(it["lore"]), 13, DmUi.TEXT_MUTED, "body_italic"))
	if String(it.get("weapon_kind", "")) != "":
		_detail.add_child(DmPa.text(String(it.get("weapon_effect", "")), 13, DmUi.BONE_300))
	if bool(it["gear"]):
		_detail_for_you(id, it, all)
	_detail_drops(id, it, all)
	if String(it["type"]) == "rune":
		var r := DmContent.rune(id)
		var sec := _section("Using it")
		var rname := String(DmContent.ability(String(r.get("rite", ""))).get("name", ""))
		sec.add_child(DmPa.rich("Open the Grimoire (<kbd>L</kbd>), pick <b>%s</b> and socket it. Every necromancer rite already has its socket from the start: runes are what you hunt for, from elites, Grave Surges, bosses and Catacomb Depths chests. %s." % [rname, r.get("short", "")], 13, DmUi.TEXT))
	var made := _made_by(id)
	if not made.is_empty():
		var sec := _section("How to make it")
		for r in made:
			sec.add_child(_recipe(r))
	var used := _used_in(id)
	if not used.is_empty():
		var sec := _section("Used in")
		var fl := DmPa.flow(6, 6)
		for r in used.slice(0, 14):
			fl.add_child(_go_button(String(r["result"]), String(DmContent.item(String(r["result"])).get("name", r["result"]))))
		if used.size() > 14:
			fl.add_child(DmPa.text("+%d more" % (used.size() - 14), 12, DmUi.TEXT_FAINT, "body", false))
		sec.add_child(fl)
	var order: Variant = it.get("order") if not bool(it["gear"]) else null
	if order != null and (order.get("relicQty") != null or id.begins_with("ingot_")):
		var sec := _section("Sexton’s orders")
		var what: String
		var prem: int = int(DmContent.get_export("gameplay_contractRules", "RELIC_PREMIUM"))
		if order.get("relicQty") != null:
			what = "A relic order asks for %d (about one hard order in five, from %s %d) and pays %dx the sell price." % [int(order["relicQty"]), skill_name(String(order["skill"])), int(order["level"]), prem]
		else:
			what = "Ordered like any smelted good, from %s %d." % [skill_name(String(order["skill"])), int(order["level"])]
		sec.add_child(DmPa.text(what, 13, DmUi.TEXT))
	if it.get("salvage") != null:
		var p: Dictionary = it["salvage"]
		var sec := _section("If you salvage it")
		var mats: Array = (p["materials"] as Array).map(func(x: String) -> String: return String(DmContent.item(x).get("name", x)))
		var reag: Array = (p["reagents"] as Array).map(func(r: Dictionary) -> String: return "%s %s" % [DmContent.item(String(r["id"])).get("name", r["id"]), DmPa.fmt_chance(float(r["chance"]))])
		var s := ""
		if not mats.is_empty():
			s += "%s x%s; " % [" or ".join(PackedStringArray(mats)), DmPa.fmt_qty(int(p["materialQty"][0]), int(p["materialQty"][1]))]
		s += "%s. %d Salvaging XP." % [", ".join(PackedStringArray(reag)), int(p["xp"])]
		sec.add_child(DmPa.text(s, 13, DmUi.TEXT))
	if bool(it["gear"]):
		_detail_upgrade(id, it, all)
	if String(it.get("set_id", "")) != "":
		_detail_set(id, it)


func _detail_for_you(id: String, it: Dictionary, all: Array) -> void:
	var sec := _section("For you")
	var band: String = String(_dd.get("band", {}).get(id, ""))
	var v: Variant = _verdict(id)
	var so: Variant = _outlook(id)
	var own: Variant = owned.get(id)
	if band != "":
		var h := DmPa.hbox(8)
		h.add_child(_fit_label(band))
		h.add_child(DmPa.text(fit_title(id, band), 13, DmUi.TEXT))
		sec.add_child(h)
	if v != null:
		var h := DmPa.hbox(8)
		for b in arrow_badges(v, so):
			h.add_child(_arrow_label(b))
		h.add_child(DmPa.text(String(v["text"]), 13, DmUi.TEXT))
		sec.add_child(h)
	elif own != null and bool(own["worn"]):
		sec.add_child(DmPa.text("You are wearing this.", 13, DmUi.TEXT))
	if so != null:
		sec.add_child(DmPa.rich("<b>%s:</b> %s. Worn alone this piece switches on no bonus until the set reaches 2 pieces; the whole %d-piece set would add about <b>+%d%%</b> to your power over what you wear now, of which <b>+%d%%</b> is its set bonuses (counted here like the Character sheet counts them)." % [so["setName"], so["hint"], int(so["total"]), int(DmMath.js_round(float(so["withSetPct"]))), int(DmMath.js_round(float(so["bonusPct"])))], 13, DmUi.TEXT))
	var pot: Variant = _dd.get("roll", {}).get(id)
	if pot != null:
		var picks: Array = pot["picks"]
		sec.add_child(DmPa.rich("The roll matters more than the label: this piece alone adds about <b>+%s%%</b>; with two <b>ideal</b> affix rolls at item level %d (%s) it adds about <b>+%s%%</b>. Affixes roll between the low and high end of their range (%s here)." % [DmPa.strip_zeros(float(pot["plain"]), 1), int(pot["ilvl"]), ", ".join(PackedStringArray(picks.map(func(p: Dictionary) -> String: return String(p["text"])))), DmPa.strip_zeros(float(pot["ideal"]), 1), " and ".join(PackedStringArray(picks.map(func(p: Dictionary) -> String: return String(p["range"]))))], 13, DmUi.TEXT))
	sec.add_child(_fit_bars(id))


func _fit_bars(id: String) -> Control:
	var wrap := DmPa.vbox(3)
	var fit: Dictionary = _items[id]["fit"]
	var mx := 1.0
	for k in fit:
		mx = maxf(mx, float(fit[k]))
	var holder := DmPa.vbox(2)
	holder.visible = false
	for d in DmContent.disciplines():
		var row := DmPa.hbox(8)
		var nm := DmPa.text(String(DmContent.discipline(String(d))["name"]), 12, DmUi.BONE_100 if String(d) == disc else DmUi.TEXT_MUTED, "body_bold" if String(d) == disc else "body", false)
		nm.custom_minimum_size.x = 110
		row.add_child(nm)
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.min_value = 0
		bar.max_value = 100
		bar.value = maxf(0.0, roundf(float(fit.get(d, 0)) / mx * 100.0))
		bar.custom_minimum_size = Vector2(0, 8)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bar)
		var f := float(fit.get(d, 0))
		var vl := DmPa.text("%s%s%%" % ["+" if f >= 0 else "", DmPa.strip_zeros(f, 1)], 12, DmUi.BONE_100, "numeric", false)
		vl.custom_minimum_size.x = 56
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(vl)
		holder.add_child(row)
	var tog := DmPa.button("▸ Fit by discipline (power added to an empty slot)", "small", false, "fitbars")
	tog.text = "▸ Fit by discipline (power added to an empty slot)"
	tog.alignment = HORIZONTAL_ALIGNMENT_LEFT
	tog.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tog.pressed.connect(func() -> void: holder.visible = not holder.visible)
	wrap.add_child(tog)
	wrap.add_child(holder)
	return wrap


func _detail_drops(id: String, it: Dictionary, all: Array) -> void:
	var drops: Array = all.filter(func(s: Dictionary) -> bool: return String(s["kind"]) != "salvage")
	if not drops.is_empty():
		var sec := _section("Where it drops")
		var shown: Array = drops if all_sources else drops.slice(0, SOURCES_SHORT)
		var rws: Array = []
		for s in shown:
			var oi := DmPa.one_in(float(s["chance"]))
			var ev := short_event(String(s["event"])) + ((" (%s)" % s["note"]) if s.has("note") else "")
			rws.append([short_place(s), ev, DmPa.fmt_chance(float(s["chance"])) + ((" " + oi) if oi != "" else ""), DmPa.fmt_qty(int(s["qty"][0]), int(s["qty"][1]))])
		var t := DmPa.table(["Where", "When", "Chance", "Qty"], rws, [1.4, 1.2, 1.1, 0.5], [2, 3])
		t.set_meta("role", "drops")
		sec.add_child(t)
		if drops.size() > SOURCES_SHORT:
			var mb := DmPa.button("Show fewer" if all_sources else "Show all %d sources" % drops.size(), "small", false, "more")
			mb.text = "Show fewer" if all_sources else "Show all %d sources" % drops.size()
			mb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			mb.pressed.connect(func() -> void:
				all_sources = not all_sources
				render_detail())
			sec.add_child(mb)
		if String(it["rarity"]) == "legendary" and String(it.get("set_id", "")) != "":
			sec.add_child(DmPa.text("Smart loot: your own discipline's set is %s." % ("the most likely to drop" if DmLegendarySets.set_for(disc) != "" else "not made yet, so all four sets share the drops evenly"), 12, DmUi.TEXT_FAINT))
	elif _made_by(id).is_empty():
		var sec := _section("Where it drops")
		sec.add_child(DmPa.text("Not a drop. See salvage or crafting below.", 12, DmUi.TEXT_FAINT))


func _recipe(r: Dictionary) -> Control:
	var v := DmPa.vbox(3)
	var extra := " · makes %d" % int(r["qty"]) if int(r["qty"]) > 1 else ""
	v.add_child(DmPa.rich("<b>%s</b> [color=#%s]%s %d · %s%s[/color]" % [r["name"], DmUi.TEXT_FAINT.to_html(false), skill_name(String(r["profession"])), int(r["level"]), r["station"], extra], 13, DmUi.TEXT))
	v.get_child(0).text = DmUi.markup("<b>%s</b>" % r["name"]) + " [color=#%s]%s %d · %s%s[/color]" % [DmUi.TEXT_FAINT.to_html(false), skill_name(String(r["profession"])), int(r["level"]), String(r["station"]).replace("[", "[lb]"), extra]
	for ing in r["ings"]:
		var ii := String(ing["item"])
		var srcs: Array = _src(ii).filter(func(x: Dictionary) -> bool: return String(x["kind"]) != "salvage" and String(x["kind"]) != "depths").slice(0, 2)
		var from_parts: Array = srcs.map(func(x: Dictionary) -> String: return "%s %s" % [short_place(x), DmPa.fmt_chance(float(x["chance"]))])
		var via: Array = _made_by(ii)
		if not via.is_empty():
			from_parts.append("made: %s %d" % [skill_name(String(via[0]["profession"])), int(via[0]["level"])])
		var from := " · ".join(PackedStringArray(from_parts)) if not from_parts.is_empty() else "see its page"
		var h := DmPa.hbox(6)
		h.add_child(_go_button(ii, "%d x %s" % [int(ing["qty"]), DmContent.item(ii).get("name", ii)]))
		h.add_child(DmPa.text("from " + from, 12, DmUi.TEXT_FAINT, "body", true))
		v.add_child(h)
	return v


func _detail_upgrade(id: String, it: Dictionary, all: Array) -> void:
	var sec := _section("Upgrading it")
	var drops: Array = all.filter(func(s: Dictionary) -> bool: return String(s["kind"]) != "salvage")
	var line := ""
	for s in drops:
		if s.has("area") and s.has("ilvlSource"):
			var lv := int(DmContent.area(String(s["area"])).get("level", 1))
			line = "Dropped from %s it is item level about <b>%d</b> (%s). Higher level means bigger affix numbers. " % [short_place(s), DmAffixRules.item_level_for(lv, String(s["ilvlSource"])), String(DmContent.get_export("gameplay_atlas", "SOURCE_LABEL")[s["ilvlSource"]]).to_lower()]
			break
	sec.add_child(DmPa.rich("%sEach drop rolls up to three affixes; bosses always give one or more and a first kill two or more. Odds of 0 / 1 / 2 / 3 affixes for a %s base:" % [line, it["rarity"]], 13, DmUi.TEXT))
	var odds: Dictionary = it.get("affix_odds", {})
	var rws: Array = []
	for pair in [["elite", "Kill or elite"], ["boss", "Boss kill"], ["first_kill", "First kill"]]:
		var row: Array = [pair[1]]
		for x in odds.get(pair[0], []):
			row.append(DmPa.fmt_chance(float(x)))
		rws.append(row)
	sec.add_child(DmPa.table(["Dropped as", "0", "1", "2", "3"], rws, [1.6, 1, 1, 1, 1], [1, 2, 3, 4]))
	sec.add_child(DmPa.text("Wear two, four or five pieces of a set for its bonuses. There is no upgrade bench: replace a piece when a better roll or set drops.", 12, DmUi.TEXT_FAINT))


func _detail_set(id: String, it: Dictionary) -> void:
	var set: Dictionary = {}
	for s in _a["sets"]:
		if String(s["id"]) == String(it["set_id"]):
			set = s
	if set.is_empty():
		return
	var worn := 0
	for p in set["pieces"]:
		if bool(owned.get(String(p), {}).get("worn", false)):
			worn += 1
	var sec := _section("%s set (%d/5 worn)" % [set["name"], worn])
	var fl := DmPa.flow(6, 6)
	for p in set["pieces"]:
		var b := _go_button(String(p), "%s%s" % [_items[p]["name"], " ✓" if owned.has(String(p)) else ""])
		b.disabled = String(p) == id
		fl.add_child(b)
	sec.add_child(fl)
	for bo in set["bonuses"]:
		sec.add_child(_bonus_row(bo, worn))

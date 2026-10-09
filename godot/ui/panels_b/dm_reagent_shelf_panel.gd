class_name DmReagentShelfPanel
extends DmPanelB
## The Reagent Shelf (archive/legacy-web:src/ui/ReagentShelfPanel.ts + content/wing.ts): every alchemy ingredient as a collection. Found ones show their icon,
## name and how many you hold; the rest are dim silhouettes ("???"). "Found" = ever carried one.
##
## Data in:  set_held({item_id: count})  the bag's item counts.   set_found(Array)  the ids recorded earlier (the web keeps them browser-local per
##           character; the integrator persists them, e.g. user://). The panel unions held shelf ids into `found`.
## Signals:  found_changed(ids: Array) -> persist the new found list (no network call exists for it in the web either).
## Shelf contents come from data/content/wing.json (SHELF_GROUPS), exported from the real TS.

signal found_changed(ids: Array)

var held: Dictionary = {}
var found: Dictionary = {}     # id -> true
## What is drawn: {found_count, total, groups: [{title, blurb, items: [{id, name, found, count, label, count_text}]}]}.
var shown: Dictionary = {}
static var _wing: Dictionary = {}


static func wing() -> Dictionary:
	if _wing.is_empty():
		_wing = DmGatherData.normalize(DmDb.content("wing"))
	return _wing


func _init() -> void:
	super._init()
	title = "Reagent Shelf"
	panel_width = 760


func set_found(ids: Array) -> void:
	found.clear()
	for id in ids:
		if wing()["SHELF_IDS"].has(id):
			found[id] = true
	rebuild()


func set_held(h: Dictionary) -> void:
	held = h
	var grew := false
	for id: String in wing()["SHELF_IDS"]:
		if int(held.get(id, 0)) > 0 and not found.has(id):
			found[id] = true
			grew = true
	if grew:
		found_changed.emit(found.keys())
	rebuild()


func _build() -> void:
	var ids: Array = wing()["SHELF_IDS"]
	var have := 0
	for id in ids:
		if found.has(id):
			have += 1
	shown = {"found_count": have, "total": ids.size(), "groups": []}
	add_child(DmPb.rich("Found <b>%d/%d</b> reagents. Brew them at the Great Cauldron or the Alembic." % [have, ids.size()], 13, DmUi.TEXT_FAINT))
	for g: Dictionary in wing()["SHELF_GROUPS"]:
		add_child(DmPb.section_title(String(g["title"])))
		add_child(DmPb.hint(String(g["blurb"])))
		var grid := GridContainer.new()   # repeat(auto-fill, minmax(104px, 1fr)) at the panel's 716 px body = 6 columns
		grid.columns = 6
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(grid)
		var gi := {"title": g["title"], "blurb": g["blurb"], "items": []}
		for id: String in g["ids"]:
			var ok := found.has(id)
			var n := int(held.get(id, 0))
			var rarity := DmPb.item_rarity(id)
			var nm := DmPb.item_name(id) if ok else "???"
			var ct := "×%d" % n if ok else ""
			var c := DmPb.card(grid, DmUi.rarity_color(rarity) if ok else DmUi.BORDER, Color(0, 0, 0, 0), Vector2(4, 6))
			var panel := c.get_meta("panel") as Control
			panel.custom_minimum_size = Vector2(104, 0)
			panel.modulate.a = 1.0 if ok else 0.5
			panel.tooltip_text = "%s: you hold %d" % [nm, n] if ok else "Not found yet"
			c.alignment = BoxContainer.ALIGNMENT_CENTER
			var ic := DmPb.icon(rarity, 40.0, null, not ok, id)
			ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			c.add_child(ic)
			var l := DmPb.text(nm, 13, DmUi.TEXT, "body", true)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			c.add_child(l)
			var cl := DmPb.text(ct, 12, DmUi.TEXT_FAINT, "numeric")
			cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cl.custom_minimum_size.y = 14
			c.add_child(cl)
			gi["items"].append({"id": id, "name": DmPb.item_name(id), "found": ok, "count": n, "label": nm, "count_text": ct})
		shown["groups"].append(gi)

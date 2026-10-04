class_name DmGardenPanel
extends DmPanelB
## Grave Gardening (src/ui/GardenPanel.ts + gardenView.ts): four Mourning Beds and two Coffin Patches that grow on the server's clock.
##
## Data in:  set_view(view)  view = GET /api/garden reply {now (server epoch ms), level, xp, xpToNext, plots:[{plot, kind: herb|tree, label,
##           seedId|null, plantedAt, readyAt, composted, state}]}.   set_bag(slots) = the bag rows ({item_id, quantity, equipped}) that
##           supply seeds and bone meal.   set_busy(bool).   Plot state is derived from readyAt each draw (the snapshot's own `state` goes stale).
## Signals:  plant_requested(plot, seed_id, compost) -> DmApi.plant_garden(character_id, plot, seed_id, compost)  (inventory-exclusive, then
##                                                      DmApi.get_inventory); `compost` is already gated by use_compost() (ticked AND meal in bag)
##           harvest_requested(plot)                  -> DmApi.harvest_garden(character_id, plot)  (same guard); feed the reply to set_view().

signal plant_requested(plot: String, seed_id: String, compost: bool)
signal harvest_requested(plot: String)

var view: Dictionary = {}
var bag: Array = []
var busy := false
var now_override_ms := -1
var skew_ms := 0
var choice: Dictionary = {}          # plot id -> {seed, compost}
## What is drawn, per plot: {plot, label, state, pct, text, plant_enabled, harvest_enabled}.
var plots_info: Array[Dictionary] = []
var plant_buttons: Dictionary = {}
var harvest_buttons: Dictionary = {}
var seed_pickers: Dictionary = {}
var compost_checks: Dictionary = {}
var _tick: Timer


func _init() -> void:
	super._init()
	title = "Grave Gardening"
	panel_width = 680


func _ready() -> void:
	_tick = Timer.new()
	_tick.wait_time = 1.0
	_tick.timeout.connect(func() -> void:
		if is_visible_in_tree() and not DmPb.pointer_busy(self):
			rebuild())
	add_child(_tick)
	_tick.start()
	rebuild()


func set_view(v: Dictionary) -> void:
	view = v
	skew_ms = int(v.get("now", 0)) - int(Time.get_unix_time_from_system() * 1000.0)
	_refresh_head()
	rebuild()


func set_bag(slots: Array) -> void:
	bag = slots
	rebuild()


func set_busy(v: bool) -> void:
	busy = v
	rebuild()


func _now() -> int:
	return now_override_ms if now_override_ms >= 0 else int(Time.get_unix_time_from_system() * 1000.0) + skew_ms


func _refresh_head() -> void:
	head_note = "" if view.is_empty() else "Grave Gardening <b>%d</b> · %s / %s xp" % [int(view["level"]), DmPb.num(view["xp"]), DmPb.num(view["xpToNext"])]


## gardenView.plotStateAt: derived from readyAt on the server clock.
static func plot_state_at(p: Dictionary, now: int) -> String:
	var seed_id: Variant = p.get("seedId")
	if seed_id == null or String(seed_id) == "":
		return "empty"
	return DmGarden.state_of({"seedId": seed_id, "readyAt": p["readyAt"]}, now)


## gardenView.useCompost: used only when ticked AND still in the bag.
static func use_compost(ticked: bool, meal: int) -> bool:
	return ticked and meal > 0


func count_of(item_id: String) -> int:
	var n := 0
	for s: Dictionary in bag:
		if s.get("item_id") == item_id:
			n += int(s.get("quantity", 0))
	return n


## Seeds in the bag that suit this plot kind at the player's level: [{id, name, qty, level, ok}] by level (stable).
func seeds_for(kind: String, level: int) -> Array:
	var out: Array = []
	for s: Dictionary in bag:
		var d := DmGarden.seed_def(String(s.get("item_id", "")))
		if d.is_empty() or d["kind"] != kind or int(s.get("equipped", 0)) != 0:
			continue
		var found := false
		for o: Dictionary in out:
			if o["id"] == d["id"]:
				o["qty"] += int(s["quantity"])
				found = true
		if not found:
			out.append({"id": d["id"], "name": DmPb.item_name(d["id"]), "qty": int(s["quantity"]), "level": int(d["level"]), "ok": level >= int(d["level"])})
	return DmStableSort.sorted(out, func(a: Dictionary, b: Dictionary) -> bool: return a["level"] < b["level"])


func _build() -> void:
	plots_info.clear()
	plant_buttons.clear()
	harvest_buttons.clear()
	seed_pickers.clear()
	compost_checks.clear()
	_head_note_row()
	add_child(DmPb.hint("Plant a seed and come back: it keeps growing while you are away. Bone meal from the Bone Kiln grows a plot a quarter faster.", 12))
	if view.is_empty():
		add_child(DmPb.hint(error_text if error_text != "" else "Tending the beds…"))
		return
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(grid)
	var now := _now()
	var meal := count_of(DmGarden.compost_item())
	for p: Dictionary in view.get("plots", []):
		_plot_card(grid, p, now, meal)
	if error_text != "":
		_error_row()


func _plot_card(grid: GridContainer, p: Dictionary, now: int, meal: int) -> void:
	var state := plot_state_at(p, now)
	var plot_id := String(p["plot"])
	var border := DmUi.OK if state == "ready" else DmUi.BORDER
	var seed := DmGarden.seed_def(String(p["seedId"])) if state != "empty" else {}
	var crop_rarity := DmPb.item_rarity(String(seed["harvest"])) if not seed.is_empty() else "common"
	var card := DmPb.card(grid, border, Color(0, 0, 0, 0), Vector2(10, 8))
	(card.get_meta("panel") as Control).custom_minimum_size = Vector2(0, 86)
	(card.get_meta("panel") as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hd := DmPb.hbox(8)
	hd.add_child(DmPb.grow(DmPb.text(String(p["label"]), 13, DmUi.BONE_100, "body_bold")))
	hd.add_child(DmPb.text(DmUi.upper("Tree patch" if p["kind"] == "tree" else "Herb bed"), 10, DmUi.TEXT_FAINT))
	card.add_child(hd)
	var info := {"plot": plot_id, "label": p["label"], "state": state, "pct": 0, "text": "", "plant_enabled": false, "harvest_enabled": false}
	if state == "empty":
		var seeds := seeds_for(String(p["kind"]), int(view["level"]))
		var first_ok := ""
		for s: Dictionary in seeds:
			if s["ok"]:
				first_ok = s["id"]
				break
		var default_seed: String = first_ok if first_ok != "" else (String(seeds[0]["id"]) if seeds.size() > 0 else "")
		var pick: Dictionary = choice.get(plot_id, {"seed": default_seed, "compost": false})
		var have := false
		for s: Dictionary in seeds:
			if s["id"] == pick["seed"]:
				have = true
		if not have:
			pick["seed"] = default_seed
		choice[plot_id] = pick
		if seeds.is_empty():
			info["text"] = "No saplings. Coffin-Oaks and Churchyard Yews sometimes drop them." if p["kind"] == "tree" else "No seeds. Dig graves in the Sexton’s Acre for Mourning Moss seeds."
			card.add_child(DmPb.hint(info["text"], 12, DmUi.TEXT_MUTED))
		else:
			var chosen: Dictionary = {}
			for s: Dictionary in seeds:
				if s["id"] == pick["seed"]:
					chosen = s
			var row := HFlowContainer.new()   # .cw-plot .row wraps: the picker keeps its width, Plant drops under it when narrow
			row.add_theme_constant_override("h_separation", 8)
			row.add_theme_constant_override("v_separation", 6)
			var ob := OptionButton.new()
			ob.custom_minimum_size.x = 150
			ob.fit_to_longest_item = false
			ob.clip_text = true
			var sel := 0
			for i in seeds.size():
				var s: Dictionary = seeds[i]
				ob.add_item("%s ×%d%s" % [s["name"], s["qty"], "" if s["ok"] else " (Lv %d)" % s["level"]])
				ob.set_item_metadata(i, s["id"])
				if s["id"] == pick["seed"]:
					sel = i
			ob.select(sel)
			ob.item_selected.connect(func(i: int) -> void:
				pick["seed"] = String(ob.get_item_metadata(i))
				rebuild.call_deferred())
			row.add_child(ob)
			seed_pickers[plot_id] = ob
			if meal > 0:
				var cb := CheckBox.new()
				cb.text = "Bone meal (%d)" % meal
				cb.button_pressed = pick["compost"]
				cb.focus_mode = Control.FOCUS_NONE
				cb.add_theme_font_size_override("font_size", 12)
				cb.toggled.connect(func(on: bool) -> void:
					pick["compost"] = on
					rebuild.call_deferred())
				row.add_child(cb)
				compost_checks[plot_id] = cb
			var plant := DmPb.button("Plant", false, busy or chosen.is_empty() or not chosen["ok"])
			plant.pressed.connect(func() -> void:
				plant_requested.emit(plot_id, String(pick["seed"]), use_compost(pick["compost"], count_of(DmGarden.compost_item()))))
			row.add_child(plant)
			plant_buttons[plot_id] = plant
			card.add_child(row)
			info["plant_enabled"] = not plant.disabled
			if not chosen.is_empty() and not chosen["ok"]:
				info["text"] = "Requires Grave Gardening %d." % chosen["level"]
			elif not chosen.is_empty():
				var growing := float(DmGarden.seed_def(chosen["id"])["growMin"]) * 60000.0 * (0.75 if use_compost(pick["compost"], meal) else 1.0)
				info["text"] = "Grows in %s." % DmGarden.remaining_text(growing)
			card.add_child(DmPb.hint(info["text"], 12, DmUi.TEXT_MUTED))
	else:
		var total := maxi(1, int(p["readyAt"]) - int(p["plantedAt"]))
		var left := maxi(0, int(p["readyAt"]) - now)
		var pct := 100 if state == "ready" else mini(100, DmMath.js_round(float(total - left) / float(total) * 100.0))
		var crop := DmPb.item_name(String(seed["harvest"]))
		var row := DmPb.hbox(8)
		row.add_child(DmPb.icon(crop_rarity, 34.0))
		var grow_box := DmPb.vbox(3)
		grow_box.custom_minimum_size.x = 90
		var bar := DmPbBar.new(5.0)
		bar.fill = DmUi.rarity_color(crop_rarity)
		bar.pct = float(pct)
		grow_box.add_child(bar)
		var status := "Ready to harvest" if state == "ready" else "%s left" % DmGarden.remaining_text(left)
		var rw := DmPb.hbox(0)
		rw.add_child(DmPb.text("%s · " % crop, 12))
		rw.add_child(DmPb.text(status, 12, DmUi.OK if state == "ready" else DmUi.TEXT_MUTED, "body_bold" if state == "ready" else "body"))
		if p.get("composted", false):
			rw.add_child(DmPb.text(" · bone meal", 12, DmUi.TEXT_MUTED, "body_italic"))
		grow_box.add_child(rw)
		row.add_child(grow_box)
		var hv := DmPb.button("Harvest", false, state != "ready" or busy)
		hv.pressed.connect(func() -> void: harvest_requested.emit(plot_id))
		row.add_child(hv)
		harvest_buttons[plot_id] = hv
		card.add_child(row)
		info["pct"] = pct
		info["text"] = "%s · %s%s" % [crop, status, " · bone meal" if p.get("composted", false) else ""]
		info["harvest_enabled"] = not hv.disabled
	plots_info.append(info)

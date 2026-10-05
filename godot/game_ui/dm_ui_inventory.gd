class_name DmUiInventory
extends RefCounted
## The Reliquary wiring of src/ui/InventoryPanel.ts + toolBelt.ts: DmReliquaryPanel fed from game.slots, every signal mapped to the DmApi call
## the web makes, then game.refresh_inventory(). Gear numbers: DmGearStats (ctx), DmItemText (cards), DmItemLocks (junk / locks).

const BAG_SIZE := 48
const TYPE_GLYPH := {"weapon": "⚔", "armor_head": "⛨", "armor_chest": "⛊", "armor_legs": "‖", "armor_feet": "◭", "armor_hands": "✋", "offhand": "◐", "ring": "◎", "trinket": "✦", "material": "◆"}
const BELT_LABEL := {"hatchet": "Hatchet", "pickaxe": "Pickaxe", "rod": "Rod", "spade": "Spade"}

var ui: Node
var game: Node
var panel: DmReliquaryPanel
var locks: DmItemLocks
var busy := false
var _confirm_belt_offer: Control = null
var store: DmCounselStore


func _init(ui_: Node, locks_: DmItemLocks, store_: DmCounselStore) -> void:
	ui = ui_
	game = ui_.game
	locks = locks_
	store = store_
	panel = DmReliquaryPanel.new()
	panel.has_sell = true
	panel.has_legion = ui_.is_necromancer()
	panel.drag_brews = true
	panel.extra_actions = Callable(self, "_extra_actions")
	panel.equip_toggled.connect(func(it: Dictionary) -> void: primary_action(it))
	panel.lock_toggled.connect(func(it: Dictionary) -> void:
		locks.toggle(it["row"])
		render())
	panel.sell_requested.connect(func(it: Dictionary, q: int) -> void: sell(it, q))
	panel.sort_requested.connect(sort_bag)
	panel.junk_sell_confirmed.connect(sell_junk)
	panel.legion_pressed.connect(func() -> void: ui.toggle_panel("legion"))
	panel.sheet_pressed.connect(func() -> void: ui.toggle_panel("sheet"))
	panel.salvage_requested.connect(func(it: Dictionary) -> void: salvage_one(it["row"]))
	panel.action_requested.connect(_on_action)
	panel.slot_right_clicked.connect(_on_right_click)
	panel.opened.connect(render)
	locks.changed.connect(render)


func slots() -> Array:
	return game.slots


func count(item_id: String) -> int:
	var n := 0
	for s in slots():
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < BAG_SIZE and s["item_id"] == item_id:
			n += int(s["quantity"])
	return n


static func icon_path(item_id: String) -> String:
	return DmUiArt.item_path(item_id)


static func icon_of_row(row: Dictionary) -> String:
	return icon_path(String(row.get("item_id", "")))


# --- rendering -----------------------------------------------------------------------------------------------------

func _brew_line(item_id: String) -> String:
	var s := DmUiBrews.summary(item_id)
	if s == "":
		return ""
	var b := DmContent.brew(item_id)
	return "%s\nBelt key %s: right-click or drag it onto the Belt at the left edge." % [s, "Z" if b["slot"] == "elixir" else "X"]


func _rune_text(row: Dictionary) -> String:
	var r := DmContent.rune(String(row["item_id"]))
	if r.is_empty():
		return ""
	var rite_name := String(DmAbilities.def(String(r["rite"]))["name"])
	var out := "Fits %s. %s" % [rite_name, " ".join(r["lines"])]
	if r.get("cost") != null:
		out += "\nCost: %s" % r["cost"]
	var now: String = String(game_sockets().get(r["rite"], ""))
	var sock := "Socket it in the Grimoire or with the button below."
	if now != "":
		sock = "Already socketed in this rite." if now == row["item_id"] else "Replaces %s, which returns to your bag." % DmContent.rune(now)["name"]
	var src: String = String(DmPaData.rune_sources().get(row["item_id"], ""))
	return out + "\n%s Drops from %s." % [sock, src]


func game_sockets() -> Dictionary:
	return DmRunes.sockets_of(slots())


func card_of(row: Dictionary, ctx: Variant) -> Dictionary:
	var meta := DmContent.item(String(row["item_id"]))
	var ic := icon_of_row(row)
	var base := {
		"id": int(row.get("id", row["slot_index"])), "slot_index": int(row["slot_index"]), "item_id": row["item_id"], "name": row.get("name", meta.get("name", "")),
		"rarity": row.get("rarity", "common"), "quantity": int(row.get("quantity", 1)), "equipped": int(row.get("equipped", 0)) != 0,
		"locked": locks.is_locked(row), "glyph": TYPE_GLYPH.get(String(row.get("item_type", "")), "◆"), "sell_value": int(row.get("sell_value", 0)),
		"lore": String(meta.get("lore", "")), "row": row, "is_brew": DmContent.brews().has(row["item_id"]),
		"equippable": DmGear.equip_slot_of(row) != "",
	}
	if ic != "":
		base["icon"] = load(ic)
	var card := DmItemText.card(ctx, slots(), row, base)
	if card.has("compare"):
		# gearText.headline: "Instead of A and B:" / "If you equip it (nothing worn there):"
		var cmp: Variant = DmGearStats.compare_equip(ctx, row)
		if cmp != null:
			card["compare_head"] = DmItemText.compare_headline(cmp["replaced"])
	var bl := _brew_line(String(row["item_id"]))
	if bl != "":
		card["brew_line"] = bl
	if String(row.get("item_type", "")) == "rune":
		card["set_line"] = _rune_text(row)
	else:
		var w := DmUiBrews.necro_weapon_tooltip(String(row["item_id"]))
		if not w.is_empty():
			card["set_line"] = "%s\nRecommended level %d. Only necromancers gain the effect; other classes keep the stats." % [w["effect"], int(w["level"])]
		elif card.get("set_line", "") != "":
			card["set_line"] = String(card["set_line"]) + "\nAny class can wear it."
	return card


var _render_sig := 0
var _rendered := false
var _cards: Dictionary = {}     # row hash -> card (item text, verdicts, compare chips: ~2 ms a row), valid while _cards_key holds
var _cards_key := 0


## Cards are the cost of a render (every bag row's verdict and comparison text), and opening the bag used to draw twice (the open, then its `opened`
## signal): redraw only when the slots, the stat sources, the locks or the grinder proximity changed, and re-text only the rows that changed.
func render() -> void:
	var ctx: Variant = ui.stat_ctx()
	var all := slots()
	var key: int = DmStatKey.of(ctx) if ctx != null else 0
	var lock_bits: Array = []
	for row in all:
		lock_bits.append(locks.is_locked(row))
	var sig := [key, all.hash(), lock_bits, ui.near_grinder(), ui.build()["stats"]].hash()
	if _rendered and sig == _render_sig:
		return
	_render_sig = sig
	_rendered = true
	if key != _cards_key:
		_cards.clear()
		_cards_key = key
	_render_now(ctx, all)


func _card_cached(row: Dictionary, ctx: Variant) -> Dictionary:
	var h := row.hash()
	var c: Variant = _cards.get(h)
	if c == null:
		c = card_of(row, ctx)
		_cards[h] = c
	(c as Dictionary)["locked"] = locks.is_locked(row)
	return c


func _render_now(ctx: Variant, all: Array) -> void:
	var bag: Array = []
	bag.resize(BAG_SIZE)
	for i in BAG_SIZE:
		bag[i] = {}
	var belt := {}
	for row in all:
		var si := int(row["slot_index"])
		if si >= 0 and si < BAG_SIZE and int(row.get("equipped", 0)) == 0:
			bag[si] = _card_cached(row, ctx)
	var worn := {}
	var wr := DmGear.equipped_by_slot(all)
	for k in wr:
		worn[k] = _card_cached(wr[k], ctx)
	for row in all:
		var kind := DmGathering.belt_slot_kind(int(row["slot_index"]))
		if kind != "" and int(row.get("quantity", 0)) > 0:
			belt[kind] = _card_cached(row, ctx)
	panel.at_grinder = ui.near_grinder()
	var junk := DmItemLocks.junk_slots(all, locks, DmItemText.keeps_for_you(ctx))
	panel.junk_count = junk.size()
	var g := 0
	for s in junk:
		g += int(s["sell_value"]) * int(s["quantity"])
	panel.junk_gold = g
	panel.legion_flag = ui.is_necromancer() and DmLegionText.kit_candidates(all).any(func(c: Dictionary) -> bool: return c["verdict"] == "up")
	panel.set_stats_line(stats_chips())
	panel.set_summary = set_summary()
	_belt_offer()
	panel.set_inventory(bag, worn, belt)


func stats_chips() -> Array:
	var cs := DmStats.compute_stats(game.character, slots())
	var chips: Array = []
	for k in DmStats.STAT_KEYS:
		chips.append({"label": DmGearStats.STAT_LABELS[k], "value": int(cs["total"][k]), "plus": int(cs["bonus"][k])})
	var b: Dictionary = ui.build()
	chips.append({"label": "Health", "value": int(b["stats"]["maxHp"])})
	chips.append({"label": "Spell", "value": DmMath.js_round(float(b["stats"]["spellPower"]))})
	return chips


func set_summary() -> Array:
	var r := DmSetText.resolve(slots())
	var out: Array = []
	var family := String(ui.build()["discipline"]["family"])
	var parts: Array = ["head", "chest", "hands", "legs", "feet"]
	for s in (r["sets"] as Array).slice(0, 2):
		var acc := Color.WHITE
		var meta: Variant = DmSetBonuses._index
		var on: Array = []
		var nxt := "Set complete"
		var next_b: Variant = null
		for b in s["bonuses"]:
			if b["active"]:
				on.append("%d  %s%s%s" % [int(b["pieces"]), ("%s: " % b["name"]) if DmCombatData.truthy(b.get("name")) else "", " · ".join(b["lines"]),
					"" if DmSetBonuses.effect_relevant(b["effect"], family) else " (no effect for your class)"])
			elif next_b == null:
				next_b = b
		if next_b != null:
			var need := int(next_b["pieces"]) - int(s["worn"])
			var miss: Array = (s["missing"] as Array).map(func(m: Dictionary) -> String: return String(m["part"]))
			nxt = "%d  %s%s\nNeed %d more: %s" % [int(next_b["pieces"]), ("%s: " % next_b["name"]) if DmCombatData.truthy(next_b.get("name")) else "", " · ".join(next_b["lines"]), need, ", ".join(miss) if need == miss.size() else " or ".join(miss)]
		out.append({"name": s["setName"], "accent": acc if s.get("accent") == null else Color.from_rgba8((int(s["accent"]) >> 16) & 255, (int(s["accent"]) >> 8) & 255, int(s["accent"]) & 255),
			"pips": parts.map(func(p: String) -> bool: return (s["wornParts"] as Array).has(p)), "on": on, "next": nxt})
	return out


# --- tool belt offer -----------------------------------------------------------------------------------------------

func offer_key() -> String:
	return "dm_belt_offer_%d" % int(game.character["id"])


func belt_tools() -> Dictionary:
	var out := {}
	for row in slots():
		var kind := DmGathering.belt_slot_kind(int(row["slot_index"]))
		if kind != "" and int(row.get("quantity", 0)) > 0:
			out[kind] = row
	return out


func belt_offer() -> Array:
	if not belt_tools().is_empty():
		return []
	var bag_tools: Array = []
	for s in slots():
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < BAG_SIZE and DmGathering.tool_kind_of(String(s["item_id"])) != "":
			bag_tools.append(s)
	var best := DmGathering.best_tool_per_kind(bag_tools.map(func(s: Dictionary) -> String: return String(s["item_id"])))
	var out: Array = []
	for k in DmGathering.BELT_KINDS:
		if best.has(k):
			for t in bag_tools:
				if t["item_id"] == best[k]:
					out.append(t)
					break
	return out


func _belt_offer() -> void:
	panel.footer_extra = null
	if store.get_item(offer_key()) == "1":
		return
	var picks := belt_offer()
	if picks.is_empty():
		return
	var h := HBoxContainer.new()
	h.add_child(DmUi.label("Belt your best tools? ", "DmMuted"))
	var yes := Button.new()
	yes.theme_type_variation = "DmButtonSmall"
	yes.text = DmUi.upper("Put %s on the belt" % ("it" if picks.size() == 1 else str(picks.size())))
	yes.name = "BeltYes"
	yes.pressed.connect(func() -> void:
		store.set_item(offer_key(), "1")
		move_to_belt(picks.map(func(p: Dictionary) -> Dictionary: return {"slot_index": int(p["slot_index"]), "equipped": 1})))
	h.add_child(yes)
	var no := Button.new()
	no.theme_type_variation = "DmButtonSmall"
	no.text = DmUi.upper("No thanks")
	no.name = "BeltNo"
	no.pressed.connect(func() -> void:
		store.set_item(offer_key(), "1")
		render())
	h.add_child(no)
	panel.footer_extra = h


# --- actions -------------------------------------------------------------------------------------------------------

func _extra_actions(it: Dictionary) -> Array:
	var row: Dictionary = it["row"]
	var id := String(row["item_id"])
	var out: Array = []
	var legion: Dictionary = DmLegionText.kit_candidate(slots(), row) if ui.is_necromancer() else {}
	if not legion.is_empty():
		out.append({"id": "legion", "label": "Give to legion", "hint": "Move it to the legion's %s slot; a piece already there returns to your bag" % String(legion["kit"]).capitalize()})
	if DmGathering.tool_kind_of(id) != "":
		out.append({"id": "toolbelt", "label": "Take off belt" if DmGathering.is_belt_slot(int(row["slot_index"])) else "Put on belt"})
	if DmContent.healing_flasks().has(id) or DmContent.buff_flasks().has(id):
		out.append({"id": "use", "label": "Drink"})
	var brew := DmContent.brew(id)
	if not brew.is_empty():
		var key := "Z" if brew["slot"] == "elixir" else "X"
		out.append({"id": "belt", "label": "Put on belt (key %s)" % key, "primary": true, "hint": "Puts it in the %s slot of the Belt at the left edge" % ("Elixir" if key == "Z" else "Tonic")})
	if DmGathering_meals().has(id):
		out.append({"id": "use", "label": "Eat"})
	var pet := pet_for_charm(id)
	if not pet.is_empty():
		out.append({"id": "adopt", "label": "Adopt %s" % pet["name"], "hint": "The %s joins you for good and the charm is spent. Call it from Capes & Pets (N)" % pet["name"]})
	if String(row.get("item_type", "")) == "rune" and ui.is_necromancer() and DmContent.rune(id) != {}:
		var rite := String(DmAbilities.def(String(DmContent.rune(id)["rite"]))["name"])
		out.append({"id": "rune", "label": "Socket into %s" % rite})
	return out


static func DmGathering_meals() -> Dictionary:
	return DmContent.file("processing").get("MEALS", {})


static func pet_for_charm(item_id: String) -> Dictionary:
	for p in DmContent.file("cosmetics").get("PETS", []):
		if p["charm"] == item_id:
			return p
	return {}


func _on_action(id: String, it: Dictionary) -> void:
	var row: Dictionary = it["row"]
	match id:
		"legion":
			give_to_legion(row)
		"toolbelt":
			toggle_tool_belt(row)
		"use":
			use_item(String(row["item_id"]))
		"belt":
			ui.set_belt(String(row["item_id"]))
		"adopt":
			adopt_charm(String(pet_for_charm(String(row["item_id"]))["id"]))
		"rune":
			socket_rune(row)


func _on_right_click(it: Dictionary) -> void:
	var row: Dictionary = it["row"]
	if DmGathering.tool_kind_of(String(row["item_id"])) != "":
		toggle_tool_belt(row)
	elif DmContent.brews().has(row["item_id"]):
		ui.set_belt(String(row["item_id"]))


func primary_action(it: Dictionary) -> void:
	var row: Dictionary = it["row"]
	var id := String(row["item_id"])
	if DmContent.healing_flasks().has(id) or DmContent.buff_flasks().has(id) or DmGathering_meals().has(id):
		use_item(id)
	elif DmGathering.tool_kind_of(id) != "":
		toggle_tool_belt(row)
	elif DmGear.equip_slot_of(row) != "":
		toggle_equip(row)


func use_item(item_id: String) -> void:
	if game.has_method("use_item"):
		await game.use_item(item_id)
	render()


func _begin() -> bool:
	if busy:
		return false
	busy = true
	panel.set_error("")
	return true


func _end() -> void:
	busy = false
	render()


func _fail(r: DmResult, fallback: String) -> bool:
	if r.ok:
		return false
	panel.set_error(r.error if r.error != "" else fallback)
	return true


func toggle_equip(row: Dictionary) -> void:
	if not _begin():
		return
	var was := int(row.get("equipped", 0)) != 0
	var r: DmResult = await game.api.equip_item(int(game.character["id"]), int(row["slot_index"]), 0 if was else 1)
	if not _fail(r, "Equip failed"):
		panel.sel_item = {}
		await game.refresh_inventory()
		if not was:
			ui.on_equipped()
	_end()


func move_to_belt(moves: Array) -> void:
	if not _begin():
		return
	var okay := true
	for m in moves:
		var r: DmResult = await game.api.belt_tool(int(game.character["id"]), int(m["slot_index"]), int(m["equipped"]))
		if _fail(r, "The belt would not take that."):
			okay = false
			break
	if okay:
		panel.sel_item = {}
		await game.refresh_inventory()
		for m in moves:
			if int(m["equipped"]) != 0:
				ui.notify("tool_belted")
				break
	else:
		await game.refresh_inventory()
	_end()


func toggle_tool_belt(row: Dictionary) -> void:
	move_to_belt([{"slot_index": int(row["slot_index"]), "equipped": 0 if DmGathering.is_belt_slot(int(row["slot_index"])) else 1}])


func give_to_legion(row: Dictionary) -> void:
	if not _begin():
		return
	var r: DmResult = await game.api.kit_move(int(game.character["id"]), int(row["slot_index"]), 1)
	if not _fail(r, "The legion would not take that."):
		panel.sel_item = {}
		await game.refresh_inventory()
		ui.play("equip")
	_end()


func take_off_legion(kit_id: String) -> Variant:
	var r: DmResult = await game.api.kit_move(int(game.character["id"]), 120 + ["weapon", "armor"].find(kit_id), 0)
	if r.ok:
		await game.refresh_inventory()
		ui.play("click")
		return null
	return r.error


func give_spare(slot_index: int) -> Variant:
	var r: DmResult = await game.api.kit_move(int(game.character["id"]), slot_index, 1)
	if r.ok:
		await game.refresh_inventory()
		ui.play("equip")
		return null
	return r.error


func adopt_charm(pet_id: String) -> void:
	if not _begin():
		return
	var r: DmResult = await game.api.adopt_pet(int(game.character["id"]), pet_id)
	if not _fail(r, "The Sexton refuses."):
		await game.refresh_inventory()
	_end()


## Returns a player-readable error, or "".
func socket_rune_id(rite: String, item_id: String) -> String:
	var r: DmResult = await game.api.rune_socket(int(game.character["id"]), rite, item_id)
	if not r.ok:
		return r.error if r.error != "" else "The rune would not move."
	await game.refresh_inventory()
	if item_id != "":
		ui.play("runeSocket")
		var rn := DmContent.rune(item_id)
		ui.toast("%s: %s" % [rn["name"], rn["short"]], "good")
		ui.notify("rune_socketed")
	return ""


func socket_rune(row: Dictionary) -> void:
	if not _begin():
		return
	var rn := DmContent.rune(String(row["item_id"]))
	var err := await socket_rune_id(String(rn["rite"]), String(row["item_id"]))
	if err != "":
		panel.set_error(err)
	_end()


func sort_bag() -> void:
	panel.sel_item = {}
	var moves := {}
	var sorted := DmBag.sort_bag_slots(slots(), moves, func(s: Dictionary) -> bool: return locks.is_locked(s))
	locks.remap(moves)
	game.slots = sorted
	if game.has_method("emit_signal"):
		game.inventory_changed.emit()
	await game.api.save_inventory(int(game.character["id"]), DmBag.to_save_payload(sorted), BAG_SIZE)
	await game.refresh_inventory()
	render()


func _credit(gold: int, name: String, n: int, show_n: bool) -> void:
	var cid := int(game.character["id"])
	game.character["gold"] = int(game.character.get("gold", 0)) + gold
	var ch: Dictionary = game.character
	await game.api.save_progress({"characterId": cid, "level": ch.get("level", 1), "xp": ch.get("experience", 0), "gold": ch["gold"],
		"stat_str": ch.get("stat_str", 5), "stat_agi": ch.get("stat_agi", 5), "stat_int": ch.get("stat_int", 5), "stat_vit": ch.get("stat_vit", 5)})
	await game.api.add_chronicle(cid, {"sold": n}, {})
	ui.play("coin")
	ui.toast("Sold %s%s for %s gold" % ["%d× " % n if show_n else "", name, DmJsFmt.locale(gold)], "good")
	game.refresh_character()


## Sell from the bag (never equipped gear): each unit leaves the bag, the bag is saved, the gold is credited like any pickup.
func sell(it: Dictionary, qty: int) -> void:
	var row: Dictionary = it["row"]
	if int(row.get("equipped", 0)) != 0 or locks.is_locked(row):
		return
	var sold := mini(qty, int(row["quantity"]))
	if sold <= 0:
		return
	_consume(row, sold)
	panel.sel_item = {}
	await game.api.save_inventory(int(game.character["id"]), DmBag.to_save_payload(slots()), BAG_SIZE)
	await _credit(sold * int(row["sell_value"]), String(row["name"]), sold, sold > 1)
	render()


func _consume(row: Dictionary, n: int) -> void:
	row["quantity"] = int(row["quantity"]) - n
	if int(row["quantity"]) <= 0:
		game.slots = slots().filter(func(s: Dictionary) -> bool: return s != row)
	game.inventory_changed.emit()


func sell_junk() -> void:
	var ctx: Variant = ui.stat_ctx()
	var list := DmItemLocks.junk_slots(slots(), locks, DmItemText.keeps_for_you(ctx))
	var gold := 0
	var n := 0
	for s in list:
		var q := int(s["quantity"])
		gold += int(s["sell_value"]) * q
		n += q
		_consume(s, q)
	panel.sel_item = {}
	if n == 0:
		return
	await game.api.save_inventory(int(game.character["id"]), DmBag.to_save_payload(slots()), BAG_SIZE)
	await _credit(gold, "%d junk item%s" % [n, "" if n == 1 else "s"], n, false)
	render()


func salvage_one(row: Dictionary) -> void:
	if not _begin():
		return
	var r: DmResult = await game.api.salvage_gear(int(game.character["id"]), [int(row["slot_index"])])
	if not _fail(r, "Salvage failed"):
		panel.sel_item = {}
		await game.refresh_inventory()
		ui.on_salvaged(r.data)
	_end()

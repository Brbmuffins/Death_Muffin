class_name DmGameLabor
extends RefCounted
## The labor + garden glue of WorldScene.ts: onLaborCollected / noteLabor / refreshContracts / checkLabor / onGardenResult / checkGarden and the
## timers that drive them (garden 4 s and labor 6 s after the data is ready, then every 60 s / 5 min).
## `views` = the DmLaborerViews (null headless / not visual); `summary` = DmGuidance.summarize_labor of the latest view (the UI's guidance
## reads it), `contract_summary` likewise for the contracts.

const GARDEN_FIRST_S := 4.0
const LABOR_FIRST_S := 6.0
const GARDEN_EVERY_S := 60.0
const LABOR_EVERY_S := 300.0
const WAITING_MS := 30 * 60000
const RANK := {"common": 0, "uncommon": 1, "rare": 2, "epic": 3, "legendary": 4}

var g
var views: Variant = null
var summary: Variant = null
var contract_summary: Variant = null
var guide_dirty := false
var labor_cap_noted: Dictionary = {}
var garden_ready := -1
var armed := false
var _garden_first := -1.0
var _labor_first := -1.0
var _garden_iv := GARDEN_EVERY_S
var _labor_iv := LABOR_EVERY_S
var _disposed := false


func _init(game) -> void:
	g = game


## The web's `dataReady` resolved: start the first checks. (update() arms itself once `game.ready_` is true if this is never called.)
func data_ready() -> void:
	if armed:
		return
	armed = true
	_garden_first = GARDEN_FIRST_S
	_labor_first = LABOR_FIRST_S
	refresh_contracts()


## Call each frame (real seconds). The 60 s / 5 min intervals run from construction like the web's scope.interval.
func update(dt: float) -> void:
	if _disposed:
		return
	if not armed and g.get("ready_") == true:
		data_ready()
	_garden_iv -= dt
	if _garden_iv <= 0.0:
		_garden_iv += GARDEN_EVERY_S
		check_garden(false)
	_labor_iv -= dt
	if _labor_iv <= 0.0:
		_labor_iv += LABOR_EVERY_S
		check_labor(false)
	if _garden_first >= 0.0:
		_garden_first -= dt
		if _garden_first < 0.0:
			_garden_first = -1.0
			check_garden(true)
	if _labor_first >= 0.0:
		_labor_first -= dt
		if _labor_first < 0.0:
			_labor_first = -1.0
			check_labor(true)


func dispose() -> void:
	_disposed = true


# --- labor ----------------------------------------------------------------------------------------------------------------------

## A laborer came home: credit gold and the skill, count the finds, and list what they brought under the laborers (the window stays open).
## `r` = LaborResult {..LaborView, collected?: {slot, node, skill, hours, actions, items:[{itemId, qty}], gold, xp, leveledUp}}.
func on_collected(r: Dictionary, slot: int) -> void:
	var c: Variant = r.get("collected")
	if not (c is Dictionary):
		return
	if g.gatherer != null:
		g.gatherer.celebrate_charms(c["items"])
	var skill := String(c["skill"])
	var before: int = g.gatherer.skills.level(skill)
	var total := 0
	for it in c["items"]:
		total += int(it["qty"])
	var life_before := float(g.chronicle.view()["life"].get("gathered.%s" % skill, 0))
	if float(c["gold"]) > 0.0:
		g.prog.add_gold(float(c["gold"]))
	g.chronicle.add("gathered.%s" % skill, total)
	g.play_sfx("coin")
	g.refresh_inventory()
	g.refresh_character()
	var rows: DmResult = await g.api.get_professions(g.hero_id)
	if _disposed:
		return
	var panel: Variant = _labor_panel()
	if not (rows.ok and rows.data is Array):
		g.toast("Your laborers brought %s finds" % _thousands(total), "good")
		return
	g.gatherer.skills.adopt(rows.data)
	var items: Array = []
	for it in c["items"]:
		var m: Dictionary = DmContent.item(String(it["itemId"]))
		items.append({"itemId": it["itemId"], "name": m["name"], "rarity": m["rarity"], "qty": int(it["qty"]), "value": int(m["sell"]) * int(it["qty"])})
	items = DmStableSort.sorted(items, func(a: Dictionary, b: Dictionary) -> bool: return a["value"] > b["value"])
	var by_rank := DmStableSort.sorted(items.duplicate(), func(a: Dictionary, b: Dictionary) -> bool:
		if RANK[a["rarity"]] != RANK[b["rarity"]]:
			return RANK[a["rarity"]] > RANK[b["rarity"]]
		return a["value"] > b["value"])
	var best: Variant = by_rank[0] if not by_rank.is_empty() else null
	var after: int = g.gatherer.skills.level(skill)
	var sk: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")[skill]
	var milestones: Array = []
	for m in DmGatherSession.crossed_milestones(life_before, life_before + float(total)):
		milestones.append("%s %s finds" % [_thousands(int(m)), sk["name"]])
	if after > before:
		milestones.append("%s level %d" % [sk["name"], after])
	var worth := 0
	for i in items:
		worth += int(i["value"])
	var report := {
		"seconds": DmMath.js_round(float(c["hours"]) * 3600.0), "reason": "labor", "items": items, "totalItems": total, "goldValue": worth, "gold": c["gold"],
		"skills": [{"skill": skill, "name": sk["name"], "xp": c["xp"], "fromLevel": before, "toLevel": after, "items": total}],
		"best": best if (best != null and int(RANK[best["rarity"]]) > 0) else null, "milestones": milestones, "records": [],
	}
	if panel != null:
		panel.add_loot(slot, report)


## onContractDelivered: the gold (the server returns it, never writes it), the chronicle, the summary and the toast. `d` = the delivery {contracts, gold, paidBonus?}.
func on_contract_delivered(d: Dictionary) -> void:
	var gold := float(d.get("gold", 0))
	if gold > 0.0:
		g.prog.add_gold(gold)
		g.play_sfx("coin")
		g.float_text(g.player.x, 2.4, g.player.z, "+%sg" % _thousands(int(gold)), "gold")
	g.chronicle.add("contracts")
	contract_summary = DmGuidance.summarize_contracts(d)
	guide_dirty = true
	g.play_sfx("orderFilled")
	var bonus: Variant = d.get("paidBonus")
	g.toast("Order filled, and the day’s bonus is yours: +%sg" % _thousands(int(bonus["gold"])) if bonus is Dictionary else "Order filled", "good")


func _labor_panel() -> Variant:
	var ui: Variant = g.get("ui")
	if ui != null and ui.get("pb") != null and ui.pb.get("labor") != null:
		return ui.pb.labor
	return null


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## noteLabor: the guidance summary of a labor view.
func note_labor(v: Dictionary) -> void:
	summary = DmGuidance.summarize_labor(v)
	guide_dirty = true


func refresh_contracts() -> void:
	var r: DmResult = await g.api.get_contracts(g.hero_id)
	if _disposed:
		return
	if r.ok and r.data is Dictionary and r.data.has("contracts"):
		contract_summary = DmGuidance.summarize_contracts(r.data)
		guide_dirty = true


## Tell the player when their laborers have work waiting: on arrival, and once when a laborer is full.
func check_labor(arrival: bool) -> void:
	var r: DmResult = await g.api.get_labor(g.hero_id)
	if _disposed or not (r.ok and r.data is Dictionary and r.data.has("slots")):
		return
	var v: Dictionary = r.data
	if views != null:
		views.apply(v)
	note_labor(v)
	refresh_contracts()
	var waiting: Array = []
	var items := 0
	for s in v["slots"]:
		if DmCombatData.truthy(s.get("nodeType")) and float(s["elapsedMs"]) >= WAITING_MS:
			waiting.append(s)
			items += int(s["estItems"])
	var full: Array = []
	for s in v["slots"]:
		if DmCombatData.truthy(s.get("capped")) and not labor_cap_noted.has(int(s["slot"])):
			full.append(s)
	for s in full:
		labor_cap_noted[int(s["slot"])] = true
	for s in v["slots"]:
		if not DmCombatData.truthy(s.get("capped")):
			labor_cap_noted.erase(int(s["slot"]))
	if arrival and not waiting.is_empty():
		g.toast("Your laborers have gathered about %s finds (H)" % _thousands(items), "good")
	elif not full.is_empty():
		g.toast("A laborer has filled up: collect what they gathered (H)", "good")


# --- garden ---------------------------------------------------------------------------------------------------------------------

## Plant / harvest finished: credit the skill, count the crop, and tell the player. `r` = GardenResult {plots, items?, leveledUp, level}.
func on_garden_result(kind: String, r: Dictionary) -> void:
	g.play_sfx("gardenHarvest" if kind == "harvest" else "gardenPlant")
	var rows: DmResult = await g.api.get_professions(g.hero_id)
	if rows.ok and rows.data is Array and not _disposed:
		g.gatherer.skills.adopt(rows.data)
	var items: Array = r.get("items", []) if r.get("items") is Array else []
	if kind == "harvest" and not items.is_empty():
		g.gatherer.celebrate_charms(items)
		var crop: Dictionary = items[0]
		g.chronicle.add("gathered.gardening", int(crop["qty"]))
		var seed_back: Variant = items[1] if items.size() > 1 else null
		g.toast("Harvested %d× %s%s" % [int(crop["qty"]), DmContent.item(String(crop["itemId"]))["name"], " (and a seed to replant)" if seed_back != null else ""], "good")
	if DmCombatData.truthy(r.get("leveledUp")):
		g.banner("Grave Gardening %d" % int(r["level"]), "The beds answer you more readily", 2600)
	garden_ready = _count_plots(r, "ready")


static func _count_plots(v: Dictionary, state: String) -> int:
	var n := 0
	for p in v.get("plots", []):
		if p["state"] == state:
			n += 1
	return n


## Tell the player when the garden has something waiting: on arrival, and as plots come ready while they play.
func check_garden(arrival: bool) -> void:
	var r: DmResult = await g.api.get_garden(g.hero_id)
	if _disposed or not (r.ok and r.data is Dictionary and r.data.has("plots")):
		return
	var ready := _count_plots(r.data, "ready")
	var growing := _count_plots(r.data, "growing")
	if ready > 0 and (arrival or ready > garden_ready):
		g.toast("%d plot%s ready in your garden (U)" % [ready, " is" if ready == 1 else "s are"], "good")
	elif arrival and growing > 0:
		g.toast("%d plot%s still growing in your garden (U)" % [growing, " is" if growing == 1 else "s are"])
	garden_ready = ready

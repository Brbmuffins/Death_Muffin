class_name DmGarden
extends RefCounted
## Port of src/gameplay/gardeningRules.ts + src/content/gardening.ts (plots, seeds). Growth is computed from SERVER timestamps
## (epoch ms), so plots grow while away; the server owns plant/harvest rolls (garden.cjs). `rng` = Callable returning [0,1).

const M := preload("res://rules/core/math.gd")
const Data := preload("res://rules/gathering/gather_data.gd")

const GARDEN_PET_CHANCE := 1.0 / 35.0


static func plots() -> Array:
	return Data.get_data()["plots"]


static func seeds() -> Array:
	return Data.get_data()["seeds"]


static func plot_def(id: String) -> Dictionary:
	for p in plots():
		if p["id"] == id:
			return p
	return {}


static func seed_def(id: String) -> Dictionary:
	for s in seeds():
		if s["id"] == id:
			return s
	return {}


static func compost_item() -> String:
	return Data.get_data()["compost"]["item"]


## row: {plot, seedId (String or null), plantedAt, readyAt, composted} or {} / null for empty. Returns "empty"|"growing"|"ready".
static func state_of(row: Variant, now: int) -> String:
	if row == null or not (row is Dictionary) or (row as Dictionary).is_empty() or (row as Dictionary).get("seedId") == null or str((row as Dictionary)["seedId"]) == "":
		return "empty"
	return "ready" if now >= int(row["readyAt"]) else "growing"


## Real-time ms a seed takes to grow (composted plots 25% faster).
static func grow_ms(seed: Dictionary, composted: bool) -> int:
	var speed: float = float(Data.get_data()["compost"]["speed"])
	return M.js_round(float(seed["growMin"]) * 60000.0 * (speed if composted else 1.0))


## Why this seed can't go in this plot now ("" = fine).
static func plant_blocker(plot: Dictionary, seed_id: String, level: int, existing: Variant, now: int) -> String:
	var seed := seed_def(seed_id)
	if plot.is_empty():
		return "There is no such plot."
	if seed.is_empty():
		return "That cannot be planted."
	if seed["kind"] != plot["kind"]:
		return "Saplings go in a Coffin Patch." if seed["kind"] == "tree" else "Seeds go in a Mourning Bed."
	if level < int(seed["level"]):
		return "Requires Grave Gardening %d." % int(seed["level"])
	if state_of(existing, now) != "empty":
		return "Something is already growing there."
	return ""


## Returns {itemId, qty, seedBack (String or null), xp}.
static func roll_harvest(seed: Dictionary, rng: Callable) -> Dictionary:
	var lo := int(seed["yields"][0])
	var hi := int(seed["yields"][1])
	var qty := lo + int(floor(float(rng.call()) * float(hi - lo + 1)))
	var back: Variant = seed["id"] if float(rng.call()) < float(seed["seedBack"]) else null
	return {"itemId": seed["harvest"], "qty": qty, "seedBack": back, "xp": seed["harvestXp"]}


## "1h 20m", "35m", "45s".
static func remaining_text(ms: float) -> String:
	var s := int(ceil(maxf(0.0, ms) / 1000.0))
	var h := s / 3600
	var m := (s % 3600) / 60
	if h > 0:
		return "%dh %dm" % [h, m]
	if m > 0:
		return "%dm" % m
	return "%ds" % s

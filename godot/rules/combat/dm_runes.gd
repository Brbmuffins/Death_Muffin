class_name DmRunes
extends RefCounted
## Port of server/rules/gameplay/runeRules.ts (socket rows) + archive/legacy-web:src/gameplay/runeCast.ts (target pickers: pure geometry shared by the cast code and bots).
## Foes / corpses are Dictionaries {id, x, z, radius}. Sorts are stable (id order of the input list breaks ties), like JS.

const RUNE_BASE := 130


static func rites() -> Array:
	return DmCombatData.abilities()["rune_rites"]


static func T() -> Dictionary:
	return DmCombatData.abilities()["rune_tuning"]


static func is_rune_id(id: Variant) -> bool:
	return id is String and DmCombatData.abilities()["runes"].has(id)


static func is_rune_rite(id: Variant) -> bool:
	return id is String and rites().has(id)


static func is_rune_slot(slot: Variant) -> bool:
	if not (slot is int or slot is float):
		return false
	var f := float(slot)
	return f == floorf(f) and f >= RUNE_BASE and f < RUNE_BASE + rites().size()


static func rune_slot_rite(slot: Variant) -> Variant:
	return rites()[int(slot) - RUNE_BASE] if is_rune_slot(slot) else null


static func rune_slot_index(rite: String) -> int:
	return RUNE_BASE + rites().find(rite)


static func rune_equipped_slot(rite: String) -> String:
	return "rune_" + rite


static func rune_fits(rune_id: String, rite: String) -> bool:
	return is_rune_id(rune_id) and is_rune_rite(rite) and DmCombatData.abilities()["runes"][rune_id]["rite"] == rite


## The sockets held by a list of inventory rows -> {rite: rune_id}.
static func sockets_of(rows: Array) -> Dictionary:
	var out := {}
	for r: Dictionary in rows:
		var rite: Variant = rune_slot_rite(r.get("slot_index"))
		if rite != null and float(DmCombatData.nn(r.get("quantity"), 1)) > 0.0 and rune_fits(str(r.get("item_id")), rite):
			out[rite] = r["item_id"]
	return out


## How many of each rune the bag holds (reserved socket rows and equipped rows do not count).
static func owned_runes(rows: Array) -> Dictionary:
	var out := {}
	for r: Dictionary in rows:
		var si: float = float(r["slot_index"])
		if si >= 0.0 and si < 100.0 and not DmCombatData.truthy(r.get("equipped")) and is_rune_id(r.get("item_id")):
			out[r["item_id"]] = float(out.get(r["item_id"], 0.0)) + float(r["quantity"])
	return out


static func sockets_signature(s: Dictionary) -> String:
	var parts: Array[String] = []
	for r: String in rites():
		parts.append(str(s.get(r, "-")))
	return "|".join(parts)


static func _dist(a: Dictionary, b: Dictionary) -> float:
	var dx: float = a["x"] - b["x"]
	var dz: float = a["z"] - b["z"]
	return DmWeaponLine.hypot2(dx, dz)


## Splinters: the living enemy nearest the struck one (other than it) within the rune's reach, or null.
static func splinter_target(first: Dictionary, foes: Array) -> Variant:
	var best: Variant = null
	var best_d: float = T()["splinter"]["reach"]
	for e: Dictionary in foes:
		if e["id"] == first["id"]:
			continue
		var d := _dist(e, first)
		if d <= best_d:
			best_d = d
			best = e
	return best


## Volley: the needle's own target plus the enemies nearest to it within reach of the caster, `needles` in all.
static func volley_targets(caster: Dictionary, first: Dictionary, foes: Array) -> Array:
	var V: Dictionary = T()["volley"]
	var others: Array = []
	var i := 0
	for e: Dictionary in foes:
		i += 1
		if e["id"] != first["id"] and _dist(e, caster) <= float(V["reach"]):
			others.append({"e": e, "d": _dist(e, first), "i": i})
	others.sort_custom(func(a, b): return a["d"] < b["d"] if a["d"] != b["d"] else a["i"] < b["i"])
	var out: Array = [first]
	for o in others.slice(0, int(V["needles"]) - 1):
		out.append(o["e"])
	return out


## Ossuary Ring: everything inside the ring (body radius counts).
static func ring_hits(center: Dictionary, radius: float, foes: Array) -> Array:
	var out: Array = []
	for e: Dictionary in foes:
		if _dist(e, center) <= radius + float(e["radius"]):
			out.append(e)
	return out


## Where the ring lands: the cursor, pulled back to the spear's reach.
static func ring_center(origin: Dictionary, aim: Dictionary, reach: float) -> Dictionary:
	var d := _dist(origin, aim)
	if d <= reach or d < 1e-6:
		return {"x": aim["x"], "z": aim["z"]}
	return {"x": origin["x"] + ((aim["x"] - origin["x"]) / d) * reach, "z": origin["z"] + ((aim["z"] - origin["z"]) / d) * reach}


## Impaling: first enemy a spear down (dx, dz) meets within range and a half-width: {foe, along} or null.
static func impale_target(origin: Dictionary, dx: float, dz: float, range_m: float, half_w: float, foes: Array) -> Variant:
	var best: Variant = null
	for e: Dictionary in foes:
		var rx: float = e["x"] - origin["x"]
		var rz: float = e["z"] - origin["z"]
		var along := rx * dx + rz * dz
		if along > 0.0 and along < range_m and absf(rx * dz - rz * dx) < half_w + float(e["radius"]) and (best == null or along < best["along"]):
			best = {"foe": e, "along": along}
	return best


## Mass Grave / Colossus: corpses (not echoes) within `r` of the point, nearest first.
static func corpses_within(point: Dictionary, r: float, corpses: Array) -> Array:
	var out: Array = []
	var i := 0
	for c: Dictionary in corpses:
		i += 1
		if not DmCombatData.truthy(c.get("echoOwner")) and _dist(c, point) <= r:
			out.append({"c": c, "d": _dist(c, point), "i": i})
	out.sort_custom(func(a, b): return a["d"] < b["d"] if a["d"] != b["d"] else a["i"] < b["i"])
	var res: Array = []
	for o in out:
		res.append(o["c"])
	return res

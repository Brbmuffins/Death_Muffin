class_name DmLabor
extends RefCounted
## Port of src/gameplay/laborRules.ts (Grave Laborers: slow idle work posts that accrue on the server's clock). Server-authoritative
## (labor.cjs rolls collections with claim_rng); the client shows estimate(). `rng` = Callable returning [0,1).

const M := preload("res://rules/core/math.gd")
const Data := preload("res://rules/gathering/gather_data.gd")
const G := preload("res://rules/gathering/gathering_rules.gd")
const Rng := preload("res://rules/core/rng.gd")

const FACTOR := 0.12
const CAP_MS := 8 * 3600000
const XP_FRAC := 0.25
const MAX_SLOTS := 4
const LEVELS_PER_SLOT := 50


static func labor_slots(total_level: int) -> int:
	return mini(MAX_SLOTS, 1 + int(floor(float(maxi(0, total_level)) / float(LEVELS_PER_SLOT))))


## levels: {skill: level}. Sum over the four gather skills (missing = 1, min 1).
static func total_gather_level(levels: Dictionary) -> int:
	var n := 0
	for s in G.GATHER_SKILLS:
		n += maxi(1, int(levels.get(s, 1)))
	return n


## Posts a laborer can take: every non-gardening node the levels allow.
static func posts_for(levels: Dictionary) -> Array:
	var out: Array = []
	for n in Data.get_data()["nodes"]:
		if n["skill"] != "gardening" and int(levels.get(n["skill"], 1)) >= int(n["level"]):
			out.append(n)
	return out


static func assign_blocker(node_type: String, levels: Dictionary) -> String:
	var def := Data.node(node_type)
	if def.is_empty() or def["skill"] == "gardening":
		return "That is not a place to work."
	if int(levels.get(def["skill"], 1)) < int(def["level"]):
		return "Requires level %d." % int(def["level"])
	return ""


static func labor_actions(def: Dictionary, elapsed_ms: float) -> int:
	var ms := maxf(0.0, minf(elapsed_ms, float(CAP_MS)))
	return int(floor((ms / float(G.action_ms(def))) * FACTOR))


## {actions, items, xp} average expectations for the panel.
static func estimate(def: Dictionary, level: int, elapsed_ms: float) -> Dictionary:
	var actions := labor_actions(def, elapsed_ms)
	var wins: float = float(actions) * G.success_chance(def, level)
	return {"actions": actions, "items": M.js_round(wins), "xp": M.js_round(wins * float(def["xp"]) * XP_FRAC)}


## Rolls a collection. start = {level, xp}. Returns {items, gold, xp, actions, progress, leveled}.
static func roll_labor(def: Dictionary, start: Dictionary, elapsed_ms: float, rng: Callable) -> Dictionary:
	var actions := labor_actions(def, elapsed_ms)
	var batch := G.roll_batch(def, {"level": start["level"], "xp": 0}, actions, rng, 0)
	var xp := int(floor(float(batch["xp"]) * XP_FRAC))
	var nxt := G.add_skill_xp(start, xp)
	return {"items": batch["items"], "gold": batch["gold"], "xp": xp, "actions": actions, "progress": {"level": nxt["level"], "xp": nxt["xp"]}, "leveled": nxt["leveled"]}


## FNV-1a over the ':'-joined parts (ASCII).
static func hash_seed(parts: Array) -> int:
	var strs: Array = []
	for p in parts:
		# JS joins integral numbers without a decimal point (JSON round-trips deliver them as floats)
		strs.append(str(int(p)) if (p is float and p == floorf(p)) else str(p))
	var joined := ":".join(strs)
	var h := 2166136261
	for i in joined.length():
		h = ((h ^ joined.unicode_at(i)) * 16777619) & 0xFFFFFFFF
	return h


## A repeatable rng for one collection (DmRng = mulberry32, same as TS claimRng). Returns the DmRng: KEEP the reference alive
## while using `.as_callable()` (a Callable does not own a RefCounted).
static func claim_rng(seed_value: int) -> Object:
	return Rng.new(seed_value)

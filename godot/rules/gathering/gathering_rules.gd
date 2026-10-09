class_name DmGathering
extends RefCounted
## Port of server/rules/gameplay/gatheringRules.ts + gatherPlan.ts (pure rules; no nodes).
##
## SERVER-AUTHORITATIVE: the Death Muffin backend (server/death-muffin/backend/gathering/*.cjs, bundled from the same TS)
## rolls the real finds, validates the time budget (check_budget), reads the bag for the tool tier and grants items/XP.
## The client uses these rules for feel (cycle rolls, node UI, estimates) and the offline mock. roll_gather/roll_batch
## here are what the server runs; they must never be trusted from a client.
##
## `rng` arguments are Callables returning a float in [0,1) (DmRng.as_callable()).

const M := preload("res://rules/core/math.gd")
const Data := preload("res://rules/gathering/gather_data.gd")

const SKILL_IDS: Array = ["woodcutting", "mining", "fishing", "gravedigging", "gardening", "alchemy", "salvaging"]
const GATHER_SKILLS: Array = ["woodcutting", "mining", "fishing", "gravedigging"]

const TICK_MS := 600
const LEVEL_CAP := 99
const GATHER_BURST := 3
const GATHER_MAX_WINDOW_MS := 30000
const GATHER_MAX_ACTIONS_PER_HOUR := 1800
const GATHER_FLUSH_MS := 8000
const GATHER_MAX_BATCH := 40
const AFK_WINDOW_MS := 90000
const RICH_YIELD := 1.5
const RICH_RESPAWN := 0.5

const BAG_SLOTS := 48
const MATERIAL_STACK := 250

## Tools
const TOOL_KIND := {"woodcutting": "hatchet", "mining": "pickaxe", "fishing": "rod", "gravedigging": "spade"}
const TOOL_METALS: Array = ["copper", "iron", "silver", "steel", "hell", "moon"]
const BELT_BASE := 110
const BELT_KINDS: Array = ["hatchet", "pickaxe", "rod", "spade"]
const BELT_SLOT_COUNT := 4

## "live" = level x 50 per level (the shipped rule); "curve" = recommended curve (owner decision pending).
const XP_CURVE := "live"


static func node_def(id: String) -> Dictionary:
	return Data.node(id)


static func nodes_for_skill(skill: String) -> Array:
	var out: Array = []
	for n in Data.get_data()["nodes"]:
		if n["skill"] == skill:
			out.append(n)
	return out


static func action_ms(def: Dictionary) -> int:
	return int(def["ticks"]) * TICK_MS


# ── XP curve ──────────────────────────────────────────────────────────────────

static func xp_to_next_live(level: int) -> int:
	return maxi(1, level) * 50


static func xp_to_next_curve(level: int) -> int:
	return M.js_round(50.0 * maxi(1, level) * pow(1.035, maxi(0, level - 20)))


static func xp_to_next(level: int) -> int:
	return xp_to_next_curve(level) if XP_CURVE == "curve" else xp_to_next_live(level)


static func total_xp_for(level: int, curve: bool = false) -> int:
	var t := 0
	for l in range(1, level):
		t += xp_to_next_curve(l) if curve else xp_to_next(l)
	return t


## p = {level, xp}; returns {level, xp, leveled}.
static func add_skill_xp(p: Dictionary, gained: Variant) -> Dictionary:
	var lv := int(floor(float(p["level"])))
	if lv == 0:
		lv = 1
	var level := maxi(1, mini(LEVEL_CAP, lv))
	var xp := maxi(0, int(floor(float(p["xp"])))) + maxi(0, int(floor(float(gained))))
	var leveled := 0
	while level < LEVEL_CAP and xp >= xp_to_next(level):
		xp -= xp_to_next(level)
		level += 1
		leveled += 1
	if level >= LEVEL_CAP:
		xp = 0
	return {"level": level, "xp": xp, "leveled": leveled}


# ── Tools & belt ──────────────────────────────────────────────────────────────

static func tool_item_id(skill: String, tier: int) -> String:
	return "tool_%s_%s" % [TOOL_KIND[skill], TOOL_METALS[tier - 1]]


## Best tier (0 = none) of `skill`'s tool among the item ids held (bag + belt).
static func tool_tier_for(skill: String, held_item_ids: Array) -> int:
	if not TOOL_KIND.has(skill):
		return 0
	var kind: String = TOOL_KIND[skill]
	var prefix := "tool_%s_" % kind
	var best := 0
	for id in held_item_ids:
		var s := str(id)
		if s == "" or not s.begins_with(prefix):
			continue
		var tier := TOOL_METALS.find(s.substr(kind.length() + 6)) + 1
		if tier > best:
			best = tier
	return best


static func is_belt_slot(slot: int) -> bool:
	return slot >= BELT_BASE and slot < BELT_BASE + BELT_SLOT_COUNT


## The tool kind an item id is ("hatchet"...), or "" (not a tool / unknown metal).
static func tool_kind_of(item_id: String) -> String:
	for kind in BELT_KINDS:
		var prefix := "tool_%s_" % kind
		if item_id.begins_with(prefix) and TOOL_METALS.has(item_id.substr(prefix.length())):
			return kind
	return ""


## Reserved inventory slot for a tool's belt place, or -1.
static func belt_slot_of(item_id: String) -> int:
	var kind := tool_kind_of(item_id)
	return BELT_BASE + BELT_KINDS.find(kind) if kind != "" else -1


static func belt_equipped_slot(kind: String) -> String:
	return "belt_" + kind


static func belt_slot_kind(slot: int) -> String:
	return BELT_KINDS[slot - BELT_BASE] if is_belt_slot(slot) else ""


## Highest-tier tool of each kind: {kind: item_id}.
static func best_tool_per_kind(item_ids: Array) -> Dictionary:
	var best: Dictionary = {}
	for id in item_ids:
		var s := str(id)
		var kind := tool_kind_of(s)
		if kind != "" and (not best.has(kind) or _tier_idx(s) > _tier_idx(best[kind])):
			best[kind] = s
	return best


# TS: TOOL_METALS.indexOf(id.slice(id.indexOf('_', 5) + 1))
static func _tier_idx(id: String) -> int:
	return TOOL_METALS.find(id.substr(id.find("_", 5) + 1))


# ── Rolls ─────────────────────────────────────────────────────────────────────

static func success_chance(def: Dictionary, level: int, tool_tier: int = 0) -> float:
	var base := 0.6 if int(def["level"]) == 1 else 0.45
	var p: float = base + 0.01 * float(level - int(def["level"])) + 0.05 * float(tool_tier)
	return maxf(0.2, minf(0.9, p))


static func _rand_int(rng: Callable, lo: int, hi: int) -> int:
	return lo + int(floor(float(rng.call()) * float(hi - lo + 1)))


## One work cycle. Returns {success, xp, gold, items:[{itemId, qty}]}.
static func roll_gather(def: Dictionary, level: int, rng: Callable, tool_tier: int = 0) -> Dictionary:
	if level < int(def["level"]) or float(rng.call()) >= success_chance(def, level, tool_tier):
		return {"success": false, "xp": 0, "gold": 0, "items": []}
	var items: Array = [{"itemId": def["item"], "qty": 1}]
	for e in def["extras"]:
		if float(rng.call()) < float(e["chance"]):
			var q := 1
			if e.has("qty"):
				q = _rand_int(rng, int(e["qty"][0]), int(e["qty"][1]))
			items.append({"itemId": e["item"], "qty": q})
	var gold := 0
	if def.has("gold"):
		gold = _rand_int(rng, int(def["gold"][0]), int(def["gold"][1]))
	return {"success": true, "xp": def["xp"], "gold": gold, "items": items}


## Rolls `actions` cycles, levelling mid-batch. start = {level, xp}. `roll_floor` = staff dev-access floor.
## Returns {progress:{level,xp}, successes, xp, gold, items:[{itemId,qty}], leveled}.
static func roll_batch(def: Dictionary, start: Dictionary, actions: int, rng: Callable, tool_tier: int = 0, roll_floor: int = 0) -> Dictionary:
	var progress := {"level": int(start["level"]), "xp": int(start["xp"])}
	var bag: Dictionary = {}
	var xp := 0
	var gold := 0
	var successes := 0
	var leveled := 0
	for i in actions:
		var r := roll_gather(def, maxi(int(progress["level"]), roll_floor), rng, tool_tier)
		if not r["success"]:
			continue
		successes += 1
		xp += int(r["xp"])
		gold += int(r["gold"])
		for g in r["items"]:
			bag[g["itemId"]] = int(bag.get(g["itemId"], 0)) + int(g["qty"])
		var nxt := add_skill_xp(progress, r["xp"])
		leveled += int(nxt["leveled"])
		progress = {"level": nxt["level"], "xp": nxt["xp"]}
	var items: Array = []
	for k in bag:
		items.append({"itemId": k, "qty": bag[k]})
	return {"progress": progress, "successes": successes, "xp": xp, "gold": gold, "items": items, "leveled": leveled}


static func xp_per_hour(def: Dictionary, level: int, tool_tier: int = 0) -> float:
	return (3600000.0 / float(action_ms(def))) * success_chance(def, level, tool_tier) * float(def["xp"])


# ── Time budget (server side of POST /api/gather) ─────────────────────────────

static func blank_ledger() -> Dictionary:
	return {"lastAt": 0, "hourStart": 0, "hourActions": 0}


## Returns {ok:true, accepted, ledger} or {ok:false, error}.
static func check_budget(def: Dictionary, ledger: Dictionary, claimed: Variant, now: int, afk: bool = false) -> Dictionary:
	var want := int(floor(float(claimed)))
	if want < 1:
		return {"ok": false, "error": "Nothing to gather"}
	var last_at := int(ledger["lastAt"])
	if afk and last_at == 0:
		return {"ok": false, "error": "Start AFK gathering from Skills first."}
	var window_ms := AFK_WINDOW_MS if afk else GATHER_MAX_WINDOW_MS
	var elapsed: int = maxi(0, now - last_at) if last_at > 0 else window_ms
	var by_time: int = int(floor(float(mini(elapsed, window_ms)) / float(action_ms(def)))) + (0 if afk else GATHER_BURST)
	var hour_start := int(ledger["hourStart"])
	var rolled := now - hour_start >= 3600000 or hour_start == 0
	var new_hour_start := now if rolled else hour_start
	var hour_actions: int = 0 if rolled else int(ledger["hourActions"])
	var by_hour := GATHER_MAX_ACTIONS_PER_HOUR - hour_actions
	var accepted := mini(mini(want, by_time), mini(by_hour, GATHER_MAX_BATCH))
	if accepted <= 0:
		return {"ok": false, "error": "Your hands are spent for this hour. Rest, then gather again." if by_hour <= 0 else "You are gathering faster than your hands allow. Slow down."}
	var new_last: int = (maxi(last_at, now - window_ms) + accepted * action_ms(def)) if afk else now
	return {"ok": true, "accepted": accepted, "ledger": {"lastAt": new_last, "hourStart": new_hour_start, "hourActions": hour_actions + accepted}}


# ── Bag placement (server grant + offline mock) ──────────────────────────────

## bag: [{slot,itemId,qty}], grants: [{itemId,qty}], max_stack: Callable(itemId)->int.
## Returns {updates:[{slot,qty}], inserts:[{slot,itemId,qty}], stored:[...], rejected:[...]}.
static func place_items(bag: Array, grants: Array, max_stack: Callable) -> Dictionary:
	var rows: Array = []
	for r in bag:
		rows.append(r.duplicate())
	var touched: Dictionary = {}
	var inserts: Array = []
	var stored: Array = []
	var rejected: Array = []
	var used: Dictionary = {}
	for r in rows:
		used[int(r["slot"])] = true
	for g in grants:
		var left := int(g["qty"])
		var cap := maxi(1, int(max_stack.call(g["itemId"])))
		var all: Array = rows + inserts
		for r in all:
			if left <= 0:
				break
			if r["itemId"] != g["itemId"] or int(r["qty"]) >= cap:
				continue
			var add := mini(left, cap - int(r["qty"]))
			r["qty"] = int(r["qty"]) + add
			left -= add
			if _is_in(rows, r):
				touched[int(r["slot"])] = r["qty"]
		var s := 0
		while s < BAG_SLOTS and left > 0:
			if not used.has(s):
				var add2 := mini(left, cap)
				inserts.append({"slot": s, "itemId": g["itemId"], "qty": add2})
				used[s] = true
				left -= add2
			s += 1
		if int(g["qty"]) - left > 0:
			stored.append({"itemId": g["itemId"], "qty": int(g["qty"]) - left})
		if left > 0:
			rejected.append({"itemId": g["itemId"], "qty": left})
	var updates: Array = []
	for k in touched:
		updates.append({"slot": k, "qty": touched[k]})
	return {"updates": updates, "inserts": inserts, "stored": stored, "rejected": rejected}


## Math.hypot (double precision; Vector2 is single precision in Godot).
static func _hypot(a: float, b: float) -> float:
	return sqrt(a * a + b * b)


# Identity test (TS `rows.includes(r)` is reference equality): Dictionary.has/== compares by value, so check by reference.
static func _is_in(rows: Array, r: Dictionary) -> bool:
	for x in rows:
		if is_same(x, r):
			return true
	return false


# ── gatherPlan.ts ─────────────────────────────────────────────────────────────

## Free point on the node's reach ring nearest to (from_x, from_z). `blocked` = Callable(x, z, r) -> bool.
## Returns {x, z} or {} when the whole ring is blocked.
static func stand_spot(blocked: Callable, node: Dictionary, from_x: float, from_z: float, r: float = 0.45) -> Dictionary:
	var kind: String = node_def(node["type"])["kind"]
	var reach: float = float(Data.get_data()["node_reach"][kind])
	var best: Dictionary = {}
	var best_d := INF
	for k in 16:
		var a := (float(k) / 16.0) * PI * 2.0
		var x: float = float(node["x"]) + cos(a) * reach
		var z: float = float(node["z"]) + sin(a) * reach
		if blocked.call(x, z, r):
			continue
		var d := _hypot(x - from_x, z - from_z)
		if d < best_d:
			best_d = d
			best = {"x": x, "z": z}
	return best


const SKILL_NAMES := {"woodcutting": "Woodcutting", "mining": "Mining", "fishing": "Fishing", "gravedigging": "Gravedigging", "gardening": "Grave Gardening"}


## Why the loop can't work a node ("" = go).
static func gather_blocker(type: String, level: int) -> String:
	var def := node_def(type)
	if def.is_empty():
		return "Nothing to gather here."
	if level < int(def["level"]):
		return "Requires %s level %d" % [SKILL_NAMES[def["skill"]], int(def["level"])]
	return ""


## Auto: nearest live node of the same type in the same area ({} when none). nodes: [{type,x,z,area,remaining}].
static func next_auto_node(from: Dictionary, nodes: Array, level: int, x: float, z: float) -> Dictionary:
	var def := node_def(from["type"])
	if def.is_empty() or level < int(def["level"]):
		return {}
	var best: Dictionary = {}
	var best_d := INF
	for n in nodes:
		if n["type"] != from["type"] or n["area"] != from["area"] or float(n["remaining"]) <= 0.0:
			continue
		if float(n["x"]) == float(from["x"]) and float(n["z"]) == float(from["z"]):
			continue
		var d := _hypot(float(n["x"]) - x, float(n["z"]) - z)
		if d < best_d:
			best_d = d
			best = n
	return best


const STOP_TEXT := {
	"moved": "",
	"panel": "",
	"bagFull": "Your bag is full. Visit the Reliquary or drop something to keep gathering.",
	"hurt": "Something struck you. Gathering stopped.",
	"dead": "",
	"left": "",
}

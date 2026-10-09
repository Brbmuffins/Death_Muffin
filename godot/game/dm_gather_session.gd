class_name DmGatherSession
extends RefCounted
## Port of GatherSession in archive/legacy-web:src/gameplay/gatherReport.ts: the "while you were away" report of an AFK session. Pure logic.

const MILESTONES := [100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]
const MIN_REPORT_SECONDS := 20
const RARITY_RANK := {"common": 0, "uncommon": 1, "rare": 2, "epic": 3, "legendary": 4}

var started_at: float
## Callable(item_id) -> {name, rarity, sell}
var info: Callable
## Callable(skill) -> int level; Callable(skill) -> lifetime finds
var level_of: Callable
var life_of: Callable
var _items: Dictionary = {}
var _xp: Dictionary = {}
var _counts: Dictionary = {}
var _start_levels: Dictionary = {}
var _start_life: Dictionary = {}
var _gold := 0.0


func _init(started_at_: float, info_: Callable, level_of_: Callable, life_of_: Callable) -> void:
	started_at = started_at_
	info = info_
	level_of = level_of_
	life_of = life_of_
	for skill in DmContent.get_export("gameplay_gatheringRules", "SKILLS"):
		_start_levels[skill] = int(level_of.call(skill))
		_start_life[skill] = float(life_of.call(skill))


static func crossed_milestones(before: float, after: float) -> Array:
	var out: Array = []
	for m in MILESTONES:
		if before < m and after >= m:
			out.append(m)
	return out


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


## Fold one /api/gather reply in: {skill, items:[{itemId, qty}], xp, gold}.
func record(reply: Dictionary) -> void:
	var skill: String = String(reply["skill"])
	if not DmContent.get_export("gameplay_gatheringRules", "SKILLS").has(skill):
		return
	var qty := 0
	for g in reply.get("items", []):
		_items[g["itemId"]] = int(_items.get(g["itemId"], 0)) + int(g["qty"])
		qty += int(g["qty"])
	_xp[skill] = int(_xp.get(skill, 0)) + int(reply.get("xp", 0))
	_counts[skill] = int(_counts.get(skill, 0)) + qty
	_gold += float(reply.get("gold", 0))


func has_yield() -> bool:
	return not _items.is_empty() or _gold > 0.0


## {report, bests} or null when the session was too short or brought nothing back. `bests` = {skill: {items, xpPerHour}}.
func finish(now_ms: float, reason: String, bests: Dictionary = {}) -> Variant:
	var seconds := maxi(0, DmMath.js_round((now_ms - started_at) / 1000.0))
	if seconds < MIN_REPORT_SECONDS or not has_yield():
		return null
	var items: Array = []
	for id in _items:
		var m: Dictionary = info.call(id)
		items.append({"itemId": id, "name": m["name"], "rarity": m["rarity"], "qty": _items[id], "value": int(m["sell"]) * int(_items[id])})
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = RARITY_RANK[a["rarity"]]
		var rb: int = RARITY_RANK[b["rarity"]]
		if ra != rb:
			return ra > rb
		if a["value"] != b["value"]:
			return a["value"] > b["value"]
		return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)
	var best: Variant = items[0] if (not items.is_empty() and int(RARITY_RANK[items[0]["rarity"]]) > 0) else null
	var sk_defs: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")
	var skills: Array = []
	for skill in _xp:
		skills.append({"skill": skill, "name": sk_defs[skill]["name"], "xp": _xp[skill], "fromLevel": int(_start_levels.get(skill, level_of.call(skill))), "toLevel": int(level_of.call(skill)), "items": int(_counts.get(skill, 0))})
	var milestones: Array = []
	var records: Array = []
	var next_bests: Dictionary = bests.duplicate(true)
	for s in skills:
		var before: float = float(_start_life.get(s["skill"], 0))
		for m in crossed_milestones(before, before + float(s["items"])):
			milestones.append("%s %s finds" % [_thousands(int(m)), s["name"]])
		if s["toLevel"] > s["fromLevel"]:
			milestones.append("%s level %d" % [s["name"], s["toLevel"]])
		var xp_per_hour := DmMath.js_round((float(s["xp"]) / float(seconds)) * 3600.0)
		var prev: Variant = bests.get(s["skill"])
		if prev != null and int(s["items"]) > int(prev["items"]):
			records.append("Most %s finds in one session (was %s)" % [s["name"], _thousands(int(prev["items"]))])
		next_bests[s["skill"]] = {"items": maxi(int(prev["items"]) if prev != null else 0, int(s["items"])), "xpPerHour": maxi(int(prev["xpPerHour"]) if prev != null else 0, xp_per_hour)}
	var total := 0
	var worth := 0
	for i in items:
		total += int(i["qty"])
		worth += int(i["value"])
	return {"report": {"seconds": seconds, "reason": reason, "items": items, "totalItems": total, "goldValue": worth, "gold": _gold, "skills": skills, "best": best, "milestones": milestones, "records": records}, "bests": next_bests}

class_name DmContracts
extends RefCounted
## Port of server/rules/gameplay/contractRules.ts: the Sexton's daily delivery board. Deterministic from (characterId, UTC day, skill levels),
## so the server and the client agree. Server-authoritative for delivery/payout (contracts.cjs); the client may display the board.
## levels: {skill: level} (missing = 1).

const M := preload("res://rules/core/math.gd")
const Data := preload("res://rules/gathering/gather_data.gd")
const Rng := preload("res://rules/core/rng.gd")
const Labor := preload("res://rules/gathering/labor_rules.gd")

const CONTRACT_SLOTS := 3
const RELIC_PREMIUM := 2
const RELIC_CHANCE := 0.2
const SMELTED_ORDERS: Array = [["ingot_tin", 3], ["ingot_bronze", 8]]
const MOB_REAGENT_LEVELS: Array = [["reagent_grave_dust", 1], ["reagent_wraith_ectoplasm", 10], ["reagent_plague_bile", 38], ["reagent_cinder_ash", 52]]
const SKILL_ORDER: Array = ["woodcutting", "mining", "fishing", "gravedigging", "gardening", "alchemy", "salvaging"]
const HARD_REWARDS: Array = [
	{"minLevel": 60, "item": {"itemId": "gem_void_sapphire", "qty": 1}},
	{"minLevel": 30, "item": {"itemId": "gem_bone_opal", "qty": 1}},
	{"minLevel": 0, "item": {"itemId": "gem_grave_garnet", "qty": 1}},
]
const MEDIUM_REWARDS: Array = [{"itemId": "flask_hp_minor", "qty": 3}, {"itemId": "seed_mourning_moss", "qty": 2}]
const SLOT_QTY_MULT: Array = [1.0, 0.8, 0.6]


## UTC calendar day "YYYY-MM-DD" of an epoch-ms timestamp.
static func day_key(ms: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(floor(float(ms) / 1000.0)))
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]


## When the current board is replaced (next 00:00 UTC), epoch ms.
static func next_reset_ms(ms: int) -> int:
	return (int(floor(float(ms) / 86400000.0)) + 1) * 86400000


static func _day_ms(day: String) -> int:
	var p := day.split("-")
	var t := Time.get_unix_time_from_datetime_dict({"year": int(p[0]), "month": int(p[1]), "day": int(p[2]), "hour": 0, "minute": 0, "second": 0})
	return int(t) * 1000


static func hash_string(s: String) -> int:
	return Labor.hash_seed([s])


## Everything this character could plausibly hand in today, cheapest tier first.
## Candidate: {itemId, skill, level, processed, fixedQty?}.
static func candidates_for(levels: Dictionary) -> Array:
	var d := Data.get_data()
	var lvl := func(s: String) -> int: return maxi(1, int(levels.get(s, 1)))
	var seen: Dictionary = {}
	var out: Array = []
	var add := func(c: Dictionary) -> void:
		if seen.has(c["itemId"]):
			return
		seen[c["itemId"]] = true
		out.append(c)
	for so in SMELTED_ORDERS:
		if int(so[1]) <= lvl.call("mining"):
			add.call({"itemId": so[0], "skill": "mining", "level": so[1], "processed": true})
	for r in d["relic_orders"]:
		if int(r["level"]) <= lvl.call(r["skill"]):
			add.call({"itemId": r["itemId"], "skill": r["skill"], "level": r["level"], "processed": false, "fixedQty": r["qty"]})
	for n in d["nodes"]:
		if n["skill"] != "gardening" and int(n["level"]) <= lvl.call(n["skill"]):
			add.call({"itemId": n["item"], "skill": n["skill"], "level": n["level"], "processed": false})
	for row in d["processing_recipes"]:
		if str(row[4]).begins_with("tool_"):
			continue
		if int(row[3]) <= lvl.call(row[2]):
			add.call({"itemId": row[4], "skill": row[2], "level": row[3], "processed": true})
	for row in d["alchemy_recipes"]:
		if int(row[3]) <= lvl.call(row[2]):
			add.call({"itemId": row[4], "skill": row[2], "level": row[3], "processed": true})
	for row in d["reagent_recipes"]:
		if int(row[3]) <= lvl.call(row[2]):
			add.call({"itemId": row[4], "skill": row[2], "level": row[3], "processed": true})
	for mr in MOB_REAGENT_LEVELS:
		if int(mr[1]) <= lvl.call("alchemy") and d["mob_reagents"].has(mr[0]):
			add.call({"itemId": mr[0], "skill": "alchemy", "level": mr[1], "processed": true})
	for s in d["seeds"]:
		if s["kind"] == "herb" and int(s["level"]) <= lvl.call("gardening"):
			add.call({"itemId": s["harvest"], "skill": "gardening", "level": s["level"], "processed": true})
	out = _stable_sorted(out, func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["level"]) != int(b["level"]):
			return int(a["level"]) < int(b["level"])
		return String(a["itemId"]) < String(b["itemId"]))
	return out


# JS Array.sort is stable; Array.sort_custom is not. Total order here (unique ids) but keep it stable anyway.
static func _stable_sorted(arr: Array, less: Callable) -> Array:
	const S := preload("res://rules/inventory/stable_sort.gd")
	return S.sorted(arr, less)


## What the Sexton asks of this item: {skill, level, relicQty (int or null)} or {} if he never does.
static func order_info(item_id: String) -> Dictionary:
	var all: Dictionary = {}
	for k in SKILL_ORDER:
		all[k] = 99
	for c in candidates_for(all):
		if c["itemId"] == item_id:
			return {"skill": c["skill"], "level": c["level"], "relicQty": c.get("fixedQty", null)}
	return {}


## Today's board: [{slot, itemId, qty, skill, rewardGold, rewardItem (Dictionary or null)}].
static func generate_board(character_id: int, day: String, levels: Dictionary) -> Array:
	var rng := Rng.new(hash_string("%d:%s" % [character_id, day]))
	var all := candidates_for(levels)
	var relics: Array = []
	var pool: Array = []
	for c in all:
		if c.has("fixedQty"):
			relics.append(c)
		else:
			pool.append(c)
	var cands: Array = pool
	if pool.size() < CONTRACT_SLOTS:
		# TS filters by reference against a freshly built list, so every candidate of the empty-level list is appended.
		cands = pool + candidates_for({})
	var third := maxi(1, cands.size() / 3)
	var bands: Array = []
	var raw: Array = [cands.slice(0, third), cands.slice(third, third * 2), cands.slice(third * 2)]
	for i in 3:
		bands.append(raw[i] if raw[i].size() > 0 else cands.slice(i))
	var used: Dictionary = {}
	var board: Array = []
	for slot in CONTRACT_SLOTS:
		var band: Array = []
		for c in bands[slot]:
			if not used.has(c["itemId"]):
				band.append(c)
		var from: Array = band
		if band.is_empty():
			from = []
			for c in cands:
				if not used.has(c["itemId"]):
					from.append(c)
		var idx := int(floor(rng.next() * float(from.size())))
		var pick: Dictionary = from[idx] if idx < from.size() else cands[slot % cands.size()]
		var relic_roll := rng.next()
		var relic_idx := int(floor(rng.next() * float(relics.size())))
		if slot == 2 and relic_roll < RELIC_CHANCE and relic_idx < relics.size():
			pick = relics[relic_idx]
		used[pick["itemId"]] = true
		var qty := M.js_round(minf(80.0, maxf(12.0, 70.0 - float(pick["level"]) * 0.5)) * float(SLOT_QTY_MULT[slot]))
		if pick["processed"]:
			qty = maxi(6, M.js_round(float(qty) * 0.4))
		qty = maxi(4, qty + int(floor(rng.next() * 5.0)) - 2)
		if pick.has("fixedQty"):
			qty = int(pick["fixedQty"])
		var sell: int = int(Data.item_meta(pick["itemId"])["sell"])
		var mult: float = float(RELIC_PREMIUM) if pick.has("fixedQty") else 1.6
		var reward_gold := M.js_round(float(qty) * float(sell) * mult + 20.0 * float(slot + 1))
		var reward_item: Variant = null
		if slot == 2:
			if pick.has("fixedQty"):
				reward_item = HARD_REWARDS[HARD_REWARDS.size() - 1]["item"].duplicate()
			else:
				for r in HARD_REWARDS:
					if int(pick["level"]) >= int(r["minLevel"]):
						reward_item = r["item"].duplicate()
						break
		elif slot == 1 and rng.next() < 0.35:
			reward_item = MEDIUM_REWARDS[int(floor(rng.next() * float(MEDIUM_REWARDS.size())))].duplicate()
		board.append({"slot": slot, "itemId": pick["itemId"], "qty": qty, "skill": pick["skill"], "rewardGold": reward_gold, "rewardItem": reward_item})
	return board


## Paid once when the last order is handed in: {gold, item}.
static func bonus_for(board: Array) -> Dictionary:
	var total := 0
	for c in board:
		total += int(c["rewardGold"])
	return {"gold": M.js_round(float(total) * 0.5), "item": {"itemId": "gem_grave_garnet", "qty": 1}}


## Consecutive days (ending today or yesterday) with at least one order handed in.
static func streak_of(done_days: Array, today: String) -> int:
	var days: Dictionary = {}
	for d in done_days:
		days[d] = true
	var cursor := today if days.has(today) else day_key(_day_ms(today) - 86400000)
	var n := 0
	while days.has(cursor):
		n += 1
		cursor = day_key(_day_ms(cursor) - 86400000)
	return n

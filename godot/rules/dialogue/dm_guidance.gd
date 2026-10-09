class_name DmGuidance
extends RefCounted
## Port of archive/legacy-web:src/gameplay/guidance.ts: gentle guidance as pure selectors over a plain snapshot of the character. The same suggestion list feeds the HUD
## "Next" line, the minimap ping and what the Prior, the Sexton and the Apothecary say when asked "where next?". Nothing here can fail or force anything.
##
## GuidanceState is a Dictionary (the TS GuidanceState, same key names):
##   {level, area, ascension, canAscend, ashesOnAscend, shards, unlocked: [area ids], areaKills: {area: n}, unlockMult, bossesBeaten: [boss ids],
##    prelateThisRun, totalKills, skills: {profession_id: level}, bagUsed, bagSize, dust, labor: null | {unlocked, assigned, ready}, contracts: null | {open, total}}
## A Suggestion is {id, kind, topic, priority, text, data, place?, target?: {x, z}, pingInPlace?, quiet?}.

const LABOR_READY_MS := 1800000.0
const BAG_FULL_FRACTION := 0.85
const GRAVE_DUST_FOR_TONIC := 4
const SIDE_AREAS: Array[String] = ["warren", "coliseum", "depths"]
const TOPIC_OF := {"prior": "route", "sexton": "acre", "apothecary": "brew"}
const NPC_IDS: Array[String] = ["prior", "sexton", "apothecary"]


static func area(id: String) -> Dictionary:
	return DmContent.area(id)


static func boss(id: String) -> Dictionary:
	return DmContent.boss(id)


static func boss_ids() -> Array:
	return DmContent.get_export("bosses", "BOSS_IDS")


static func _f(v: Variant, d: float = 0.0) -> float:
	return float(DmCombatData.nn(v, d))


## baseState(over)
static func base_state(over: Dictionary = {}) -> Dictionary:
	var s := {
		"level": 1, "area": "chapterhouse", "ascension": 0, "canAscend": false, "ashesOnAscend": 0, "shards": 0, "unlocked": [], "areaKills": {}, "unlockMult": 1,
		"bossesBeaten": [], "prelateThisRun": false, "totalKills": 0, "skills": {}, "bagUsed": 0, "bagSize": 48, "dust": 0, "labor": null, "contracts": null,
	}
	for k in over:
		s[k] = over[k]
	return s


## summarizeLabor(view): view = {slots: [{unlocked, nodeType, capped, elapsedMs}]} (the laborers response).
static func summarize_labor(v: Dictionary) -> Dictionary:
	var unlocked: Array = []
	for s: Dictionary in v["slots"]:
		if DmCombatData.truthy(s.get("unlocked")):
			unlocked.append(s)
	var assigned: Array = []
	for s: Dictionary in unlocked:
		if DmCombatData.truthy(s.get("nodeType")):
			assigned.append(s)
	var ready := 0
	for s: Dictionary in assigned:
		if DmCombatData.truthy(s.get("capped")) or _f(s.get("elapsedMs")) >= LABOR_READY_MS:
			ready += 1
	return {"unlocked": unlocked.size(), "assigned": assigned.size(), "ready": ready}


## summarizeContracts(board): board = {contracts: [{done}]}.
static func summarize_contracts(b: Dictionary) -> Dictionary:
	var open := 0
	for c: Dictionary in b["contracts"]:
		if not DmCombatData.truthy(c.get("done")):
			open += 1
	return {"open": open, "total": (b["contracts"] as Array).size()}


# --- Seals and bosses ------------------------------------------------------------------------------------------------------------

static func is_open(s: Dictionary, a: String) -> bool:
	return area(a).get("unlock") == null or (s["unlocked"] as Array).has(a)


static func kills_in(s: Dictionary, a: String) -> float:
	return _f((s["areaKills"] as Dictionary).get(a), 0.0)


static func seal_need(s: Dictionary, a: String) -> float:
	var kills: float = _f((area(a).get("unlock") as Dictionary).get("kills") if area(a).get("unlock") != null else 0.0)
	return maxf(1.0, float(DmMath.js_round(kills * _f(s.get("unlockMult"), 1.0))))


## The door a seal opens, by its last word: "Ossuary", "Warren", "Nave"...
static func seal_door_name(a: String) -> String:
	var parts := String(area(a)["name"]).split(" ")
	return parts[parts.size() - 1]


static func format_seal_progress(a: String, kills: float, need: float) -> String:
	return "%s seal: %s/%s kills" % [seal_door_name(a), DmJsFmt.num_str(minf(kills, need)), DmJsFmt.num_str(need)]


## Every seal you can already work on (its feeding hall is open), main road first: [{area, from, kills, need, side}].
static func pending_seals(s: Dictionary) -> Array:
	var out: Array = []
	for a: String in DmContent.area_order():
		var u: Variant = area(a).get("unlock")
		if u == null or is_open(s, a) or not is_open(s, String(u["area"])):
			continue
		var need := seal_need(s, a)
		out.append({"area": a, "from": u["area"], "kills": minf(kills_in(s, String(u["area"])), need), "need": need, "side": SIDE_AREAS.has(a)})
	return DmStableSort.sorted(out, func(x: Dictionary, y: Dictionary) -> bool: return int(x["side"]) < int(y["side"]))


static func boss_beaten(s: Dictionary, id: String) -> bool:
	return bool(s["prelateThisRun"]) if id == "prelate" else (s["bossesBeaten"] as Array).has(id)


## Bosses whose hall is open and who have not fallen, in the road's order.
static func bosses_waiting(s: Dictionary) -> Array:
	var out: Array = []
	for id in boss_ids():
		if is_open(s, String(boss(id)["area"])) and not boss_beaten(s, id):
			out.append(id)
	return out


static func lower_the(name: String) -> String:
	return "the " + name.substr(4) if name.begins_with("The ") else name


## An interactable's world point, or null.
static func spot(id: String) -> Variant:
	for a: String in DmContent.area_order():
		for it: Dictionary in area(a).get("interactables", []):
			if it["id"] == id:
				return {"x": it["x"], "z": it["z"]}
	return null


static func area_centre(a: String) -> Dictionary:
	var r: Dictionary = area(a)["rect"]
	return {"x": (float(r["x0"]) + float(r["x1"])) / 2.0, "z": (float(r["z0"]) + float(r["z1"])) / 2.0}


static func npc_interactable_id(npc: String) -> String:
	return "npc_%s" % npc


# --- Suggestions -------------------------------------------------------------------------------------------------------------------

static func _add(out: Array, x: Dictionary) -> void:
	var d := {"data": {}}
	for k in x:
		if x[k] != null:
			d[k] = x[k]
	out.append(d)


static func _lvl(a: String) -> float:
	return float(area(a)["level"])


## suggestions(s), best first.
static func suggestions(s: Dictionary) -> Array:
	var out: Array = []
	var total_kills := _f(s.get("totalKills"))
	# --- The road (the Prior) ---
	if total_kills < 10.0 and _f(s.get("ascension")) == 0.0 and s["area"] != "graves":
		_add(out, {"id": "first-steps", "kind": "first-steps", "topic": "route", "priority": 95,
			"text": "Walk east to the Chapterhouse, then north to the Hollow Graves" if s["area"] == "acre" else "Walk north into the Hollow Graves and fight your first dead",
			"place": "graves", "target": area_centre("graves"), "data": {"area": area("graves")["name"]}})
	if bool(s["canAscend"]):
		_add(out, {"id": "ascend", "kind": "ascend", "topic": "route", "priority": 72,
			"text": "The Altar of Ascension is ready: +%s Ashes when you choose" % DmJsFmt.num_str(_f(s["ashesOnAscend"])),
			"place": "chapterhouse", "target": spot("altar"), "pingInPlace": true, "data": {"ashes": s["ashesOnAscend"]}})
	var waiting := bosses_waiting(s)
	var ready: Variant = null
	for id in waiting:
		if _f(s["shards"]) >= _f(boss(id)["shards"]):
			ready = id
			break
	if ready != null:
		var b := boss(ready)
		_add(out, {"id": "boss-ready:%s" % ready, "kind": "boss-ready", "topic": "route", "priority": 86,
			"text": "%s waits at %s — %s soul shards" % [b["name"], lower_the(b["summonLabel"]), DmJsFmt.num_str(float(b["shards"]))],
			"place": b["area"], "target": spot(String(b["summonId"])), "pingInPlace": true,
			"data": {"boss": b["name"], "at": lower_the(b["summonLabel"]), "shards": b["shards"], "area": lower_the(String(area(b["area"])["name"]))}})
	var seals := pending_seals(s)
	var main: Variant = null
	for x: Dictionary in seals:
		if not x["side"]:
			main = x
			break
	if main != null:
		var prog := format_seal_progress(main["area"], main["kills"], main["need"])
		_add(out, {"id": "seal:%s" % main["area"], "kind": "seal", "topic": "route", "priority": 60, "text": prog,
			"place": main["from"], "target": area_centre(main["from"]),
			"data": {"seal": prog, "from": lower_the(String(area(main["from"])["name"])), "to": lower_the(String(area(main["area"])["name"])),
				"kills": main["kills"], "need": main["need"], "level": _lvl(main["area"])}})
	var short: Variant = null
	for id in waiting:
		if _f(s["shards"]) < _f(boss(id)["shards"]):
			short = id
			break
	if short != null:
		var b2 := boss(short)
		_add(out, {"id": "boss-short:%s" % short, "kind": "boss-short", "topic": "route", "priority": 50,
			"text": "Soul shards for %s: %s / %s (elites carry them)" % [b2["name"], DmJsFmt.num_str(_f(s["shards"])), DmJsFmt.num_str(float(b2["shards"]))],
			"place": b2["area"],
			"data": {"boss": b2["name"], "at": lower_the(b2["summonLabel"]), "shards": b2["shards"], "have": s["shards"], "area": lower_the(String(area(b2["area"])["name"]))}})
	var hunt: Variant = null
	var order: Array = DmContent.area_order().duplicate()
	order.reverse()
	for a: String in order:
		if not bool(area(a).get("safe", false)) and is_open(s, a) and not SIDE_AREAS.has(a):
			hunt = a
			break
	if hunt != null and main == null:
		var clear := waiting.is_empty()
		var ar := area(hunt)
		_add(out, {"id": "hunt", "kind": "hunt", "topic": "route", "priority": 10,
			"text": "%sHunt in %s: level %s%s dead" % ["Every seal is broken and every king buried. " if clear else "", lower_the(String(ar["name"])), DmJsFmt.num_str(float(ar["level"])), "+" if ar.get("scaling") != null else ""],
			"place": hunt, "target": area_centre(hunt), "data": {"area": lower_the(String(ar["name"])), "level": ar["level"], "clear": 1 if clear else 0}})
	# --- The Acre (the Sexton) ---
	var bag_size := _f(s["bagSize"])
	var bag_used := _f(s["bagUsed"])
	if bag_size > 0.0 and bag_used / bag_size >= BAG_FULL_FRACTION:
		_add(out, {"id": "bag-full", "kind": "bag-full", "topic": "acre", "priority": 88, "text": "Your bag is nearly full: salvage or stash spare gear (Acre, V)",
			"place": "acre", "target": spot("bone_grinder"), "pingInPlace": true, "data": {"used": s["bagUsed"], "size": s["bagSize"]}})
	var labor: Variant = s.get("labor")
	var contracts: Variant = s.get("contracts")
	if labor != null and _f(labor["ready"]) > 0.0:
		_add(out, {"id": "labor-ready", "kind": "labor-ready", "topic": "acre", "priority": 70,
			"text": "A laborer’s work is ready: collect it in the Acre (H)" if _f(labor["ready"]) == 1.0 else "Your laborers are ready in the Acre (H)",
			"place": "acre", "target": spot(npc_interactable_id("sexton")), "data": {"ready": labor["ready"]}})
	if contracts != null and _f(contracts["open"]) > 0.0:
		var o := _f(contracts["open"])
		_add(out, {"id": "contracts", "kind": "contracts", "topic": "acre", "priority": 40,
			"text": "%s Sexton’s Contract%s for delivery (O)" % [DmJsFmt.num_str(o), " waits" if o == 1.0 else "s wait"], "data": {"open": contracts["open"], "total": contracts["total"]}})
	if labor != null and _f(labor["unlocked"]) > _f(labor["assigned"]):
		_add(out, {"id": "labor-idle", "kind": "labor-idle", "topic": "acre", "priority": 35, "text": "A Grave Laborer stands idle: give them a post (H)",
			"place": "acre", "data": {"idle": _f(labor["unlocked"]) - _f(labor["assigned"])}})
	var skills: Dictionary = s["skills"]
	var all_one := true
	for k in ["woodcutting", "mining", "fishing", "gravedigging"]:
		if _f(skills.get(k), 1.0) > 1.0:
			all_one = false
	if all_one and not (labor != null and _f(labor["assigned"]) > 0.0):
		_add(out, {"id": "gather-intro", "kind": "gather-intro", "topic": "acre", "priority": 42,
			"text": "Gathering in the Sexton’s Acre trains skills and supplies your crafting (P)", "place": "acre", "target": area_centre("acre"), "data": {}})
	# --- Brewing (the Apothecary) ---
	var alchemy := _f(skills.get("alchemy"), 1.0)
	var dust := _f(s["dust"])
	if dust >= GRAVE_DUST_FOR_TONIC and alchemy < 5.0:
		_add(out, {"id": "brew-dust", "kind": "brew-dust", "topic": "brew", "priority": 62 if s["area"] == "alchemist_wing" else 45,
			"text": "You carry %s Grave Dust: brew a tonic at the Great Cauldron in the Alchemist’s Wing" % DmJsFmt.num_str(dust),
			"place": "alchemist_wing", "target": spot("wing_cauldron"), "pingInPlace": true, "data": {"dust": s["dust"]}})
	elif alchemy <= 1.0 and dust < GRAVE_DUST_FOR_TONIC:
		_add(out, {"id": "brew-first", "kind": "brew-first", "topic": "brew", "priority": 12,
			"text": "Four Grave Dust brew your first tonic; the dead of the Graves drop it", "quiet": true, "data": {"dust": s["dust"]}})
	return DmStableSort.sorted(out, func(a: Dictionary, b: Dictionary) -> bool: return float(a["priority"]) > float(b["priority"]))


## The line for the HUD: the best non-quiet suggestion that the player has not dismissed (null for none). `dismissed` = a suggestion id or "".
static func next_suggestion(s: Dictionary, dismissed: String = "") -> Variant:
	for x: Dictionary in suggestions(s):
		if not x.get("quiet", false) and x["id"] != dismissed:
			return x
	return null


## The best suggestion on one person's subject.
static func suggestion_for(npc: String, s: Dictionary) -> Variant:
	for x: Dictionary in suggestions(s):
		if x["topic"] == TOPIC_OF[npc]:
			return x
	return null


# --- "Something new to say" ------------------------------------------------------------------------------------------------------------

## What each person would like to tell you now: [{key, persist}].
static func news_for(npc: String, s: Dictionary) -> Array:
	var out: Array = []
	var p := func(key: String) -> void: out.append({"key": key, "persist": true})
	var t := func(key: String) -> void: out.append({"key": key, "persist": false})
	var asc := DmJsFmt.num_str(_f(s["ascension"]))
	var skills: Dictionary = s["skills"]
	if npc == "prior":
		if bool(s["canAscend"]):
			p.call("ascend:ready:%s" % asc)
		for id in boss_ids():
			if boss_beaten(s, id):
				p.call("boss:%s:%s" % [id, asc if id == "prelate" else "0"])
		for a: String in DmContent.area_order():
			if area(a).get("unlock") != null and (s["unlocked"] as Array).has(a):
				p.call("seal:%s:0" % a)
		if _f(s["ascension"]) > 0.0:
			p.call("rank:%s" % asc)
	elif npc == "sexton":
		var labor: Variant = s.get("labor")
		var contracts: Variant = s.get("contracts")
		if labor != null and _f(labor["ready"]) > 0.0:
			t.call("labor:ready")
		if _f(s["bagSize"]) > 0.0 and _f(s["bagUsed"]) / _f(s["bagSize"]) >= BAG_FULL_FRACTION:
			t.call("bag:full")
		if contracts != null and _f(contracts["open"]) > 0.0:
			t.call("contracts:open")
	else:
		if _f(s["dust"]) >= GRAVE_DUST_FOR_TONIC and _f(skills.get("alchemy"), 1.0) < 5.0:
			p.call("dust:first")
		if _f(skills.get("alchemy"), 1.0) >= 10.0:
			p.call("alchemy:10")
		if is_open(s, "cloister"):
			p.call("reagent:cloister")
		if is_open(s, "pyre"):
			p.call("reagent:pyre")
		if is_open(s, "fen"):
			p.call("reagent:fen")
	return out


## readTrophies: the boss ids stored as JSON text under bossTrophyKey(character id) (only known boss ids survive).
static func boss_trophy_key(character_id: float) -> String:
	return "dm_boss_trophies_v1:%s" % DmJsFmt.num_str(character_id)


static func parse_trophies(raw: Variant) -> Array:
	var got: Variant = []
	if raw != null:
		var j := JSON.new()
		got = j.data if j.parse(String(raw)) == OK else null
	var out: Array = []
	if got is Array:
		for x in got:
			if x is String and boss_ids().has(x):
				out.append(x)
	return out

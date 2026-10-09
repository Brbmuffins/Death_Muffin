class_name DmOfflineLoadout
extends RefCounted
## Port of server/rules/gameplay/loadoutRules.ts (loadout presets: validation + applying the gear half to inventory rows), used by the offline
## backend exactly as the web mock / server loadouts.cjs use it. Rows are Dictionaries {slot_index, item_id, quantity, equipped?, equipped_slot?, instance_id?}.

const MAX_PRESETS := 6
const NAME_MAX := 24
const BAG_SLOTS := 48
const MAIN_HAND_SLOT := 105
const OFF_HAND_SLOT := 106

static var _id_re: RegEx = RegEx.create_from_string("^[a-z0-9_]{1,64}$")
static var _ctl_re: RegEx = RegEx.create_from_string("[\\x00-\\x1f\\x7f<>]")
static var _ws_re: RegEx = RegEx.create_from_string("\\s+")


static func _is_id(x: Variant) -> bool:
	return x is String and _id_re.search(String(x)) != null


## null (JS) = nothing worn; {} marks "unreadable" with a sentinel key.
static func _clean_gear(raw: Variant) -> Variant:
	if raw == null:
		return null
	if not (raw is Dictionary):
		return {"__bad": true}
	var g: Dictionary = raw
	if not _is_id(g.get("itemId")):
		return {"__bad": true}
	var inst: Variant = g.get("instanceId")
	if inst != null and not ((inst is int or (inst is float and inst == floorf(inst))) and inst > 0):
		return {"__bad": true}
	return {"itemId": g["itemId"], "instanceId": null if inst == null else int(inst)}


static func clean_name(raw: Variant) -> Variant:
	if not (raw is String):
		return null
	var s: String = _ctl_re.sub(String(raw), "", true)
	s = _ws_re.sub(s, " ", true).strip_edges()
	s = s.left(NAME_MAX).strip_edges()
	return null if s.is_empty() else s


## {ok:true, preset} or {ok:false, error}.
static func normalize_preset(raw: Variant) -> Dictionary:
	if raw == null or not (raw is Dictionary or raw is Array):
		return {"ok": false, "error": "That loadout is not readable."}
	var r: Dictionary = raw if raw is Dictionary else {}
	var name: Variant = clean_name(r.get("name"))
	if name == null:
		return {"ok": false, "error": "Give the loadout a name."}
	var rites: Variant = r.get("rites")
	if not (rites is Dictionary) or not _is_id(rites.get("primary")) or not (rites.get("keys") is Array) or rites["keys"].size() != 5 or not rites["keys"].all(func(k): return _is_id(k)):
		return {"ok": false, "error": "A loadout holds a primary and five rites."}
	var seen: Dictionary = {}
	for k in rites["keys"]:
		seen[k] = true
	if seen.size() != 5:
		return {"ok": false, "error": "A rite can sit on one key only."}
	var runes: Dictionary = {}
	var rr: Variant = r.get("runes")
	if rr != null:
		if not (rr is Dictionary):
			return {"ok": false, "error": "The runes are not readable."}
		for rite in rr:
			var id: Variant = rr[rite]
			if id == null:
				continue
			if not DmRunes.is_rune_rite(rite) or not (id is String) or not DmRunes.is_rune_id(id) or not DmRunes.rune_fits(id, rite):
				return {"ok": false, "error": "A rune in that loadout does not fit its rite."}
			runes[rite] = id
	var weapon: Variant = _clean_gear(r.get("weapon"))
	var offhand: Variant = _clean_gear(r.get("offhand"))
	if (weapon is Dictionary and weapon.has("__bad")) or (offhand is Dictionary and offhand.has("__bad")):
		return {"ok": false, "error": "The weapon in that loadout is not readable."}
	return {"ok": true, "preset": {"name": name, "rites": {"primary": rites["primary"], "keys": rites["keys"].duplicate()}, "runes": runes, "weapon": weapon, "offhand": offhand}}


## Mutable state for one apply (GDScript lambdas capture by value, so the steps are methods).
class Applier:
	extends RefCounted
	var rows: Array = []
	var info: Callable
	var report := {"applied": [], "skipped": [], "unchanged": true}

	func in_bag(r: Dictionary) -> bool:
		return int(r["slot_index"]) >= 0 and int(r["slot_index"]) < DmOfflineLoadout.BAG_SLOTS

	func inst_of(r: Dictionary) -> Variant:
		return r.get("instance_id")

	func same(a: Variant, b: Variant) -> bool:
		return a == b

	func free_slots() -> Array:
		var used: Dictionary = {}
		for r in rows:
			if in_bag(r):
				used[int(r["slot_index"])] = true
		var out: Array = []
		for i in DmOfflineLoadout.BAG_SLOTS:
			if not used.has(i):
				out.append(i)
		return out

	func give_back(item_id: String) -> bool:
		var cap: int = int(info.call(item_id)["maxStack"])
		for r in rows:
			if in_bag(r) and r["item_id"] == item_id and not r.get("equipped", 0) and inst_of(r) == null and int(r["quantity"]) < cap:
				r["quantity"] = int(r["quantity"]) + 1
				return true
		var f := free_slots()
		if f.is_empty():
			return false
		rows.append({"slot_index": f[0], "item_id": item_id, "quantity": 1, "equipped": 0, "equipped_slot": null, "instance_id": null})
		return true

	func snapshot() -> Array:
		var out: Array = []
		for r in rows:
			out.append(r.duplicate())
		return out

	func find_at(slot: int) -> Variant:
		for r in rows:
			if int(r["slot_index"]) == slot:
				return r
		return null

	func hand(part: String, want: Variant, equip_slot: String, reserved: int) -> void:
		if want == null:
			return
		var worn: Variant = find_at(reserved)
		if worn != null and worn["item_id"] == want["itemId"] and same(inst_of(worn), want["instanceId"]):
			return
		var from: Variant = null
		for r in rows:
			if in_bag(r) and not r.get("equipped", 0) and r["item_id"] == want["itemId"] and same(inst_of(r), want["instanceId"]):
				from = r
				break
		if from == null:
			report["skipped"].append({"part": part, "rite": null, "itemId": want["itemId"], "reason": "missing"})
			return
		var meta: Dictionary = info.call(want["itemId"])
		if meta["equipSlot"] != equip_slot:
			report["skipped"].append({"part": part, "rite": null, "itemId": want["itemId"], "reason": "wrong_slot"})
			return
		var snap := snapshot()
		var reason := ""
		var displaced: Array = []
		for r in rows:
			if is_same(r, from):
				continue
			var si := int(r["slot_index"])
			if si == reserved or (bool(meta["twoHanded"]) and si == DmOfflineLoadout.OFF_HAND_SLOT) or (equip_slot == "off_hand" and si == DmOfflineLoadout.MAIN_HAND_SLOT and bool(info.call(r["item_id"])["twoHanded"])):
				displaced.append(r)
		var bag_slot := int(from["slot_index"])
		var free := free_slots()
		if displaced.size() > free.size() + 1:
			reason = "no_room"
		else:
			from["slot_index"] = reserved
			from["equipped"] = 1
			from["equipped_slot"] = equip_slot
			for i in displaced.size():
				displaced[i]["slot_index"] = bag_slot if i == 0 else free[i - 1]
				displaced[i]["equipped"] = 0
				displaced[i]["equipped_slot"] = null
		if reason != "":
			rows = snap
			report["skipped"].append({"part": part, "rite": null, "itemId": want["itemId"], "reason": reason})
			return
		report["applied"].append({"part": part, "rite": null, "itemId": want["itemId"]})
		report["unchanged"] = false

	func rune(rite: String, want: Variant) -> void:
		var socket := DmRunes.rune_slot_index(rite)
		var current: Variant = find_at(socket)
		var cur_id: Variant = null if current == null else current["item_id"]
		if cur_id == want:
			return
		if want != null and not DmRunes.rune_fits(want, rite):
			report["skipped"].append({"part": "rune", "rite": rite, "itemId": want, "reason": "wrong_slot"})
			return
		var snap := snapshot()
		var reason := ""
		if want != null:
			var from: Variant = null
			for r in rows:
				if in_bag(r) and not r.get("equipped", 0) and r["item_id"] == want and inst_of(r) == null and int(r["quantity"]) > 0:
					from = r
					break
			if from == null:
				reason = "missing"
			elif int(from["quantity"]) > 1:
				from["quantity"] = int(from["quantity"]) - 1
			else:
				rows = rows.filter(func(r): return not is_same(r, from))
		if reason == "" and current != null:
			rows = rows.filter(func(r): return not is_same(r, current))
			if not give_back(current["item_id"]):
				reason = "no_room"
		if reason == "" and want != null:
			rows.append({"slot_index": socket, "item_id": want, "quantity": 1, "equipped": 1, "equipped_slot": "rune_" + rite, "instance_id": null})
		if reason != "":
			rows = snap
			report["skipped"].append({"part": "rune", "rite": rite, "itemId": want, "reason": reason})
			return
		report["applied"].append({"part": "rune", "rite": rite, "itemId": want})
		report["unchanged"] = false


## Apply the gear half of a preset to the rows (pure: the input is not touched). info(item_id) -> {maxStack, equipSlot (String or null), twoHanded}.
## Returns {rows, report}.
static func apply_loadout(input: Array, info: Callable, preset: Dictionary) -> Dictionary:
	var a := Applier.new()
	a.info = info
	for r in input:
		a.rows.append(r.duplicate())
	a.hand("weapon", preset.get("weapon"), "main_hand", MAIN_HAND_SLOT)
	a.hand("offhand", preset.get("offhand"), "off_hand", OFF_HAND_SLOT)
	var runes: Dictionary = preset.get("runes", {})
	for rite in DmRunes.rites():
		a.rune(rite, runes.get(rite))
	a.rows = DmStableSort.sorted(a.rows, func(x, y): return int(x["slot_index"]) < int(y["slot_index"]))
	return {"rows": a.rows, "report": a.report}

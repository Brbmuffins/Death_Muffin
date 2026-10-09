class_name DmRites
extends RefCounted
## Port of archive/legacy-web:src/gameplay/loadout.ts: the Grimoire loadout (primary + five rites on keys 1-5) and the "seen" set, per character, persisted through a
## DmCounselStore-like object (dm_loadout_v2_<id>, dm_rites_seen_v1_<id>). A kit is DmAbilities.kit_for(family).

const SLOTS := 5

var kit: Dictionary
var character_id := 0
var level := 1
var primary := ""
var keys: Array = []
var seen: Dictionary = {}
var _store: Object


static func assignable(kit_: Dictionary) -> Array:
	var out: Array = []
	for id in (kit_["grimoire"] as Array) + [kit_["rmb"]]:
		if not out.has(id):
			out.append(id)
	return out


static func sanitize_loadout(raw: Variant, lvl: float, kit_: Dictionary) -> Array:
	var available := assignable(kit_)
	var defaults: Array = (kit_["defaultLoadout"] as Array) + [kit_["rmb"]]
	var usable := func(id: Variant) -> bool:
		return id is String and available.has(id) and DmAbilities.unlock_level(id) <= lvl
	var picked: Array = []
	for i in SLOTS:
		var id: Variant = raw[i] if raw is Array and i < raw.size() else null
		picked.append(id if usable.call(id) else null)
	for i in SLOTS:
		if picked[i] != null and picked.find(picked[i]) != i:
			picked[i] = null
	for i in SLOTS:
		if picked[i] != null:
			continue
		var fb: Variant = null
		if i < defaults.size() and not picked.has(defaults[i]):
			fb = defaults[i]
		if fb == null:
			for g in available:
				if usable.call(g) and not picked.has(g):
					fb = g
					break
		if fb == null:
			for g in available:
				if not picked.has(g):
					fb = g
					break
		picked[i] = fb
	return picked


static func sanitize_primary(raw: Variant, lvl: float, kit_: Dictionary) -> String:
	if raw is String and (kit_["primaries"] as Array).has(raw) and DmAbilities.unlock_level(raw) <= lvl:
		return raw
	return String(kit_["defaultPrimary"])


static func assign(loadout: Array, slot: int, id: String) -> Array:
	var next := loadout.duplicate()
	var from := next.find(id)
	if from == slot:
		return next
	if from >= 0:
		next[from] = next[slot]
	next[slot] = id
	return next


## The swap control is hidden until a level-gated Grimoire rite is learned (firstHourRules.swapReady).
static func swap_ready(grimoire: Array, lvl: float) -> bool:
	for id in grimoire:
		var u := DmAbilities.unlock_level(id)
		if u > 1 and lvl >= u:
			return true
	return false


func _init(character_id_: int, kit_: Dictionary, level_: float, store: Object = null) -> void:
	character_id = character_id_
	kit = kit_
	_store = store
	level = int(level_)
	var raw: Variant = null
	if _store != null and str(_store.get_item("dm_loadout_v2_%d" % character_id)) != "":
		raw = DmUiConfig.parse(_store.get_item("dm_loadout_v2_%d" % character_id))
	if raw is Dictionary:
		primary = sanitize_primary(raw.get("primary"), level_, kit)
		keys = sanitize_loadout(raw.get("keys"), level_, kit)
	else:
		primary = String(kit["defaultPrimary"])
		keys = sanitize_loadout(null, level_, kit)
	var sraw: Variant = null
	if _store != null and str(_store.get_item("dm_rites_seen_v1_%d" % character_id)) != "":
		sraw = DmUiConfig.parse(_store.get_item("dm_rites_seen_v1_%d" % character_id))
	if sraw is Array:
		for x in sraw:
			if x is String:
				seen[x] = true
	for id in assignable(kit) + (kit["primaries"] as Array):
		if DmAbilities.unlock_level(id) <= 1:
			seen[id] = true
	seen[primary] = true
	for id in keys:
		if DmAbilities.unlock_level(id) <= 1:
			seen[id] = true


func set_level(l: float) -> void:
	level = int(l)


func save() -> void:
	if _store != null:
		_store.set_item("dm_loadout_v2_%d" % character_id, JSON.stringify({"primary": primary, "keys": keys}))


func mark_seen(ids: Array) -> void:
	var changed := false
	for id in ids:
		if not seen.has(id):
			seen[id] = true
			changed = true
	if changed and _store != null:
		_store.set_item("dm_rites_seen_v1_%d" % character_id, JSON.stringify(seen.keys()))


func unseen() -> Array:
	var out: Array = []
	for id in (kit["primaries"] as Array) + assignable(kit):
		if DmAbilities.unlock_level(id) <= level and not seen.has(id) and not out.has(id):
			out.append(id)
	return out


func hotbar(signature: String) -> Array:
	return keys + [signature]


## Grimoire: put a rite on a slot (swap if it sat elsewhere). Returns true when something changed.
func set_rite(slot: int, id: String) -> bool:
	if slot < 0 or slot >= SLOTS or not assignable(kit).has(id) or level < DmAbilities.unlock_level(id) or keys[slot] == id:
		return false
	keys = assign(keys, slot, id)
	save()
	mark_seen([id])
	return true


func set_primary(id: String) -> bool:
	if level < DmAbilities.unlock_level(id) or primary == id:
		return false
	primary = id
	save()
	mark_seen([id])
	return true


## applyRitesPreset: returns lines about rites not learned yet.
func apply_preset(rites: Dictionary) -> Array:
	var ks := sanitize_loadout(rites.get("keys"), level, kit)
	var pr := sanitize_primary(rites.get("primary"), level, kit)
	var lines: Array = []
	var lost: Array = []
	for id in [rites.get("primary")] + (rites.get("keys", []) as Array):
		if not (ks.has(id) or id == pr) and DmAbilities.defs().has(id):
			lost.append(id)
	if not lost.is_empty():
		var names: Array = lost.map(func(i: String) -> String: return String(DmAbilities.def(i)["name"]))
		lines.append("%s %s not learned yet, so other rites fill %s." % [", ".join(names), "are" if lost.size() > 1 else "is", "those keys" if lost.size() > 1 else "that key"])
	primary = pr
	keys = ks
	save()
	mark_seen([pr] + ks)
	return lines

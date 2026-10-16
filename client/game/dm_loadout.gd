class_name DmLoadout
extends RefCounted
## Port of archive/legacy-web:src/gameplay/loadout.ts: the Grimoire loadout (left-click primary + five rites on keys 1-5), a per-character preference kept in a
## local JSON store (the stand-in for browser storage). `kit` = DmAbilities.kit_for(family) (keys: grimoire, rmb, defaultLoadout,
## primaries, defaultPrimary, signatures, hotbar).

const SLOTS := 5
const FILE := "user://dm_loadout_v2_%d.json"
const SEEN_FILE := "user://dm_rites_seen_v1_%d.json"


static func assignable_rites(kit: Dictionary) -> Array:
	var out: Array = []
	for id in kit["grimoire"] + [kit["rmb"]]:
		if not out.has(id):
			out.append(id)
	return out


static func sanitize_loadout(raw: Variant, level: float, kit: Dictionary) -> Array:
	var available := assignable_rites(kit)
	var defaults: Array = (kit["defaultLoadout"] as Array).duplicate()
	defaults.append(kit["rmb"])
	var picked: Array = []
	for i in SLOTS:
		var id: Variant = raw[i] if raw is Array and i < (raw as Array).size() else null
		var usable: bool = id is String and available.has(id) and DmAbilities.unlock_level(id) <= level
		picked.append(id if usable else null)
	for i in SLOTS:
		if picked[i] != null and picked.find(picked[i]) != i:
			picked[i] = null
	var out: Array = []
	for i in SLOTS:
		if picked[i] != null:
			out.append(picked[i])
			continue
		var fallback: Variant = null
		if i < defaults.size() and defaults[i] != null and not picked.has(defaults[i]):
			fallback = defaults[i]
		if fallback == null:
			for g in available:
				if DmAbilities.unlock_level(g) <= level and not picked.has(g):
					fallback = g
					break
		if fallback == null:
			for g in available:
				if not picked.has(g):
					fallback = g
					break
		picked[i] = fallback
		out.append(fallback)
	return out


static func sanitize_primary(raw: Variant, level: float, kit: Dictionary) -> String:
	if raw is String and (kit["primaries"] as Array).has(raw) and DmAbilities.unlock_level(raw) <= level:
		return raw
	return kit["defaultPrimary"]


static func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## {primary, keys}
static func load_rites(character_id: int, level: float, kit: Dictionary, persist: bool = true) -> Dictionary:
	var v: Variant = _read(FILE % character_id) if persist else null
	if v is Dictionary:
		return {"primary": sanitize_primary(v.get("primary"), level, kit), "keys": sanitize_loadout(v.get("keys"), level, kit)}
	return {"primary": kit["defaultPrimary"], "keys": sanitize_loadout(null, level, kit)}


static func save_rites(character_id: int, rites: Dictionary, persist: bool = true) -> void:
	if not persist:
		return
	var f := FileAccess.open(FILE % character_id, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"primary": rites["primary"], "keys": rites["keys"]}))


static func assign_rite(loadout: Array, slot: int, id: String) -> Array:
	var nxt := loadout.duplicate()
	var from := nxt.find(id)
	if from == slot:
		return nxt
	if from >= 0:
		nxt[from] = nxt[slot]
	nxt[slot] = id
	return nxt


static func load_seen(character_id: int, rites: Dictionary, kit: Dictionary, persist: bool = true) -> Dictionary:
	var seen := {}
	var raw: Variant = _read(SEEN_FILE % character_id) if persist else null
	if raw is Array:
		for x in raw:
			if x is String:
				seen[x] = true
	for id in assignable_rites(kit) + kit["primaries"]:
		if DmAbilities.unlock_level(id) <= 1:
			seen[id] = true
	seen[rites["primary"]] = true
	for id in rites["keys"]:
		if DmAbilities.unlock_level(id) <= 1:
			seen[id] = true
	return seen


static func save_seen(character_id: int, seen: Dictionary, persist: bool = true) -> void:
	if not persist:
		return
	var f := FileAccess.open(SEEN_FILE % character_id, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(seen.keys()))


static func unseen_rites(seen: Dictionary, level: float, kit: Dictionary) -> Array:
	var out: Array = []
	for id in kit["primaries"] + assignable_rites(kit):
		if DmAbilities.unlock_level(id) <= level and not seen.has(id) and not out.has(id):
			out.append(id)
	return out

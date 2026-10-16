class_name DmGuidanceMemory
extends RefCounted
## Port of the `Guidance` class in archive/legacy-web:src/gameplay/guidance.ts: what this character has met and heard, plus this session's "already told you" set.
## The web keeps it in browser storage (dm_guidance_v1:<characterId>). Here `storage_path` (e.g. "user://dm_guidance_<id>.json", empty = memory only)
## is read on init and written on every change; or use to_dict()/from_dict() and store it with the rest of the local save.

var met_npcs: Array = []
var heard: Array = []
var seen: Array = []
var storage_path := ""
var _session := {}


func _init(path: String = "") -> void:
	storage_path = path
	if path != "" and FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			from_dict(parsed)


func to_dict() -> Dictionary:
	return {"v": 1, "met": met_npcs.duplicate(), "heard": heard.duplicate(), "seen": seen.duplicate()}


## loadMemory: unknown npc ids and non-strings are dropped.
func from_dict(v: Dictionary) -> void:
	var strs := func(a: Variant) -> Array:
		var out: Array = []
		if a is Array:
			for x in a:
				if x is String:
					out.append(x)
		return out
	var known := func(a: Variant) -> Array:
		var out: Array = []
		for x in strs.call(a):
			if DmGuidance.NPC_IDS.has(x):
				out.append(x)
		return out
	met_npcs = known.call(v.get("met"))
	heard = strs.call(v.get("heard"))
	seen = known.call(v.get("seen"))


func _save() -> void:
	if storage_path == "":
		return
	var f := FileAccess.open(storage_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(to_dict()))


func met(npc: String) -> bool:
	return met_npcs.has(npc)


## Unheard news for one person.
func unheard(npc: String, s: Dictionary) -> Array:
	var out: Array = []
	for n: Dictionary in DmGuidance.news_for(npc, s):
		var k := "%s:%s" % [npc, n["key"]]
		if (not heard.has(k)) if n["persist"] else (not _session.has(k)):
			out.append(n)
	return out


## The "!" over their head: they have something they have not said yet. A stranger always has a welcome.
func has_something_new(npc: String, s: Dictionary) -> bool:
	return not met(npc) or unheard(npc, s).size() > 0


## They talk: remember you met, and that the current news was told.
func told(npc: String, s: Dictionary) -> void:
	if not met_npcs.has(npc):
		met_npcs.append(npc)
	for n: Dictionary in DmGuidance.news_for(npc, s):
		var k := "%s:%s" % [npc, n["key"]]
		if n["persist"]:
			if not heard.has(k):
				heard.append(k)
		else:
			_session[k] = true
	_save()


func heard_topic(npc: String, topic: String) -> bool:
	return heard.has("topic:%s:%s" % [npc, topic])


func hear_topic(npc: String, topic: String) -> void:
	var k := "topic:%s:%s" % [npc, topic]
	if heard.has(k):
		return
	heard.append(k)
	_save()


## First sight of a person (for the counsel tip). Returns true once.
func first_sight(npc: String) -> bool:
	if seen.has(npc):
		return false
	seen.append(npc)
	_save()
	return true

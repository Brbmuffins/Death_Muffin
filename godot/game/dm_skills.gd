class_name DmSkills
extends RefCounted
## Port of `Skills` in archive/legacy-web:src/gameplay/Gathering.ts: levels per skill (server truth from /api/professions and every /api/gather reply)
## plus the XP shown optimistically but not yet confirmed by the server. Profession rows are Dictionaries
## {profession_id, skill_level, skill_xp} (the server's shape). TS `onChange(fn)` = the `changed` signal.

signal changed

## The dev-access overlay (TS devAccess.active): gate_level() answers LEVEL_CAP. Set by the host; never saved.
var dev_access := false

var _levels: Dictionary = {}    # skill -> {level, xp}
## Optimistic XP per skill since the last reply (display only).
var _pending_xp: Dictionary = {}


func _init(rows: Array = []) -> void:
	adopt(rows)


## Server rows win. Skills the server has no row for are level 1.
func adopt(rows: Array, clear_pending_for: String = "") -> void:
	for r in rows:
		var id := str(r["profession_id"])
		if not DmGathering.SKILL_IDS.has(id):
			continue
		_levels[id] = {"level": maxi(1, int(r["skill_level"])), "xp": maxi(0, int(r["skill_xp"]))}
	if clear_pending_for != "":
		_pending_xp.erase(clear_pending_for)
	changed.emit()


## {level, xp} (a copy).
func get_skill(skill: String) -> Dictionary:
	if _levels.has(skill):
		return (_levels[skill] as Dictionary).duplicate()
	return {"level": 1, "xp": 0}


func level(skill: String) -> int:
	return int(get_skill(skill)["level"])


## The level tier gates compare against: the real level, or the cap under dev access (never saved).
func gate_level(skill: String) -> int:
	return DmGathering.LEVEL_CAP if dev_access else level(skill)


## Level/XP including optimistic XP, for bars and floating text: {level, xp, next}.
func shown(skill: String) -> Dictionary:
	var p := DmGathering.add_skill_xp(get_skill(skill), int(_pending_xp.get(skill, 0)))
	return {"level": p["level"], "xp": p["xp"], "next": DmGathering.xp_to_next(int(p["level"]))}


func add_pending(skill: String, xp: int) -> void:
	_pending_xp[skill] = int(_pending_xp.get(skill, 0)) + xp
	changed.emit()


func total() -> int:
	var n := 0
	for s in DmGathering.SKILL_IDS:
		n += level(s)
	return n


func rows() -> Array:
	var out: Array = []
	for s in DmGathering.SKILL_IDS:
		out.append({"profession_id": s, "skill_level": level(s), "skill_xp": int(get_skill(s)["xp"])})
	return out

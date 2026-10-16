class_name DmCoreCorpses
extends RefCounted
## The corpse field as the rites see it (the contract of today's DmCorpseField that casts use), answered by the combat core: it lays, ages and removes
## corpses and decides who wins a consume. Every call is synchronous and the consume is atomic: two casters on one corpse, one winner.
##   pick_corpse(aim, pick_r, max_range, from_pos, area)   the corpse under the cursor (else the nearest to the caster within 7 m), or null
##   corpses_in_radius(pos, r, filter, area)               nearest first (the core's order), filtered in GDScript when a filter is given
##   get_corpse(id) / consume(id, by_peer, reason) / add_corpse(...)
## Records are snapshots (DmCoreCorpse), so a rite reads what it needs BEFORE it consumes.
## `notes(id)`: a Dictionary a rite may keep on a corpse (Carrion Seed's seed); it goes away with the corpse (the core's corpse_gone event).

signal corpse_consumed(corpse_id: int, by_peer: int, reason: String)   ## from the core's event buffer, so at the end of the tick that consumed it

var _host: DmCoreHost
var _notes: Dictionary = {}        ## corpse id -> Dictionary


func _init(host: DmCoreHost) -> void:
	_host = host
	host.corpse_consumed.connect(func(id: int, by: int, reason: String) -> void: corpse_consumed.emit(id, by, reason))
	host.corpse_gone.connect(func(id: int, _reason: String) -> void: _notes.erase(id))


## The corpse `aim` points at (within `pick_r` of it and `max_range` of `from_pos`), else the nearest to `from_pos` within the fallback range; null when none.
## `area` "" = any.
func pick_corpse(aim: Vector3, pick_r: float, max_range: float, from_pos: Vector3, area := "") -> DmCoreCorpse:
	var id := int(_host.core.corpse_pick(Vector2(aim.x, aim.z), pick_r, max_range, Vector2(from_pos.x, from_pos.z), area))
	return get_corpse(id) if id != 0 else null


func corpses_in_radius(pos: Vector3, r: float, filter: Callable = Callable(), area := "", _include_echo := false) -> Array[DmCoreCorpse]:
	var out: Array[DmCoreCorpse] = []
	for id in _host.core.corpses_in_radius(Vector2(pos.x, pos.z), r, area):
		var c := get_corpse(id)
		if c != null and (not filter.is_valid() or bool(filter.call(c))):
			out.append(c)
	return out


func get_corpse(id: int) -> DmCoreCorpse:
	return DmCoreCorpse.of(_host.core.corpse_info(id))


## True for exactly one caller; false when the corpse is already gone.
func consume(id: int, by_peer: int, reason := "consumed") -> bool:
	return bool(_host.core.corpse_consume(id, by_peer, reason))


## Lays a corpse (a sacrificed thrall's, with Legion of the Unburied); returns its id.
func add_corpse(x: float, z: float, kind: String, enemy: String, elite: bool, facing: float, scale: float, area: String) -> int:
	return int(_host.core.corpse_add(Vector2(x, z), kind, enemy, elite, facing, scale, area))


func count() -> int:
	return int(_host.core.corpse_count())


## What a rite keeps on corpse `id` (an empty Dictionary at first, dropped with the corpse).
func notes(id: int) -> Dictionary:
	if not _notes.has(id):
		_notes[id] = {}
	return _notes[id]


func has_notes(id: int) -> bool:
	return _notes.has(id)

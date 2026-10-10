class_name DmCasterBudget
extends RefCounted
## Moon shadow caster budget: only the nearest enemies cast into the directional shadow map (every caster is drawn again, skinned, in that pass).
## The hero, thralls and bosses always cast (they never pass through here); corpses and spectral bodies are left as they are. Polled by DmNextPerf
## at 2 Hz, not per frame. Counts come from DmGraphicsPreset (`casters`, `casters_crowd` from CROWD_AT enemies up).

const CROWD_AT := 32
static var _d2 := PackedFloat32Array()
static var _sorted := PackedFloat32Array()
static var _list: Array = []


## `enemies`: the "dm_enemy" group. Returns how many casters were left on.
static func update(enemies: Array, fx: float, fz: float, budget: int, budget_crowd: int) -> int:
	_list.clear()
	_d2.resize(0)
	for n in enemies:
		var e := n as DmEnemy
		if e == null or e.creature == null or not e.creature.loaded:
			continue
		if e.is_in_group(&"dm_boss"):
			e.creature.set_cast_shadow(true)
			continue
		if e.sm != null and e.sm.id() == DmEnemyState.Id.DEAD:
			continue
		var p := e.global_position
		_list.append(e)
		_d2.append((p.x - fx) * (p.x - fx) + (p.z - fz) * (p.z - fz))
	var cap := budget_crowd if _list.size() >= CROWD_AT else budget
	var cut := INF
	if _list.size() > cap:
		_sorted = _d2.duplicate()
		_sorted.sort()
		cut = _sorted[cap - 1] if cap > 0 else -1.0
	var on := 0
	for i in _list.size():
		var cast: bool = _d2[i] <= cut
		(_list[i] as DmEnemy).creature.set_cast_shadow(cast)
		if cast:
			on += 1
	_list.clear()
	return on

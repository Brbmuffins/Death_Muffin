class_name DmCoreLegion
extends RefCounted
## One hero's legion as the rites see it: what today's DmThrallHost gave a cast (raise from corpses, rally, Rend, sacrifice, who is near), answered by the
## combat core. The thralls themselves live in the core (brain, formation, swing, death) and are drawn by the crowd view; a thrall is an id here, never a node,
## and `info(id)` is the core's record of it (`DmCore.thrall_info`). The numbers of a raise are still today's GDScript: `DmThralls.raise_stats / colossus_stats`
## (client/code: the rules), handed to `DmCore.raise_thrall` with the cap. The corpse contract is DmCoreCorpses' (atomic consume), so a lost race is "gone".
## Made by the caster (`DmRiteCaster.thralls()`); the hero's core id is read when it is needed (the body is registered with the core after it is made).

signal raised(thrall_id: int, corpse: DmCoreCorpse)
signal exhume_failed(why: String)                  ## no_corpse / gone / few / owner_dead

var legend: Dictionary = {"championEvery": 0.0, "thrallDeathBurst": 0.0}   ## DmLegend mods of the owner
var raised_n: int = 0                                                       ## ordinary raises so far (every Nth is a champion)

var _body: Node3D
var _game: Object                                  ## DmNextGame: core_host, area_of
var _burst_for: int = -1                           ## the core id the Legion-of-the-Unburied fraction was last given for


func _init(body: Node3D, game: Object) -> void:
	_body = body
	_game = game


func owner_id() -> int:
	return int(_body.get("core_id")) if _body != null and is_instance_valid(_body) and _body.get("core_id") != null else 0


func owner_peer() -> int:
	return int(_body.get("owner_peer")) if _body != null and is_instance_valid(_body) and _body.get("owner_peer") != null else 1


func _core() -> RefCounted:
	return (_game.get("core_host") as DmCoreHost).core


func _field() -> DmCoreCorpses:
	return (_game.get("core_host") as DmCoreHost).corpses


func _area() -> String:
	return String(_game.area_of(owner_peer())) if _game != null and _game.has_method("area_of") else ""


## The owner's worn legendaries (DmLegend.sim_legend_of). The burst fraction is the core's: it applies to the living legion and to thralls raised later.
func set_legend(l: Dictionary) -> void:
	legend = l
	_burst_for = -1
	_push_burst()


func _push_burst() -> void:
	var o := owner_id()
	if o != 0 and o != _burst_for:
		_burst_for = o
		_core().set_legion_burst(o, float(legend.get("thrallDeathBurst", 0.0)))


# ------------------------------------------------------------------------------------------------ raising (host)

## Raise from the corpse(s) near `aim` (the rite's aim point). intent = the sim's exhume intent {kind, cap, hp, damage, attackSpeedMult, allyHeal?,
## count? (Mass Grave), colossus?, r?}. Returns {ok, thralls: Array[int] (the new thralls' ids), crumbled: Array[int], why}. A second concurrent raise on the
## same corpse fails ("gone"): the consume is atomic.
func raise(intent: Dictionary, aim: Vector3) -> Dictionary:
	if not _owner_alive():
		return _fail("owner_dead")
	_push_burst()
	if bool(intent.get("colossus", false)):
		return _raise_colossus(intent, aim)
	var MG: Dictionary = DmRunes.T()["massGrave"]
	var EX: Dictionary = DmSimData.ABILITIES["exhume"]
	var count := int(maxf(1.0, minf(float(MG["count"]), floorf(float(intent.get("count", 1))))))
	var field := _field()
	var got: Array[DmCoreCorpse] = []
	if count == 1:
		var c := field.pick_corpse(aim, float(EX["radius"]), float(EX["range"]), _body.global_position, _area())
		if c == null:
			return _fail("no_corpse")
		if not field.consume(c.id, owner_peer(), "consumed"):
			return _fail("gone")
		got.append(c)
	else:
		for c in field.corpses_in_radius(aim, maxf(float(intent.get("r", 0.8)), float(MG["pickRadius"])), Callable(), _area()).slice(0, count):
			if field.consume(c.id, owner_peer(), "consumed"):
				got.append(c)
		if got.is_empty():
			return _fail("no_corpse")
	var mult := float(MG["statMult"]) if got.size() > 1 else 1.0
	var out := {"ok": true, "thralls": [], "crumbled": []}
	for c in got:
		raised_n += 1
		var st := DmThralls.raise_stats(intent, _rec(c), mult, raised_n, float(legend.get("championEvery", 0.0)))
		var id := int(_core().raise_thrall(st, owner_id(), Vector2(c.x, c.z), c.facing, float(intent["cap"])))
		out["crumbled"].append_array(_core().last_crumbled())
		if id != 0:
			out["thralls"].append(id)
			raised.emit(id, c)
	return out


func _raise_colossus(intent: Dictionary, aim: Vector3) -> Dictionary:
	var C: Dictionary = DmRunes.T()["colossus"]
	var r := minf(float(C["pickRadius"]), maxf(0.2, float(intent.get("r", C["pickRadius"]))))
	var field := _field()
	var near: Array = field.corpses_in_radius(aim, r, Callable(), _area()).slice(0, int(C["corpses"]))
	if near.size() < int(C["minCorpses"]):
		return _fail("few")
	var used: Array = []
	var recs: Array = []
	var sx := 0.0
	var sz := 0.0
	for c: DmCoreCorpse in near:
		if field.consume(c.id, owner_peer(), "consumed"):
			used.append(c)
			recs.append(_rec(c))
			sx += c.x
			sz += c.z
	if used.size() < int(C["minCorpses"]):
		return _fail("few")   # lost a race for some of them; the ones taken are gone
	var st := DmThralls.colossus_stats(intent, recs)   # an older Colossus is replaced, and the cap made room for, inside the core
	st["kind"] = "colossus"
	var id := int(_core().raise_thrall(st, owner_id(), Vector2(sx / used.size(), sz / used.size()), float((used[0] as DmCoreCorpse).facing), float(intent["cap"])))
	var out := {"ok": true, "thralls": [], "crumbled": Array(_core().last_crumbled())}
	if id != 0:
		out["thralls"].append(id)
		raised.emit(id, used[0])
	return out


## A corpse as the plain dictionary DmThralls wants.
func _rec(c: DmCoreCorpse) -> Dictionary:
	return {"id": c.id, "pos": Vector3(c.x, 0.0, c.z), "kind": c.kind, "enemy": c.enemy, "elite": c.elite, "facing": c.facing}


## Bonded Dead boon: one thrall at the owner's feet when the legion is empty; no corpse needed.
func raise_bonded(intent: Dictionary) -> Dictionary:
	if not _owner_alive() or count() > 0:
		return _fail("owner_dead" if not _owner_alive() else "not_empty")
	_push_burst()
	raised_n += 1
	var st := DmThralls.raise_stats(intent, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, raised_n, float(legend.get("championEvery", 0.0)))
	var p := _body.global_position
	var id := int(_core().raise_thrall(st, owner_id(), Vector2(p.x, p.z), 0.0, float(intent["cap"])))
	return {"ok": id != 0, "thralls": [id] if id != 0 else [], "crumbled": []}


func _fail(why: String) -> Dictionary:
	exhume_failed.emit(why)
	return {"ok": false, "why": why, "thralls": [], "crumbled": []}


func _owner_alive() -> bool:
	return _body != null and is_instance_valid(_body) and owner_id() != 0 and not (_body.has_method("dm_alive") and not _body.dm_alive())


# ------------------------------------------------------------------------------------------------ queries (rites, HUD)

## The owner's thralls that are not dead (a rising one counts), in raise order: ids.
func list() -> PackedInt32Array:
	var core := _core()
	var me := owner_id()
	var ids: PackedInt32Array = core.thrall_ids()
	var owners: PackedInt32Array = core.thrall_owners()
	var states: PackedInt32Array = core.thrall_states()
	var out := PackedInt32Array()
	for i in ids.size():
		if owners[i] == me and states[i] != DmCoreEvents.ThrallState.DEAD:
			out.append(ids[i])
	return out


## Those that can act: not rising, not dead.
func active() -> PackedInt32Array:
	var core := _core()
	var me := owner_id()
	var ids: PackedInt32Array = core.thrall_ids()
	var owners: PackedInt32Array = core.thrall_owners()
	var states: PackedInt32Array = core.thrall_states()
	var out := PackedInt32Array()
	for i in ids.size():
		if owners[i] == me and states[i] != DmCoreEvents.ThrallState.DEAD and states[i] != DmCoreEvents.ThrallState.RISING:
			out.append(ids[i])
	return out


func count() -> int:
	return int(_core().thrall_count(owner_id()))


func places_used() -> float:
	return float(_core().thrall_places(owner_id()))


## The core's record of thrall `id` (an empty Dictionary when it is gone): kind, state, hp, max_hp, damage, pos, target, rally_t, cursed_t ...
func info(id: int) -> Dictionary:
	return _core().thrall_info(id)


## The owner's thralls whose centre is within `r` of `pos` (rising ones too, the dead not): ids in raise order.
func near(pos: Vector3, r: float) -> PackedInt32Array:
	return _core().thralls_in_radius(Vector2(pos.x, pos.z), r, owner_id())


## Black Litany / sacrifice: kills `n` (-1 = all) thralls with reason "sacrificed", returns their stats [{kind, maxHp, damage, pos, yaw}].
func sacrifice(n: int = -1) -> Array:
	return _core().sacrifice_thralls(owner_id(), n)


func kill(id: int, reason: String) -> bool:
	return bool(_core().kill_thrall(id, reason))


## Rally the Dead: every thrall heals, hastens and (when given) turns on enemy `focus` (the core clamps the time).
func rally(secs: float, focus: int = 0) -> void:
	_core().rally_thralls(owner_id(), secs, focus)


## Command: Rend (signature "rend"): the legion leaps to a ring around `point`, cleaves, pays hp. Returns the enemies hit; `leaps` (optional)
## receives [from_x, from_z, to_x, to_z] per thrall for the visuals. A thrall's blow carries the thrall as its source.
func command_rend(point: Vector3, leaps: Array = []) -> int:
	var R: Dictionary = DmSimData.SIGNATURE["rend"]
	var core := _core()
	var legion := active()
	var hit := {}
	var i := 0
	for id in legion:
		var t: Dictionary = core.thrall_info(id)
		var ang := float(i) / float(maxi(1, legion.size())) * TAU
		i += 1
		var from: Vector2 = t["pos"]
		var to := Vector2(point.x + cos(ang) * 1.2, point.z + sin(ang) * 1.2)
		core.set_thrall_pos(id, to)
		leaps.append([from.x, from.y, to.x, to.y])
		core.set_thrall_stats(id, {"hp": maxf(1.0, float(t["hp"]) - float(t["max_hp"]) * float(R["hpCost"])), "attackCd": 0.2})
		core.set_thrall_target(id, 0)
		var dmg := float(t["damage"]) * float(R["damageMult"]) * (float(DmSimData.HAG_HEX["thrallDamageMult"]) if float(t["cursed_t"]) > 0.0 else 1.0)
		for eid in core.enemies_in_radius(to, float(R["cleaveRadius"])):
			core.damage(eid, dmg, id)
			hit[eid] = true
	return hit.size()


## A purchase refreshes standing thralls (DmThralls.apply_refresh); health keeps its fraction.
func refresh(hp_mult: float, damage_mult: float, speed_mult: float) -> void:
	var core := _core()
	for id in list():
		var t: Dictionary = core.thrall_info(id)
		var r := DmThralls.apply_refresh({"hp": t["hp"], "maxHp": t["max_hp"], "damage": t["damage"], "attackInterval": t["interval"]}, hp_mult, damage_mult, speed_mult)
		core.set_thrall_stats(id, r)


## Recall: every thrall to the owner's side.
func recall() -> void:
	_core().recall_thralls(owner_id())


func clear(reason: String = "crumbled") -> void:
	for id in list():
		_core().kill_thrall(id, reason)

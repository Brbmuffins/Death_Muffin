class_name DmThrallHost
extends Node
## One player's legion, host-side (REBUILD D1). Raises thralls from corpses, enforces the legion cap, deals formation seats, answers
## rally / commands / queries, and builds / applies replication snapshots. Solo is the same path (host == the only player).
##
## Corpse contract = the real DmCorpseField (godot/next/corpses): `pick_corpse(aim, pick_r, max_range, from_pos, area) -> DmSimCorpse|null`,
## `consume(id, by_peer, reason) -> bool` (atomic, true for one caller), `corpses_in_radius(pos, r, filter, area, include_echo) -> Array[DmSimCorpse]`.
## Integration: `DmThrallHost.attach(body, game)` once per player body on EVERY peer (same NodePath); it replicates itself over RPC.

signal raised(thrall: DmThrall, corpse: Dictionary)
signal thrall_died(thrall: DmThrall, reason: String)
signal exhume_failed(why: String)                  ## no_corpse / gone / few / owner_dead

const SCENES := {
	"warrior": preload("res://next/thralls/warrior.tscn"), "shieldbearer": preload("res://next/thralls/shieldbearer.tscn"),
	"hound": preload("res://next/thralls/hound.tscn"), "wraith": preload("res://next/thralls/wraith.tscn"),
	"archer": preload("res://next/thralls/archer.tscn"), "bonemage": preload("res://next/thralls/bonemage.tscn"),
	"plaguebearer": preload("res://next/thralls/plaguebearer.tscn"), "colossus": preload("res://next/thralls/colossus.tscn"),
}
static var _ids: int = 0

var owner_peer: int = 1
var owner_body: Node3D
var corpses: Object                                 ## the corpse field (contract above)
var game: Node                                      ## DmNextGame (area_of); optional
var world: Node                                     ## thralls are added here (default: this host's parent)
var legend: Dictionary = {"championEvery": 0.0, "thrallDeathBurst": 0.0}   ## DmLegend mods of the owner
var legion_id: String = ""                          ## owner's discipline id (look)
var kit: Dictionary = {}                            ## owner's legion kit (look)
var net_authority: int = 1                          ## tests: a puppet host uses 2
var raised_n: int = 0
var _list: Array[DmThrall] = []
var _by_id: Dictionary = {}
var _dead_out: Array = []
var _net_t: float = 0.0
var _full_t: float = 0.0                           ## deaths not yet sent in a snapshot


func _ready() -> void:
	DmSimData.ensure()
	DmThrall.warm()
	set_multiplayer_authority(net_authority)


## Soft body separation between this legion's thralls (the sim's separate(): radius 0.4 each, they yield to each other). Only computes
## a push velocity per thrall (no transform writes: those cost ~4 ms per tick for 12 bodies); the thrall folds it into its own move.
func _physics_process(dt: float) -> void:
	if not is_multiplayer_authority():
		return
	_replicate(dt)
	var n := _list.size()
	for t in _list:
		t.sep_v = Vector3.ZERO
	for i in n:
		var a := _list[i]
		if a.state == DmThrall.S.DEAD or a.state == DmThrall.S.RISING:
			continue
		var ap := a.global_position
		for j in range(i + 1, n):
			var b := _list[j]
			var bp := b.global_position
			var dx := bp.x - ap.x
			var dz := bp.z - ap.z
			var mn := a.radius + b.radius
			var d2 := dx * dx + dz * dz
			if d2 >= mn * mn or d2 < 1e-8 or b.state == DmThrall.S.DEAD or b.state == DmThrall.S.RISING:
				continue
			var k := (mn - sqrt(d2)) * 6.0 / sqrt(d2)
			a.sep_v -= Vector3(dx, 0.0, dz) * k
			b.sep_v += Vector3(dx, 0.0, dz) * k


## The one integration call: a host on `body` (a DmHeroBody), on EVERY peer, same name/path, right after the body spawns. Thralls live under `game`.
## The rites call `body.get_node("Thralls").raise(intent, aim)`; everything else (replication, statuses, formation) is internal.
static func attach(body: Node3D, game: Node) -> DmThrallHost:
	var h := DmThrallHost.new()
	h.name = "Thralls"
	h.owner_body = body
	var op: Variant = body.get("owner_peer")
	h.owner_peer = int(op) if op != null else 1
	h.corpses = game.get("corpses")
	h.game = game
	h.world = game
	body.add_child(h)
	return h


# ------------------------------------------------------------------------------------------------ raising (host)

## Raise from the corpse(s) near `aim` (the rite's aim point). intent = the sim's exhume intent {kind, cap, hp, damage, attackSpeedMult, allyHeal?,
## count? (Mass Grave), colossus?, r?}. Returns {ok, thralls: Array[DmThrall], crumbled: Array[int], why}. A second concurrent raise on the same
## corpse fails ("gone"): consume() is atomic.
func raise(intent: Dictionary, aim: Vector3) -> Dictionary:
	if not _owner_alive():
		return _fail("owner_dead")
	if bool(intent.get("colossus", false)):
		return _raise_colossus(intent, aim)
	var MG: Dictionary = DmRunes.T()["massGrave"]
	var EX: Dictionary = DmSimData.ABILITIES["exhume"]
	var count := int(maxf(1.0, minf(float(MG["count"]), floorf(float(intent.get("count", 1))))))
	var got: Array = []
	if count == 1:
		var c: Object = corpses.pick_corpse(aim, float(EX["radius"]), float(EX["range"]), owner_body.global_position, _area())
		if c == null:
			return _fail("no_corpse")
		var rec := _rec(c)   # read before consuming
		if not corpses.consume(rec["id"], owner_peer, "consumed"):
			return _fail("gone")
		got.append(rec)
	else:
		for c in corpses.corpses_in_radius(aim, maxf(float(intent.get("r", 0.8)), float(MG["pickRadius"])), Callable(), _area()).slice(0, count):
			var rec := _rec(c)
			if corpses.consume(rec["id"], owner_peer, "consumed"):
				got.append(rec)
		if got.is_empty():
			return _fail("no_corpse")
	var mult := float(MG["statMult"]) if got.size() > 1 else 1.0
	var out := {"ok": true, "thralls": [], "crumbled": []}
	for c in got:
		out["crumbled"].append_array(_make_room(float(intent["cap"]), 1.0))
		raised_n += 1
		var st := DmThralls.raise_stats(intent, c, mult, raised_n, float(legend.get("championEvery", 0.0)))
		var t := _spawn(st, c["pos"], float(c["facing"]))
		out["thralls"].append(t)
		raised.emit(t, c)
	return out


func _raise_colossus(intent: Dictionary, aim: Vector3) -> Dictionary:
	var C: Dictionary = DmRunes.T()["colossus"]
	var r := minf(float(C["pickRadius"]), maxf(0.2, float(intent.get("r", C["pickRadius"]))))
	var near: Array = corpses.corpses_in_radius(aim, r, Callable(), _area()).slice(0, int(C["corpses"]))
	if near.size() < int(C["minCorpses"]):
		return _fail("few")
	var used: Array = []
	var sx := 0.0
	var sz := 0.0
	for c in near:
		var rec := _rec(c)
		if corpses.consume(rec["id"], owner_peer, "consumed"):
			used.append(rec)
			sx += rec["pos"].x
			sz += rec["pos"].z
	if used.size() < int(C["minCorpses"]):
		return _fail("few")   # lost a race for some of them; the ones taken are gone
	for old in _list.duplicate():
		if old.kind == "colossus":
			old.kill("crumbled")
	var crumbled := _make_room(float(intent["cap"]), float(C["slots"]))
	var st := DmThralls.colossus_stats(intent, used)
	st["kind"] = "colossus"
	var t := _spawn(st, Vector3(sx / used.size(), 0.0, sz / used.size()), float(used[0]["facing"]))
	raised.emit(t, used[0])
	return {"ok": true, "thralls": [t], "crumbled": crumbled}


## A DmSimCorpse as the plain dictionary DmThralls wants.
func _rec(c: Object) -> Dictionary:
	return {"id": c.id, "pos": Vector3(c.x, 0.0, c.z), "kind": c.kind, "enemy": c.enemy, "elite": c.elite, "facing": c.facing}


func _area() -> String:
	return String(game.area_of(owner_peer)) if game != null and game.has_method("area_of") else ""


## Bonded Dead boon: one thrall at the owner's feet when the legion is empty; no corpse needed.
func raise_bonded(intent: Dictionary) -> Dictionary:
	if not _owner_alive() or not _list.is_empty():
		return _fail("owner_dead" if not _owner_alive() else "not_empty")
	raised_n += 1
	var st := DmThralls.raise_stats(intent, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, raised_n, float(legend.get("championEvery", 0.0)))
	var t := _spawn(st, owner_body.global_position, 0.0)
	return {"ok": true, "thralls": [t], "crumbled": []}


func _fail(why: String) -> Dictionary:
	exhume_failed.emit(why)
	return {"ok": false, "why": why, "thralls": [], "crumbled": []}


func _owner_alive() -> bool:
	return owner_body != null and is_instance_valid(owner_body) and not (owner_body.has_method("dm_alive") and not owner_body.dm_alive())


## Oldest ordinary thrall crumbles first, a Colossus last (DmThralls.make_room). Returns the crumbled ids.
func _make_room(cap: float, weight: float) -> Array:
	var owned: Array = []
	for t in _list:
		owned.append({"id": t.id, "kind": t.kind, "bornAt": t.born_at})
	var ids := DmThralls.make_room(owned, cap, weight)
	for i in ids:
		_by_id[i].kill("crumbled")
	return ids


func _spawn(st: Dictionary, pos: Vector3, yaw: float) -> DmThrall:
	_ids += 1
	var d := st.duplicate()
	d["id"] = _ids
	d["owner_peer"] = owner_peer
	d["slot"] = _next_slot()
	d["legion"] = legion_id
	d["pos"] = Vector3(pos.x, 0.0, pos.z)
	d["yaw"] = yaw
	return _add(d, true)


func _add(d: Dictionary, brain: bool) -> DmThrall:
	var t: DmThrall = SCENES[String(d["kind"])].instantiate()
	t.name = "Thrall_%d" % int(d["id"])   # same NodePath on every peer (the status set replicates by path)
	t.kit = kit
	t.configure(d)
	t.born_at = float(t.id)   # ordering only (oldest crumbles first)
	if brain:
		t.owner_node = owner_body
		t.death_burst_frac = float(legend.get("thrallDeathBurst", 0.0))
	t.set_multiplayer_authority(net_authority)
	t.died.connect(_on_died)
	_list.append(t)
	_by_id[t.id] = t
	(world if world != null else get_parent()).add_child(t)
	DmStatusSet.attach(t)   # every peer (replicated visuals); brain peers write speed_mult / attack_rate_mult through it
	_reform()
	return t


func _next_slot() -> int:
	var used := {}
	for t in _list:
		used[t.slot] = true
	var s := 0
	while used.has(s):
		s += 1
	return s


func _on_died(t: DmThrall) -> void:
	_list.erase(t)
	_by_id.erase(t.id)
	_dead_out.append({"id": t.id, "s": t.get_net_state()})
	_reform()
	thrall_died.emit(t, t.dead_reason)


## Deal formation seats: rank by slot among the living.
func _reform() -> void:
	var n := _list.size()
	for t in _list:
		var rank := 0
		for o in _list:
			if o.slot < t.slot:
				rank += 1
		t.formation_rank = rank
		t.formation_count = n


# ------------------------------------------------------------------------------------------------ queries / hooks (rites, HUD)

func list() -> Array[DmThrall]:
	return _list

func count() -> int:
	return _list.size()

func places_used() -> float:
	var u := 0.0
	for t in _list:
		u += DmThralls.weight(t.kind)
	return u

func by_id(i: int) -> DmThrall:
	return _by_id.get(i)

func near(pos: Vector3, r: float) -> Array[DmThrall]:
	var out: Array[DmThrall] = []
	for t in _list:
		if Vector2(t.global_position.x - pos.x, t.global_position.z - pos.z).length() <= r:
			out.append(t)
	return out


## Rally the Dead: every thrall heals + hastens + (when given) turns on `focus`.
func rally(secs: float, focus: Node3D = null) -> void:
	var RL: Dictionary = DmSimData.RALLY
	var s := minf(float(RL["durationS"]) + float(RL["gravecallerBonusS"]), maxf(float(RL["durationS"]), secs))
	for t in _list:
		if t.state != DmThrall.S.RISING:
			t.rally(s, focus)


## Command: Rend (signature "rend"): the legion leaps to a ring around `point`, cleaves, pays hp. Returns the enemies hit; `leaps` (optional)
## receives [from_x, from_z, to_x, to_z] per thrall for the visuals.
func command_rend(point: Vector3, leaps: Array = []) -> int:
	var R: Dictionary = DmSimData.SIGNATURE["rend"]
	var legion: Array[DmThrall] = []
	for t in _list:
		if t.state != DmThrall.S.RISING:
			legion.append(t)
	var hit := {}
	var i := 0
	for t in legion:
		var ang := float(i) / float(maxi(1, legion.size())) * TAU
		i += 1
		var from := t.global_position
		t.global_position = Vector3(point.x + cos(ang) * 1.2, 0.0, point.z + sin(ang) * 1.2)
		leaps.append([from.x, from.z, t.global_position.x, t.global_position.z])
		t.hp = maxf(1.0, t.hp - t.max_hp * float(R["hpCost"]))
		t.attack_cd = 0.2
		t.target = null
		var dmg := t.damage * float(R["damageMult"]) * (float(DmSimData.HAG_HEX["thrallDamageMult"]) if t.cursed_t > 0.0 else 1.0)
		for n in t.get_tree().get_nodes_in_group(&"dm_enemy"):
			var e := n as DmEnemy
			if e.sm.id() != DmEnemyState.Id.DEAD and Vector2(e.global_position.x - t.global_position.x, e.global_position.z - t.global_position.z).length() <= float(R["cleaveRadius"]) + e.radius:
				DmStatusSet.hit(e, dmg, t)
				hit[e.get_instance_id()] = true
	return hit.size()


## Black Litany / sacrifice: kills `n` (-1 = all) thralls with reason "sacrificed", returns their stats [{kind, ...}].
func sacrifice(n: int = -1) -> Array:
	var out: Array = []
	for t in _list.duplicate():
		if n >= 0 and out.size() >= n:
			break
		out.append({"kind": t.kind, "maxHp": t.max_hp, "damage": t.damage})
		t.kill("sacrificed")
	return out


## A purchase refreshes standing thralls (DmThralls.apply_refresh); health keeps its fraction.
func refresh(hp_mult: float, damage_mult: float, speed_mult: float) -> void:
	for t in _list:
		var r := DmThralls.apply_refresh({"hp": t.hp, "maxHp": t.max_hp, "damage": t.damage, "attackInterval": t.interval}, hp_mult, damage_mult, speed_mult)
		t.hp = r["hp"]
		t.max_hp = r["maxHp"]
		t.damage = r["damage"]
		t.interval = r["attackInterval"]


## Recall: every thrall to the owner's side (the sim's recallThralls).
func recall() -> void:
	for t in _list:
		t.global_position = owner_body.global_position + Vector3(sin(float(t.slot)), 0.0, cos(float(t.slot)))
		t.target = null


func clear(reason: String = "crumbled") -> void:
	for t in _list.duplicate():
		t.kill(reason)


# ------------------------------------------------------------------------------------------------ replication

## Host: one entry per living thrall {id, s: net_state, i: spawn_info (only when `full`)}. Send full on join / ~1 Hz, partial at 10-20 Hz.
## A thrall that died since the last snapshot is sent once more with state DEAD (clients play the death and forget it).
func snapshot(full: bool = false) -> Array:
	var out: Array = []
	for t in _list:
		var e := {"id": t.id, "s": t.get_net_state()}
		if full:
			e["i"] = t.spawn_info()
		out.append(e)
	out.append_array(_dead_out)
	_dead_out.clear()
	return out


## Client: create / update puppets from a snapshot. `full` snapshots also remove puppets they no longer list.
func apply_snapshot(snap: Array, full: bool = false) -> void:
	var seen := {}
	for e: Dictionary in snap:
		var i := int(e["id"])
		seen[i] = true
		var t: DmThrall = _by_id.get(i)
		if t == null:
			if not e.has("i"):
				continue
			t = _add(e["i"], false)
		t.apply_net_state(e["s"])
		if t.state == DmThrall.S.DEAD:
			_list.erase(t)
			_by_id.erase(i)
	if full:
		for t in _list.duplicate():
			if not seen.has(t.id):
				t.apply_net_state({"pos": t.global_position, "yaw": t.rotation.y, "state": DmThrall.S.DEAD, "hp": 0.0, "swing": t.swing_n, "aim": t.aim, "rally": false, "why": "crumbled"})
				_list.erase(t)
				_by_id.erase(t.id)


# ------------------------------------------------------------------------------------------------ wire (host -> clients, 15 Hz + full 1 Hz)

func _replicate(dt: float) -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.get_peers().is_empty() or (_list.is_empty() and _dead_out.is_empty()):
		return
	_net_t += dt
	_full_t += dt
	if _full_t >= 1.0:
		_full_t = 0.0
		_net_t = 0.0
		_rpc_snap_full.rpc(snapshot(true))
	elif _net_t >= 1.0 / 15.0:
		_net_t = 0.0
		_rpc_snap.rpc(snapshot(false))


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_snap(snap: Array) -> void:
	apply_snapshot(snap, false)


@rpc("authority", "call_remote", "reliable")
func _rpc_snap_full(snap: Array) -> void:
	apply_snapshot(snap, true)

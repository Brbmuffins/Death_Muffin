class_name DmEnemyClstAcolyte
extends DmEnemyClstCaster
## Lich Acolyte: a curse caster (see DmEnemyClstCaster) with UNBIND: a thrall of the player's that is KILLED within UNBIND.range of it is claimed
## (one acolyte per fallen thrall, each ready one in turn) and UNBIND.delayS later a Risen climbs out where it fell, on the dead's side. At most
## UNBIND.maxAlive claimed Risen alive or pending per acolyte, UNBIND.cooldownS between claims.
## The wave director owns spawning: on `unbind_rise` it spawns a "risen" at `at` and calls `adopt(risen)` so the cap counts it.

signal unbind_rise(at: Vector3, by: DmEnemyClstAcolyte)

const WATCH_S := 0.5

var unbind_cd: float = 0.0
var pending: Array = []        ## [seconds_left, Vector3] claimed falls waiting to rise
var unbound: Array = []        ## Risen adopted from this acolyte's claims
var _watch_t: float = 0.0
var _cfg: Dictionary


func _ready() -> void:
	super()
	_cfg = DmSimData.UNBIND
	_watch_t = rng.randf() * WATCH_S


func _physics_process(delta: float) -> void:
	super(delta)
	if not is_multiplayer_authority():
		return
	var sid := sm.id()
	if sid == DmEnemyState.Id.DEAD or sid == DmEnemyState.Id.RISING:
		return
	unbind_cd -= delta
	var i := pending.size() - 1
	while i >= 0:
		pending[i][0] -= delta
		if pending[i][0] <= 0.0:
			var at: Vector3 = pending[i][1]
			pending.remove_at(i)
			unbind_rise.emit(at, self)
		i -= 1
	_watch_t -= delta
	if _watch_t <= 0.0:
		_watch_t = WATCH_S
		for n in get_tree().get_nodes_in_group(&"dm_thrall"):
			if not n.died.is_connected(_on_thrall_died):
				n.died.connect(_on_thrall_died)


func _on_thrall_died(t: Node3D) -> void:
	if sm.id() == DmEnemyState.Id.DEAD or sm.id() == DmEnemyState.Id.RISING or sm.id() == DmEnemyState.Id.BURROW or unbind_cd > 0.0:
		return
	if String(t.get("dead_reason")) != "killed" or t.has_meta(&"clst_claimed") or flat_dist_to(t) > float(_cfg["range"]):
		return
	if pending.size() + _alive_unbound() >= int(_cfg["maxAlive"]):
		return
	t.set_meta(&"clst_claimed", true)
	unbind_cd = float(_cfg["cooldownS"])
	pending.append([float(_cfg["delayS"]), t.global_position])
	cue.emit(&"unbind", t.global_position, 0.0)


func _alive_unbound() -> int:
	var n := 0
	for i in range(unbound.size() - 1, -1, -1):
		var r: Variant = unbound[i]
		if not is_instance_valid(r) or (r as DmEnemy).sm.id() == DmEnemyState.Id.DEAD:
			unbound.remove_at(i)
		else:
			n += 1
	return n


func adopt(risen: DmEnemy) -> void:
	unbound.append(risen)
	risen.set_meta(&"unbound_by", self)

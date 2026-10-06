class_name DmEnemyPfHazard
extends DmEnemyHazard
## Slag Brute and Drowned Sexton: the slam brute (DmEnemyHazard) with the late-area specials.
## - `slamPool` (Slag Brute): the slam leaves a burning pool on the aim, radius = slamRadius, SLAG_POOL 4 s at 0.3 x damage per second.
## - `hook` (Drowned Sexton): a player 3.4-8.5 m out with a clear line gets the chain instead (DmStatePfHookChase): a 0.95 s wind-up telegraphed as a
##   line, then everything within 1.25 m of it (reach 8.5 + 0.6 m) takes 0.7 x damage; players are dragged 4.5 m toward the sexton and rooted
##   0.5 s. 6.5 s cooldown of its own, then the slam as usual. Its `deathCorpses` 2 (one extra risen corpse) belong to the corpse field.

var hooking: bool = false
var hook_cd: float = 0.0
var _pool: bool = false


func _ready() -> void:
	super()
	_pool = bool(def.get("slamPool", false))
	sm.changed.connect(func(prev: int, _n: int) -> void:
		if prev == DmEnemyState.Id.ATTACK:
			hooking = false)   # an interrupted chain does not turn the next slam into a hook (the sim leaves the flag set)


func _build_states() -> void:
	super()
	if bool(def.get("hook", false)):
		sm.add(DmStatePfHookChase.new(self, DmEnemyState.Id.CHASE))


func look_options() -> Dictionary:
	return DmPfUtil.look(super(), def_id)


func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		hook_cd -= delta
	super(delta)


func hook_ready(tg: Node3D, d: float) -> bool:
	var H: Dictionary = DmSimData.SEXTON_HOOK
	return attack_cd <= 0.0 and hook_cd <= 0.0 and not DmPfUtil.is_thrall(tg) and d >= float(H["minRange"]) and d <= float(H["range"]) \
		and not DmPfUtil.wall_between(self, global_position, tg.global_position)


func announce_telegraph(seconds: float) -> void:
	if hooking:
		telegraph.emit(&"hook", global_position, aim, float(DmSimData.SEXTON_HOOK["range"]), seconds)
	else:
		super(seconds)


func strike() -> void:
	if hooking:
		hooking = false
		_hook_strike()
		return
	super()
	if _pool:
		var r := slam_radius()
		DmPfUtil.ember_pool(self, aim, r, float(DmSimData.SLAG_POOL["poolS"]), damage * float(DmSimData.SLAG_POOL["poolDpsMult"]))


func on_impact_visual() -> void:
	if _pool and not hooking and not is_multiplayer_authority():
		DmPfUtil.ember_pool(self, aim, slam_radius(), float(DmSimData.SLAG_POOL["poolS"]), 0.0)


func _hook_strike() -> void:
	var H: Dictionary = DmSimData.SEXTON_HOOK
	var p := global_position
	var dir := Vector3(aim.x - p.x, 0.0, aim.z - p.z)
	var ln := dir.length()
	if ln < 0.001:
		dir = Vector3(sin(rotation.y), 0.0, cos(rotation.y))
		ln = 1.0
	var ux := dir.x / ln
	var uz := dir.z / ln
	var reach := float(H["range"]) + 0.6
	var half := float(H["halfWidth"]) + 0.3
	var dmg := DmPfUtil.blow(self) * float(H["blowMult"])
	for n in get_tree().get_nodes_in_group(TARGET_GROUP):
		var tg := n as Node3D
		if not target_valid(tg):
			continue
		var vx := tg.global_position.x - p.x
		var vz := tg.global_position.z - p.z
		var along := vx * ux + vz * uz
		if along < 0.0 or along > reach or absf(vx * uz - vz * ux) > half or DmPfUtil.wall_between(self, p, tg.global_position):
			continue
		hit_target(tg, dmg)
		if not DmPfUtil.is_thrall(tg) and target_valid(tg):
			DmPfUtil.pull(self, tg, p, float(H["pullM"]), float(H["rootMs"]) / 1000.0)
	cue.emit(&"hook", aim, float(H["range"]))


func get_net_state() -> Dictionary:
	var d := super()
	d["hk"] = hooking
	return d


func apply_net_state(d: Dictionary) -> void:
	hooking = bool(d.get("hk", false))
	super(d)

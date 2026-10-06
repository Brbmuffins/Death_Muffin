class_name DmEnemyGargoyle
extends DmEnemy
## Belfry Gargoyle (Nave, def `gargoyle`): a hovering flanker (def flying 1.1) that, with its cooldown up and the target 3.5-9 m away in plain
## sight, marks a spot under the target (telegraph "dive", dive.radius), climbs, and drops onto it when the wind-up ends; everything inside the
## radius takes a blow, then it sits grounded for 0.3 + 1.4 s. Inside bite range it just bites like a hound. See DmStateCathDive / DmStateCathDiveChase.

var diving: bool = false      ## the current swing is a dive (replicated as "dv" so puppets draw the right telegraph / clip / lift)
var _dive_clock: float = 0.0  ## seconds into the swing, for the visual lift (puppets start at net_age)
var _los := PhysicsRayQueryParameters3D.new()

func _ready() -> void:
	super()
	_los.collision_mask = LAYER_WORLD
	state_changed.connect(func(_p: int, n: int) -> void:
		if n == DmEnemyState.Id.ATTACK:
			_dive_clock = 0.0 if is_multiplayer_authority() else net_age)


func _build_states() -> void:
	super()
	sm.add(DmStateCathDiveChase.new(self, DmEnemyState.Id.CHASE))
	sm.add(DmStateCathDive.new(self, DmEnemyState.Id.ATTACK))


## No wall between the body and `p` (the sim's wall_between), at hover height so low rubble does not count.
func clear_line_to(p: Vector3) -> bool:
	_los.from = global_position + Vector3(0.0, 1.0, 0.0)
	_los.to = Vector3(p.x, global_position.y + 1.0, p.z)
	return get_world_3d().direct_space_state.intersect_ray(_los).is_empty()


func begin_attack() -> void:
	if not diving:
		super()
		return
	aim = target.global_position if target_valid(target) else global_position
	aim.y = global_position.y
	face_point(aim, 1.0)
	announce_telegraph(windup_s)


func announce_telegraph(seconds: float) -> void:
	if diving:
		telegraph.emit(&"dive", global_position, aim, float(def["dive"]["radius"]), seconds)


func strike() -> void:
	if not diving:
		super()
		return
	var r := float(def["dive"]["radius"])
	for tg in targets_within(aim, r):
		hit_target(tg, damage)
	cue.emit(&"slam", aim, r)


func play_attack(windup: float) -> void:
	if diving and creature != null:
		_anim = "dive"
		creature.play_once("dive", 1.0, windup * 1.2)
	else:
		super(windup)


## DmEntityViews: climb over the mark for the first half of the wind-up, then drop onto it; grounded (lift 0.05) while it recovers.
func _process(delta: float) -> void:
	super(delta)
	if creature == null or not diving or sm.id() != DmEnemyState.Id.ATTACK:
		return
	_dive_clock += delta
	var kk := _dive_clock / windup_s
	var lift := 0.05
	if kk < 1.0:
		lift = flying + kk * 3.0 if kk < 0.5 else (flying + 1.5) * pow(1.0 - (kk - 0.5) * 2.0, 2.0)
	$Visual.position.y = lift


func get_net_state() -> Dictionary:
	var d := super()
	d["dv"] = diving
	return d


func apply_net_state(d: Dictionary) -> void:
	diving = bool(d.get("dv", false))
	super(d)

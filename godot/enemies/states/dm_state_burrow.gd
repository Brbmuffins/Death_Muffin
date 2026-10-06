class_name DmStateBurrow
extends DmEnemyState
## Underground travel (Barrow Ghoul, def `burrow`): invisible and untouchable, tunnelling straight at the nearest target at BURROW.speed. When the
## target is within surfaceR or the tunnel budget (`burrow_left`, BURROW.travelM metres; unlimited on the first run from spawn) is spent, it
## starts an eruption (ERUPT) unless BURROW.maxPerTarget other bodies are already erupting under that target. No target: wait below.

var burrow_left: float = INF
## A tunnel that a wall stops (a Depths floor's rooms) would wait there forever on the first run (unlimited budget): a body that has made no
## headway for STUCK_S surfaces (ERUPT at the target) like one whose budget ran out.
const STUCK_S := 0.8
var _last := Vector3.ZERO
var _stuck_t := 0.0

func enter(_prev: int) -> void:
	t = 0.0
	enemy.stop()
	enemy.set_underground(true)
	_last = enemy.global_position
	_stuck_t = 0.0

func exit(_next: int) -> void:
	pass

func tick(dt: float) -> int:
	var B: Dictionary = DmSimData.BURROW
	var tg := enemy.target
	if not enemy.target_valid(tg) or enemy.scan_due(dt):
		tg = enemy.find_target(enemy.aggro_range)
		enemy.target = tg
	if tg == null:
		return -1
	var d := enemy.flat_dist_to(tg)
	if d <= float(B["surfaceR"]) or burrow_left <= 0.0:
		var busy := 0
		for n in enemy.get_tree().get_nodes_in_group(&"dm_enemy"):
			var o := n as DmEnemy
			if o != null and o != enemy and o.sm.id() == Id.ERUPT and o.target == tg:
				busy += 1
		if busy >= int(B["maxPerTarget"]):
			return -1
		return Id.ERUPT
	var moved := enemy.global_position.distance_to(_last)
	_last = enemy.global_position
	_stuck_t = _stuck_t + dt if (t > 0.3 and moved < float(B["speed"]) * dt * 0.25) else 0.0
	if _stuck_t > STUCK_S:
		return Id.ERUPT
	enemy.move_straight(tg.global_position, float(B["speed"]))
	burrow_left -= float(B["speed"]) * dt   # close enough: the body is only blocked by walls
	enemy.face_point(tg.global_position, dt)
	return -1

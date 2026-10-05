class_name DmStateFlee
extends DmEnemyState
## Hit-and-run (Tithe Bat, def hitRun): after a blow, run away from the target for `hit_run` seconds, bending sideways by the flank side, then
## come back. Reusable by any kind with a `hitRun` def field.

func enter(_prev: int) -> void:
	t = 0.0

func tick(_dt: float) -> int:
	var tg := enemy.target
	if not enemy.target_valid(tg):
		return Id.IDLE
	if t >= enemy.hit_run:
		return Id.CHASE
	var p := enemy.global_position
	var a := tg.global_position
	var d := maxf(0.001, enemy.flat_dist_to(tg))
	var perp := Vector3(-(a.z - p.z), 0.0, a.x - p.x) / d
	enemy.steer_to(p * 2.0 - a + perp * 2.0 * enemy.flank_side, 1.0)
	return -1

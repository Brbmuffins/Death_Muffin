class_name DmStateFlankChase
extends DmStateChase
## Flankers (Bone Hound, Skull-Rat, Tithe Bat): sim "flank" behaviour. Beyond 2.5 m the goal is offset sideways by min(3, dist * 0.45) on the
## body's flank side, so a pack fans out around the target instead of queuing behind it; inside 2.5 m they go straight in.

func engage(tg: Node3D, d: float, dt: float) -> int:
	if d <= enemy.attack_range + DmEnemy.ATTACK_TRIGGER_PAD and enemy.attack_cd <= 0.0:
		return Id.ATTACK
	if d > enemy.attack_range * DmEnemy.STOP_FRAC:
		var goal := tg.global_position
		if d > 2.5:
			var p := enemy.global_position
			var perp := Vector3(-(goal.z - p.z), 0.0, goal.x - p.x) / d
			goal += perp * minf(3.0, d * 0.45) * enemy.flank_side
		enemy.steer_to(goal, 1.0)
	else:
		enemy.stop()
		enemy.face_point(tg.global_position, dt)
	return -1

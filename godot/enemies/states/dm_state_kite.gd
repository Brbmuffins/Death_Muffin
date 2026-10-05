class_name DmStateKite
extends DmStateChase
## Ranged kinds (Bellbound Penitent, Shroud Moth): sim "caster" behaviour. Cast when dist <= attackRange - 0.5 and the cooldown is up; walk in
## while dist > attackRange - 1.5; back off at 0.8x speed when the target is closer than 3.5 m; otherwise stand and face it.

const BACK_OFF_DIST := 3.5
const BACK_OFF_SPEED := 0.8

func engage(tg: Node3D, d: float, dt: float) -> int:
	if d <= enemy.attack_range - 0.5 and enemy.attack_cd <= 0.0:
		return Id.ATTACK
	if d > enemy.attack_range - 1.5:
		enemy.steer_to(tg.global_position, 1.0)
	elif d < BACK_OFF_DIST:
		var p := enemy.global_position
		enemy.steer_to(p * 2.0 - tg.global_position, BACK_OFF_SPEED)
		enemy.face_point(tg.global_position, dt)
	else:
		enemy.stop()
		enemy.face_point(tg.global_position, dt)
	return -1

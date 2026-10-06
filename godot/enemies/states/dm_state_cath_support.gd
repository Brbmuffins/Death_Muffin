class_name DmStateCathSupport
extends DmStateChase
## Support caster movement (sim "support" behaviour, Crypt Deacon): curse when the cooldown is up and the target is within attackRange; walk in
## while farther than attackRange - 0.5, back off at 0.7x when closer than 4 m, otherwise stand. The corpse-raise and Sanctify triggers
## (which work with or without a target) live on the kind (DmEnemyDeacon), not here.

const BACK_OFF_DIST := 4.0
const BACK_OFF_SPEED := 0.7

func engage(tg: Node3D, d: float, dt: float) -> int:
	if enemy.attack_cd <= 0.0 and d <= enemy.attack_range and not (enemy as DmEnemyDeacon).silenced():
		return Id.ATTACK
	if d > enemy.attack_range - 0.5:
		enemy.steer_to(tg.global_position, 1.0)
	elif d < BACK_OFF_DIST:
		var p := enemy.global_position
		enemy.steer_to(p * 2.0 - tg.global_position, BACK_OFF_SPEED)
		enemy.face_point(tg.global_position, dt)
	else:
		enemy.stop()
		enemy.face_point(tg.global_position, dt)
	return -1

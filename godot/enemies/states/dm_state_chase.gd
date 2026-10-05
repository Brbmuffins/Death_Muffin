class_name DmStateChase
extends DmEnemyState
## Close on the target through the navmesh; swing when in range and the cooldown is up; drop the target and go home when it gets away.
## sim_enemy_ai melee branch: attack when dist <= attackRange + 0.35 and cd <= 0; keep walking while dist > attackRange * 0.8.

func tick(dt: float) -> int:
	var tg := enemy.target
	if not enemy.target_valid(tg):
		return Id.RETURN if enemy.should_return() else Id.IDLE
	var d := enemy.flat_dist_to(tg)
	# Leash: the target ran past aggro * 1.5 (hysteresis, so a target at the edge does not flicker) or we strayed too far from home.
	if d > enemy.aggro_range * DmEnemy.DROP_MULT or enemy.flat_dist_home() > enemy.leash_range:
		enemy.target = null
		return Id.RETURN
	if enemy.scan_due(dt):
		var nearer := enemy.find_target(enemy.aggro_range)
		if nearer != null and nearer != tg:
			enemy.target = nearer
			tg = nearer
			d = enemy.flat_dist_to(tg)
	if d <= enemy.attack_range + DmEnemy.ATTACK_TRIGGER_PAD and enemy.attack_cd <= 0.0:
		return Id.ATTACK
	if d > enemy.attack_range * DmEnemy.STOP_FRAC:
		enemy.steer_to(tg.global_position, 1.0)
	else:
		enemy.stop()
		enemy.face_point(tg.global_position, dt)
	return -1

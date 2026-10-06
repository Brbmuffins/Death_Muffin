class_name DmStatePfLureKite
extends DmStateKite
## Fen Wisp (def `lure`): the caster's kite, but when the target closes inside 3.5 m it backs off toward the open water (FEN_LURE) instead of
## straight away: heading = 0.55 x away-from-target + 0.45 x toward-the-lure, 3 m ahead, at 0.8x speed (sim_enemy_ai caster branch).

func engage(tg: Node3D, d: float, dt: float) -> int:
	if d >= BACK_OFF_DIST or d > enemy.attack_range - 1.5 or (d <= enemy.attack_range - 0.5 and enemy.attack_cd <= 0.0):
		return super(tg, d, dt)
	var p := enemy.global_position
	var dd := maxf(d, 0.001)
	var ax := (p.x - tg.global_position.x) / dd
	var az := (p.z - tg.global_position.z) / dd
	var lure := (enemy as DmEnemyPfCaster).lure_point
	var lx := lure.x - p.x
	var lz := lure.z - p.z
	var ll := maxf(sqrt(lx * lx + lz * lz), 0.001)
	var goal := Vector3(p.x + (ax * 0.55 + lx / ll * 0.45) * 3.0, p.y, p.z + (az * 0.55 + lz / ll * 0.45) * 3.0)
	enemy.steer_to(goal, BACK_OFF_SPEED)
	enemy.face_point(tg.global_position, dt)
	return -1

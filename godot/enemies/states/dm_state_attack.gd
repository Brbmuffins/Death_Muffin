class_name DmStateAttack
extends DmEnemyState
## Wind-up -> impact -> recovery, the sim's windup/recover pair. The aim is fixed at wind-up start (the telegraph), the blow lands when the
## wind-up ends if the target is within attackRange * 1.35 + 0.4 of the body (sim strike reach), the cooldown starts at impact and
## runs through the recovery, then back to chase. Damage is a whole-swing hit; only stun() or death interrupts a swing.

enum Phase { WINDUP, RECOVER }
const RECOVER_TIME := 0.3

var phase: int = Phase.WINDUP

func enter(_prev: int) -> void:
	t = 0.0
	phase = Phase.WINDUP
	enemy.stop()
	if enemy.target_valid(enemy.target):
		enemy.face_point(enemy.target.global_position, 1.0)
	enemy.play_attack(enemy.windup_s)

func tick(dt: float) -> int:
	if phase == Phase.WINDUP:
		if t >= enemy.windup_s:
			enemy.attack_cd = enemy.cooldown_s
			enemy.strike()
			phase = Phase.RECOVER
			t = 0.0
		return -1
	if t >= RECOVER_TIME:
		return Id.CHASE if enemy.target_valid(enemy.target) else Id.IDLE
	return -1

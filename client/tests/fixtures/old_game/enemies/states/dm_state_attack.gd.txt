class_name DmStateAttack
extends DmEnemyState
## Wind-up -> impact -> recovery, the sim's windup/recover pair. The aim is fixed at wind-up start (the telegraph, enemy.begin_attack), the blow
## (enemy.strike, overridable per kind) lands when the wind-up ends, the cooldown starts at impact and runs through the recovery, then
## enemy.post_attack_state() (chase, or flee for hit-and-run kinds). Damage is a whole-swing hit; only stun() or death interrupts a swing.

enum Phase { WINDUP, RECOVER }
const RECOVER_TIME := 0.3

var phase: int = Phase.WINDUP

func enter(_prev: int) -> void:
	t = 0.0
	phase = Phase.WINDUP
	enemy.stop()
	enemy.begin_attack()
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
		return enemy.post_attack_state()
	return -1

class_name DmStateEmerge
extends DmEnemyState
## 0.3 s of recovery right after a body surfaces (the sim's recover after an eruption), then it fights normally.

const RECOVER_TIME := 0.3

func enter(_prev: int) -> void:
	t = 0.0
	enemy.stop()
	enemy.play_attack(RECOVER_TIME)

func tick(_dt: float) -> int:
	if t < RECOVER_TIME:
		return -1
	return Id.CHASE if enemy.target_valid(enemy.target) else Id.IDLE

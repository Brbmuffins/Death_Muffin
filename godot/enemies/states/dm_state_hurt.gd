class_name DmStateHurt
extends DmEnemyState
## Flinch / stun. A plain hit only staggers while the enemy is idle, chasing or returning (never mid-swing: the sim never let damage cancel a
## swing, and a crowd of DoT ticks must not stun-lock a pack), and at most once per STAGGER_ICD. stun(sec) is the hard version.

var duration: float = 0.3

func enter(_prev: int) -> void:
	t = 0.0
	enemy.stop()
	enemy.play_hurt()

func tick(_dt: float) -> int:
	if t >= duration:
		return Id.CHASE if enemy.target_valid(enemy.target) else Id.IDLE
	return -1

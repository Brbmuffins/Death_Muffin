class_name DmStateReturn
extends DmEnemyState
## Leashed: walk home at full speed, ignoring targets (no kiting a robber back and forth across its leash), then idle.

func enter(_prev: int) -> void:
	t = 0.0
	enemy.target = null

func tick(_dt: float) -> int:
	if enemy.flat_dist_home() <= DmEnemy.HOME_ARRIVE:
		return Id.IDLE
	enemy.steer_to(enemy.home, 1.0)
	return -1

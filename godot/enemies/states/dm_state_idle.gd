class_name DmStateIdle
extends DmEnemyState
## No target: drift about the home point at 0.3x speed (the sim's idle wander) and scan for a target a few times a second.

func enter(_prev: int) -> void:
	t = 0.0
	enemy.target = null
	enemy.stop()

func tick(dt: float) -> int:
	if enemy.scan_due(dt):
		var tg := enemy.find_target(enemy.aggro_range)
		if tg != null:
			enemy.target = tg
			return Id.CHASE
	enemy.wander(dt)
	return -1

class_name DmStateDead
extends DmEnemyState
## Terminal. The body stops colliding and pathing, the death clip plays, the corpse lingers `corpse_s` seconds (DmEnemy frees it with a
## timer: the brain stops ticking once dead). tick() is never reached.

func enter(_prev: int) -> void:
	t = 0.0
	enemy.stop()
	enemy.on_death()

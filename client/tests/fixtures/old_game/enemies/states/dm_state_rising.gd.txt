class_name DmStateRising
extends DmEnemyState
## Spawn rise (sim RISE_TIME 1.1 s): inert while the body claws out of the ground. Skipped when the enemy spawns `rising = false`.

const RISE_TIME := 1.1

func tick(_dt: float) -> int:
	return Id.IDLE if t >= RISE_TIME else -1

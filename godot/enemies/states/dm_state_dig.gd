class_name DmStateDig
extends DmEnemyState
## Dig-in (Barrow Ghoul, the first time it falls below BURROW.digAtFrac of its hp): a BURROW.digS (0.8 s) dig animation on the surface, hittable,
## then it goes underground for BURROW.travelM metres of tunnel. Bleeds and slows are cleared by the enemy on entry (statuses live in the host
## combat code; `status_cleared` fires so it can drop them).

func enter(_prev: int) -> void:
	t = 0.0
	enemy.stop()
	enemy.play_dig(float(DmSimData.BURROW["digS"]))
	enemy.cue.emit(&"dig_in", enemy.global_position, 0.0)

func tick(_dt: float) -> int:
	if t < float(DmSimData.BURROW["digS"]):
		return -1
	enemy.statuses_cleared.emit()
	var b := enemy.sm.states[Id.BURROW] as DmStateBurrow
	b.burrow_left = float(DmSimData.BURROW["travelM"])
	return Id.BURROW

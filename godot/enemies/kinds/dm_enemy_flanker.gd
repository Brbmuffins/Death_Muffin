class_name DmEnemyFlanker
extends DmEnemy
## Flank kinds (Bone Hound, Skull-Rat, Tithe Bat): fast bodies that fan out to the target's side (DmStateFlankChase); kinds with a def `hitRun`
## (Tithe Bat) flee for that many seconds after every bite (DmStateFlee). Everything else is the base melee set.

func _build_states() -> void:
	super()
	sm.add(DmStateFlankChase.new(self, DmEnemyState.Id.CHASE))
	sm.add(DmStateFlee.new(self, DmEnemyState.Id.FLEE))

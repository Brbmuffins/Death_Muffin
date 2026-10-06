class_name DmEnemyPfMelee
extends DmEnemy
## Cinder Husk (def `emberDeath`): a plain melee body (the robber set) that bursts into a burning pool where it falls: EMBER_DEATH radius 1.6 m,
## 3 s, 0.3 x its damage per second. The pool is host-spawned and damaging; every other peer draws a visual-only copy when its own copy of the
## body dies (DmEnemyFx plays the burst, flare and sound from the same state change).

func look_options() -> Dictionary:
	return DmPfUtil.look(super(), def_id)


func on_death() -> void:
	super()
	if bool(def.get("emberDeath", false)):
		var ED: Dictionary = DmSimData.EMBER_DEATH
		DmPfUtil.ember_pool(self, global_position, float(ED["radius"]), float(ED["poolS"]), damage * float(ED["poolDpsMult"]))

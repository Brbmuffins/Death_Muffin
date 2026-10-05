class_name DmEnemyBurrower
extends DmEnemy
## Barrow Ghoul (def `burrow`): spawns underground (when `rising`), tunnels at the nearest target (DmStateBurrow), erupts under it (DmStateErupt,
## telegraphed ring, damage), then fights as a plain melee body (the robber set). The first time it drops below digAtFrac of its hp it digs
## back in (DmStateDig) for another tunnel run. Untouchable underground and while erupting. Spawned `rising = false` it just starts on the
## surface (the sim spawns non-rising ghouls in "move").

var dug_in: bool = false


func _build_states() -> void:
	super()
	sm.add(DmStateBurrow.new(self, DmEnemyState.Id.BURROW))
	sm.add(DmStateErupt.new(self, DmEnemyState.Id.ERUPT))
	sm.add(DmStateDig.new(self, DmEnemyState.Id.DIG))
	sm.add(DmStateEmerge.new(self, DmEnemyState.Id.EMERGE))


func initial_state() -> int:
	return DmEnemyState.Id.BURROW if rising else DmEnemyState.Id.IDLE


func is_hittable() -> bool:
	var s := sm.id()
	return s != DmEnemyState.Id.BURROW and s != DmEnemyState.Id.ERUPT


func take_damage(amount: float, from: Node = null, allow_stagger: bool = true) -> bool:
	var ok := super(amount, from, allow_stagger)
	if ok and not dug_in and hp > 0.0 and hp < max_hp * float(DmSimData.BURROW["digAtFrac"]):
		dug_in = true
		sm.change(DmEnemyState.Id.DIG)
	return ok


func _remote_extra(st: int) -> void:
	if st == DmEnemyState.Id.DIG:
		play_dig(float(DmSimData.BURROW["digS"]))
	elif st == DmEnemyState.Id.EMERGE:
		play_attack(DmStateEmerge.RECOVER_TIME)

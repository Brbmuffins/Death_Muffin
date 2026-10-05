class_name DmEnemyCenser
extends DmEnemy
## Censer Bearer: a melee body whose incense hastes every living enemy within CENSER.radius once a second (itself too): +30% move, +25% attack
## rate for CENSER.hasteS after the last pulse. Kill it first.

var _aura_cd: float = 0.0

func _physics_process(delta: float) -> void:
	super(delta)
	if not is_multiplayer_authority():
		return
	var sid := sm.id()
	if sid == DmEnemyState.Id.DEAD or sid == DmEnemyState.Id.RISING:
		return
	_aura_cd -= delta
	if _aura_cd > 0.0:
		return
	_aura_cd = 1.0
	var c: Dictionary = DmSimData.CENSER
	var r2 := float(c["radius"]) * float(c["radius"])
	for n in get_tree().get_nodes_in_group(&"dm_enemy"):
		var o := n as DmEnemy
		if o == null or o.sm.id() == DmEnemyState.Id.DEAD:
			continue
		var d := o.global_position - global_position
		if d.x * d.x + d.z * d.z <= r2:
			o.incense_t = maxf(o.incense_t, float(c["hasteS"]))
